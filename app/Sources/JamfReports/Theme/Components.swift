import SwiftUI

// MARK: - Kicker (mono uppercase eyebrow above titles)

struct Breadcrumb: Identifiable, Sendable {
    var id: String { label }
    let label: String
    var action: (@MainActor @Sendable () -> Void)? = nil
}

struct Kicker: View {
    enum Tone { case muted, gold, teal, warn, danger }
    let text: String
    var tone: Tone = .muted
    var breadcrumbs: [Breadcrumb] = []

    var body: some View {
        HStack(spacing: 4) {
            ForEach(breadcrumbs) { crumb in
                Button {
                    if let action = crumb.action {
                        Task { @MainActor in
                            action()
                        }
                    }
                } label: {
                    Text(crumb.label.uppercased())
                        .font(Theme.Fonts.mono(10.5, weight: .semibold))
                        .tracking(1.5)
                        .foregroundStyle(color)
                        .opacity(crumb.action != nil ? 1 : 0.6)
                }
                .buttonStyle(.plain)
                .disabled(crumb.action == nil)

                Text("/")
                    .font(Theme.Fonts.mono(10, weight: .bold))
                    .foregroundStyle(Theme.Colors.hairlineStrong)
            }

            Text(text.uppercased())
                .font(Theme.Fonts.mono(10.5, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(color)
        }
    }

    private var color: Color {
        switch tone {
        case .muted: Theme.Colors.fgMuted
        case .gold:  Theme.Colors.goldBright
        case .teal:  Theme.Colors.tealBright
        case .warn:  Theme.Colors.warn
        case .danger: Theme.Colors.danger
        }
    }
}

// MARK: - Page header (kicker + serif H1 + subtitle)

struct PageHeader: View {
    let kicker: String
    var kickerTone: Kicker.Tone = .gold
    var breadcrumbs: [Breadcrumb] = []
    let title: String
    var subtitle: String?
    var lastModified: Date? = nil
    @ViewBuilder var trailing: () -> AnyView

    init(
        kicker: String,
        kickerTone: Kicker.Tone = .gold,
        breadcrumbs: [Breadcrumb] = [],
        title: String,
        subtitle: String? = nil,
        lastModified: Date? = nil,
        @ViewBuilder trailing: @escaping () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.kicker = kicker
        self.kickerTone = kickerTone
        self.breadcrumbs = breadcrumbs
        self.title = title
        self.subtitle = subtitle
        self.lastModified = lastModified
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Kicker(text: effectiveKicker, tone: effectiveKickerTone, breadcrumbs: breadcrumbs)
                    if let ageLabel = stalenessLabel {
                        Text("·")
                            .font(Theme.Fonts.mono(10.5, weight: .bold))
                            .foregroundStyle(Theme.Colors.hairlineStrong)
                        Text(ageLabel.uppercased())
                            .font(Theme.Fonts.mono(10.5, weight: .semibold))
                            .tracking(1.5)
                            .foregroundStyle(effectiveKickerTone == .gold ? Theme.Colors.fgMuted : color(for: effectiveKickerTone))
                    }
                }
                Text(title)
                    .font(Theme.Fonts.serif(26, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Colors.fgMuted)
                }
            }
            Spacer()
            trailing()
        }
    }

    private var effectiveKicker: String {
        kicker
    }

    private var effectiveKickerTone: Kicker.Tone {
        if let lastModified {
            let hours = Calendar.current.dateComponents([.hour], from: lastModified, to: Date()).hour ?? 0
            if hours >= 24 * 7 { return .danger }
            if hours >= 24 { return .warn }
        }
        return kickerTone
    }

    private var stalenessLabel: String? {
        guard let lastModified else { return nil }
        let calendar = Calendar.current
        let components = calendar.dateComponents([.day, .hour, .minute], from: lastModified, to: Date())

        if let days = components.day, days >= 1 {
            if effectiveKickerTone == .gold { return nil } // Only show if stale
            return "Updated \(days) \(days == 1 ? "day" : "days") ago"
        }
        return nil
    }

    private func color(for tone: Kicker.Tone) -> Color {
        switch tone {
        case .muted: Theme.Colors.fgMuted
        case .gold:  Theme.Colors.goldBright
        case .teal:  Theme.Colors.tealBright
        case .warn:  Theme.Colors.warn
        case .danger: Theme.Colors.danger
        }
    }
}

// MARK: - Card surface

struct Card<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.winBG2)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
    }
}

/// Liquid-glass elevated pane — used for the gold "next-up" callout on Schedules.
struct GlassPane<Content: View>: View {
    var padding: CGFloat = 18
    var borderColor: Color = Theme.Colors.hairlineStrong
    @ViewBuilder var content: () -> Content

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                reduceTransparency ? AnyShapeStyle(Theme.Colors.winBG2) : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius, style: .continuous)
                    .strokeBorder(
                        reduceTransparency ? Theme.Colors.hairlineStrong : borderColor,
                        lineWidth: 0.5
                    )
            )
    }
}

// MARK: - Pill / chip

struct Pill: View {
    enum Tone { case muted, gold, teal, warn, danger }
    let text: String
    var tone: Tone = .muted
    var icon: String? = nil

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.system(size: 9, weight: .semibold)) }
            Text(text.uppercased())
        }
        .font(Theme.Fonts.mono(10.5, weight: .semibold))
        .tracking(0.6)
        .foregroundStyle(fg)
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(bg, in: Capsule())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var bg: Color {
        let opacityScale = bgOpacityScale
        let opacity = contrast == .increased ? opacityScale.increased : opacityScale.base
        switch tone {
        case .muted:  return Color.white.opacity(opacity)
        case .gold:   return Theme.Colors.gold.opacity(opacity)
        case .teal:   return Theme.Colors.teal.opacity(opacity)
        case .warn:   return Theme.Colors.warn.opacity(opacity)
        case .danger: return Theme.Colors.danger.opacity(opacity)
        }
    }

    private var bgOpacityScale: (base: Double, increased: Double) {
        switch tone {
        case .muted:  (0.07, 0.12)
        case .gold:   (0.18, 0.30)
        case .teal:   (0.30, 0.46)
        case .warn:   (0.20, 0.34)
        case .danger: (0.20, 0.34)
        }
    }

    private var fg: Color {
        switch tone {
        case .muted:  Theme.Colors.fgMuted
        case .gold:   Theme.Colors.goldBright
        case .teal:   Color(hex: 0x6DC0C0)
        case .warn:   Color(hex: 0xFFB340)
        case .danger: Color(hex: 0xFF8077)
        }
    }
}

// MARK: - Buttons

struct PNPButton: View {
    enum Style { case neutral, gold, ghost, danger }
    enum Size { case sm, md, lg }
    let title: String
    var icon: String? = nil
    var style: Style = .neutral
    var size: Size = .md
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: iconSize, weight: .semibold)) }
                Text(title).font(.system(size: fontSize, weight: style == .gold ? .semibold : .medium))
            }
            .padding(.horizontal, hPad)
            .frame(height: height)
            .foregroundStyle(fg)
            .background(bg, in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                    .strokeBorder(border, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var height: CGFloat { switch size { case .sm: 22; case .md: 28; case .lg: 36 } }
    private var hPad: CGFloat   { switch size { case .sm: 8;  case .md: 14; case .lg: 18 } }
    private var fontSize: CGFloat { switch size { case .sm: 11.5; case .md: 13; case .lg: 13.5 } }
    private var iconSize: CGFloat { switch size { case .sm: 10; case .md: 12; case .lg: 13 } }

    private var bg: Color {
        switch style {
        case .neutral: Color.white.opacity(0.07)
        case .gold:    Theme.Colors.gold
        case .ghost:   .clear
        case .danger:  Theme.Colors.danger.opacity(0.15)
        }
    }
    private var fg: Color {
        switch style {
        case .neutral: Theme.Colors.fg
        case .gold:    Color(hex: 0x1A1408)
        case .ghost:   Theme.Colors.goldBright
        case .danger:  Color(hex: 0xFF8077)
        }
    }
    private var border: Color {
        switch style {
        case .neutral, .danger: Theme.Colors.hairlineStrong
        case .gold:    Color.black.opacity(0.2)
        case .ghost:   .clear
        }
    }
}

// MARK: - Toggle (HIG, gold accent when on)

struct PNPToggle: View {
    @Binding var isOn: Bool
    var label: String = ""
    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.Colors.gold : Color.white.opacity(0.12))
                    .frame(width: 36, height: 22)
                    .overlay(
                        Capsule().strokeBorder(
                            isOn ? Theme.Colors.goldDim : Theme.Colors.hairlineStrong,
                            lineWidth: 0.5
                        )
                    )
                Circle()
                    .fill(.white)
                    .frame(width: 17, height: 17)
                    .padding(2)
                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label.isEmpty ? "Toggle" : label)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Segmented control

struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String, icon: String?)]

    init(selection: Binding<Value>, options: [(Value, String, String?)]) {
        self._selection = selection
        self.options = options.map { ($0.0, $0.1, $0.2) }
    }

    var body: some View {
        HStack(spacing: 1) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, opt in
                Button {
                    selection = opt.value
                } label: {
                    HStack(spacing: 5) {
                        if let icon = opt.icon { Image(systemName: icon).font(.system(size: 10, weight: .semibold)) }
                        Text(opt.label).font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .foregroundStyle(selection == opt.value ? Theme.Colors.fg : Theme.Colors.fg2)
                    .background(
                        Group {
                            if selection == opt.value {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.white.opacity(0.12))
                                    .shadow(color: .black.opacity(0.3), radius: 1, y: 1)
                            }
                        }
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(opt.label)
                .accessibilityAddTraits(selection == opt.value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
    }
}

// MARK: - KPI tile

struct StatTile: View {
    let label: String
    let value: String
    var sub: String? = nil
    var delta: String? = nil
    enum Trend { case up, down, flat }
    var deltaTrend: Trend = .flat
    var sparkValues: [Double]? = nil
    var sparkColor: Color = Theme.Colors.gold

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Kicker(text: label)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value)
                    .font(Theme.Fonts.serif(32, weight: .bold))
                    .foregroundStyle(Theme.Colors.fg)
                    .monospacedDigit()
                if let delta {
                    HStack(spacing: 3) {
                        if deltaTrend == .up   { Image(systemName: "arrow.up").font(.system(size: 10, weight: .bold)) }
                        if deltaTrend == .down { Image(systemName: "arrow.down").font(.system(size: 10, weight: .bold)) }
                        Text(delta)
                    }
                    .font(Theme.Fonts.mono(11, weight: .semibold))
                    .foregroundStyle(deltaColor)
                }
            }
            if let sub {
                Text(sub).font(.system(size: 11.5)).foregroundStyle(Theme.Colors.fgMuted)
            }
            if let sparkValues, !sparkValues.isEmpty {
                Sparkline(values: sparkValues, color: defaultSparklineColor)
                    .frame(height: 32)
                    .padding(.top, 2)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.winBG2)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Metrics.cardRadius, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(fullAccessibilityLabel)
    }

    private var fullAccessibilityLabel: String {
        var parts = ["\(label): \(value)"]
        if let delta {
            switch deltaTrend {
            case .up:   parts.append("up \(delta)")
            case .down: parts.append("down \(delta)")
            case .flat: break
            }
        }
        if let sub { parts.append(sub) }
        return parts.joined(separator: ", ")
    }

    private var deltaColor: Color {
        switch deltaTrend {
        case .up: Theme.Colors.ok
        case .down: Theme.Colors.danger
        case .flat: Theme.Colors.fgMuted
        }
    }

    private var defaultSparklineColor: Color {
        // If caller explicitly set sparkColor, use it; otherwise follow delta trend
        if sparkColor != Theme.Colors.gold {
            return sparkColor
        }
        switch deltaTrend {
        case .up: return Theme.Colors.ok
        case .down: return Theme.Colors.danger
        case .flat: return Theme.Colors.gold
        }
    }
}

// MARK: - Sparkline (lightweight, used inside KPIs)

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.Colors.gold

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GeometryReader { geo in
            let path = makePath(in: geo.size)
            let fillOpacity = contrast == .increased ? 0.40 : 0.25
            ZStack {
                path
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                fill(in: geo.size).fill(
                    LinearGradient(
                        colors: [color.opacity(fillOpacity), color.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
        .accessibilityHidden(true)
    }

    private func makePath(in size: CGSize) -> Path {
        guard let rawLo = values.min(), let hi = values.max(), hi != rawLo else { return Path() }
        let lo = max(rawLo, 0)  // Clamp min to 0 to prevent negative Y baseline for percentage-like metrics
        let n = values.count
        var p = Path()
        for (i, v) in values.enumerated() {
            let x = CGFloat(i) / CGFloat(max(n - 1, 1)) * size.width
            let y = size.height - CGFloat((v - lo) / (hi - lo)) * size.height
            i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
        }
        return p
    }

    private func fill(in size: CGSize) -> Path {
        var p = makePath(in: size)
        p.addLine(to: CGPoint(x: size.width, y: size.height))
        p.addLine(to: CGPoint(x: 0, y: size.height))
        p.closeSubpath()
        return p
    }
}

// MARK: - Mono inline span

struct Mono: View {
    let text: String
    var size: CGFloat = 11.5
    var color: Color = Theme.Colors.fgMuted
    var body: some View {
        Text(text).font(Theme.Fonts.mono(size)).foregroundStyle(color)
    }
}

// MARK: - Form field components

struct FieldLabel: View {
    let label: String
    var trailing: String? = nil
    var body: some View {
        HStack {
            Text(label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.Colors.fg2)
            Spacer()
            if let trailing {
                Text(trailing).font(Theme.Fonts.mono(10)).foregroundStyle(Theme.Colors.fgMuted)
            }
        }
    }
}

struct FieldHelp: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.Colors.fgMuted)
            .padding(.top, 4)
    }
}

struct PNPTextField: View {
    @Binding var value: String
    var placeholder: String = ""
    var mono: Bool = false
    var secure: Bool = false

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $value)
            } else {
                TextField(placeholder, text: $value)
            }
        }
        .textFieldStyle(.plain)
        .font(mono ? Theme.Fonts.mono(12) : .system(size: 13))
        .foregroundStyle(Theme.Colors.fg)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
    }
}

// MARK: - Section header inside a card

struct SectionHeader: View {
    let title: String
    var trailing: String? = nil  // Legacy single parameter, now maps to trailingTag
    var trailingTag: String? = nil
    var trailingValue: String? = nil
    var size: CGFloat = 15

    var body: some View {
        HStack {
            Text(title).font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.Colors.fg)
            Spacer()

            // Handle legacy trailing parameter
            if let trailing {
                Kicker(text: trailing)
            }

            // Handle new specific trailing types
            if let trailingTag {
                Kicker(text: trailingTag)
            }

            if let trailingValue {
                Text(trailingValue)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.Colors.fg2)
            }
        }
    }
}

// MARK: - Status Bar

struct StatusBar: View {
    let status: String?

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 8) {
            if let status {
                if status.contains("...") || status.lowercased().contains("running") || status.lowercased().contains("collecting") {
                    ProgressView().controlSize(.small)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                }
                Text(status)
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Colors.fg2)
            } else {
                Text("Ready")
                    .font(Theme.Fonts.mono(10.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 24)
        .background(reduceTransparency ? AnyShapeStyle(Theme.Colors.winBG2) : AnyShapeStyle(.ultraThinMaterial))
        .overlay(alignment: .top) {
            Divider().background(Theme.Colors.hairline)
        }
    }
}

// MARK: - Editable Number Stepper

/// A compact numeric input that pairs a free-text editable field with the
/// classic up/down stepper. Click the number to type a value directly, or
/// nudge with the chevrons. Use this anywhere you'd otherwise reach for a
/// bare `Stepper` — typing is materially faster when the user has a target
/// value in mind.
///
/// `range` is enforced via `onChange` after the user commits because
/// `TextField(value:format:)` does not honor the `Stepper(in:)` bound on its
/// own. Out-of-range typed values snap to the nearest end of the range.
struct EditableNumberStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var prefix: String? = nil
    var suffix: String? = nil
    /// Width of the inner text field. Tune up if your max value has more digits.
    var fieldWidth: CGFloat = 32
    var help: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let prefix {
                Text(prefix)
                    .font(Theme.Fonts.mono(11.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            TextField("", value: $value, format: .number)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .font(Theme.Fonts.mono(11.5))
                .foregroundStyle(Theme.Colors.fg2)
                .frame(width: fieldWidth)
                .onChange(of: value) { _, newValue in
                    let clamped = max(range.lowerBound, min(range.upperBound, newValue))
                    if clamped != newValue { value = clamped }
                }
            if let suffix {
                Text(suffix)
                    .font(Theme.Fonts.mono(11.5))
                    .foregroundStyle(Theme.Colors.fgMuted)
            }
            Stepper("", value: $value, in: range, step: 1)
                .labelsHidden()
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            Color.white.opacity(0.07),
            in: RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metrics.buttonRadius, style: .continuous)
                .strokeBorder(Theme.Colors.hairlineStrong, lineWidth: 0.5)
        )
        .help(help ?? "")
    }
}

// MARK: - Data Table Components

/// Reusable table header for hand-rolled tables that need custom row layouts.
/// A column with `width == nil` flexes to fill remaining space.
struct DataTableHeader: View {
    let columns: [DataTableColumn]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                Group {
                    if let width = column.width {
                        Text(column.title.uppercased())
                            .frame(width: width, alignment: column.alignment.textAlignment)
                    } else {
                        Text(column.title.uppercased())
                            .frame(maxWidth: .infinity, alignment: column.alignment.textAlignment)
                    }
                }
                .font(Theme.Fonts.mono(10, weight: .semibold))
                .foregroundStyle(Theme.Colors.fgMuted)
                if column.id != columns.last?.id {
                    Spacer(minLength: 12)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Theme.Colors.winBG3)
    }
}

/// Reusable table row wrapper for consistent styling
struct DataTableRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) {
            content
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(Color.clear)
    }
}

/// Column configuration for DataTableHeader.
/// Pass `width: nil` for a flex column that fills remaining space.
struct DataTableColumn: Identifiable {
    let id = UUID()
    let title: String
    let width: CGFloat?
    let alignment: DataTableAlignment

    enum DataTableAlignment {
        case leading, center, trailing

        var textAlignment: Alignment {
            switch self {
            case .leading: return .leading
            case .center: return .center
            case .trailing: return .trailing
            }
        }
    }
}
