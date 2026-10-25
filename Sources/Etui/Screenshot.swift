import AppKit
import ScreenCaptureKit

struct ScrollFrame {
    let image: CGImage
    let rows: [[UInt8]]

    init?(_ image: CGImage) {
        let width = 64
        var pixels = [UInt8](repeating: 0, count: width * image.height * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: image.height))
            return true
        }
        guard rendered else { return nil }
        self.image = image
        rows = (0..<image.height).map { y in
            (4..<60).map { x in
                let i = (y * width + x) * 4
                return UInt8((Int(pixels[i]) + Int(pixels[i + 1]) * 2 + Int(pixels[i + 2])) / 4)
            }
        }
    }

    func difference(_ next: ScrollFrame, offset: Int, sampled: Bool) -> Double {
        let count = rows.count - offset
        guard count > 0 else { return .infinity }
        let step = sampled ? max(1, count / 32) : 1
        var error = 0
        var values = 0
        for y in stride(from: 0, to: count, by: step) {
            let a = rows[y + offset]
            let b = next.rows[y]
            guard Int(a.max() ?? 0) - Int(a.min() ?? 0) > 12 else { continue }
            for x in a.indices {
                error += abs(Int(a[x]) - Int(b[x]))
            }
            values += a.count
        }
        return values >= 56 * 8 ? Double(error) / Double(values) : .infinity
    }

    func advance(to next: ScrollFrame) -> Int? {
        guard image.width == next.image.width, rows.count == next.rows.count,
              rows.count >= 64 else { return nil }
        if isStable(next) { return 0 }
        let overlap = max(48, rows.count / 4)
        let scores = (1...(rows.count - overlap)).map { ($0, difference(next, offset: $0, sampled: true)) }
        guard let best = scores.min(by: { $0.1 < $1.1 }), best.1 < 3,
              difference(next, offset: best.0, sampled: false) < 3 else { return nil }
        guard !scores.contains(where: { abs($0.0 - best.0) > 3 && $0.1 < max(0.15, best.1 * 1.5) }) else { return nil }
        return best.0
    }

    func isStable(_ next: ScrollFrame) -> Bool {
        guard image.width == next.image.width, rows.count == next.rows.count else { return false }
        var error = 0
        for y in rows.indices {
            for x in rows[y].indices {
                error += abs(Int(rows[y][x]) - Int(next.rows[y][x]))
            }
        }
        return Double(error) / Double(rows.count * 56) < 0.25
    }
}

struct ShotFrame {
    let image: CGImage
    let scale: CGFloat

    func crop(_ rect: CGRect, screenHeight: CGFloat) -> CGImage? {
        guard scale > 0, rect.width >= 1, rect.height >= 1 else { return nil }
        let x = max(0, Int(rect.minX * scale))
        let y = max(0, Int((screenHeight - rect.maxY) * scale))
        guard x < image.width, y < image.height else { return nil }
        let width = min(image.width - x, max(1, Int(rect.width * scale)))
        let height = min(image.height - y, max(1, Int(rect.height * scale)))
        return image.cropping(to: CGRect(x: x, y: y, width: width, height: height))
    }
}

struct ScrollShot {
    enum Failure: String {
        case overlap = "No reliable overlap. Scroll back, then move down more slowly."
        case limit = "Image limit reached. Finish to keep the captured portion."
        case render = "Could not append this frame."
    }

    private(set) var last: ScrollFrame
    private var strips: [CGImage]
    private(set) var height: Int
    private(set) var limited = false
    static let pixelLimit = 40_000_000

    init?(_ image: CGImage) {
        guard image.height >= 64, image.width * image.height <= Self.pixelLimit,
              let frame = ScrollFrame(image) else { return nil }
        last = frame
        strips = [image]
        height = image.height
    }

    mutating func append(_ image: CGImage) -> Failure? {
        guard !limited else { return .limit }
        guard let frame = ScrollFrame(image), let advance = last.advance(to: frame) else {
            return .overlap
        }
        guard advance > 0 else { return nil }
        guard (height + advance) * image.width <= Self.pixelLimit else {
            limited = true
            return .limit
        }
        guard let strip = image.cropping(to: CGRect(x: 0, y: image.height - advance, width: image.width, height: advance)),
              let context = CGContext(data: nil, width: image.width, height: advance, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return .render
        }
        context.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
        guard let copied = context.makeImage() else { return .render }
        strips.append(copied)
        height += advance
        last = frame
        return nil
    }

    func image(maxWidth: Int? = nil) -> CGImage? {
        let scale = maxWidth.map { min(1, CGFloat($0) / CGFloat(last.image.width), 2048 / CGFloat(height)) } ?? 1
        let width = max(1, Int(CGFloat(last.image.width) * scale))
        guard let context = CGContext(data: nil, width: width, height: max(1, Int(CGFloat(height) * scale)), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var top = height
        for strip in strips {
            top -= strip.height
            context.draw(strip, in: CGRect(x: 0, y: CGFloat(top) * scale,
                                           width: CGFloat(strip.width) * scale, height: CGFloat(strip.height) * scale))
        }
        return context.makeImage()
    }
}

@MainActor
final class Screenshot {
    private var overlays: [NSPanel] = []
    private var controls: ShotPanel?
    private var task: Task<Void, Never>?
    private var shot: ScrollShot?
    private var frames: [CGDirectDisplayID: ShotFrame] = [:]
    private var clipboard: Clipboard
    private var caller: NSRunningApplication?
    private var finishing = false

    init(clipboard: Clipboard) {
        self.clipboard = clipboard
    }

    func start() {
        guard task == nil else { return }
        caller = NSWorkspace.shared.frontmostApplication
        task = Task {
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            } catch {
                guard !Task.isCancelled else { return }
                cancel()
                let alert = NSAlert()
                alert.messageText = "Screen capture unavailable"
                alert.informativeText = "Allow Etui in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.\n\n\(error.localizedDescription)"
                alert.runModal()
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let frozen = try await freeze(content)
                guard !frozen.isEmpty else { return fail("Could not capture the screen.") }
                frames = frozen
            } catch {
                guard !Task.isCancelled else { return }
                return fail(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            select(content: content)
        }
    }

    private func freeze(_ content: SCShareableContent) async throws -> [CGDirectDisplayID: ShotFrame] {
        let excluded = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var frozen: [CGDirectDisplayID: ShotFrame] = [:]
        for screen in NSScreen.screens {
            guard !Task.isCancelled else { return [:] }
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let display = content.displays.first(where: { $0.displayID == number }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = CGFloat(filter.pointPixelScale)
            config.sourceRect = CGRect(x: 0, y: 0, width: screen.frame.width, height: screen.frame.height)
            config.width = Int(screen.frame.width * scale)
            config.height = Int(screen.frame.height * scale)
            config.showsCursor = true
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            let actual = screen.frame.width > 0 ? CGFloat(image.width) / screen.frame.width : scale
            frozen[display.displayID] = ShotFrame(image: image, scale: actual)
        }
        return frozen
    }

    private func selection(on panel: NSPanel) -> ShotSelection? {
        panel.contentView as? ShotSelection
    }

    private func select(content: SCShareableContent) {
        let desktopTop = NSScreen.screens.first?.frame.maxY ?? 0
        let ordered = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let windows = content.windows.filter {
            $0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.sorted { (ordered.firstIndex(of: $0.windowID) ?? .max) < (ordered.firstIndex(of: $1.windowID) ?? .max) }
        let toolbar = ShotPanel(size: NSSize(width: 256, height: 48))
        toolbar.title = "Screenshot"
        toolbar.level = .popUpMenu
        toolbar.onCancel = { [weak self] in self?.cancel() }
        var mode = ShotMode.area
        let submit = Tap(symbol: "doc.on.doc", flat: true) { [weak toolbar] in toolbar?.onSubmit?() }
        submit.frame = NSRect(x: 212, y: 8, width: 32, height: 32)
        submit.isEnabled = false
        submit.toolTip = "Copy · Return"
        submit.setAccessibilityLabel("Copy screenshot")
        let markup = Tap(symbol: "pencil.tip", flat: true) { [weak toolbar] in toolbar?.onMarkup?() }
        markup.frame = NSRect(x: 176, y: 8, width: 32, height: 32)
        markup.isEnabled = false
        markup.toolTip = "Markup · ⇧Return"
        markup.setAccessibilityLabel("Markup screenshot")
        for (index, item) in ShotMode.allCases.enumerated() {
            let button = Tap(symbol: item.symbol, flat: true) { [weak self, weak toolbar] in
                guard let self, let toolbar else { return }
                let previous = mode
                mode = item
                for button in toolbar.contentView?.subviews.compactMap({ $0 as? Tap }) ?? [] where button.tag > 0 {
                    let selected = ShotMode.allCases[button.tag - 1] == mode
                    button.state = selected ? .on : .off
                    button.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
                }
                guard previous != mode else { return }
                submit.image = NSImage(systemSymbolName: mode == .scroll ? "play.fill" : "doc.on.doc", accessibilityDescription: nil)
                submit.toolTip = mode == .scroll ? "Start scrolling capture · Return" : "Copy · Return"
                submit.setAccessibilityLabel(mode == .scroll ? "Start scrolling capture" : "Copy screenshot")
                submit.isEnabled = false
                markup.isEnabled = false
                toolbar.onSubmit = nil
                toolbar.onMarkup = nil
                for panel in overlays {
                    guard let view = selection(on: panel) else { continue }
                    view.mode = mode
                    if previous == .window || mode == .window { view.clear() }
                    if !view.area.isEmpty { view.selected?(view.area, nil) }
                }
                if overlays.allSatisfy({ selection(on: $0)?.area.isEmpty == true }) {
                    (overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first)?.makeKeyAndOrderFront(nil)
                }
            }
            button.tag = index + 1
            button.setButtonType(.pushOnPushOff)
            button.state = item == mode ? .on : .off
            button.frame = NSRect(x: 12 + index * 36, y: 8, width: 32, height: 32)
            button.contentTintColor = item == mode ? .controlAccentColor : .secondaryLabelColor
            button.keyEquivalent = String(index + 1)
            button.keyEquivalentModifierMask = .command
            button.toolTip = "\(item.rawValue) · ⌘\(index + 1)"
            button.setAccessibilityLabel(item.rawValue)
            toolbar.contentView?.addSubview(button)
        }
        let divider = NSBox(frame: NSRect(x: 126, y: 12, width: 1, height: 24))
        divider.boxType = .separator
        toolbar.contentView?.addSubview(divider)
        let cancel = Tap(symbol: "xmark", flat: true) { [weak self] in self?.cancel() }
        cancel.frame = NSRect(x: 140, y: 8, width: 32, height: 32)
        cancel.toolTip = "Cancel · Esc"
        cancel.setAccessibilityLabel("Cancel screenshot")
        toolbar.contentView?.addSubview(cancel)
        toolbar.contentView?.addSubview(markup)
        toolbar.contentView?.addSubview(submit)
        controls = toolbar
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
                  let display = content.displays.first(where: { $0.displayID == number }),
                  let snapshot = frames[display.displayID]?.image else { continue }
            let panel = ShotPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.configureFloatingPanel()
            panel.level = .statusBar
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.onCancel = { [weak self] in self?.cancel() }
            panel.onKeyEquivalent = { [weak toolbar] event in toolbar?.performKeyEquivalent(with: event) ?? false }
            let view = ShotSelection(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.snapshot = snapshot
            view.windows = windows.map { window in
                NSRect(x: window.frame.minX - screen.frame.minX,
                       y: desktopTop - window.frame.maxY - screen.frame.minY,
                       width: window.frame.width, height: window.frame.height)
            }
            view.selected = { [weak self, weak toolbar, weak view] rect, windowIndex in
                guard let self, let toolbar, let view else { return }
                for other in overlays {
                    guard let selection = selection(on: other), selection !== view else { continue }
                    selection.clear()
                }
                submit.isEnabled = rect.width >= 32 && rect.height >= (mode == .scroll ? 64 : 32)
                markup.isEnabled = submit.isEnabled && mode != .scroll
                let global = rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                let visible = screen.visibleFrame
                let y = global.minY - toolbar.frame.height - 10
                toolbar.setFrameOrigin(NSPoint(x: min(max(global.maxX - toolbar.frame.width, visible.minX), visible.maxX - toolbar.frame.width),
                                               y: min(max(y, visible.minY), visible.maxY - toolbar.frame.height)))
                if view.isDragging { toolbar.orderFrontRegardless() } else { toolbar.makeKeyAndOrderFront(nil) }
                let run: (Bool) -> Void = { [weak self, weak view] annotate in
                    guard let self, view != nil, submit.isEnabled else { return }
                    capture(rect: rect, display: display, screen: screen, scrolling: mode == .scroll,
                            annotate: annotate && mode != .scroll)
                }
                toolbar.onSubmit = { run(false) }
                toolbar.onMarkup = { run(true) }
            }
            panel.onSubmit = { [weak toolbar] in toolbar?.onSubmit?() }
            panel.onMarkup = { [weak toolbar] in toolbar?.onMarkup?() }
            panel.contentView = view
            panel.display()
            overlays.append(panel)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
        }
        guard !overlays.isEmpty else { return self.cancel() }
        NSApp.activate(ignoringOtherApps: true)
        let underMouse = overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays[0]
        underMouse.makeKeyAndOrderFront(nil)
        let visible = underMouse.screen?.visibleFrame ?? underMouse.frame
        toolbar.setFrameOrigin(NSPoint(x: visible.midX - toolbar.frame.width / 2, y: visible.minY + 24))
        toolbar.orderFrontRegardless()
    }

    private func capture(rect: NSRect, display: SCDisplay, screen: NSScreen, scrolling: Bool, annotate: Bool) {
        if !scrolling {
            guard let frame = frames[display.displayID],
                  let image = frame.crop(rect, screenHeight: screen.frame.height) else {
                return fail("Could not crop the screenshot.")
            }
            let scale = frame.scale
            overlays.forEach { $0.orderOut(nil) }
            overlays.removeAll()
            controls?.orderOut(nil)
            controls = nil
            frames = [:]
            if annotate {
                edit(image, scale: scale, screen: screen, region: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY))
            } else {
                copy(image)
            }
            return
        }
        overlays.forEach { $0.ignoresMouseEvents = true }
        controls?.onSubmit = nil
        controls?.onMarkup = nil
        task = Task {
            do {
                let current = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                guard !Task.isCancelled else { return }
                let excluded = current.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                guard !excluded.isEmpty else { return fail("Could not exclude Etui's capture interface.") }
                overlays.forEach { $0.orderOut(nil) }
                overlays.removeAll()
                controls?.orderOut(nil)
                frames = [:]
                let filter = SCContentFilter(display: display, excludingApplications: excluded, exceptingWindows: [])
                let config = SCStreamConfiguration()
                config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
                config.width = Int(rect.width * CGFloat(filter.pointPixelScale))
                config.height = Int(rect.height * CGFloat(filter.pointPixelScale))
                config.showsCursor = false
                config.captureResolution = .best
                let outline = ShotPanel(contentRect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY),
                                        styleMask: [.borderless], backing: .buffered, defer: false)
                outline.configureFloatingPanel()
                outline.hasShadow = false
                outline.ignoresMouseEvents = true
                outline.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                outline.contentView?.wantsLayer = true
                outline.contentView?.layer?.borderColor = NSColor.controlAccentColor.cgColor
                outline.contentView?.layer?.borderWidth = 2
                overlays = [outline]
                outline.orderFrontRegardless()
                caller?.activate()
                scroll(filter: filter, config: config, screen: screen, rect: outline.frame)
            } catch { if !Task.isCancelled { fail(error.localizedDescription) } }
        }
    }

    private func edit(_ image: CGImage, scale: CGFloat, screen: NSScreen, region: NSRect) {
        let editor = MarkEditor(image: image, scale: scale, screen: screen.frame, visible: screen.visibleFrame, region: region)
        editor.panel.level = .statusBar
        editor.panel.onCancel = { [weak self] in self?.cancel() }
        editor.panel.onSubmit = { [weak self, weak canvas = editor.canvas] in
            guard let self, let canvas else { return }
            guard let result = canvas.exported else { return fail("Could not render the markup.") }
            copy(result)
        }
        controls = editor.panel
        NSApp.activate(ignoringOtherApps: true)
        editor.panel.makeKeyAndOrderFront(nil)
        editor.panel.makeFirstResponder(editor.canvas)
    }

    private func scroll(filter: SCContentFilter, config: SCStreamConfiguration, screen: NSScreen, rect: NSRect) {
        let visible = screen.visibleFrame
        let width: CGFloat = 160
        let height = min(320, visible.height - 48)
        let x = rect.maxX + width + 12 <= visible.maxX ? rect.maxX + 12 : max(visible.minX, rect.minX - width - 12)
        let panel = ShotPanel(size: NSSize(width: width, height: height))
        panel.setFrameOrigin(NSPoint(x: x, y: max(visible.minY, min(rect.maxY - height, visible.maxY - height))))
        panel.title = "Scrolling screenshot"
        panel.onCancel = { [weak self] in self?.cancel() }
        let finish = Tap(symbol: "checkmark", flat: true) { [weak panel] in panel?.onSubmit?() }
        finish.frame = NSRect(x: width - 52, y: 8, width: 32, height: 32)
        finish.isEnabled = false
        finish.contentTintColor = .controlAccentColor
        finish.toolTip = "Finish and copy"
        finish.setAccessibilityLabel("Finish and copy screenshot")
        panel.onSubmit = { [weak self] in
            guard let self, shot != nil, !finishing else { return }
            finishing = true
            finish.isEnabled = false
        }
        let cancel = Tap(symbol: "xmark", flat: true) { [weak self] in self?.cancel() }
        cancel.frame = NSRect(x: 20, y: 8, width: 32, height: 32)
        cancel.toolTip = "Cancel"
        cancel.setAccessibilityLabel("Cancel scrolling capture")
        panel.contentView?.addSubview(finish)
        panel.contentView?.addSubview(cancel)
        let live = NSScrollView(frame: NSRect(x: 12, y: 48, width: width - 24, height: height - 60))
        live.drawsBackground = false
        live.hasVerticalScroller = true
        live.scrollerStyle = .overlay
        live.autohidesScrollers = true
        live.wantsLayer = true
        live.layer?.cornerRadius = 8
        live.layer?.masksToBounds = true
        let picture = NSImageView(frame: .zero)
        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.imageAlignment = .alignTop
        live.documentView = picture
        panel.contentView?.addSubview(live)
        controls = panel
        panel.orderFrontRegardless()
        task = Task {
            var pending: ScrollFrame?
            var previewHeight = 0
            do {
                while !Task.isCancelled {
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    guard !Task.isCancelled, let frame = ScrollFrame(image) else { return }
                    if let previous = pending, previous.isStable(frame) {
                        if shot == nil {
                            shot = ScrollShot(image)
                            guard shot != nil else { return fail("Selected area is too large.") }
                            finish.isEnabled = true
                        } else {
                            let message = shot?.append(image)
                            finish.contentTintColor = message == nil ? .controlAccentColor : .systemOrange
                            finish.toolTip = message?.rawValue ?? "Finish and copy"
                            finish.setAccessibilityHelp(message?.rawValue)
                            if finishing {
                                finishing = false
                                if message == nil || message == .limit {
                                    finishScroll()
                                    return
                                }
                                finish.isEnabled = true
                            }
                        }
                    }
                    if let shot, previewHeight != shot.height,
                       let thumbnail = shot.image(maxWidth: 136) {
                        let scaled = CGFloat(shot.height) * 136 / CGFloat(config.width)
                        picture.image = NSImage(cgImage: thumbnail, size: NSSize(width: 136, height: scaled))
                        previewHeight = shot.height
                        picture.frame.size = NSSize(width: 136, height: max(live.contentSize.height, scaled))
                        live.contentView.scroll(to: NSPoint(x: 0, y: 0))
                    }
                    pending = frame
                    try await Task.sleep(for: .milliseconds(200))
                }
            } catch is CancellationError {
            } catch { if !Task.isCancelled { fail(error.localizedDescription) } }
        }
    }

    private func finishScroll() {
        task?.cancel()
        guard let image = shot?.image() else { return fail("Could not assemble the screenshot.") }
        copy(image)
    }

    private func copy(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return fail("Could not encode the screenshot.") }
        let board = NSPasteboard.general
        board.clearContents()
        guard board.setData(data, forType: .png) else { return fail("Could not copy the screenshot.") }
        clipboard.record(kind: .image, data: data, now: Store.now())
        cancel()
    }

    private func fail(_ message: String) {
        cancel()
        let alert = NSAlert()
        alert.messageText = "Screenshot failed"
        alert.informativeText = message
        alert.runModal()
    }

    func cancel() {
        task?.cancel()
        task = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        controls?.orderOut(nil)
        controls = nil
        shot = nil
        frames = [:]
        finishing = false
        caller?.activate()
        caller = nil
    }
}

@MainActor
final class ShotPanel: NSPanel {
    var onCancel: (() -> Void)?
    var onSubmit: (() -> Void)?
    var onMarkup: (() -> Void)?
    var onKeyEquivalent: ((NSEvent) -> Bool)?

    func submit(with event: NSEvent) {
        (event.modifierFlags.contains(.shift) ? onMarkup ?? onSubmit : onSubmit)?()
    }
    convenience init(size: NSSize) {
        self.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureFloatingPanel()
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let glass = GlassPanel(frame: NSRect(origin: .zero, size: size))
        contentView?.addSubview(glass)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent?(event) == true || super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        switch keyAction(event) {
        case .dismiss: onCancel?()
        case .submit: submit(with: event)
        default: super.keyDown(with: event)
        }
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

enum ShotMode: String, CaseIterable {
    case area = "Area"
    case window = "Window"
    case scroll = "Scroll"

    var symbol: String {
        switch self {
        case .area: "rectangle.dashed"
        case .window: "macwindow"
        case .scroll: "arrow.up.and.down"
        }
    }
}

@MainActor
final class ShotSelection: NSView {
    var windows: [NSRect] = []
    var snapshot: CGImage? {
        didSet { snapshotImage = snapshot.map { NSImage(cgImage: $0, size: bounds.size) } }
    }
    private var snapshotImage: NSImage?
    var mode = ShotMode.area
    var selected: ((NSRect, Int?) -> Void)?
    private var start: NSPoint?
    var isDragging: Bool { start != nil }
    private(set) var area: NSRect = .zero
    private var original: NSRect = .zero
    private var handle: NSPoint?
    private var committed = false
    private(set) var windowIndex: Int?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var handles: [NSPoint] {
        [-1.0, 1].flatMap { x in [-1.0, 1].map { NSPoint(x: x, y: $0) } }
    }

    private func position(_ handle: NSPoint) -> NSPoint {
        NSPoint(x: area.midX + handle.x * area.width / 2, y: area.midY + handle.y * area.height / 2)
    }

    func clear() {
        area = .zero
        committed = false
        windowIndex = nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard start == nil, !committed else { return }
        let point = convert(event.locationInWindow, from: nil)
        area = mode == .window ? windows.first { $0.contains(point) }?.intersection(bounds) ?? .zero : .zero
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        start = point
        original = committed ? area : .zero
        handle = committed ? handles.first { hypot(position($0).x - point.x, position($0).y - point.y) <= 10 } : nil
        if committed, handle == nil, area.contains(point) { handle = .zero }
        if handle == nil { original = .zero }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let handle {
            let dx = point.x - start.x
            let dy = point.y - start.y
            if handle == .zero {
                area = original.offsetBy(dx: min(max(dx, -original.minX), bounds.maxX - original.maxX),
                                         dy: min(max(dy, -original.minY), bounds.maxY - original.maxY))
            } else {
                let left = handle.x < 0 ? min(original.minX + dx, original.maxX - 32) : original.minX
                let right = handle.x > 0 ? max(original.maxX + dx, original.minX + 32) : original.maxX
                let bottom = handle.y < 0 ? min(original.minY + dy, original.maxY - 32) : original.minY
                let top = handle.y > 0 ? max(original.maxY + dy, original.minY + 32) : original.maxY
                area = NSRect(x: left, y: bottom, width: right - left, height: top - bottom).intersection(bounds)
            }
        } else {
            area = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                          width: abs(point.x - start.x), height: abs(point.y - start.y)).intersection(bounds)
        }
        windowIndex = nil
        committed = true
        needsDisplay = true
        selected?(area.integral, nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start else { return }
        let point = convert(event.locationInWindow, from: nil)
        if handle == nil, hypot(point.x - start.x, point.y - start.y) < 4 {
            windowIndex = mode == .window ? windows.firstIndex { $0.contains(point) } : nil
            area = windowIndex.map { windows[$0].intersection(bounds) } ?? .zero
        }
        self.start = nil
        handle = nil
        committed = !area.isEmpty
        needsDisplay = true
        selected?(area.integral.intersection(bounds), windowIndex)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.cancelOperation(nil) }
        if event.keyCode == 36 { (window as? ShotPanel)?.submit(with: event) }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if committed { addCursorRect(area.insetBy(dx: 10, dy: 10), cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        if let snapshotImage {
            snapshotImage.draw(in: bounds)
        }
        NSColor.black.withAlphaComponent(0.4).setFill()
        if snapshotImage != nil, !area.isEmpty {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: area))
            dim.windingRule = .evenOdd
            dim.fill()
        } else {
            bounds.fill()
        }
        if !area.isEmpty {
            if snapshotImage == nil {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current?.compositingOperation = .copy
                NSColor.black.withAlphaComponent(0.01).setFill()
                area.fill()
                NSGraphicsContext.restoreGraphicsState()
            }
            NSColor.controlAccentColor.setStroke()
            let border = NSBezierPath(rect: area)
            border.lineWidth = 2
            border.stroke()
            if committed {
                for handle in handles {
                    let point = position(handle)
                    let dot = NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
                    NSGraphicsContext.saveGraphicsState()
                    let shadow = NSShadow()
                    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                    shadow.shadowBlurRadius = 3
                    shadow.shadowOffset = NSSize(width: 0, height: -1)
                    shadow.set()
                    NSColor.white.setFill()
                    dot.fill()
                    NSGraphicsContext.restoreGraphicsState()
                    dot.lineWidth = 1
                    NSColor.controlAccentColor.setStroke()
                    dot.stroke()
                }
            }
        }
        guard !area.isEmpty else { return }
        let text = "\(Int(area.width)) × \(Int(area.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = text.size(withAttributes: attributes)
        let label = NSRect(x: min(max(8, area.minX), bounds.maxX - size.width - 24),
                           y: min(area.maxY + 8, bounds.maxY - 30), width: size.width + 16, height: 24)
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: label, xRadius: 8, yRadius: 8).fill()
        text.draw(at: NSPoint(x: label.minX + 8, y: label.minY + 5), withAttributes: attributes)
    }
}
