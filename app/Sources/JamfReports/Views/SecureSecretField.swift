import AppKit
import SwiftUI

// MARK: - SecureSecretField

/// `NSSecureTextField` wrapper that avoids binding a `String` property on every
/// keystroke, reducing the window during which `@Observable` diffing can capture
/// intermediate credential state (P9-A-07).
///
/// The coordinator reads `NSSecureTextField.stringValue` **only** when the user
/// moves focus away or presses Return. At that point it calls `onFinalize` with
/// the UTF-8 bytes, then immediately overwrites the field's `stringValue` to
/// drop the temporary NSString copy.
///
/// `onTextChange` receives a Bool (true if the field is non-empty) on every
/// keystroke. This drives button-enabled state without ever exposing the
/// in-progress string value to `@Observable` diffing (P9-A-07).
///
/// Usage in `OnboardingView`:
/// ```swift
/// SecureSecretField(placeholder: "Client Secret",
///                  onTextChange: { flow.secretFieldHasText = $0 }) { data in
///     flow.setClientSecret(data)
/// }
/// ```
struct SecureSecretField: NSViewRepresentable {

    var placeholder: String = ""
    /// Called on every keystroke with `true` if the field is non-empty.
    /// The Bool is the ENTIRE payload — the string itself is never passed.
    var onTextChange: ((Bool) -> Void)?
    var onFinalize: (Data) -> Void

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.fieldAction(_:))
        field.setAccessibilityLabel("Client Secret")
        field.setAccessibilityPlaceholderValue(placeholder)
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        nsView.placeholderString = placeholder
        context.coordinator.onFinalize = onFinalize
        context.coordinator.onTextChange = onTextChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onFinalize: onFinalize, onTextChange: onTextChange)
    }

    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var onFinalize: (Data) -> Void
        var onTextChange: ((Bool) -> Void)?

        init(onFinalize: @escaping (Data) -> Void, onTextChange: ((Bool) -> Void)? = nil) {
            self.onFinalize = onFinalize
            self.onTextChange = onTextChange
        }

        /// Called when the user presses Return (field's target-action).
        @objc func fieldAction(_ sender: NSSecureTextField) {
            finalize(sender)
        }

        /// Called when the field loses focus.
        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            finalize(field)
        }

        /// Called on every keystroke. Delivers only a Bool (non-empty), never
        /// the in-progress string content (P9-A-07).
        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            onTextChange?(!field.stringValue.isEmpty)
        }

        private func finalize(_ field: NSSecureTextField) {
            let raw = field.stringValue
            guard !raw.isEmpty else { return }
            let bytes = Data(raw.utf8)
            // Overwrite the field immediately so the NSString copy in AppKit is
            // replaced before the caller's closure fires.
            field.stringValue = ""
            onFinalize(bytes)
        }
    }
}
