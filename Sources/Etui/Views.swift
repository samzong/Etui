import AppKit
import Carbon

private func panelFill(for appearance: NSAppearance) -> NSColor {
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(srgbRed: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255, alpha: 0.72)
        : NSColor(white: 1, alpha: 0.62)
}

final class GlassPanel: NSGlassEffectView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        cornerRadius = 20
        style = .regular
        tintColor = panelFill(for: effectiveAppearance)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tintColor = panelFill(for: effectiveAppearance)
    }
}

final class Tap: NSButton {
    private let run: () -> Void
    private let flat: Bool
    private var hovered = false

    init(symbol: String? = nil, title: String = "", flat: Bool = false, run: @escaping () -> Void) {
        self.run = run
        self.flat = flat
        super.init(frame: .zero)
        self.title = title
        image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        isBordered = symbol != nil && !flat
        bezelStyle = .regularSquare
        showsBorderOnlyWhileMouseInside = true
        imageScaling = .scaleNone
        alignment = flat ? .center : .left
        if flat {
            imagePosition = .imageOnly
            symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        }
        font = .systemFont(ofSize: 12, weight: .medium)
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(fire)
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard flat else { return }
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if flat, isEnabled, state == .on || hovered || isHighlighted {
            let color: NSColor = state == .on ? .controlAccentColor : .labelColor
            color.withAlphaComponent(isHighlighted ? 0.22 : state == .on ? 0.16 : 0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }

    @objc private func fire() {
        run()
    }
}

extension NSPanel {
    func configureFloatingPanel() {
        isReleasedWhenClosed = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        hasShadow = true
        backgroundColor = .clear
        level = .floating
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    func dismissAndHide() {
        orderOut(nil)
        NSRunningApplication.current.hide()
    }
}

func screenFor(point: NSPoint) -> NSScreen? {
    NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
}

enum KeyAction {
    case dismiss
    case submit
    case up
    case down
    case backspace
    case type(String)
}

func typableText(_ event: NSEvent) -> String? {
    guard event.modifierFlags.isDisjoint(with: [.command, .control]),
          let text = event.characters, !text.isEmpty,
          text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700 ... 0xF8FF).contains($0.value) })
    else { return nil }
    return text
}

func keyAction(_ event: NSEvent) -> KeyAction? {
    switch Int(event.keyCode) {
    case kVK_Escape: return .dismiss
    case kVK_Return, kVK_ANSI_KeypadEnter: return .submit
    case kVK_DownArrow: return .down
    case kVK_UpArrow: return .up
    case kVK_Delete: return .backspace
    default: return typableText(event).map(KeyAction.type)
    }
}

struct PanelStyle {
    var width: CGFloat
    var pad: CGFloat
    var header: CGFloat
    var rowHeight: CGFloat
    var rows: Int
    var highlightInset: CGFloat
    var cornerRadius: CGFloat
    var highlightOpacity: CGFloat
    var iconRect: NSRect
    var labelRect: NSRect
    var fontSize: CGFloat
    var badgeRect: NSRect?
    var tintsSelection = false

    func height(header: CGFloat, rows: Int) -> CGFloat {
        pad + header + CGFloat(rows) * rowHeight + pad
    }

    func rowFrame(_ index: Int, panelHeight: CGFloat, header: CGFloat) -> NSRect {
        NSRect(x: pad, y: panelHeight - pad - header - rowHeight * CGFloat(index + 1),
               width: width - pad * 2, height: rowHeight)
    }

    func index(at point: NSPoint, panelHeight: CGFloat, header: CGFloat, rows: Int) -> Int? {
        (0 ..< rows).first { rowFrame($0, panelHeight: panelHeight, header: header).contains(point) }
    }
}

@MainActor
struct Row {
    let root: NSView
    let highlight: NSBox
    let icon: NSImageView
    let label: NSTextField
    let badge: NSTextField?
    let style: PanelStyle

    init(style: PanelStyle) {
        self.style = style
        root = NSView(frame: NSRect(x: 0, y: 0, width: style.width - style.pad * 2, height: style.rowHeight))
        root.autoresizingMask = [.width, .minYMargin]
        highlight = NSBox(frame: NSRect(x: style.highlightInset, y: style.highlightInset,
                                        width: style.width - style.pad * 2 - style.highlightInset * 2,
                                        height: style.rowHeight - style.highlightInset * 2))
        highlight.boxType = .custom
        highlight.title = ""
        highlight.titlePosition = .noTitle
        highlight.borderWidth = 0
        highlight.cornerRadius = style.cornerRadius
        highlight.fillColor = .controlAccentColor.withAlphaComponent(style.highlightOpacity)
        highlight.autoresizingMask = [.width, .height]
        highlight.isHidden = true
        icon = NSImageView(frame: style.iconRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        label = NSTextField(labelWithString: "")
        label.frame = style.labelRect
        label.font = .systemFont(ofSize: style.fontSize)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        badge = style.badgeRect.map { rect in
            let badge = NSTextField(labelWithString: "")
            badge.frame = rect
            badge.alignment = .right
            badge.font = .systemFont(ofSize: 12)
            badge.textColor = .tertiaryLabelColor
            return badge
        }
        [highlight, icon, label].forEach(root.addSubview)
        if let badge {
            root.addSubview(badge)
        }
    }

    func show(title: String, image: NSImage?, badge text: String, selected: Bool) {
        highlight.isHidden = !selected
        icon.image = image
        label.stringValue = title
        badge?.stringValue = text
        if style.tintsSelection {
            label.textColor = selected ? .white : .labelColor
            badge?.textColor = selected ? .white.withAlphaComponent(0.7) : .tertiaryLabelColor
        }
    }
}

private final class DirectEditor: NSTextView {
    override func keyDown(with event: NSEvent) {
        if let text = typableText(event) {
            insertText(text, replacementRange: selectedRange())
        } else if event.characters?.isEmpty == false {
            super.keyDown(with: event)
        }
    }
}

private final class SearchCell: NSTextFieldCell {
    private let editor: DirectEditor = {
        let editor = DirectEditor()
        editor.isFieldEditor = true
        editor.isAutomaticSpellingCorrectionEnabled = false
        return editor
    }()

    override func fieldEditor(for _: NSView) -> NSTextView? {
        editor
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        centered(super.drawingRect(forBounds: rect))
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        centered(super.titleRect(forBounds: rect))
    }

    override func edit(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: centered(rect), in: view, editor: editor, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in view: NSView, editor: NSText, delegate: Any?, start: Int, length: Int) {
        super.select(withFrame: centered(rect), in: view, editor: editor, delegate: delegate, start: start, length: length)
    }

    private func centered(_ rect: NSRect) -> NSRect {
        let height = font.map { $0.ascender - $0.descender } ?? 22
        return NSRect(x: rect.minX, y: rect.minY + max(0, (rect.height - height) / 2),
                      width: rect.width, height: min(height, rect.height))
    }
}

final class PanelContent: NSView {
    static let style = PanelStyle(width: 640, pad: 4, header: 44, rowHeight: 44, rows: Rank.limit,
                                  highlightInset: 4, cornerRadius: 10, highlightOpacity: 0.18,
                                  iconRect: NSRect(x: 14, y: 6, width: 32, height: 32),
                                  labelRect: NSRect(x: 56, y: 10, width: 560, height: 24),
                                  fontSize: 15, badgeRect: nil)
    private static let searchInset: CGFloat = 24

    private let search = NSTextField()
    private let rows = (0 ..< PanelContent.style.rows).map { _ in Row(style: PanelContent.style) }
    private var icons: [Data: NSImage] = [:]
    private var count = 0

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.style.width, height: Self.height(rows: 0)))
        wantsLayer = true
        addSubview(GlassPanel(frame: bounds))
        rows.forEach { addSubview($0.root) }
        search.cell = SearchCell(textCell: "")
        search.isBezeled = false
        search.drawsBackground = false
        search.isEditable = true
        search.isSelectable = true
        search.focusRingType = .none
        search.font = .systemFont(ofSize: 22)
        search.textColor = .labelColor
        search.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [
            .font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.quaternaryLabelColor,
        ])
        search.autoresizingMask = [.width, .minYMargin]
        addSubview(search)
        applyFrames(height: frame.height)
    }

    func mount(on panel: NSPanel, delegate: NSTextFieldDelegate) {
        panel.becomesKeyOnlyIfNeeded = false
        panel.configureFloatingPanel()
        search.delegate = delegate
        panel.contentView = self
    }

    var query: String {
        search.stringValue
    }

    func clear() {
        search.stringValue = ""
        icons.removeAll()
    }

    func focus(on panel: NSPanel, end: Bool) {
        panel.makeFirstResponder(search)
        if end {
            search.currentEditor()?.selectedRange = NSRange(location: (query as NSString).length, length: 0)
        }
    }

    static func height(rows: Int) -> CGFloat {
        style.height(header: style.header, rows: rows)
    }

    func render(entries: [Entry], selected: Int) -> CGFloat {
        count = min(entries.count, rows.count)
        for (index, row) in rows.enumerated() {
            row.root.isHidden = index >= count
            guard index < count else { continue }
            row.show(title: entries[index].name, image: icon(for: entries[index]),
                     badge: "", selected: index == selected)
        }
        return Self.height(rows: count)
    }

    func layout(on panel: NSPanel, height: CGFloat, visible: Bool) {
        let frame = panel.frame
        guard abs(frame.height - height) >= 0.5 else { return }
        panel.setFrame(NSRect(x: frame.minX, y: frame.minY + frame.height - height,
                              width: Self.style.width, height: height), display: true)
        applyFrames(height: height)
        if visible {
            focus(on: panel, end: true)
        }
    }

    func click(on panel: NSPanel, event: NSEvent) -> Int? {
        guard !passesClick(on: panel, event: event) else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return Self.style.index(at: point, panelHeight: Self.height(rows: count), header: Self.style.header, rows: count)
    }

    func passesClick(on panel: NSPanel, event: NSEvent) -> Bool {
        event.windowNumber != panel.windowNumber || search.frame.contains(convert(event.locationInWindow, from: nil))
    }

    func place(on panel: NSPanel) {
        guard let screen = screenFor(point: NSEvent.mouseLocation) else { return }
        let visible = screen.visibleFrame
        let height = Self.height(rows: count)
        panel.setFrame(NSRect(x: visible.minX + floor((visible.width - Self.style.width) / 2),
                              y: visible.minY + visible.height - height - visible.height * 0.20,
                              width: Self.style.width, height: height), display: true)
    }

    private func applyFrames(height: CGFloat) {
        search.frame = NSRect(x: Self.searchInset, y: height - Self.style.pad - Self.style.header,
                              width: Self.style.width - Self.searchInset * 2, height: Self.style.header)
        for (index, row) in rows.enumerated() {
            row.root.frame = Self.style.rowFrame(index, panelHeight: height, header: Self.style.header)
        }
    }

    private func icon(for entry: Entry) -> NSImage? {
        let key = Data(entry.id.utf8)
        if let image = icons[key] {
            return image
        }
        let image: NSImage?
        switch entry.kind {
        case .calculation:
            image = nil
        case .quit:
            image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        case .awake(let on):
            image = NSImage(systemSymbolName: on ? "cup.and.saucer.fill" : "cup.and.saucer", accessibilityDescription: nil)
        case .externalDisplay:
            image = NSImage(systemSymbolName: "display.2", accessibilityDescription: nil)
        case .closedLid:
            image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
        case .clean:
            image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        case .app, .target, .settings:
            image = NSWorkspace.shared.icon(forFile: entry.path).copy() as? NSImage
            image?.size = NSSize(width: 32, height: 32)
        }
        icons[key] = image
        return image
    }
}
