import AppKit

enum Mark: Equatable {
    case rect(NSRect)
    case arrow(NSPoint, NSPoint)
    case text(String, NSPoint)
    case mosaic(NSRect)
}

enum MarkTool: String, CaseIterable {
    case rect = "Rectangle"
    case arrow = "Arrow"
    case text = "Text"
    case mosaic = "Mosaic"

    var symbol: String {
        switch self {
        case .rect: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .mosaic: "checkerboard.rectangle"
        }
    }

    func mark(from start: NSPoint, to end: NSPoint) -> Mark? {
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y),
                          width: abs(end.x - start.x), height: abs(end.y - start.y))
        return switch self {
        case .rect:
            .rect(rect)
        case .arrow:
            .arrow(start, end)
        case .text:
            nil
        case .mosaic:
            rect.width >= 1 && rect.height >= 1 ? .mosaic(rect) : nil
        }
    }
}

enum Markup {
    static let color = NSColor.systemRed
    static let width: CGFloat = 3

    static func font(lineWidth: CGFloat) -> NSFont {
        .systemFont(ofSize: 20 * lineWidth / width)
    }

    static func blockSize(lineWidth: CGFloat) -> Int {
        max(4, Int((lineWidth * 4).rounded()))
    }

    static func mosaic(_ image: CGImage, blockSize step: Int) -> CGImage? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, step > 0 else { return nil }
        let space = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        var source = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = source.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: space, bitmapInfo: bitmapInfo) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        let cols = (width + step - 1) / step
        let rows = (height + step - 1) / step
        var dest = [UInt8](repeating: 0, count: cols * rows * 4)
        source.withUnsafeBufferPointer { src in
            dest.withUnsafeMutableBufferPointer { dst in
                for cy in 0..<rows {
                    let sy0 = max(0, min(cy * step, height - step))
                    let sy1 = min(height, (cy + 1) * step)
                    let py0 = height - sy1
                    let py1 = height - sy0
                    let ty = rows - 1 - cy
                    for cx in 0..<cols {
                        let sx0 = max(0, min(cx * step, width - step))
                        let sx1 = min(width, (cx + 1) * step)
                        let count = (sx1 - sx0) * (py1 - py0)
                        var r = 0
                        var g = 0
                        var b = 0
                        var a = 0
                        for py in py0..<py1 {
                            let row = py * width
                            for px in sx0..<sx1 {
                                let i = (row + px) * 4
                                r += Int(src[i])
                                g += Int(src[i + 1])
                                b += Int(src[i + 2])
                                a += Int(src[i + 3])
                            }
                        }
                        let half = count / 2
                        let out = (ty * cols + cx) * 4
                        dst[out] = UInt8((r + half) / count)
                        dst[out + 1] = UInt8((g + half) / count)
                        dst[out + 2] = UInt8((b + half) / count)
                        dst[out + 3] = UInt8((a + half) / count)
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(dest) as CFData) else { return nil }
        return CGImage(width: cols, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: cols * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    static func render(_ marks: [Mark], in context: CGContext, image: CGImage, mosaic tiles: CGImage? = nil, lineWidth: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let mosaicRects = marks.compactMap { mark -> CGRect? in
            guard case .mosaic(let rect) = mark else { return nil }
            let clipped = rect.intersection(bounds)
            guard clipped.width > 0, clipped.height > 0 else { return nil }
            let snapped = clipped.integral.intersection(bounds)
            return snapped.width > 0 && snapped.height > 0 ? snapped : nil
        }
        if !mosaicRects.isEmpty {
            let step = blockSize(lineWidth: lineWidth)
            if let tiles = tiles ?? mosaic(image, blockSize: step) {
                let target = CGRect(x: 0, y: 0, width: tiles.width * step, height: tiles.height * step)
                for rect in mosaicRects {
                    context.saveGState()
                    context.clip(to: rect)
                    context.interpolationQuality = .none
                    context.draw(tiles, in: target)
                    context.restoreGState()
                }
            }
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for mark in marks {
            switch mark {
            case .rect(let rect):
                context.stroke(rect)
            case .arrow(let start, let end):
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = lineWidth * 4
                context.move(to: start)
                context.addLine(to: end)
                for side in [-1.0, 1.0] {
                    let turn = angle + .pi + side * .pi / 6
                    context.move(to: end)
                    context.addLine(to: CGPoint(x: end.x + cos(turn) * head, y: end.y + sin(turn) * head))
                }
                context.strokePath()
            case .text(let text, let point):
                let string = NSAttributedString(string: text, attributes: [.font: font(lineWidth: lineWidth), .foregroundColor: color])
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                string.draw(at: NSPoint(x: point.x, y: point.y - string.size().height))
                NSGraphicsContext.restoreGraphicsState()
            case .mosaic:
                break
            }
        }
        context.restoreGState()
    }

    static func export(_ image: CGImage, marks: [Mark], mosaic: CGImage? = nil, lineWidth: CGFloat) -> CGImage? {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        render(marks, in: context, image: image, mosaic: mosaic, lineWidth: lineWidth)
        return context.makeImage()
    }
}

@MainActor
final class MarkCanvas: NSView {
    let image: CGImage
    let unit: CGFloat
    let lineWidth: CGFloat
    var tool = MarkTool.rect {
        didSet {
            finishText()
            window?.invalidateCursorRects(for: self)
        }
    }
    private(set) var marks: [Mark] = []
    private var start: NSPoint?
    private var pending: Mark?
    private var mosaicTiles: CGImage?
    private let history = UndoManager()
    private var input: MarkTextView?
    private var textPoint: NSPoint?

    init(image: CGImage, unit: CGFloat, lineWidth: CGFloat) {
        self.image = image
        self.unit = unit
        self.lineWidth = lineWidth
        history.groupsByEvent = false
        super.init(frame: NSRect(x: 0, y: 0, width: CGFloat(image.width) * unit, height: CGFloat(image.height) * unit))
    }

    required init?(coder _: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { history }

    var exported: CGImage? {
        Markup.export(image, marks: marks, mosaic: mosaicTiles, lineWidth: lineWidth)
    }

    private func pixel(_ event: NSEvent) -> NSPoint {
        let point = convert(event.locationInWindow, from: nil)
        return NSPoint(x: min(max(point.x / unit, 0), CGFloat(image.width)),
                       y: min(max(point.y / unit, 0), CGFloat(image.height)))
    }

    override func mouseDown(with event: NSEvent) {
        finishText()
        window?.makeFirstResponder(self)
        pending = nil
        let point = pixel(event)
        if tool == .text {
            beginText(at: point)
        } else {
            start = point
        }
    }

    private func beginText(at point: NSPoint) {
        let font = Markup.font(lineWidth: lineWidth * unit)
        let height = ceil(font.ascender - font.descender + font.leading) + 4
        let field = MarkTextView(frame: NSRect(x: point.x * unit, y: point.y * unit - height,
                                             width: max(1, bounds.width - point.x * unit), height: height))
        field.font = font
        field.textColor = Markup.color
        field.drawsBackground = false
        field.isRichText = false
        field.allowsUndo = true
        field.textContainerInset = .zero
        field.textContainer?.lineFragmentPadding = 0
        field.textContainer?.maximumNumberOfLines = 1
        field.textContainer?.lineBreakMode = .byClipping
        field.onFinish = { [weak self] cancel in self?.finishText(cancel: cancel) }
        input = field
        textPoint = point
        addSubview(field)
        window?.makeFirstResponder(field)
    }

    func finishText(cancel: Bool = false) {
        guard let input, let point = textPoint else { return }
        let text = input.string
        input.onFinish = nil
        input.removeFromSuperview()
        self.input = nil
        textPoint = nil
        window?.makeFirstResponder(self)
        if !cancel && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.beginUndoGrouping()
            add(.text(text, point))
            history.endUndoGrouping()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        pending = tool.mark(from: start, to: pixel(event))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            start = nil
            pending = nil
            needsDisplay = true
        }
        guard let start else { return }
        let end = pixel(event)
        guard hypot(end.x - start.x, end.y - start.y) >= lineWidth * 2,
              let mark = tool.mark(from: start, to: end) else { return }
        history.beginUndoGrouping()
        add(mark)
        history.endUndoGrouping()
    }

    private func add(_ mark: Mark) {
        marks.append(mark)
        history.registerUndo(withTarget: self) { $0.remove() }
        needsDisplay = true
    }

    private func remove() {
        guard let mark = marks.popLast() else { return }
        history.registerUndo(withTarget: self) { $0.add(mark) }
        needsDisplay = true
    }

    @objc func undo(_: Any?) {
        finishText()
        history.undo()
    }

    @objc func redo(_: Any?) {
        history.redo()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.cancelOperation(nil) }
        if event.keyCode == 36 { (window as? ShotPanel)?.onSubmit?() }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let all = marks + (pending.map { [$0] } ?? [])
        if mosaicTiles == nil, all.contains(where: { if case .mosaic = $0 { true } else { false } }) {
            mosaicTiles = Markup.mosaic(image, blockSize: Markup.blockSize(lineWidth: lineWidth))
        }
        context.interpolationQuality = .high
        context.draw(image, in: bounds)
        context.saveGState()
        context.scaleBy(x: unit, y: unit)
        Markup.render(all, in: context, image: image, mosaic: mosaicTiles, lineWidth: lineWidth)
        if case .mosaic(let rect) = pending {
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(1 / unit)
            context.stroke(rect)
        }
        context.restoreGState()
    }
}

@MainActor
final class MarkTextView: NSTextView {
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }
    var onFinish: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onFinish?(true)
        } else {
            super.keyDown(with: event)
        }
    }

    override func insertNewline(_ sender: Any?) {
        onFinish?(false)
    }

    override func insertText(_ insertString: Any, replacementRange: NSRange) {
        let string = (insertString as? NSAttributedString)?.string ?? insertString as? String ?? ""
        super.insertText(string.components(separatedBy: .newlines).joined(separator: " "), replacementRange: replacementRange)
    }
}

@MainActor
final class MarkEditor {
    let panel: ShotPanel
    let canvas: MarkCanvas

    init(image: CGImage, scale: CGFloat, screen: NSRect, visible: NSRect, region: NSRect? = nil) {
        let natural = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let inPlace = region.map { screen.contains($0) } ?? false
        let zoom = inPlace ? 1 : min(1, (visible.width - 48) / natural.width, (visible.height - 108) / natural.height)
        canvas = MarkCanvas(image: image, unit: zoom / scale, lineWidth: Markup.width * scale)
        let undoX = 12 + CGFloat(MarkTool.allCases.count) * 36
        let toolbarSize = NSSize(width: undoX + 136, height: 48)
        let frame: NSRect
        let toolbarFrame: NSRect
        if inPlace, let region {
            let border = region.insetBy(dx: -2, dy: -2)
            let x = min(max(region.midX - toolbarSize.width / 2, visible.minX), visible.maxX - toolbarSize.width)
            let y: CGFloat
            if border.maxY + 8 + toolbarSize.height <= visible.maxY {
                y = border.maxY + 8
            } else if border.minY - 8 - toolbarSize.height >= visible.minY {
                y = border.minY - 8 - toolbarSize.height
            } else {
                y = max(visible.minY, region.maxY - toolbarSize.height - 8)
            }
            let toolbar = NSRect(origin: NSPoint(x: x, y: y), size: toolbarSize)
            frame = border.union(toolbar)
            canvas.frame.origin = NSPoint(x: region.minX - frame.minX, y: region.minY - frame.minY)
            toolbarFrame = toolbar.offsetBy(dx: -frame.minX, dy: -frame.minY)
        } else {
            let size = NSSize(width: max(canvas.frame.width, toolbarSize.width - 24) + 24, height: canvas.frame.height + 60)
            frame = NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2, width: size.width, height: size.height)
            canvas.frame.origin = NSPoint(x: (size.width - canvas.frame.width) / 2, y: 12)
            toolbarFrame = NSRect(x: (size.width - toolbarSize.width) / 2, y: size.height - 48, width: toolbarSize.width, height: 48)
        }
        panel = ShotPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.configureFloatingPanel()
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "Markup"
        if !inPlace { panel.contentView?.addSubview(GlassPanel(frame: NSRect(origin: .zero, size: frame.size))) }
        let border = NSView(frame: canvas.frame.insetBy(dx: -2, dy: -2))
        border.wantsLayer = true
        border.layer?.borderColor = NSColor.controlAccentColor.cgColor
        border.layer?.borderWidth = 2
        panel.contentView?.addSubview(border)
        panel.contentView?.addSubview(canvas)
        let toolbar = GlassPanel(frame: toolbarFrame)
        toolbar.autoresizingMask = []
        panel.contentView?.addSubview(toolbar)
        let width = toolbarSize.width
        for (index, item) in MarkTool.allCases.enumerated() {
            let button = Tap(symbol: item.symbol, flat: true) { [weak panel, weak canvas, weak toolbar] in
                canvas?.tool = item
                panel?.makeFirstResponder(canvas)
                for button in toolbar?.subviews.compactMap({ $0 as? Tap }) ?? [] where button.tag > 0 {
                    let selected = MarkTool.allCases[button.tag - 1] == item
                    button.state = selected ? .on : .off
                    button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
                }
            }
            button.tag = index + 1
            button.setButtonType(.pushOnPushOff)
            button.state = item == canvas.tool ? .on : .off
            button.frame = NSRect(x: 12 + CGFloat(index) * 36, y: 8, width: 32, height: 32)
            button.contentTintColor = item == canvas.tool ? .controlAccentColor : .secondaryLabelColor
            button.keyEquivalent = String(index + 1)
            button.keyEquivalentModifierMask = .command
            button.toolTip = "\(item.rawValue) · ⌘\(index + 1)"
            button.setAccessibilityLabel(item.rawValue)
            toolbar.addSubview(button)
        }
        let undo = Tap(symbol: "arrow.uturn.backward", flat: true) { [weak canvas] in canvas?.undo(nil) }
        undo.frame = NSRect(x: undoX, y: 8, width: 32, height: 32)
        undo.toolTip = "Undo · ⌘Z"
        undo.setAccessibilityLabel("Undo markup")
        let divider = NSBox(frame: NSRect(x: width - 94, y: 12, width: 1, height: 24))
        divider.boxType = .separator
        let cancel = Tap(symbol: "xmark", flat: true) { [weak panel] in panel?.onCancel?() }
        cancel.frame = NSRect(x: width - 80, y: 8, width: 32, height: 32)
        cancel.toolTip = "Cancel · Esc"
        cancel.setAccessibilityLabel("Cancel markup")
        let submit = Tap(symbol: "doc.on.doc", flat: true) { [weak panel, weak canvas] in
            canvas?.finishText()
            panel?.onSubmit?()
        }
        submit.frame = NSRect(x: width - 44, y: 8, width: 32, height: 32)
        submit.contentTintColor = .controlAccentColor
        submit.toolTip = "Copy · Return"
        submit.setAccessibilityLabel("Copy screenshot")
        [undo, divider, cancel, submit].forEach { toolbar.addSubview($0) }
    }
}
