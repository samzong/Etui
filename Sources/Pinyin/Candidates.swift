import AppKit

@MainActor
final class Candidates {
    static let shared = Candidates()

    private let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    private let label = NSTextField(labelWithString: "")
    private let inset = NSSize(width: 12, height: 7)
    private var generation = 0

    private init() {
        panel.level = NSWindow.Level(Int(CGShieldingWindowLevel()))
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let glass = NSGlassEffectView()
        glass.cornerRadius = 12
        let content = NSView()
        content.addSubview(label)
        glass.contentView = content
        panel.contentView = glass
    }

    func show(_ candidates: [(text: String, comment: String)], highlighted: Int, first: Bool, last: Bool, at caret: NSRect) {
        let font = NSFont.systemFont(ofSize: 16)
        let small = NSFont.systemFont(ofSize: 12)
        let line = NSMutableAttributedString()
        for (index, candidate) in candidates.enumerated() {
            let color: NSColor = index == highlighted ? .controlAccentColor : .labelColor
            line.append(NSAttributedString(string: index == 0 ? "" : "   "))
            line.append(NSAttributedString(string: "\(index + 1) ", attributes: [.font: small, .foregroundColor: NSColor.labelColor]))
            line.append(NSAttributedString(string: candidate.text, attributes: [.font: font, .foregroundColor: color]))
            if !candidate.comment.isEmpty {
                line.append(NSAttributedString(string: " " + candidate.comment, attributes: [.font: small, .foregroundColor: NSColor.secondaryLabelColor]))
            }
        }
        if !(first && last) {
            for (arrow, enabled) in [("   ◀", !first), (" ▶", !last)] {
                line.append(NSAttributedString(string: arrow, attributes: [.font: small, .foregroundColor: enabled ? NSColor.secondaryLabelColor : NSColor.quaternaryLabelColor]))
            }
        }
        present(line, at: caret)
    }

    func flash(_ text: String, at caret: NSRect) {
        present(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.labelColor]), at: caret)
        let current = generation
        Task {
            try? await Task.sleep(for: .milliseconds(1500))
            if generation == current {
                hide()
            }
        }
    }

    private func present(_ line: NSAttributedString, at caret: NSRect) {
        generation += 1
        label.attributedStringValue = line
        label.frame = NSRect(origin: NSPoint(x: inset.width, y: inset.height), size: label.fittingSize)

        let size = NSSize(width: label.frame.width + inset.width * 2, height: label.frame.height + inset.height * 2)
        let bounds = (NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = NSPoint(x: caret.minX, y: caret.minY - size.height - 4)
        if origin.y < bounds.minY {
            origin.y = caret.maxY + 4
        }
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }
}
