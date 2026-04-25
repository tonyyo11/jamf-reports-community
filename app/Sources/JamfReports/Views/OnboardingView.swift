import SwiftUI

struct OnboardingView: View {
    enum AuthMode: String, CaseIterable, Hashable {
        case apiClient = "API Client", localAdmin = "Local Admin", demo = "Demo Mode"
    }

    private struct Step: Identifiable {
        let id: Int
        let label: String
        let done: Bool
        let current: Bool
    }

    private let steps: [Step] = [
        .init(id: 1, label: "Welcome",          done: true,  current: false),
        .init(id: 2, label: "Install jamf-cli", done: true,  current: false),
        .init(id: 3, label: "Workspace",        done: true,  current: false),
        .init(id: 4, label: "Authenticate",     done: false, current: true),
        .init(id: 5, label: "CSV mapping",      done: false, current: false),
        .init(id: 6, label: "First report",     done: false, current: false),
    ]

    @State private var authMode: AuthMode = .apiClient
    @State private var jamfURL = "https://meridian.jamfcloud.com"
    @State private var clientID = "d8a9f3c0-2e1b-4f5d-91c2-3b4a5c6d7e8f"
    @State private var clientSecret = "••••••••••••••••••••••••"
    @State private var profileName = "meridian-prod"

    private let privileges = [
        "Computers · Read", "Mobile Devices · Read", "Mobile Profiles · Read",
        "Computer EAs · Read", "Policies · Read", "Patch Mgmt · Read",
        "Mobile Apps · Read", "Software Updates · Read", "Computer Groups · Read",
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                progressStrip
                stepHeader
                authCard
                navigationButtons
            }
            .padding(EdgeInsets(top: 40, leading: 60, bottom: 40, trailing: 60))
            .frame(maxWidth: 880)
            .frame(maxWidth: .infinity)
        }
    }

    private var progressStrip: some View {
        HStack(spacing: 10) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { idx, s in
                stepPill(s)
                if idx < steps.count - 1 {
                    Rectangle().fill(Theme.Colors.hairlineStrong).frame(width: 10, height: 0.5)
                }
            }
        }
    }

    private func stepPill(_ s: Step) -> some View {
        HStack(spacing: 8) {
            if s.done {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(hex: 0x6DC0C0))
            } else {
                Text("\(s.id)")
                    .font(Theme.Fonts.mono(10, weight: .semibold))
                    .foregroundStyle(s.current ? Theme.Colors.goldBright : Theme.Colors.fgMuted)
            }
            Text(s.label)
                .font(.system(size: 11.5))
                .foregroundStyle(s.current ? Theme.Colors.fg :
                                 s.done ? Theme.Colors.fg2 : Theme.Colors.fgMuted)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(
            Capsule().fill(
                s.current ? Theme.Colors.gold.opacity(0.18) :
                s.done ? Theme.Colors.teal.opacity(0.20) : Color.white.opacity(0.04)
            )
        )
        .overlay(
            Capsule().strokeBorder(
                s.current ? Theme.Colors.gold.opacity(0.5) :
                s.done ? Theme.Colors.teal.opacity(0.4) : Theme.Colors.hairline,
                lineWidth: 0.5
            )
        )
    }

    private var stepHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Kicker(text: "Step 4 of 6 · Authenticate", tone: .gold)
            Text("Connect to Jamf Pro.")
                .font(Theme.Fonts.serif(36, weight: .bold))
                .foregroundStyle(Theme.Colors.fg)
                .tracking(-0.7)
            Text("Reports use a dedicated API client with read-only privileges. Credentials are stored in your macOS keychain by jamf-cli — Jamf Reports never sees them after this step.")
                .font(.system(size: 14))
                .foregroundStyle(Theme.Colors.fgMuted)
                .frame(maxWidth: 600, alignment: .leading)
        }
    }

    private var authCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SegmentedControl(
                selection: $authMode,
                options: [
                    (AuthMode.apiClient, "API Client", "key.fill"),
                    (AuthMode.localAdmin, "Local Admin", "person.2.fill"),
                    (AuthMode.demo, "Demo Mode", "testtube.2"),
                ]
            )
            Card(padding: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Jamf Pro URL")
                        PNPTextField(value: $jamfURL)
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                            Text("Reachable · Jamf Pro 11.10.1")
                        }
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color(hex: 0x6DC0C0))
                    }

                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Client ID")
                            PNPTextField(value: $clientID, mono: true)
                        }
                        .frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 5) {
                            FieldLabel(label: "Client Secret")
                            PNPTextField(value: $clientSecret, mono: true, secure: true)
                        }
                        .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        FieldLabel(label: "Profile name")
                        PNPTextField(value: $profileName, mono: true)
                        FieldHelp(text: "Unique key used by jamf-cli · also names this workspace")
                    }

                    privilegesBox
                }
            }
        }
    }

    private var privilegesBox: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Required Jamf Pro API privileges")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Colors.fg)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3), spacing: 6) {
                ForEach(privileges, id: \.self) { p in
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color(hex: 0x6DC0C0))
                        Text(p).font(.system(size: 11)).foregroundStyle(Theme.Colors.fg2)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.025))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Theme.Colors.hairline, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var navigationButtons: some View {
        HStack {
            PNPButton(title: "Back")
            Spacer()
            PNPButton(title: "Skip · use Demo Mode", style: .ghost)
            PNPButton(title: "Verify & continue", icon: "checkmark", style: .gold, size: .lg)
        }
    }
}
