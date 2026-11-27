import AppKit
import Darwin

enum MenuBarPolicy {
    static let beijing = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 8 * 3600)!
    static let refreshInterval: TimeInterval = 5
    static let yellowThreshold = 500
    static let redThreshold = 800
    static let maxProcessRows = 8
    private static let weekdays = ["", "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    private static func components(_ components: Set<Calendar.Component>, at date: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents(components, from: date)
    }

    static func clockText(at date: Date, timeZone: TimeZone = beijing) -> String {
        let parts = components([.hour, .minute], at: date, in: timeZone)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    static func dateText(at date: Date, timeZone: TimeZone = beijing) -> String {
        let parts = components([.year, .month, .day, .weekday], at: date, in: timeZone)
        let weekday = parts.weekday.flatMap { weekdays.indices.contains($0) ? weekdays[$0] : nil } ?? ""
        return String(format: "Beijing (UTC+8) · %04d-%02d-%02d %@", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, weekday)
    }

    static func nextMinuteDelay(after date: Date) -> TimeInterval {
        60 - date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.05
    }

    static func color(for count: Int?) -> NSColor? {
        guard let count else { return nil }
        if count > redThreshold { return .systemRed }
        if count > yellowThreshold { return .systemYellow }
        return nil
    }
}

struct SurgeSnapshot: Equatable, Sendable {
    struct ProcessCount: Equatable, Sendable {
        var name: String
        var count: Int
    }

    var total: Int
    var processes: [ProcessCount]
}

struct SurgeSource: Sendable {
    static let surgeCLI = "/Applications/Surge.app/Contents/Applications/surge-cli"
    static let maxBytes = 16 * 1024 * 1024

    let executable: String
    let timeout: TimeInterval

    init(executable: String = surgeCLI, timeout: TimeInterval = 3) {
        self.executable = executable
        self.timeout = timeout
    }

    static func processName(_ raw: String?) -> String {
        let trimmed = trim(raw ?? "")
        guard !trimmed.isEmpty, trimmed != "/" else { return "System" }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard let last = parts.last else { return "System" }
        for part in parts {
            let text = String(part)
            if lowercase(text).hasSuffix(".app"), text.count > 4 { return String(text.dropLast(4)) }
        }
        return String(last)
    }

    static func parse(_ data: Data, maxRows: Int = MenuBarPolicy.maxProcessRows) -> SurgeSnapshot? {
        guard data.count <= maxBytes, let dump = try? JSONDecoder().decode(ActiveDump.self, from: data) else { return nil }
        let active = dump.requests.filter { $0.completed != true }
        var counts: [String: Int] = [:]
        for request in active { counts[processName(request.processPath), default: 0] += 1 }
        let sorted = counts
            .map { SurgeSnapshot.ProcessCount(name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : Array(lowercase($0.name).utf8).lexicographicallyPrecedes(Array(lowercase($1.name).utf8)) }
        let processes: [SurgeSnapshot.ProcessCount]
        if maxRows > 0, sorted.count > maxRows {
            let head = sorted.prefix(maxRows - 1)
            let tail = sorted.dropFirst(maxRows - 1)
            processes = Array(head) + [SurgeSnapshot.ProcessCount(name: "Other (\(tail.count))", count: tail.reduce(0) { $0 + $1.count })]
        } else {
            processes = sorted
        }
        return SurgeSnapshot(total: active.count, processes: processes)
    }

    func read() -> SurgeSnapshot? {
        let deadline = DispatchTime.now() + timeout
        let process = Process()
        let output = Pipe()
        let reader = output.fileHandleForReading
        let writer = output.fileHandleForWriting
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? reader.close()
            try? writer.close()
        }
        let fd = reader.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["dump", "active", "--raw"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        try? writer.close()
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.uptimeNanoseconds else { return nil }
            let ms = Int32(clamping: (deadline.uptimeNanoseconds - now + 999_999) / 1_000_000)
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, ms)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, pfd.revents & Int16(POLLIN | POLLHUP) != 0 else { return nil }
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return nil
            }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= Self.maxBytes else { return nil }
        }
        guard finished.wait(timeout: deadline) == .success, process.terminationStatus == 0 else { return nil }
        return Self.parse(data)
    }

    private struct ActiveDump: Decodable {
        struct Request: Decodable {
            let processPath: String?
            let completed: Bool?
        }
        let requests: [Request]
    }
}

enum MenuBarPopupState: Equatable {
    case loading
    case ready(SurgeSnapshot)
    case unavailable
}

@MainActor
private func menuLabel(_ text: String = "", font: NSFont, color: NSColor, align: NSTextAlignment = .left) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.alignment = align
    label.lineBreakMode = .byTruncatingTail
    return label
}

@MainActor
private final class MenuBarContent: NSView {
    static let width: CGFloat = 260
    private static let pad: CGFloat = 12
    private static let rowHeight: CGFloat = 24

    private let dateLabel = menuLabel(font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
    private let summaryTitle = menuLabel("Surge Connections", font: .systemFont(ofSize: 13, weight: .medium), color: .labelColor)
    private let summaryCount = menuLabel("—", font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold), color: .tertiaryLabelColor, align: .right)
    private let separator = NSBox()
    private let rows: [(root: NSView, name: NSTextField, count: NSTextField)] = (0 ..< MenuBarPolicy.maxProcessRows).map { _ in
        let root = NSView(frame: .zero)
        root.autoresizingMask = [.width, .minYMargin]
        let name = menuLabel(font: .systemFont(ofSize: 13), color: .labelColor)
        let count = menuLabel(font: .monospacedDigitSystemFont(ofSize: 13, weight: .regular), color: .secondaryLabelColor, align: .right)
        root.addSubview(name)
        root.addSubview(count)
        return (root, name, count)
    }

    static func height(rowCount: Int) -> CGFloat {
        pad * 2 + 61 + CGFloat(max(1, rowCount)) * rowHeight
    }

    convenience init() {
        self.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height(rowCount: 1)))
        wantsLayer = true
        addSubview(GlassPanel(frame: bounds))
        [dateLabel, summaryTitle, separator].forEach { $0.autoresizingMask = [.width, .minYMargin] }
        summaryCount.autoresizingMask = [.minXMargin, .minYMargin]
        separator.boxType = .custom
        separator.titlePosition = .noTitle
        separator.borderWidth = 0
        separator.fillColor = NSColor(name: nil) {
            $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08)
        }
        [dateLabel, summaryTitle, summaryCount, separator].forEach(addSubview)
        rows.forEach { addSubview($0.root) }
        place(height: frame.height)
    }

    func render(dateText: String, state: MenuBarPopupState) -> CGFloat {
        dateLabel.stringValue = dateText
        let items: [(String, String, NSColor)]
        switch state {
        case .loading:
            summaryCount.stringValue = "—"
            summaryCount.textColor = .tertiaryLabelColor
            items = [("Loading…", "", .tertiaryLabelColor)]
        case .unavailable:
            summaryCount.stringValue = "—"
            summaryCount.textColor = .tertiaryLabelColor
            items = [("Surge unavailable", "", .tertiaryLabelColor)]
        case .ready(let snapshot):
            summaryCount.stringValue = String(snapshot.total)
            summaryCount.textColor = MenuBarPolicy.color(for: snapshot.total) ?? .labelColor
            items = snapshot.processes.isEmpty
                ? [("No active connections", "", .tertiaryLabelColor)]
                : snapshot.processes.prefix(rows.count).map { ($0.name, String($0.count), .labelColor) }
        }
        for (index, row) in rows.enumerated() {
            row.root.isHidden = index >= items.count
            guard index < items.count else { continue }
            row.name.stringValue = items[index].0
            row.count.stringValue = items[index].1
            row.name.textColor = items[index].2
        }
        return Self.height(rowCount: items.count)
    }

    func place(height: CGFloat) {
        let inner = Self.width - Self.pad * 2
        var y = height - Self.pad - 16
        dateLabel.frame = NSRect(x: Self.pad, y: y, width: inner, height: 16)
        y -= 30
        summaryTitle.frame = NSRect(x: Self.pad, y: y + 3, width: inner - 64, height: 18)
        summaryCount.frame = NSRect(x: Self.width - Self.pad - 64, y: y + 2, width: 64, height: 20)
        y -= 9
        separator.frame = NSRect(x: Self.pad, y: y, width: inner, height: 1)
        y -= 6
        for (index, row) in rows.enumerated() {
            row.root.frame = NSRect(x: Self.pad, y: y - CGFloat(index + 1) * Self.rowHeight, width: inner, height: Self.rowHeight)
            row.name.frame = NSRect(x: 0, y: 3, width: inner - 48, height: 18)
            row.count.frame = NSRect(x: inner - 48, y: 3, width: 48, height: 18)
        }
    }
}

@MainActor
final class MenuBarPanel: NSPanel, NSWindowDelegate {
    private let content = MenuBarContent()
    private(set) var renderedState: MenuBarPopupState = .loading
    var onDismiss: ((Bool) -> Void)?

    override var canBecomeKey: Bool { true }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: MenuBarContent.width, height: MenuBarContent.height(rowCount: 1)),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        configureFloatingPanel()
        contentView = content
    }

    func render(dateText: String, state: MenuBarPopupState) -> CGFloat {
        renderedState = state
        return content.render(dateText: dateText, state: state)
    }

    func place(below anchor: NSRect?, height: CGFloat) {
        let reference = anchor ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: MenuBarContent.width, height: height)
        let visible = (screenFor(point: NSPoint(x: reference.midX, y: reference.midY))?.visibleFrame ?? reference).insetBy(dx: 8, dy: 8)
        let width = MenuBarContent.width
        let x = anchor != nil ? min(max(reference.midX - width / 2, visible.minX), max(visible.minX, visible.maxX - width)) : max(visible.minX, visible.maxX - width)
        let y = anchor != nil ? min(max(reference.minY - 6 - height, visible.minY), max(visible.minY, visible.maxY - height)) : max(visible.minY, visible.maxY - height)
        setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height), display: true)
        content.place(height: height)
    }

    func resizeKeepingTop(height: CGFloat) {
        guard abs(frame.height - height) >= 0.5 else { return }
        let visible = (screen?.visibleFrame ?? screenFor(point: NSPoint(x: frame.midX, y: frame.midY))?.visibleFrame ?? frame).insetBy(dx: 8, dy: 8)
        let y = min(max(frame.maxY - height, visible.minY), max(visible.minY, visible.maxY - height))
        setFrame(NSRect(x: frame.minX, y: y.rounded(), width: MenuBarContent.width, height: height), display: true)
        content.place(height: height)
    }

    func windowDidResignKey(_: Notification) {
        if isVisible { onDismiss?(true) }
    }

    override func keyDown(with event: NSEvent) {
        if case .dismiss = keyAction(event) {
            onDismiss?(false)
            return
        }
        super.keyDown(with: event)
    }

    required init?(coder _: NSCoder) { nil }
}

@MainActor
final class MenuBar: NSObject {
    static let enabledKey = "menuBarClock"

    private let defaults: UserDefaults
    private let statusBar: NSStatusBar
    private let now: () -> Date
    private let source: @Sendable () -> SurgeSnapshot?
    let panel = MenuBarPanel()

    private(set) var enabled: Bool
    private var item: NSStatusItem?
    private var minuteTimer: Timer?
    private var sampleTimer: Timer?
    private var notifications: [NSObjectProtocol] = []
    private var started = false
    private var sampling = false
    private var generation: UInt64 = 0
    private var popupState: MenuBarPopupState = .loading
    private var resignedOnButtonAt: TimeInterval = -.infinity

    var isShowingItem: Bool { item != nil }
    var currentTitle: String? { item?.button?.title }

    init(defaults: UserDefaults = .standard, statusBar: NSStatusBar = .system,
         now: @escaping () -> Date = Date.init, source: @escaping @Sendable () -> SurgeSnapshot? = { SurgeSource().read() }) {
        self.defaults = defaults
        self.statusBar = statusBar
        self.now = now
        self.source = source
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        super.init()
        panel.onDismiss = { [weak self] in self?.handleDismiss(fromResign: $0) }
    }

    func start() {
        guard !started else { return }
        started = true
        for (center, name) in [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NotificationCenter.default, Notification.Name.NSSystemClockDidChange),
        ] {
            notifications.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshClock() }
            })
        }
        if enabled { mountItem() }
    }

    func stop() {
        started = false
        dismissPopup()
        unmountItem()
        for notification in notifications {
            NSWorkspace.shared.notificationCenter.removeObserver(notification)
            NotificationCenter.default.removeObserver(notification)
        }
        notifications.removeAll()
    }

    func set(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        guard started else { return }
        if value { mountItem() } else { dismissPopup(); unmountItem() }
    }

    @objc func togglePopup() {
        if panel.isVisible { dismissPopup(); return }
        if ProcessInfo.processInfo.systemUptime - resignedOnButtonAt < 0.25 {
            resignedOnButtonAt = -.infinity
            return
        }
        presentPopup()
    }

    func dismissPopup() { handleDismiss(fromResign: false) }

    func applySample(_ snapshot: SurgeSnapshot?) {
        popupState = snapshot.map(MenuBarPopupState.ready) ?? .unavailable
        guard panel.isVisible else { return }
        panel.resizeKeepingTop(height: panel.render(dateText: MenuBarPolicy.dateText(at: now()), state: popupState))
    }

    private func mountItem() {
        if item == nil {
            let statusItem = statusBar.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            statusItem.button?.target = self
            statusItem.button?.action = #selector(togglePopup)
            item = statusItem
        }
        refreshClock()
    }

    private func unmountItem() {
        minuteTimer?.invalidate()
        minuteTimer = nil
        if let item { statusBar.removeStatusItem(item); self.item = nil }
    }

    private func refreshClock() {
        minuteTimer?.invalidate()
        guard started, enabled, let item else { minuteTimer = nil; return }
        let current = now()
        item.button?.title = MenuBarPolicy.clockText(at: current)
        if panel.isVisible {
            panel.resizeKeepingTop(height: panel.render(dateText: MenuBarPolicy.dateText(at: current), state: popupState))
        }
        let timer = Timer(timeInterval: MenuBarPolicy.nextMinuteDelay(after: current), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshClock() }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    private func presentPopup() {
        guard started, enabled else { return }
        generation &+= 1
        popupState = .loading
        panel.place(below: buttonScreenRect(), height: panel.render(dateText: MenuBarPolicy.dateText(at: now()), state: popupState))
        NSApp?.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
        sampleNow()
        sampleTimer?.invalidate()
        let timer = Timer(timeInterval: MenuBarPolicy.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sampleNow() }
        }
        RunLoop.main.add(timer, forMode: .common)
        sampleTimer = timer
    }

    private func handleDismiss(fromResign: Bool) {
        sampleTimer?.invalidate()
        sampleTimer = nil
        if fromResign, buttonScreenRect()?.contains(NSEvent.mouseLocation) == true {
            resignedOnButtonAt = ProcessInfo.processInfo.systemUptime
        }
        popupState = .loading
        if panel.isVisible { panel.orderOut(nil) }
    }

    private func buttonScreenRect() -> NSRect? {
        guard let button = item?.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func sampleNow() {
        guard panel.isVisible, enabled, !sampling else { return }
        sampling = true
        let expected = generation
        let read = source
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let snapshot = read()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sampling = false
                guard self.panel.isVisible, self.enabled else { return }
                if expected == self.generation { self.applySample(snapshot) } else { self.sampleNow() }
            }
        }
    }
}
