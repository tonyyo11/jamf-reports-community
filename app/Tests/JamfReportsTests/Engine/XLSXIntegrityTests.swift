import Foundation
import XCTest
import ZIPFoundation
@testable import JamfReports

// MARK: - XLSXIntegrityTests
//
// Guards the two structural defects that made `OOXMLWriter` emit `.xlsx`
// workbooks Excel flagged as corrupt ("Repaired Records: Cell information
// from /xl/worksheets/sheetN.xml"):
//
//  1. The ZIP `addEntry` provider returned the whole blob on every chunk
//     call, so each STORED entry's `compressedSize` ballooned to a multiple
//     of `uncompressedSize`. Excel reads `compressedSize` bytes for a STORED
//     entry and chokes on the repeated content.
//  2. Repeated `(row, col)` writes emitted two `<c>` elements with the same
//     `r` reference inside one `<row>` — the classic Excel corruption
//     signature.
//
// Both assertions fail against the pre-fix writer and pass after it.

final class XLSXIntegrityTests: XCTestCase {

    /// Build a workbook that exercises every cell kind plus the two failure
    /// modes: a large sheet (forces multi-chunk ZIP writes) and overlapping
    /// `(row, col)` writes.
    private func makeRepresentativeWorkbook() -> Workbook {
        let wb = Workbook(accentColor: "#2D5EA2")

        // Sheet 1: writeSheetHeader + header row + typed data cells.
        let s1 = wb.addSheet("Fleet Overview")
        var row = s1.writeSheetHeader(title: "Fleet Overview",
                                      subtitle: "Generated: test", ncols: 4)
        for (col, header) in ["Section", "Resource", "Value", "Status"].enumerated() {
            s1.write(header, row: row, col: col, format: .header)
        }
        row += 1
        for i in 0..<8 {
            s1.write("section-\(i)", row: row, col: 0, format: .cell)
            s1.write("resource-\(i)", row: row, col: 1, format: .cell)
            s1.write(i, row: row, col: 2, format: .int)
            s1.write(Double(i) / 8.0, row: row, col: 3, format: .pct)
            row += 1
        }

        // Sheet 2: deliberate overlapping writes at the same (row, col), plus
        // a merged-cell origin later overwritten by a plain write.
        let s2 = wb.addSheet("Overlap")
        s2.write("first-write", row: 0, col: 0, format: .cell)
        s2.write("second-write", row: 0, col: 0, format: .cell)
        s2.write(true, row: 0, col: 1, format: .green)
        s2.mergeRange(firstRow: 1, firstCol: 0, lastRow: 1, lastCol: 2,
                      value: "merged-origin", format: .title)
        s2.write("overwrites-merge", row: 1, col: 0, format: .cell)
        s2.writeBlank(row: 2, col: 0, format: .cell)

        // Sheet 3: large enough that the ZIP writer splits it across multiple
        // 16 KB chunks — the multi-chunk path is where the provider bug surfaced.
        let s3 = wb.addSheet("Large")
        for r in 0..<400 {
            for c in 0..<10 {
                s3.write("cell-r\(r)-c\(c)-padding-padding", row: r, col: c, format: .cell)
            }
        }
        return wb
    }

    private func writeTempWorkbook(_ wb: Workbook) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("XLSXIntegrity-\(UUID().uuidString).xlsx")
        try wb.write(to: url)
        return url
    }

    // MARK: - STORED entry size consistency (primary defect)

    func testStoredEntriesHaveConsistentSize() throws {
        let url = try writeTempWorkbook(makeRepresentativeWorkbook())
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .read)
        var entryCount = 0
        for entry in archive {
            entryCount += 1
            // Every part is added with compressionMethod .none (STORED).
            // For a STORED entry the spec requires compressedSize == uncompressedSize.
            XCTAssertEqual(
                entry.compressedSize, entry.uncompressedSize,
                "STORED entry '\(entry.path)' has compressedSize "
                    + "\(entry.compressedSize) != uncompressedSize "
                    + "\(entry.uncompressedSize) — Excel will reject this part"
            )
        }
        XCTAssertGreaterThan(entryCount, 0, "archive should contain entries")
    }

    // MARK: - Worksheet XML well-formedness

    func testEveryXMLPartIsWellFormed() throws {
        let url = try writeTempWorkbook(makeRepresentativeWorkbook())
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive where entry.path.hasSuffix(".xml") || entry.path.hasSuffix(".rels") {
            let data = try extract(entry, from: archive)
            let parser = XMLParser(data: data)
            XCTAssertTrue(
                parser.parse(),
                "XML part '\(entry.path)' is not well-formed: "
                    + "\(parser.parserError?.localizedDescription ?? "unknown")"
            )
        }
    }

    // MARK: - No duplicate cell references (secondary defect)

    func testNoDuplicateCellReferencesWithinARow() throws {
        let url = try writeTempWorkbook(makeRepresentativeWorkbook())
        defer { try? FileManager.default.removeItem(at: url) }

        let archive = try Archive(url: url, accessMode: .read)
        for entry in archive where entry.path.hasPrefix("xl/worksheets/sheet") {
            let xml = String(decoding: try extract(entry, from: archive), as: UTF8.self)
            for dup in duplicateCellRefs(in: xml) {
                XCTFail("\(entry.path): <row> contains duplicate <c r=\"\(dup)\">")
            }
        }
    }

    // MARK: - Helpers

    private func extract(_ entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    /// Return every cell reference that appears two or more times inside the
    /// same `<row>` element.
    private func duplicateCellRefs(in xml: String) -> [String] {
        var dups: [String] = []
        for chunk in xml.components(separatedBy: "<row ").dropFirst() {
            guard let rowEnd = chunk.range(of: "</row>") else { continue }
            let body = String(chunk[chunk.startIndex..<rowEnd.lowerBound])
            var counts: [String: Int] = [:]
            var cursor = body.startIndex
            while let open = body.range(of: "<c r=\"", range: cursor..<body.endIndex) {
                guard let close = body.range(of: "\"", range: open.upperBound..<body.endIndex)
                else { break }
                let ref = String(body[open.upperBound..<close.lowerBound])
                counts[ref, default: 0] += 1
                cursor = close.upperBound
            }
            dups.append(contentsOf: counts.filter { $0.value > 1 }.map(\.key))
        }
        return dups
    }
}
