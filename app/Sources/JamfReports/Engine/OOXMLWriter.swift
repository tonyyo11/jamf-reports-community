import Foundation
import ZIPFoundation

// MARK: - Errors

enum OOXMLError: Error, LocalizedError {
    case archiveCreationFailed(URL)

    var errorDescription: String? {
        switch self {
        case .archiveCreationFailed(let url):
            return "Failed to create XLSX archive at \(url.path)"
        }
    }
}

// MARK: - Cell value

/// A sanitized, formula-injection-safe cell value.
/// Mirrors the Python `_safe_write()` semantics exactly.
enum CellValue: Sendable {
    case blank
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    /// Sanitize an arbitrary value, escaping formula-injection prefixes and
    /// stripping control characters, matching the Python `_safe_write` contract.
    static func safe(_ raw: Any?) -> CellValue {
        guard let raw else { return .blank }

        switch raw {
        case let v as String:
            return sanitizeString(v)
        case let v as Int:
            return .int(v)
        case let v as Double:
            if v.isNaN || v.isInfinite { return .int(0) }
            return .double(v)
        case let v as Float:
            let d = Double(v)
            if d.isNaN || d.isInfinite { return .int(0) }
            return .double(d)
        case let v as Bool:
            return .bool(v)
        case let v as NSNumber:
            // NSNumber may box Bool, Int, Double — check in order.
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                return .bool(v.boolValue)
            }
            return .double(v.doubleValue)
        default:
            return sanitizeString(String(describing: raw))
        }
    }

    private static func sanitizeString(_ raw: String) -> CellValue {
        // Strip C0/C1 control characters, keeping only tab, LF, CR.
        let filtered = raw.unicodeScalars.filter { scalar in
            let v = scalar.value
            let isControl = (v <= 0x1F && v != 0x09 && v != 0x0A && v != 0x0D)
                || (v >= 0x7F && v <= 0x9F)
            return !isControl
        }
        // Excel cell limit: 32,767 characters.
        let s: String
        if filtered.count > 32_000 {
            s = String(String.UnicodeScalarView(filtered.prefix(32_000)))
        } else {
            s = String(String.UnicodeScalarView(filtered))
        }
        // Escape formula-injection: cells starting with =, +, -, @ get a leading tab.
        if let first = s.first, "=+-@".contains(first) {
            return .string("\t" + s)
        }
        return .string(s)
    }
}

// MARK: - Cell format

/// Named format descriptors matching the Python `_build_formats` dict.
/// The 11 formats Python uses are all represented here.
enum CellFormat: String, Sendable, CaseIterable {
    case title
    case subtitle
    case header
    case cell
    case green
    case yellow
    case red
    case pct
    case pctGreen
    case pctYellow
    case pctRed
    case date
    case int

    /// Return the numeric-format string for this format, if any.
    var numFmt: String? {
        switch self {
        case .pct, .pctGreen, .pctYellow, .pctRed: return "0.0%"
        case .date: return "yyyy-mm-dd"
        case .int: return "0"
        default: return nil
        }
    }

    var isBold: Bool { self == .title || self == .header }
    var isItalic: Bool { self == .subtitle }

    var bgColorHex: String? {
        switch self {
        case .green, .pctGreen:  return "C6EFCE"
        case .yellow, .pctYellow: return "FFEB9C"
        case .red, .pctRed:      return "FFC7CE"
        default:                  return nil
        }
    }

    var fontColorHex: String? {
        switch self {
        case .header:   return "FFFFFF"
        case .subtitle: return "595959"
        default:        return nil
        }
    }

    var hasBorder: Bool {
        switch self {
        case .title, .subtitle: return false
        default:                return true
        }
    }

    var fontSize: Int? {
        switch self {
        case .title:    return 14
        case .subtitle: return 10
        default:        return nil
        }
    }

    // Index in the workbook formats list — populated at write time.
    var formatIndex: Int { CellFormat.allCases.firstIndex(of: self) ?? 0 }
}

// MARK: - Column width / row freeze

struct ColumnWidth: Sendable {
    let first: Int
    let last: Int
    let width: Double
}

struct FreezePane: Sendable {
    let row: Int
    let col: Int
}

// MARK: - Image embed

struct ImageEmbed: Sendable {
    let row: Int
    let col: Int
    let data: Data
    let filename: String
    let xScale: Double
    let yScale: Double
}

// MARK: - Merge range

struct MergeRange: Sendable {
    let firstRow: Int
    let firstCol: Int
    let lastRow: Int
    let lastCol: Int
    let value: CellValue
    let format: CellFormat?
}

// MARK: - Worksheet builder

/// Mutable accumulator for a single Excel worksheet.
/// All operations are append-only; the final XML is emitted by `Workbook.finalize()`.
///
/// Thread safety: `@unchecked Sendable` is declared so that dashboard structs
/// (`CoreDashboard`, `CSVDashboard`, `SchoolDashboard`) — which hold a `Workbook` and
/// must themselves be `Sendable` for Swift 6 strict concurrency — can compile without
/// error. This class is NOT safe for concurrent mutation. All sheet writes within a
/// single `Workbook` must be serialized on one task or actor. Generating multiple
/// independent reports in parallel is safe because each report owns its own `Workbook`.
final class Worksheet: @unchecked Sendable {
    let name: String
    private(set) var cells: [(row: Int, col: Int, value: CellValue, format: CellFormat?)] = []
    private(set) var mergeRanges: [MergeRange] = []
    private(set) var columnWidths: [ColumnWidth] = []
    private(set) var freezePane: FreezePane? = nil
    private(set) var imageEmbeds: [ImageEmbed] = []

    init(name: String) {
        self.name = name
    }

    func write(_ value: Any?, row: Int, col: Int, format: CellFormat? = nil) {
        cells.append((row, col, .safe(value), format))
    }

    func writeBlank(row: Int, col: Int, format: CellFormat? = nil) {
        cells.append((row, col, .blank, format))
    }

    func mergeRange(
        firstRow: Int, firstCol: Int,
        lastRow: Int, lastCol: Int,
        value: Any?, format: CellFormat? = nil
    ) {
        mergeRanges.append(MergeRange(
            firstRow: firstRow, firstCol: firstCol,
            lastRow: lastRow, lastCol: lastCol,
            value: .safe(value), format: format
        ))
        cells.append((firstRow, firstCol, .safe(value), format))
    }

    func setColumnWidth(_ first: Int, _ last: Int, _ width: Double) {
        columnWidths.append(ColumnWidth(first: first, last: last, width: width))
    }

    func freezePane(row: Int, col: Int) {
        freezePane = FreezePane(row: row, col: col)
    }

    func insertImage(row: Int, col: Int, data: Data, filename: String,
                     xScale: Double = 1.0, yScale: Double = 1.0) {
        imageEmbeds.append(ImageEmbed(
            row: row, col: col, data: data, filename: filename,
            xScale: xScale, yScale: yScale
        ))
    }

    /// Cells de-duplicated by `(row, col)`, keeping the LAST write — matching
    /// `xlsxwriter`'s last-write-wins semantics. Excel rejects a worksheet that
    /// contains two `<c>` elements with the same `r` reference inside one
    /// `<row>` ("Repaired Records: Cell information"), so every consumer of the
    /// cell list must read through here rather than the raw `cells` array.
    var dedupedCells: [(row: Int, col: Int, value: CellValue, format: CellFormat?)] {
        var index: [String: Int] = [:]
        var result: [(row: Int, col: Int, value: CellValue, format: CellFormat?)] = []
        for cell in cells {
            let key = "\(cell.row)-\(cell.col)"
            if let existing = index[key] {
                result[existing] = cell
            } else {
                index[key] = result.count
                result.append(cell)
            }
        }
        return result
    }
}

// MARK: - Workbook

/// Builds an `.xlsx` file (OOXML) without any C interop.
/// Uses ZIPFoundation to assemble the ZIP archive.
///
/// Usage:
/// ```swift
/// let wb = Workbook(accentColor: "#2D5EA2")
/// let ws = wb.addSheet("Fleet Overview")
/// ws.write("Total Devices", row: 0, col: 0, format: .header)
/// ws.write(1234, row: 0, col: 1, format: .cell)
/// try wb.write(to: outputURL)
/// ```
///
/// Thread safety: `@unchecked Sendable` is declared so that dashboard structs
/// (`CoreDashboard`, `CSVDashboard`, `SchoolDashboard`) — which hold a `Workbook` and
/// must themselves be `Sendable` for Swift 6 strict concurrency — can compile without
/// error. This class is NOT safe for concurrent mutation. All sheet writes within a
/// single `Workbook` must be serialized on one task or actor. Generating multiple
/// independent reports in parallel is safe because each report owns its own `Workbook`.
final class Workbook: @unchecked Sendable {
    private var sheets: [Worksheet] = []
    let accentColor: String

    init(accentColor: String = "#2D5EA2") {
        self.accentColor = accentColor
    }

    @discardableResult
    func addSheet(_ name: String) -> Worksheet {
        let sanitized = sanitizeSheetName(name)
        let ws = Worksheet(name: sanitized)
        sheets.append(ws)
        return ws
    }

    /// Return the first worksheet whose name matches `name` (exact, after sanitization).
    func sheet(named name: String) -> Worksheet? {
        let sanitized = sanitizeSheetName(name)
        return sheets.first { $0.name == sanitized }
    }

    /// Write the workbook to `url` atomically using a temp file + `replaceItem`.
    func write(to url: URL) throws {
        let tempDir = FileManager.default.temporaryDirectory
        let tempURL = tempDir.appendingPathComponent(UUID().uuidString + ".xlsx")
        try buildZIP(at: tempURL)
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
    }

    // MARK: - Private ZIP assembly

    /// Add a pre-computed `Data` blob to a ZIPFoundation `Archive`.
    ///
    /// ZIPFoundation calls the provider repeatedly in `bufferSize`-byte chunks
    /// (16 KB by default), advancing `position` each iteration, and sums the
    /// returned bytes into the entry's compressed size. The provider MUST return
    /// only the requested slice `data[position ..< position + requested]`.
    /// Returning the whole blob on every call inflates `compressedSize` to a
    /// multiple of the real length — for a STORED entry that desynchronizes
    /// `compressedSize` from `uncompressedSize`, which Excel rejects as corrupt
    /// worksheet content even though the ZIP container still opens.
    private static func addData(_ data: Data, path: String, to archive: Archive) throws {
        let size = Int64(data.count)
        try archive.addEntry(with: path, type: .file, uncompressedSize: size) { position, requested in
            let start = Int(position)
            guard start < data.count else { return Data() }
            let end = Swift.min(start + requested, data.count)
            return data.subdata(in: start..<end)
        }
    }

    private func buildZIP(at url: URL) throws {
        let archive = try Archive(url: url, accessMode: .create)

        try Self.addData(Data(contentTypesXML().utf8), path: "[Content_Types].xml", to: archive)
        try Self.addData(Data(rootRelsXML().utf8), path: "_rels/.rels", to: archive)
        try Self.addData(Data(appXML().utf8), path: "docProps/app.xml", to: archive)
        try Self.addData(Data(workbookXML().utf8), path: "xl/workbook.xml", to: archive)
        try Self.addData(Data(workbookRelsXML().utf8), path: "xl/_rels/workbook.xml.rels", to: archive)
        try Self.addData(Data(stylesXML().utf8), path: "xl/styles.xml", to: archive)

        let (ssTable, ssXML) = buildSharedStrings()
        try Self.addData(Data(ssXML.utf8), path: "xl/sharedStrings.xml", to: archive)

        // xl/worksheets/sheet{n}.xml + embedded images
        var imageCounter = 0
        for (idx, ws) in sheets.enumerated() {
            let sheetNum = idx + 1

            var drawingRels: [(imageId: Int, filename: String)] = []
            for embed in ws.imageEmbeds {
                imageCounter += 1
                let mediaPath = "xl/media/image\(imageCounter).\(imageExtension(embed.filename))"
                try Self.addData(embed.data, path: mediaPath, to: archive)
                drawingRels.append((imageId: imageCounter, filename: embed.filename))
            }

            if !ws.imageEmbeds.isEmpty {
                let drelsXML = buildDrawingRelsXML(drawingRels)
                try Self.addData(
                    Data(drelsXML.utf8),
                    path: "xl/drawings/_rels/drawing\(sheetNum).xml.rels",
                    to: archive
                )
                let drawingXML = buildDrawingXML(ws.imageEmbeds, sheetNum: sheetNum)
                try Self.addData(
                    Data(drawingXML.utf8),
                    path: "xl/drawings/drawing\(sheetNum).xml",
                    to: archive
                )
            }

            let sheetXML = buildSheetXML(
                ws, sharedStrings: ssTable,
                hasDrawing: !ws.imageEmbeds.isEmpty,
                sheetNum: sheetNum
            )
            try Self.addData(
                Data(sheetXML.utf8),
                path: "xl/worksheets/sheet\(sheetNum).xml",
                to: archive
            )

            if !ws.imageEmbeds.isEmpty {
                let wsRelsXML = buildWorksheetRelsXML(sheetNum: sheetNum)
                try Self.addData(
                    Data(wsRelsXML.utf8),
                    path: "xl/worksheets/_rels/sheet\(sheetNum).xml.rels",
                    to: archive
                )
            }
        }
    }

    // MARK: - XML generators

    private func contentTypesXML() -> String {
        var parts = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>",
            "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">",
            "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>",
            "<Default Extension=\"xml\" ContentType=\"application/xml\"/>",
            "<Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/>",
            "<Override PartName=\"/xl/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml\"/>",
            "<Override PartName=\"/xl/sharedStrings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml\"/>",
            "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>",
        ]
        for (idx, ws) in sheets.enumerated() {
            parts.append("<Override PartName=\"/xl/worksheets/sheet\(idx+1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>")
            if !ws.imageEmbeds.isEmpty {
                parts.append("<Override PartName=\"/xl/drawings/drawing\(idx+1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.drawing+xml\"/>")
            }
        }
        parts.append("</Types>")
        return parts.joined()
    }

    private func rootRelsXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/>\
        </Relationships>
        """
    }

    private func appXML() -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties">\
        <Application>JamfReports</Application>\
        </Properties>
        """
    }

    private func workbookXML() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
        xml += " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        xml += "<sheets>"
        for (idx, ws) in sheets.enumerated() {
            let escaped = xmlEscape(ws.name)
            xml += "<sheet name=\"\(escaped)\" sheetId=\"\(idx+1)\" r:id=\"rId\(idx+1)\"/>"
        }
        xml += "</sheets></workbook>"
        return xml
    }

    private func workbookRelsXML() -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (idx, _) in sheets.enumerated() {
            xml += "<Relationship Id=\"rId\(idx+1)\" "
            xml += "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" "
            xml += "Target=\"worksheets/sheet\(idx+1).xml\"/>"
        }
        let ssId = sheets.count + 1
        xml += "<Relationship Id=\"rId\(ssId)\" "
        xml += "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings\" "
        xml += "Target=\"sharedStrings.xml\"/>"
        let stylesId = sheets.count + 2
        xml += "<Relationship Id=\"rId\(stylesId)\" "
        xml += "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" "
        xml += "Target=\"styles.xml\"/>"
        xml += "</Relationships>"
        return xml
    }

    // MARK: - Styles XML

    private func stylesXML() -> String {
        let accent = rgbFromHex(accentColor)

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<styleSheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">"

        // numFmts
        xml += "<numFmts count=\"3\">"
        xml += "<numFmt numFmtId=\"164\" formatCode=\"0.0%\"/>"
        xml += "<numFmt numFmtId=\"165\" formatCode=\"yyyy-mm-dd\"/>"
        xml += "<numFmt numFmtId=\"166\" formatCode=\"0\"/>"
        xml += "</numFmts>"

        // fonts
        xml += "<fonts count=\"4\">"
        xml += "<font><sz val=\"11\"/><color theme=\"1\"/><name val=\"Calibri\"/></font>"
        xml += "<font><b/><sz val=\"14\"/><name val=\"Calibri\"/></font>"
        xml += "<font><i/><sz val=\"10\"/><color rgb=\"FF595959\"/><name val=\"Calibri\"/></font>"
        xml += "<font><b/><sz val=\"11\"/><color rgb=\"FFFFFFFF\"/><name val=\"Calibri\"/></font>"
        xml += "</fonts>"

        // fills — index 0 and 1 required by spec, then custom
        xml += "<fills count=\"8\">"
        xml += "<fill><patternFill patternType=\"none\"/></fill>"
        xml += "<fill><patternFill patternType=\"gray125\"/></fill>"
        xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FF\(accent)\"/></patternFill></fill>"
        xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFC6EFCE\"/></patternFill></fill>"
        xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFFFEB9C\"/></patternFill></fill>"
        xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFFFC7CE\"/></patternFill></fill>"
        xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFC6EFCE\"/></patternFill></fill>"
        xml += "<fill><patternFill patternType=\"solid\"><fgColor rgb=\"FFFFEB9C\"/></patternFill></fill>"
        xml += "</fills>"

        // borders — index 0 = none, index 1 = thin all sides
        xml += "<borders count=\"2\">"
        xml += "<border><left/><right/><top/><bottom/><diagonal/></border>"
        xml += "<border>"
        for side in ["left", "right", "top", "bottom"] {
            xml += "<\(side) style=\"thin\"><color indexed=\"64\"/></\(side)>"
        }
        xml += "<diagonal/></border>"
        xml += "</borders>"

        // cellStyleXfs
        xml += "<cellStyleXfs count=\"1\"><xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"0\"/></cellStyleXfs>"

        // cellXfs — one per CellFormat case. The `count` attribute is required
        // by ECMA-376; every sibling collection element (numFmts, fonts, fills,
        // borders, cellStyleXfs) carries it.
        xml += "<cellXfs count=\"13\">"
        // 0: title  — bold 14, no border
        xml += "<xf numFmtId=\"0\" fontId=\"1\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        // 1: subtitle — italic 10, grey, no border
        xml += "<xf numFmtId=\"0\" fontId=\"2\" fillId=\"0\" borderId=\"0\" xfId=\"0\"/>"
        // 2: header — bold white on accent, border
        xml += "<xf numFmtId=\"0\" fontId=\"3\" fillId=\"2\" borderId=\"1\" xfId=\"0\" applyFill=\"1\"/>"
        // 3: cell — normal, border
        xml += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\"/>"
        // 4: green
        xml += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"3\" borderId=\"1\" xfId=\"0\" applyFill=\"1\"/>"
        // 5: yellow
        xml += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"4\" borderId=\"1\" xfId=\"0\" applyFill=\"1\"/>"
        // 6: red
        xml += "<xf numFmtId=\"0\" fontId=\"0\" fillId=\"5\" borderId=\"1\" xfId=\"0\" applyFill=\"1\"/>"
        // 7: pct  (0.0%)
        xml += "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        // 8: pctGreen
        xml += "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"3\" borderId=\"1\" xfId=\"0\" applyFill=\"1\" applyNumberFormat=\"1\"/>"
        // 9: pctYellow
        xml += "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"4\" borderId=\"1\" xfId=\"0\" applyFill=\"1\" applyNumberFormat=\"1\"/>"
        // 10: pctRed
        xml += "<xf numFmtId=\"164\" fontId=\"0\" fillId=\"5\" borderId=\"1\" xfId=\"0\" applyFill=\"1\" applyNumberFormat=\"1\"/>"
        // 11: date  (yyyy-mm-dd)
        xml += "<xf numFmtId=\"165\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        // 12: int   (0)
        xml += "<xf numFmtId=\"166\" fontId=\"0\" fillId=\"0\" borderId=\"1\" xfId=\"0\" applyNumberFormat=\"1\"/>"
        xml += "</cellXfs>"
        xml += "</styleSheet>"
        return xml
    }

    private func rgbFromHex(_ hex: String) -> String {
        let clean = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        return clean.uppercased()
    }

    // MARK: - Shared strings

    private func buildSharedStrings() -> ([String: Int], String) {
        var table: [String: Int] = [:]
        var strings: [String] = []
        // totalRefs counts every cell-reference use; uniqueCount = strings.count.
        var totalRefs = 0

        for ws in sheets {
            for (_, _, value, _) in ws.dedupedCells {
                if case .string(let s) = value, !s.isEmpty {
                    totalRefs += 1
                    if table[s] == nil {
                        table[s] = strings.count
                        strings.append(s)
                    }
                }
            }
            for merge in ws.mergeRanges {
                if case .string(let s) = merge.value, !s.isEmpty {
                    totalRefs += 1
                    if table[s] == nil {
                        table[s] = strings.count
                        strings.append(s)
                    }
                }
            }
        }

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<sst xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
        xml += " count=\"\(totalRefs)\" uniqueCount=\"\(strings.count)\">"
        for s in strings {
            xml += "<si><t xml:space=\"preserve\">\(xmlEscape(s))</t></si>"
        }
        xml += "</sst>"
        return (table, xml)
    }

    // MARK: - Sheet XML

    private func buildSheetXML(
        _ ws: Worksheet,
        sharedStrings: [String: Int],
        hasDrawing: Bool,
        sheetNum: Int
    ) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\""
        xml += " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"

        // ECMA-376 §18.3.1 sequence: sheetPr, dimension, sheetViews, sheetFormatPr, cols, sheetData.
        // sheetViews must precede cols.
        if let fp = ws.freezePane {
            xml += "<sheetViews><sheetView workbookViewId=\"0\">"
            xml += "<pane xSplit=\"\(fp.col)\" ySplit=\"\(fp.row)\" topLeftCell=\"\(cellRef(row: fp.row, col: fp.col))\" activePane=\"bottomRight\" state=\"frozen\"/>"
            xml += "</sheetView></sheetViews>"
        }

        // Column widths
        if !ws.columnWidths.isEmpty {
            xml += "<cols>"
            for cw in ws.columnWidths {
                xml += "<col min=\"\(cw.first+1)\" max=\"\(cw.last+1)\" width=\"\(cw.width)\" customWidth=\"1\"/>"
            }
            xml += "</cols>"
        }

        // Build row dictionary. `dedupedCells` collapses repeated (row, col)
        // writes to a single last-write-wins cell so no `<row>` emits two `<c>`
        // elements with the same `r` reference.
        var rowDict: [Int: [(col: Int, value: CellValue, format: CellFormat?)]] = [:]
        for (row, col, value, fmt) in ws.dedupedCells {
            rowDict[row, default: []].append((col, value, fmt))
        }

        // Merge ranges — mark cells
        var mergeSet: Set<String> = []
        for merge in ws.mergeRanges {
            mergeSet.insert("\(merge.firstRow)-\(merge.firstCol)")
        }

        xml += "<sheetData>"
        let rows = rowDict.keys.sorted()
        for row in rows {
            let cols = rowDict[row] ?? []
            xml += "<row r=\"\(row+1)\">"
            for (col, value, fmt) in cols.sorted(by: { $0.col < $1.col }) {
                let ref = cellRef(row: row, col: col)
                let styleIdx = formatStyleIndex(fmt)
                xml += cellXML(ref: ref, value: value, styleIdx: styleIdx, sharedStrings: sharedStrings)
            }
            xml += "</row>"
        }
        xml += "</sheetData>"

        // Merge ranges
        if !ws.mergeRanges.isEmpty {
            xml += "<mergeCells count=\"\(ws.mergeRanges.count)\">"
            for m in ws.mergeRanges {
                let ref = "\(cellRef(row: m.firstRow, col: m.firstCol)):\(cellRef(row: m.lastRow, col: m.lastCol))"
                xml += "<mergeCell ref=\"\(ref)\"/>"
            }
            xml += "</mergeCells>"
        }

        if hasDrawing {
            xml += "<drawing r:id=\"rId1\"/>"
        }
        xml += "</worksheet>"
        return xml
    }

    private func cellXML(
        ref: String,
        value: CellValue,
        styleIdx: Int,
        sharedStrings: [String: Int]
    ) -> String {
        switch value {
        case .blank:
            return "<c r=\"\(ref)\" s=\"\(styleIdx)\"/>"
        case .string(let s):
            if let idx = sharedStrings[s] {
                return "<c r=\"\(ref)\" t=\"s\" s=\"\(styleIdx)\"><v>\(idx)</v></c>"
            }
            return "<c r=\"\(ref)\" t=\"inlineStr\" s=\"\(styleIdx)\"><is><t>\(xmlEscape(s))</t></is></c>"
        case .int(let i):
            return "<c r=\"\(ref)\" s=\"\(styleIdx)\"><v>\(i)</v></c>"
        case .double(let d):
            // Guard at the render site in addition to CellValue.safe construction.
            // A CellValue.double created directly (bypassing .safe) could still carry
            // NaN/inf and produce invalid SpreadsheetML.
            let safe = d.isFinite ? d : 0.0
            return "<c r=\"\(ref)\" s=\"\(styleIdx)\"><v>\(safe)</v></c>"
        case .bool(let b):
            return "<c r=\"\(ref)\" t=\"b\" s=\"\(styleIdx)\"><v>\(b ? 1 : 0)</v></c>"
        }
    }

    private func formatStyleIndex(_ format: CellFormat?) -> Int {
        guard let format else { return 3 } // default: cell
        switch format {
        case .title:    return 0
        case .subtitle: return 1
        case .header:   return 2
        case .cell:     return 3
        case .green:    return 4
        case .yellow:   return 5
        case .red:      return 6
        case .pct:      return 7
        case .pctGreen: return 8
        case .pctYellow: return 9
        case .pctRed:   return 10
        case .date:     return 11
        case .int:      return 12
        }
    }

    // MARK: - Drawing XML (image embeds)

    // MARK: - PNG dimension reader

    /// Read pixel width × height from a PNG IHDR chunk.
    /// Returns nil if data is too short or the signature/IHDR is invalid.
    private func pngDimensions(_ data: Data) -> (width: Int, height: Int)? {
        guard data.count >= 24 else { return nil }
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard [UInt8](data.prefix(8)) == signature else { return nil }
        let ihdrType = String(bytes: data[12..<16], encoding: .ascii) ?? ""
        guard ihdrType == "IHDR" else { return nil }
        let w = (Int(data[16]) << 24) | (Int(data[17]) << 16) | (Int(data[18]) << 8) | Int(data[19])
        let h = (Int(data[20]) << 24) | (Int(data[21]) << 16) | (Int(data[22]) << 8) | Int(data[23])
        return (w, h)
    }

    private func buildDrawingXML(_ embeds: [ImageEmbed], sheetNum: Int) -> String {
        // Default DPI for ChartRenderer retina output (scale=2 × 72 pt/in = 144 DPI).
        let defaultDPI: Double = 144
        // EMU per inch = 914,400
        let emuPerInch: Double = 914_400

        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<xdr:wsDr xmlns:xdr=\"http://schemas.openxmlformats.org/drawingml/2006/spreadsheetDrawing\""
        xml += " xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\""
        xml += " xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">"
        for (idx, embed) in embeds.enumerated() {
            // Compute EMU from actual PNG pixel dimensions.
            let (emuCX, emuCY): (Int, Int)
            if let dims = pngDimensions(embed.data), dims.width > 0, dims.height > 0 {
                emuCX = Int(Double(dims.width) / defaultDPI * emuPerInch * embed.xScale)
                emuCY = Int(Double(dims.height) / defaultDPI * emuPerInch * embed.yScale)
            } else {
                // Fallback: ChartRenderer.defaultSize (1200×600 px) at 144 DPI.
                emuCX = Int(1200.0 / defaultDPI * emuPerInch * embed.xScale)
                emuCY = Int(600.0 / defaultDPI * emuPerInch * embed.yScale)
            }
            xml += "<xdr:twoCellAnchor editAs=\"oneCell\">"
            xml += "<xdr:from><xdr:col>\(embed.col)</xdr:col><xdr:colOff>0</xdr:colOff>"
            xml += "<xdr:row>\(embed.row)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:from>"
            xml += "<xdr:to><xdr:col>\(embed.col+4)</xdr:col><xdr:colOff>0</xdr:colOff>"
            xml += "<xdr:row>\(embed.row+15)</xdr:row><xdr:rowOff>0</xdr:rowOff></xdr:to>"
            xml += "<xdr:pic><xdr:nvPicPr>"
            xml += "<xdr:cNvPr id=\"\(idx+2)\" name=\"Image \(idx+1)\"/>"
            xml += "<xdr:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></xdr:cNvPicPr>"
            xml += "</xdr:nvPicPr><xdr:blipFill>"
            xml += "<a:blip r:embed=\"rId\(idx+1)\"/>"
            xml += "<a:stretch><a:fillRect/></a:stretch>"
            xml += "</xdr:blipFill><xdr:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/>"
            xml += "<a:ext cx=\"\(emuCX)\" cy=\"\(emuCY)\"/>"
            xml += "</a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></xdr:spPr>"
            xml += "</xdr:pic><xdr:clientData/></xdr:twoCellAnchor>"
        }
        xml += "</xdr:wsDr>"
        return xml
    }

    private func buildDrawingRelsXML(_ drawingRels: [(imageId: Int, filename: String)]) -> String {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
        xml += "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
        for (idx, rel) in drawingRels.enumerated() {
            xml += "<Relationship Id=\"rId\(idx+1)\" "
            xml += "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" "
            xml += "Target=\"../media/image\(rel.imageId).\(imageExtension(rel.filename))\"/>"
        }
        xml += "</Relationships>"
        return xml
    }

    private func buildWorksheetRelsXML(sheetNum: Int) -> String {
        """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>\
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" \
        Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" \
        Target="../drawings/drawing\(sheetNum).xml"/>\
        </Relationships>
        """
    }

    // MARK: - Utilities

    private func cellRef(row: Int, col: Int) -> String {
        columnLetter(col) + "\(row + 1)"
    }

    private func columnLetter(_ col: Int) -> String {
        var result = ""
        var n = col
        repeat {
            result = String(UnicodeScalar(UInt32(65 + (n % 26)))!) + result
            n = n / 26 - 1
        } while n >= 0
        return result
    }

    private func imageExtension(_ filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "bmp"].contains(ext) ? ext : "png"
    }

    private func sanitizeSheetName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "[]:*?/\\")
        var s = name.components(separatedBy: invalid).joined(separator: " ")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if s.isEmpty { s = "Sheet" }
        return String(s.prefix(31))
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

// MARK: - Sheet header helper (mirrors Python _write_sheet_header)

extension Worksheet {
    /// Write a two-row title/subtitle header and return the next data row index.
    /// Mirrors the Python `_write_sheet_header` function exactly.
    @discardableResult
    func writeSheetHeader(title: String, subtitle: String, ncols: Int = 8) -> Int {
        mergeRange(firstRow: 0, firstCol: 0, lastRow: 0, lastCol: ncols - 1,
                   value: title, format: .title)
        mergeRange(firstRow: 1, firstCol: 0, lastRow: 1, lastCol: ncols - 1,
                   value: subtitle, format: .subtitle)
        return 3
    }
}
