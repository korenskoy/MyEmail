//
//  RichTextEditor.swift
//  MyEmail
//
//  NSViewRepresentable bridge for NSTextView (rich-text compose).
//  Used only from ComposeView.
//

import AppKit
import SwiftUI

// MARK: - RichTextSupport

enum RichTextSupport {
    /// Custom attribute marking the signature range so we can locate and swap it
    /// when the user changes the "From" account.
    nonisolated static let signatureKey = NSAttributedString.Key("myEmailSignature")

    /// Generic CSS family aliases — Thunderbird-style. Picker shows these as
    /// "Proportional" / "Monospaced"; HTML export replaces the inline
    /// font-family with a CSS generic fallback chain so recipients without
    /// Helvetica/Menlo still render a sane font.
    nonisolated static let proportionalFamily = "Helvetica"
    nonisolated static let monospacedFamily = "Menlo"

    /// Default body font for compose. Maps to the "Proportional" generic.
    nonisolated static var defaultFont: NSFont {
        NSFont(name: proportionalFamily, size: NSFont.systemFontSize)
            ?? .systemFont(ofSize: NSFont.systemFontSize)
    }

    static var defaultTypingAttributes: [NSAttributedString.Key: Any] {
        [.font: defaultFont, .foregroundColor: NSColor.labelColor]
    }

    /// Serialize NSAttributedString to a standalone HTML document for SMTP.
    /// Post-processes the output to add CSS generic fallbacks for the two
    /// "Proportional"/"Monospaced" picker aliases.
    static func htmlFromAttributed(_ attr: NSAttributedString) -> String? {
        guard attr.length > 0 else { return nil }
        do {
            let data = try attr.data(
                from: NSRange(location: 0, length: attr.length),
                documentAttributes: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ]
            )
            guard let html = String(data: data, encoding: .utf8) else { return nil }
            return injectGenericFontFallbacks(html)
        } catch {
            LogService.log(.error, .smtp, "Failed to encode attributed body as HTML", detail: "\(error)")
            return nil
        }
    }

    /// Thunderbird-style: outgoing HTML uses only CSS generic families for
    /// the two picker aliases, so each recipient renders in their own system
    /// sans/mono font. The concrete editing font (Helvetica/Menlo) never
    /// leaks into the wire format.
    private static func injectGenericFontFallbacks(_ html: String) -> String {
        let replacements: [(String, String)] = [
            ("font-family: '\(proportionalFamily)'", "font-family: sans-serif"),
            ("font-family: \(proportionalFamily)",   "font-family: sans-serif"),
            ("font-family: '\(monospacedFamily)'",   "font-family: monospace"),
            ("font-family: \(monospacedFamily)",     "font-family: monospace"),
        ]
        var result = html
        for (needle, replacement) in replacements {
            result = result.replacingOccurrences(of: needle, with: replacement)
        }
        return result
    }

    /// Parse an HTML fragment to NSAttributedString. Used for reply/forward quotes.
    static func attributedFromHTML(_ html: String) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ],
            documentAttributes: nil
        )
    }

    nonisolated static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Apply a reply-quote visual style to an attributed string: left indent
    /// on every paragraph + muted foreground for text that used the default
    /// color. Preserves existing inline formatting (links, bold, fonts).
    static func applyQuoteStyle(to attr: NSAttributedString) -> NSAttributedString {
        guard attr.length > 0 else { return attr }
        let mutable = NSMutableAttributedString(attributedString: attr)
        let range = NSRange(location: 0, length: mutable.length)
        let indent: CGFloat = 20

        mutable.enumerateAttribute(.paragraphStyle, in: range, options: []) { value, subRange, _ in
            let base = (value as? NSParagraphStyle) ?? NSParagraphStyle.default
            let style = base.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            mutable.addAttribute(.paragraphStyle, value: style, range: subRange)
        }

        mutable.enumerateAttribute(.foregroundColor, in: range, options: []) { value, subRange, _ in
            let color = value as? NSColor
            // Only dim text that used the default/label color; preserve link
            // colors and any author-authored colors from the original message.
            if color == nil || color == NSColor.labelColor
                || color == NSColor.textColor || color == NSColor.black {
                mutable.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: subRange)
            }
        }

        return mutable
    }

    // MARK: - Formatting commands

    /// Toggle a font trait (bold/italic) on the current selection or typing
    /// attributes. Uses NSFontManager so platform font substitution works.
    static func toggleTrait(_ trait: NSFontTraitMask, on textView: NSTextView) {
        let manager = NSFontManager.shared
        let selection = textView.selectedRange()

        func convert(_ font: NSFont) -> NSFont {
            manager.traits(of: font).contains(trait)
                ? manager.convert(font, toNotHaveTrait: trait)
                : manager.convert(font, toHaveTrait: trait)
        }

        if selection.length > 0, let storage = textView.textStorage {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: selection, options: []) { value, range, _ in
                let current = (value as? NSFont) ?? defaultFont
                storage.addAttribute(.font, value: convert(current), range: range)
            }
            storage.endEditing()
            textView.didChangeText()
        } else {
            var typing = textView.typingAttributes
            let current = (typing[.font] as? NSFont) ?? defaultFont
            typing[.font] = convert(current)
            textView.typingAttributes = typing
        }
    }

    /// Apply a font family to the current selection or typing attributes,
    /// preserving size and traits (bold/italic).
    static func setFontFamily(_ family: String, on textView: NSTextView) {
        let manager = NSFontManager.shared
        applyFont(on: textView) { current in
            let traits = manager.traits(of: current)
            let weight = manager.weight(of: current)
            return manager.font(
                withFamily: family,
                traits: traits,
                weight: weight,
                size: current.pointSize
            ) ?? current
        }
    }

    /// Apply a point size to the current selection or typing attributes,
    /// preserving family and traits.
    static func setFontSize(_ size: CGFloat, on textView: NSTextView) {
        applyFont(on: textView) { current in
            NSFontManager.shared.convert(current, toSize: size)
        }
    }

    /// Read the dominant font from the current selection (or typing attrs).
    static func currentFont(in textView: NSTextView) -> NSFont {
        let selection = textView.selectedRange()
        if selection.length > 0,
           let storage = textView.textStorage,
           let font = storage.attribute(.font, at: selection.location, effectiveRange: nil) as? NSFont {
            return font
        }
        return (textView.typingAttributes[.font] as? NSFont) ?? defaultFont
    }

    private static func applyFont(
        on textView: NSTextView,
        transform: (NSFont) -> NSFont
    ) {
        let selection = textView.selectedRange()
        if selection.length > 0, let storage = textView.textStorage {
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: selection, options: []) { value, range, _ in
                let current = (value as? NSFont) ?? defaultFont
                storage.addAttribute(.font, value: transform(current), range: range)
            }
            storage.endEditing()
            textView.didChangeText()
        } else {
            var typing = textView.typingAttributes
            let current = (typing[.font] as? NSFont) ?? defaultFont
            typing[.font] = transform(current)
            textView.typingAttributes = typing
        }
    }

    /// Toggle underline attribute. Works on selection or, when empty,
    /// on typing attributes so the next keystroke inherits the change.
    static func toggleUnderline(on textView: NSTextView) {
        let single = NSUnderlineStyle.single.rawValue
        let selection = textView.selectedRange()
        if selection.length > 0, let storage = textView.textStorage {
            storage.beginEditing()
            storage.enumerateAttribute(.underlineStyle, in: selection, options: []) { value, range, _ in
                let cur = (value as? Int) ?? 0
                storage.addAttribute(.underlineStyle, value: cur == 0 ? single : 0, range: range)
            }
            storage.endEditing()
            textView.didChangeText()
        } else {
            var typing = textView.typingAttributes
            let cur = (typing[.underlineStyle] as? Int) ?? 0
            typing[.underlineStyle] = cur == 0 ? single : 0
            textView.typingAttributes = typing
        }
    }
}

// MARK: - RichTextEditor

/// SwiftUI wrapper around NSTextView for rich-text composition.
struct RichTextEditor: NSViewRepresentable {
    @Binding var attributed: NSAttributedString
    let onTextViewReady: (NSTextView) -> Void
    var onFileURLsDropped: (([URL]) -> Void)?
    var onDragTargetChanged: ((Bool) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.autoresizingMask = [.width, .height]

        let contentSize = scrollView.contentSize
        let textContainer = NSTextContainer(
            size: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.widthTracksTextView = true

        let layoutManager = NSLayoutManager()
        layoutManager.addTextContainer(textContainer)

        let textStorage = NSTextStorage()
        textStorage.addLayoutManager(layoutManager)

        let textView = ComposeFileDropAwareTextView(
            frame: NSRect(origin: .zero, size: contentSize),
            textContainer: textContainer
        )
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView

        textView.isRichText = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.usesFontPanel = true
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticDataDetectionEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.allowsImageEditing = false
        textView.font = RichTextSupport.defaultFont
        textView.typingAttributes = RichTextSupport.defaultTypingAttributes
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.drawsBackground = false
        textView.delegate = context.coordinator
        textView.onFileURLsDropped = onFileURLsDropped
        textView.onDragTargetChanged = onDragTargetChanged

        if attributed.length > 0 {
            textView.textStorage?.setAttributedString(attributed)
        }

        let ref = textView
        DispatchQueue.main.async { [onTextViewReady] in
            onTextViewReady(ref)
        }

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if let drop = textView as? ComposeFileDropAwareTextView {
            drop.onFileURLsDropped = onFileURLsDropped
            drop.onDragTargetChanged = onDragTargetChanged
        }
        // Skip if identical to avoid fighting the user's caret.
        if !textView.attributedString().isEqual(to: attributed) {
            let sel = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributed)
            let loc = min(sel.location, attributed.length)
            textView.setSelectedRange(NSRange(location: loc, length: 0))
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: RichTextEditor
        init(_ parent: RichTextEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.attributed = textView.attributedString()
        }
    }
}

// MARK: - File-URL-aware NSTextView

/// Intercepts file-URL drops so the compose view can treat them as
/// attachments instead of inserting the file path as text.
/// Non-file drags (plain text, rich text, web URLs) still behave natively.
final class ComposeFileDropAwareTextView: NSTextView {

    var onFileURLsDropped: (([URL]) -> Void)?
    var onDragTargetChanged: ((Bool) -> Void)?

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if extractFileURLs(sender).isEmpty == false {
            onDragTargetChanged?(true)
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        if extractFileURLs(sender).isEmpty == false { return .copy }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDragTargetChanged?(false)
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        onDragTargetChanged?(false)
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        if extractFileURLs(sender).isEmpty == false { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = extractFileURLs(sender)
        if !urls.isEmpty {
            onDragTargetChanged?(false)
            onFileURLsDropped?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func extractFileURLs(_ info: any NSDraggingInfo) -> [URL] {
        let pb = info.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard pb.canReadObject(forClasses: [NSURL.self], options: options),
              let objs = pb.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        else { return [] }
        return objs
    }
}

// MARK: - FormattingToolbar

/// Thin formatting bar shown above the editor in rich-text mode.
struct FormattingToolbar: View {
    let textView: NSTextView?
    @State private var showLinkSheet = false
    @State private var currentFamily: String = RichTextSupport.proportionalFamily
    @State private var currentSize: CGFloat = NSFont.systemFontSize

    private static let genericFamilies: [String] = [
        RichTextSupport.proportionalFamily,
        RichTextSupport.monospacedFamily,
    ]
    private static let otherFamilies: [String] = NSFontManager.shared
        .availableFontFamilies
        .sorted()
        .filter { !genericFamilies.contains($0) }
    private static let availableSizes: [CGFloat] = [9, 10, 11, 12, 13, 14, 16, 18, 20, 24, 28, 32, 36, 48]

    /// Friendly label for generic-family aliases; falls back to the raw family.
    private static func displayLabel(for family: String) -> String {
        switch family {
        case RichTextSupport.proportionalFamily: return String(localized: "Proportional")
        case RichTextSupport.monospacedFamily:   return String(localized: "Monospaced")
        default: return family
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            toolbarButton("Bold", systemImage: "bold", shortcut: "b") { tv in
                RichTextSupport.toggleTrait(.boldFontMask, on: tv)
            }
            toolbarButton("Italic", systemImage: "italic", shortcut: "i") { tv in
                RichTextSupport.toggleTrait(.italicFontMask, on: tv)
            }
            toolbarButton("Underline", systemImage: "underline", shortcut: "u") { tv in
                RichTextSupport.toggleUnderline(on: tv)
            }
            verticalDivider
            familyPicker
            sizePicker
            verticalDivider
            toolbarButton("Bulleted list", systemImage: "list.bullet") { tv in
                prefixLinesAsList(in: tv, numbered: false)
            }
            toolbarButton("Numbered list", systemImage: "list.number") { tv in
                prefixLinesAsList(in: tv, numbered: true)
            }
            verticalDivider
            toolbarButton("Insert link", systemImage: "link", shortcut: "k") { _ in
                showLinkSheet = true
            }
            toolbarButton("Text color", systemImage: "paintpalette") { _ in
                NSColorPanel.shared.orderFront(nil)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
        .sheet(isPresented: $showLinkSheet) {
            LinkInsertSheet(textView: textView) { showLinkSheet = false }
        }
        .onAppear { syncFromTextView() }
        .onChange(of: textView) { _, _ in syncFromTextView() }
        .task(id: ObjectIdentifier(textView ?? NSTextView())) {
            await observeSelectionChanges()
        }
    }

    private var familyPicker: some View {
        Picker("Font family", selection: Binding(
            get: { currentFamily },
            set: { newValue in
                currentFamily = newValue
                if let tv = textView {
                    RichTextSupport.setFontFamily(newValue, on: tv)
                }
            }
        )) {
            ForEach(Self.genericFamilies, id: \.self) { family in
                Text(Self.displayLabel(for: family)).tag(family)
            }
            Divider()
            ForEach(Self.otherFamilies, id: \.self) { family in
                Text(family).tag(family)
            }
        }
        .labelsHidden()
        .frame(width: 160)
        .help("Font family")
    }

    private var sizePicker: some View {
        Picker("Font size", selection: Binding(
            get: { currentSize },
            set: { newValue in
                currentSize = newValue
                if let tv = textView {
                    RichTextSupport.setFontSize(newValue, on: tv)
                }
            }
        )) {
            ForEach(Self.availableSizes, id: \.self) { size in
                Text("\(Int(size))").tag(size)
            }
        }
        .labelsHidden()
        .frame(width: 64)
        .help("Font size")
    }

    /// Update pickers to reflect the font under the caret/selection.
    private func syncFromTextView() {
        guard let tv = textView else { return }
        let font = RichTextSupport.currentFont(in: tv)
        if let family = font.familyName { currentFamily = family }
        currentSize = font.pointSize
    }

    /// Observe selection changes via NSTextView notifications so the pickers
    /// reflect formatting under the caret as the user moves around.
    private func observeSelectionChanges() async {
        guard let tv = textView else { return }
        let center = NotificationCenter.default
        let stream = center.notifications(
            named: NSTextView.didChangeSelectionNotification,
            object: tv
        )
        for await _ in stream {
            if Task.isCancelled { break }
            syncFromTextView()
        }
    }

    private var verticalDivider: some View {
        Divider().frame(height: 14).padding(.horizontal, 4)
    }

    @ViewBuilder
    private func toolbarButton(
        _ label: LocalizedStringKey,
        systemImage: String,
        shortcut: KeyEquivalent? = nil,
        action: @escaping (NSTextView) -> Void
    ) -> some View {
        let button = Button {
            if let tv = textView { action(tv) }
        } label: {
            Image(systemName: systemImage)
                .frame(width: 24, height: 20)
        }
        .buttonStyle(.borderless)
        .help(label)

        if let shortcut {
            button.keyboardShortcut(shortcut, modifiers: .command)
        } else {
            button
        }
    }

    /// Prefixes each paragraph in the selection with "• " or "N. " while
    /// preserving per-run attributes inside the line (bold, links, colors).
    /// Not a real NSTextList — plain text prefixes survive HTML export cleanly.
    private func prefixLinesAsList(in textView: NSTextView, numbered: Bool) {
        guard let storage = textView.textStorage else { return }
        let fullText = storage.string as NSString
        let paragraphRange = fullText.paragraphRange(for: textView.selectedRange())
        let paragraph = storage.attributedSubstring(from: paragraphRange)

        let result = NSMutableAttributedString()
        var counter = 1
        var lineStart = 0
        let nsParagraph = paragraph.string as NSString

        while lineStart < nsParagraph.length {
            let lineRange = nsParagraph.lineRange(for: NSRange(location: lineStart, length: 0))
            let contentLength = lineRange.length - (nsParagraph.substring(with: lineRange).hasSuffix("\n") ? 1 : 0)
            let contentRange = NSRange(location: lineRange.location, length: max(0, contentLength))

            if contentRange.length > 0 {
                let prefixStr = numbered ? "\(counter). " : "• "
                counter += 1
                let firstCharAttrs = paragraph.attributes(at: contentRange.location, effectiveRange: nil)
                result.append(NSAttributedString(string: prefixStr, attributes: firstCharAttrs))
                result.append(paragraph.attributedSubstring(from: contentRange))
            }
            if lineRange.location + lineRange.length <= nsParagraph.length,
               contentLength < lineRange.length {
                result.append(NSAttributedString(
                    string: "\n",
                    attributes: paragraph.attributes(at: contentRange.location, effectiveRange: nil)
                ))
            }
            lineStart = lineRange.location + lineRange.length
        }

        storage.beginEditing()
        storage.replaceCharacters(in: paragraphRange, with: result)
        storage.endEditing()
        textView.didChangeText()
    }
}

// MARK: - LinkInsertSheet

struct LinkInsertSheet: View {
    let textView: NSTextView?
    let onClose: () -> Void

    @State private var urlText: String = "https://"
    @State private var linkText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Insert link").font(.headline)
            TextField("URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
            TextField("Link label", text: $linkText)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Insert") { insert() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(URL(string: urlText) == nil)
            }
        }
        .padding(16)
        .frame(width: 360)
        .onAppear { populateFromSelection() }
    }

    private func populateFromSelection() {
        guard let textView, let storage = textView.textStorage else { return }
        let sel = textView.selectedRange()
        if sel.length > 0 {
            linkText = (storage.string as NSString).substring(with: sel)
        }
    }

    private func insert() {
        guard let textView, let storage = textView.textStorage,
              let url = URL(string: urlText) else { return }
        let sel = textView.selectedRange()
        let visible = linkText.isEmpty ? urlText : linkText

        var attrs = textView.typingAttributes
        attrs[.link] = url
        attrs[.foregroundColor] = NSColor.linkColor
        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue

        let insertion = NSAttributedString(string: visible, attributes: attrs)
        storage.beginEditing()
        if sel.length > 0 {
            storage.replaceCharacters(in: sel, with: insertion)
        } else {
            storage.insert(insertion, at: sel.location)
        }
        storage.endEditing()
        textView.didChangeText()
        onClose()
    }
}
