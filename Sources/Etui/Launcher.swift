import AppKit
import Carbon
import ServiceManagement

final class Launcher: NSPanel, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private let content = PanelContent()
    private let history = History.load()
    private let clipboard = Clipboard.load()
    private lazy var clips = ClipPanel(clipboard: clipboard)
    private lazy var translate = TransPanel(clipboard: clipboard)
    private lazy var screenshot = Screenshot(clipboard: clipboard)
    private var catalog: [Entry] = []
    private var results: [Entry] = []
    private var selected = 0
    private var visibleStart = 0
    private let switcher = Switcher()
    private var shown = false
    private var monitor: Any?
    private var hotkeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var awake: NSObjectProtocol?
    private let closedLid = ClosedLid()

    private static let shortcuts: [(key: Int, modifiers: Int, label: String, run: @MainActor (Launcher) -> Void)] = [
        (kVK_Space, cmdKey, "Command+Space", { $0.toggle() }),
        (kVK_ANSI_V, cmdKey | shiftKey, "Command+Shift+V", { $0.clips.toggle() }),
        (kVK_ANSI_Semicolon, shiftKey | optionKey, "Shift+Option+Semicolon", { _ in Tile.snap(.left) }),
        (kVK_ANSI_Quote, shiftKey | optionKey, "Shift+Option+Quote", { _ in Tile.snap(.right) }),
        (kVK_ANSI_LeftBracket, shiftKey | optionKey, "Shift+Option+LeftBracket", { _ in Tile.shift(.left) }),
        (kVK_ANSI_RightBracket, shiftKey | optionKey, "Shift+Option+RightBracket", { _ in Tile.shift(.right) }),
        (kVK_ANSI_D, optionKey, "Option+D", { $0.translate.fromSelection() }),
        (kVK_ANSI_A, optionKey, "Option+A", { $0.translate.fromInput() }),
        (kVK_ANSI_A, controlKey | cmdKey, "Control+Command+A", { $0.screenshot.start() }),
    ]

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: PanelContent.height(rows: 0)),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        delegate = self
        content.mount(on: self, delegate: self)
        closedLid.onChange = { [weak self] in self?.updateClosedLid() }
    }

    func applicationDidFinishLaunching(_: Notification) {
        installMenu()
        registerShortcuts()
        clipboard.start()
        awake = Launcher.keepAwake()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            self?.handle(event) == false ? nil : event
        }
        if Bundle.main.bundleURL.pathExtension == "app", SMAppService.mainApp.status == .notRegistered {
            do {
                try SMAppService.mainApp.register()
            } catch {
                fputs("Etui: login item register failed: \(error)\n", stderr)
            }
        }
    }

    private static func keepAwake() -> NSObjectProtocol {
        ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                                              reason: "Etui Keep Awake")
    }

    private func registerShortcuts() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var pressed = EventHotKeyID()
            guard let context, let event,
                  GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr else {
                return OSStatus(eventNotHandledErr)
            }
            MainActor.assumeIsolated {
                let index = Int(pressed.id) - 1
                guard Launcher.shortcuts.indices.contains(index) else { return }
                Launcher.shortcuts[index].run(Unmanaged<Launcher>.fromOpaque(context).takeUnretainedValue())
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            fputs("Etui: could not create hotkey manager\n", stderr)
            return
        }
        for (index, shortcut) in Launcher.shortcuts.enumerated() {
            var hotkey: EventHotKeyRef?
            let result = RegisterEventHotKey(UInt32(shortcut.key), UInt32(shortcut.modifiers),
                                             EventHotKeyID(signature: 0x4C43_4852, id: UInt32(index + 1)),
                                             GetApplicationEventTarget(), 0, &hotkey)
            if result == noErr, let hotkey {
                hotkeys.append(hotkey)
            } else {
                fputs("Etui: \(shortcut.label) unavailable: OSStatus \(result)\n", stderr)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_: Notification) {
        hotkeys.forEach { UnregisterEventHotKey($0) }
        if let handler {
            RemoveEventHandler(handler)
        }
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func windowDidResignKey(_: Notification) {
        dismiss()
    }

    func controlTextDidChange(_: Notification) {
        refresh()
    }

    func toggle() {
        shown ? dismiss() : present()
    }

    private func present() {
        let hidden = Store.hidden()
        catalog = Catalog.applyDisplayNames(Catalog.scan().filter { $0.kind == .quit || !hidden.contains($0.id as NSString) })
            + [.awake(awake != nil), .closedLid(closedLid.state), .clean()]
        content.clear()
        shown = true
        refresh()
        content.place(on: self)
        NSApp.activate(ignoringOtherApps: true)
        orderFrontRegardless()
        makeKeyAndOrderFront(nil)
        content.focus(on: self, end: false)
        reloadTargets()
        Task { try? await closedLid.refresh() }
    }

    private func updateClosedLid() {
        guard shown, let index = catalog.firstIndex(where: { $0.id == "internal.closed-lid" }) else { return }
        catalog[index] = .closedLid(closedLid.state)
        refresh(keeping: results.indices.contains(selected) ? results[selected].id : nil)
    }

    private func toggleClosedLid() {
        guard !closedLid.state.busy else { return }
        let enable = closedLid.state == .disabled
        if enable {
            let alert = NSAlert()
            alert.messageText = "Keep Running with Lid Closed?"
            alert.informativeText = "This disables system sleep on battery and power, including manual Sleep, and can block software sleep for low battery or overheating. It stays enabled after quitting Etui or restarting. Turn it off before putting your Mac in a bag."
            alert.addButton(withTitle: "Enable")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        Task {
            do {
                if closedLid.state == .unknown {
                    try await closedLid.refresh()
                } else {
                    try await closedLid.set(enable)
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could Not Change Closed-Lid Sleep"
                alert.informativeText = error.localizedDescription
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    private func reloadTargets() {
        switcher.reload { [weak self] in
            guard let self, shown else { return }
            refresh(keeping: results.indices.contains(selected) ? results[selected].id : nil)
        }
    }

    private func dismiss(hiding: Bool = true) {
        guard shown else { return }
        shown = false
        hiding ? dismissAndHide() : orderOut(nil)
    }

    private func refresh(keeping id: String? = nil) {
        let ranked = Rank.query(content.query, apps: catalog + switcher.entries, history: history, now: Store.now())
        var seen = Set<String>()
        results = ranked
            .flatMap { $0.kind == .app ? [$0] + switcher.targets(of: $0.id) : [$0] }
            .filter { seen.insert($0.id).inserted }
        selected = id.flatMap { id in results.firstIndex { $0.id == id } } ?? 0
        visibleStart = max(0, selected - Rank.limit + 1)
        render()
    }

    private func render() {
        let visible = Array(results.dropFirst(visibleStart).prefix(Rank.limit))
        let height = content.render(entries: visible, selected: selected - visibleStart)
        content.layout(on: self, height: height, visible: shown)
    }

    private func moveSelection(_ delta: Int) {
        guard !results.isEmpty else { return }
        selected = (selected + delta + results.count) % results.count
        if selected < visibleStart {
            visibleStart = selected
        } else if selected >= visibleStart + Rank.limit {
            visibleStart = selected - Rank.limit + 1
        }
        render()
    }

    private func launch(_ index: Int? = nil) {
        if let index {
            selected = index
        }
        guard results.indices.contains(selected) else { return }
        let entry = results[selected]
        if case .closedLid(let state) = entry.kind, state.busy { return }
        if entry.kind == .target {
            Task {
                guard await switcher.focus(entry.id) else {
                    NSSound.beep()
                    reloadTargets()
                    return
                }
                dismiss(hiding: false)
            }
            return
        }
        if entry.kind != .quit {
            history.record(content.query, id: entry.id)
        }
        dismiss(hiding: entry.kind != .app)
        switch entry.kind {
        case .quit:
            NSApp.terminate(nil)
        case .settings:
            if let url = URL(string: "x-apple.systempreferences:\(entry.id)") {
                NSWorkspace.shared.open(url)
            }
        case .app:
            if switcher.reveal(app: entry.id) { break }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: entry.path), configuration: config)
        case .awake:
            if let awake {
                ProcessInfo.processInfo.endActivity(awake)
                self.awake = nil
            } else {
                awake = Launcher.keepAwake()
            }
        case .closedLid:
            toggleClosedLid()
        case .clean:
            Clean.run()
        case .target:
            break
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard shown else { return true }
        switch event.type {
        case .keyDown where !event.modifierFlags.contains(.command):
            switch keyAction(event) {
            case .dismiss: dismiss()
            case .submit: launch()
            case .down: moveSelection(1)
            case .up: moveSelection(-1)
            default: return true
            }
        case .leftMouseDown:
            guard let index = content.click(on: self, event: event) else {
                return content.passesClick(on: self, event: event)
            }
            launch(visibleStart + index)
        default: return true
        }
        return false
    }

    private func installMenu() {
        let bar = NSMenu()
        for entries in [[("Quit", "terminate:", "q", false)], [
            ("Undo", "undo:", "z", false), ("Redo", "redo:", "z", true),
            ("Cut", "cut:", "x", false), ("Copy", "copy:", "c", false),
            ("Paste", "paste:", "v", false), ("Select All", "selectAll:", "a", false),
        ]] {
            let menu = NSMenu()
            for (title, action, key, shift) in entries {
                let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
                if shift {
                    item.keyEquivalentModifierMask = [.command, .shift]
                }
                menu.addItem(item)
            }
            let parent = NSMenuItem()
            parent.submenu = menu
            bar.addItem(parent)
        }
        NSApp.mainMenu = bar
    }

    required init?(coder _: NSCoder) {
        nil
    }
}
