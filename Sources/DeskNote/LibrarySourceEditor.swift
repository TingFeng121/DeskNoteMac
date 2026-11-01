import AppKit
import SwiftUI

/// Source mode keeps every Markdown delimiter visible. Only attributes change while typing;
/// AppKit owns the text, input-method composition, selection and undo history.
struct LibrarySourceEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false

        let editor = LibrarySourceTextView()
        editor.baseFontSize = CGFloat(fontSize)
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFontPanel = false
        editor.backgroundColor = .clear
        editor.drawsBackground = false
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.autoresizingMask = [.width]
        editor.textContainer?.size = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainerInset = NSSize(width: 18, height: 16)
        editor.delegate = context.coordinator
        editor.string = text
        editor.highlight()
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? LibrarySourceTextView else { return }
        context.coordinator.text = $text
        editor.baseFontSize = CGFloat(fontSize)
        guard !editor.hasMarkedText() else { return }
        if editor.string != text {
            let selection = editor.selectedRange()
            editor.string = text
            editor.setSelectedRange(NSRange(location: min(selection.location, (text as NSString).length), length: 0))
            editor.highlight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? LibrarySourceTextView else { return }
            // An input method owns its marked range until composition commits.
            guard !editor.hasMarkedText() else { return }
            text.wrappedValue = editor.string
        }
    }
}

private final class LibrarySourceTextView: NSTextView {
    var baseFontSize: CGFloat = 13 {
        didSet { if oldValue != baseFontSize { highlight() } }
    }
    private var highlighting = false

    override func didChangeText() {
        super.didChangeText()
        highlight()
    }

    override func unmarkText() {
        super.unmarkText()
        highlight()
        // Some input methods finish composition without a final textDidChange notification.
        delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: self))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        highlight()
    }

    override func insertTab(_ sender: Any?) {
        guard !hasMarkedText() else { super.insertTab(sender); return }
        insertText("  ", replacementRange: selectedRange())
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, !hasMarkedText() else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "b": wrap("**", "**"); return true
        case "i": wrap("*", "*"); return true
        case "k": wrap("[", "](https://)"); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func wrap(_ before: String, _ after: String) {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        insertText(before + selected + after, replacementRange: range)
        setSelectedRange(NSRange(location: range.location + (before as NSString).length, length: range.length))
    }

    func highlight() {
        guard !highlighting, !hasMarkedText(), let storage = textStorage else { return }
        highlighting = true
        defer { highlighting = false }
        let whole = NSRange(location: 0, length: storage.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = baseFontSize * 0.3
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph
        ]
        storage.beginEditing()
        storage.setAttributes(base, range: whole)
        func apply(_ pattern: String, _ attributes: [NSAttributedString.Key: Any], options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            for match in regex.matches(in: string, range: whole) {
                storage.addAttributes(attributes, range: match.range)
            }
        }
        apply(#"^#{1,6}\s+.*$"#, [.foregroundColor: NSColor.controlAccentColor,
              .font: NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .semibold)], options: .anchorsMatchLines)
        apply(#"\*\*[^\n]+?\*\*|__[^\n]+?__"#, [.font: NSFont.monospacedSystemFont(ofSize: baseFontSize, weight: .bold)])
        apply(#"!?\[[^\]\n]*\]\([^\n)]*\)|\[\[[^\]\n]+\]\]"#, [.foregroundColor: NSColor.linkColor])
        apply(#"^\s*(?:[-*+]\s+|\d+\.\s+|>\s?|---\s*$)"#, [.foregroundColor: NSColor.secondaryLabelColor], options: .anchorsMatchLines)
        apply(#"`[^`\n]+`"#, [.foregroundColor: NSColor.secondaryLabelColor,
              .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)])
        apply(#"^\s*```[^\n]*(?:\n[\s\S]*?^\s*```\s*$|\z)"#,
              [.foregroundColor: NSColor.secondaryLabelColor], options: .anchorsMatchLines)
        storage.endEditing()
        typingAttributes = base
    }
}
