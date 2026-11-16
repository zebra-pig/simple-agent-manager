import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
import UIKit

/// A plain text editor that routes explicitly pasted files through attachment
/// intake. Clipboard contents are read only when the user invokes Paste.
struct ComposerTextInput: UIViewRepresentable {
    @Binding var text: String
    @Binding var focused: Bool
    let files: ComposerFiles?
    var commandKey: ((String) -> Bool)?

    func makeUIView(context: Context) -> AttachmentTextView {
        let view = AttachmentTextView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.isEditable = true
        view.isSelectable = true
        view.allowsEditingTextAttributes = false
        return view
    }

    func updateUIView(_ view: AttachmentTextView, context: Context) {
        context.coordinator.parent = self
        // Clear the UIKit responder as well as SwiftUI focus before navigation.
        // Otherwise the retained project editor can restore its keyboard on return.
        // UIKit can request an update while becoming first responder, before
        // textViewDidBeginEditing publishes focus. Only a true -> false binding
        // transition is a dismissal intent; an unchanged false must allow taps.
        let dismiss = context.coordinator.lastFocused && !focused
        context.coordinator.lastFocused = focused
        if dismiss, view.isFirstResponder { view.resignFirstResponder() }
        view.isEditable = context.environment.isEnabled
        view.commandKey = commandKey
        view.attach = files.map { files in { AttachmentIntake.add(providers: $0, to: files) } }
        // Do not reset the selection or an in-progress IME composition.
        if view.text != text, view.markedTextRange == nil { view.text = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AttachmentTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let line = uiView.font?.lineHeight ?? 22
        let height = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: min(max(line, height), line * 6))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextInput
        var lastFocused: Bool
        init(_ parent: ComposerTextInput) {
            self.parent = parent
            lastFocused = parent.focused
        }

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            if text == "\n", textView.markedTextRange == nil, parent.commandKey?("select") == true { return false }
            return true
        }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ textView: UITextView) { parent.focused = true }
        func textViewDidEndEditing(_ textView: UITextView) { parent.focused = false }
    }
}

final class AttachmentTextView: UITextView {
    var commandKey: ((String) -> Bool)?

    override var keyCommands: [UIKeyCommand]? {
        guard commandKey != nil else { return super.keyCommands }
        return (super.keyCommands ?? []) + [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape, "\t", "\r"].map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(pickCommand(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func pickCommand(_ command: UIKeyCommand) {
        let action = switch command.input {
        case UIKeyCommand.inputUpArrow: "previous"
        case UIKeyCommand.inputDownArrow: "next"
        case UIKeyCommand.inputEscape: "dismiss"
        default: "select"
        }
        _ = commandKey?(action)
    }

    var attach: (([NSItemProvider]) -> Void)?

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), attach != nil {
            let board = UIPasteboard.general
            // These queries inspect type availability, not clipboard contents.
            if board.hasImages || board.types.contains(where: { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .fileURL)
                    || (type.conforms(to: .data) && !type.conforms(to: .text) && !type.conforms(to: .url))
            }) { return true }
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        let providers = UIPasteboard.general.itemProviders
        let attachments = providers.filter(AttachmentIntake.isFile)
        guard !attachments.isEmpty, let attach else {
            super.paste(sender)
            return
        }
        attach(attachments)
        // Preserve text in a mixed clipboard payload at the current selection.
        for provider in providers where !AttachmentIntake.isFile(provider) && provider.canLoadObject(ofClass: String.self) {
            _ = provider.loadObject(ofClass: String.self) { [weak self] value, _ in
                guard let value else { return }
                DispatchQueue.main.async { self?.insertText(value) }
            }
        }
    }
}
#endif
