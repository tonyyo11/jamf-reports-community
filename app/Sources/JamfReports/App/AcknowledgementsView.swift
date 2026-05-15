import SwiftUI

// Resource files mirror canonical copies at the repo root (/LICENSE, /NOTICE.md,
// /THIRD_PARTY_NOTICES.md). Keep them in sync when editing — drift will be
// visible in this view but not blocked by any check.

struct AcknowledgementsMenuButton: View {
    // CommandGroup body items can't reach `@Environment(\.openWindow)` directly;
    // the env action is only available inside a View. Hence this wrapper.
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Acknowledgements…") {
            openWindow(id: "acknowledgements")
        }
    }
}

struct AcknowledgementsView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case license = "License"
        case notice = "Trademark Notice"
        case thirdParty = "Third-Party Notices"

        var id: String { rawValue }

        var resourceName: String {
            switch self {
            case .license: return "LICENSE"
            case .notice: return "NOTICE"
            case .thirdParty: return "THIRD_PARTY_NOTICES"
            }
        }

        var resourceExtension: String {
            switch self {
            case .license: return "txt"
            case .notice, .thirdParty: return "md"
            }
        }
    }

    @State private var selection: Tab = .license

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selection) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            Divider()

            ScrollView {
                Text(text(for: selection))
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }

    private func text(for tab: Tab) -> String {
        let resource = "\(tab.resourceName).\(tab.resourceExtension)"
        guard let url = Bundle.module.url(
            forResource: tab.resourceName,
            withExtension: tab.resourceExtension
        ) else {
            return "Resource not bundled: \(resource)"
        }
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return "Could not read \(resource): \(error.localizedDescription)"
        }
    }
}
