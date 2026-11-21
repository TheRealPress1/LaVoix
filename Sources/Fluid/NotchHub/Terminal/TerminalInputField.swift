import AppKit
import SwiftUI

/// The terminal's one-line (or a few lines) input. It is the only way text reaches the shell, and it takes text only from the keyboard hardware:
///  - every key and every command-key (paste) is checked with `TerminalGuard.isHardware`; one that another program posted is dropped;
///  - every change to the text must happen inside such a key, or be one the field makes itself (clearing after a run, recalling history); anything else
///    (an Accessibility call, a drop, a service, a programmatic insert) is refused;
///  - it is not an Accessibility element, has no context menu, takes no drops and no services, so nothing outside can read it or write to it.
/// Enter runs the line. Shift-Enter adds a line. Up and Down walk through what he ran in this launch. Ctrl-C stops a running command (or clears the line).
/// Tab does nothing here: there is no completion in this tab.
final class TerminalInputTextView: NSTextView {
    var onSubmit: ((String) -> Bool)?
    var onInterrupt: (() -> Bool)?
    var onHistoryUp: ((String) -> String?)?
    var onHistoryDown: (() -> String?)?
    var onBlocked: (() -> Void)?

    private var hardwareKeyInFlight = false
    private var internalEdit = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.configure()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        self.configure()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private func configure() {
        self.isRichText = false
        self.allowsUndo = false
        self.drawsBackground = false
        self.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        self.textColor = NSColor.white.withAlphaComponent(0.95)
        self.insertionPointColor = NSColor.white
        self.isAutomaticQuoteSubstitutionEnabled = false
        self.isAutomaticDashSubstitutionEnabled = false
        self.isAutomaticTextReplacementEnabled = false
        self.isAutomaticSpellingCorrectionEnabled = false
        self.isAutomaticLinkDetectionEnabled = false
        self.isAutomaticDataDetectionEnabled = false
        self.isAutomaticTextCompletionEnabled = false
        self.isContinuousSpellCheckingEnabled = false
        self.isGrammarCheckingEnabled = false
        self.smartInsertDeleteEnabled = false
        self.isVerticallyResizable = true
        self.isHorizontallyResizable = false
        self.textContainerInset = NSSize(width: 0, height: 4)
        self.textContainer?.widthTracksTextView = true
        self.unregisterDraggedTypes()
        self.setAccessibilityElement(false)
    }

    // MARK: - closed doors

    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? { [] }
    override func accessibilitySetValue(_ value: Any?, forAttribute attribute: NSAccessibility.Attribute) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? { nil }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { false }
    override func readSelection(from pboard: NSPasteboard) -> Bool { false }

    /// The one choke point for the text: only a hardware key, or the field's own housekeeping, may change it.
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard self.hardwareKeyInFlight || self.internalEdit else { self.onBlocked?(); return false }
        return super.shouldChangeText(in: affectedCharRange, replacementString: replacementString)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard self.hardwareKeyInFlight || self.internalEdit else { self.onBlocked?(); return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        guard self.hardwareKeyInFlight else { self.onBlocked?(); return }
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        // Several lines stay in the field until he presses Enter: a paste never runs by itself.
        self.insertText(TerminalGuard.sanitized(text), replacementRange: self.selectedRange())
    }

    override func pasteAsPlainText(_ sender: Any?) { self.paste(sender) }
    override func pasteAsRichText(_ sender: Any?) { self.paste(sender) }

    /// The field's own edits (clearing after a run, recalling history).
    func setText(_ text: String) {
        self.internalEdit = true
        self.string = text
        self.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        self.internalEdit = false
    }

    // MARK: - keys

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return super.performKeyEquivalent(with: event) }
        guard TerminalGuard.isHardware(event) else { self.onBlocked?(); return true }
        self.hardwareKeyInFlight = true
        defer { self.hardwareKeyInFlight = false }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard TerminalGuard.isHardware(event) else { self.onBlocked?(); return }
        self.hardwareKeyInFlight = true
        defer { self.hardwareKeyInFlight = false }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 36, 76:                                            // Return, Enter
            if flags.contains(.shift) || flags.contains(.option) { self.insertText("\n", replacementRange: self.selectedRange()); return }
            if self.onSubmit?(self.string) == true { self.setText("") }
            return
        case 126 where flags.isEmpty && !self.string.contains("\n"):   // Up
            if let older = self.onHistoryUp?(self.string) { self.setText(older) }
            return
        case 125 where flags.isEmpty && !self.string.contains("\n"):   // Down
            if let newer = self.onHistoryDown?() { self.setText(newer) }
            return
        case 48:                                                // Tab: no completion here
            return
        case 8 where flags == .control:                         // Ctrl-C
            if self.onInterrupt?() != true { self.setText("") }
            return
        default:
            break
        }
        super.keyDown(with: event)
    }

    // MARK: - test hooks (the autotest cannot produce hardware events)

    /// Runs `body` as if a hardware key were being handled.
    func performAsHardwareKey(_ body: () -> Void) {
        self.hardwareKeyInFlight = true
        body()
        self.hardwareKeyInFlight = false
    }
}

struct TerminalInputField: NSViewRepresentable {
    let store: TerminalStore

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.setAccessibilityElement(false)
        let text = TerminalInputTextView(frame: .zero)
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let store = self.store
        text.onSubmit = { line in MainActor.assumeIsolated { store.submit(line) } }
        text.onInterrupt = { MainActor.assumeIsolated { store.interrupt() } }
        text.onHistoryUp = { current in MainActor.assumeIsolated { store.historyPrevious(current: current) } }
        text.onHistoryDown = { MainActor.assumeIsolated { store.historyNext() } }
        text.onBlocked = { MainActor.assumeIsolated { store.noteBlockedInput() } }
        scroll.documentView = text
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
