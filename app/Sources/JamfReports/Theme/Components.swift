import SwiftUI

// MARK: - Kicker (mono uppercase eyebrow above titles)

struct Kicker: View {
    enum Tone { case muted, gold, teal }
    let text: String
    var tone: Tone = .muted

    var body: some View {
        Text(text.uppercased())
            .font(Theme.Fonts.mono(10.5, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(color)
    }

    private var color: Color {
        switch tone {
        case .muted: Theme.Colors.fgMuted
        case .gold:  Theme.Colors.goldBright
        case .teal:  Theme.Colors.tealBright
        }
    }
}

// MARK: - Page header (kicker + serif H1 + subtitle)

struct PageHeader: View {
    let kicker: String
    var kickerTone: Kicker.Tone = .gold
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> AnyView

    init(
        kicker: String,
        kickerTone: Kicker.Tone = .gold,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> AnyView = { AnyView(EmptyView()) }
    ) {
        self.kicker = kicker
        self.kickerTone = kickerTone
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Kicker(text: kicker, tone: kickerTone)
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

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Metrics.largeCardRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: 0.5)
            )
    }
}

// MARK: - Pill / chip

struct Pill: View {
    enum Tone { case muted, gold, teal, warn, danger }
    let text: String
    var tone: Tone = .muted
    var icon: String? = nil

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
    }

    private var bg: Color {
        switch tone {
        case .muted:  Color.white.opacity(0.07)
        case .gold:   Theme.Colors.gold.opacity(0.18)
        case .teal:   Theme.Colors.teal.opacity(0.30)
        case .warn:   Theme.Colors.warn.opacity(0.20)
        case .danger: Theme.Colors.danger.opacity(0.20)
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
                Sparkline(values: sparkValues, color: sparkColor)
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
    }

    private var deltaColor: Color {
        switch deltaTrend {
        case .up: Theme.Colors.ok
        case .down: Theme.Colors.danger
        case .flat: Theme.Colors.fgMuted
        }
    }
}

// MARK: - Sparkline (lightweight, used inside KPIs)

struct Sparkline: View {
    let values: [Double]
    var color: Color = Theme.Colors.gold

    var body: some View {
        GeometryReader { geo in
            let path = makePath(in: geo.size)
            ZStack {
                path
                    .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                fill(in: geo.size).fill(
                    LinearGradient(
                        colors: [color.opacity(0.25), color.opacity(0.0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
        }
    }

    private func makePath(in size: CGSize) -> Path {
        guard let lo = values.min(), let hi = values.max(), hi != lo else { return Path() }
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
    var trailing: String? = nil
    var size: CGFloat = 15
    var body: some View {
        HStack {
            Text(title).font(.system(size: size, weight: .semibold)).foregroundStyle(Theme.Colors.fg)
            Spacer()
            if let trailing { Kicker(text: trailing) }
        }
    }
}
