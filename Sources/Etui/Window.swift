import AppKit

enum Edge {
    case left, right, top, bottom
}

enum Tile {
    private static let slop: CGFloat = 8

    static func stages(_ edge: Edge, screen: CGRect) -> [CGRect] {
        if edge == .top || edge == .bottom {
            let height = (screen.height / 2).rounded()
            return [CGRect(x: screen.minX, y: edge == .top ? screen.maxY - height : screen.minY,
                           width: screen.width, height: height)]
        }
        return [(1, 2), (2, 3), (1, 3), (1, 1)].map { numerator, denominator in
            let width = (screen.width * numerator / denominator).rounded()
            return CGRect(x: edge == .left ? screen.minX : screen.maxX - width,
                          y: screen.minY, width: width, height: screen.height)
        }
    }

    static func next(_ edge: Edge, current: CGRect, screen: CGRect) -> CGRect {
        let frames = stages(edge, screen: screen)
        let matched = frames.firstIndex { stage in
            [stage.minX - current.minX, stage.minY - current.minY,
             stage.width - current.width, stage.height - current.height].allSatisfy { abs($0) <= slop }
        }
        return frames[matched.map { ($0 + 1) % frames.count } ?? 0]
    }

    static func snap(_ edge: Edge) {
        guard granted() else { return }
        guard let window = frontWindow(), let current = frame(window), let display = screen(covering: current) else {
            fputs("Etui: no tileable frontmost window\n", stderr)
            return
        }
        apply(window, next(edge, current: current, screen: display.visibleFrame))
    }

    static func neighbor(_ edge: Edge, of source: CGRect, among screens: [CGRect]) -> CGRect? {
        let ordered = screens.sorted { ($0.minX, $0.minY) < ($1.minX, $1.minY) }
        guard ordered.count > 1, let index = ordered.firstIndex(of: source) else { return nil }
        return ordered[(index + (edge == .left ? ordered.count - 1 : 1)) % ordered.count]
    }

    static func relocated(_ rect: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        let scaleX = target.width / source.width
        let scaleY = target.height / source.height
        return CGRect(x: (target.minX + (rect.minX - source.minX) * scaleX).rounded(),
                      y: (target.minY + (rect.minY - source.minY) * scaleY).rounded(),
                      width: (rect.width * scaleX).rounded(), height: (rect.height * scaleY).rounded())
    }

    static func shift(_ edge: Edge) {
        guard granted() else { return }
        let screens = NSScreen.screens
        guard let window = frontWindow(), let current = frame(window), let source = screen(covering: current),
              let frame = neighbor(edge, of: source.frame, among: screens.map(\.frame)),
              let target = screens.first(where: { $0.frame == frame }) else {
            fputs("Etui: no frontmost window with a neighboring screen\n", stderr)
            return
        }
        apply(window, relocated(current, from: source.visibleFrame, to: target.visibleFrame))
    }

    static func granted() -> Bool {
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": kCFBooleanTrue as Any] as CFDictionary)
            if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return false
        }
        return true
    }

    private static func child(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
        attribute(owner, name).map { unsafeDowncast($0, to: AXUIElement.self) }
    }

    private static func axValue<Value>(_ value: CFTypeRef?, _ type: AXValueType, _ out: UnsafeMutablePointer<Value>) -> Bool {
        guard let value else { return false }
        return CFGetTypeID(value) == AXValueGetTypeID()
            && AXValueGetValue(unsafeDowncast(value, to: AXValue.self), type, out)
    }

    private static func frontWindow() -> AXUIElement? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        return child(application, kAXFocusedWindowAttribute)
            ?? child(application, kAXMainWindowAttribute)
            ?? (attribute(application, kAXWindowsAttribute) as? [AXUIElement])?.first
    }

    private static func frame(_ window: AXUIElement) -> CGRect? {
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard axValue(attribute(window, kAXPositionAttribute), .cgPoint, &origin),
              axValue(attribute(window, kAXSizeAttribute), .cgSize, &size) else { return nil }
        return flipped(CGRect(origin: origin, size: size))
    }

    private static func apply(_ window: AXUIElement, _ rect: CGRect) {
        var origin = flipped(rect).origin
        var size = rect.size
        guard let position = AXValueCreate(.cgPoint, &origin), let extent = AXValueCreate(.cgSize, &size) else { return }
        for (name, value) in [(kAXSizeAttribute, extent), (kAXPositionAttribute, position), (kAXSizeAttribute, extent)] {
            AXUIElementSetAttributeValue(window, name as CFString, value)
        }
    }

    private static func flipped(_ rect: CGRect) -> CGRect {
        let screens = NSScreen.screens
        let primary = (screens.first { $0.frame.origin == .zero } ?? screens.first)?.frame.maxY ?? 0
        return CGRect(x: rect.minX, y: primary - rect.maxY, width: rect.width, height: rect.height)
    }

    private static func screen(covering frame: CGRect) -> NSScreen? {
        NSScreen.screens.map { ($0, $0.frame.intersection(frame)) }
            .max { $0.1.width * $0.1.height < $1.1.width * $1.1.height }?.0
    }
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
