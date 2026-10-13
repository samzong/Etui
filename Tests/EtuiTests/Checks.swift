import AppKit
import Foundation
import Testing

@testable import Etui

private func makeRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("etui-checks-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func writeBundle(_ root: URL, _ path: String, _ values: [String: Any]) throws {
    let info = root.appendingPathComponent(path).appendingPathComponent("Contents/Info.plist")
    try FileManager.default.createDirectory(at: info.deletingLastPathComponent(), withIntermediateDirectories: true)
    try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0).write(to: info)
}

private func sent(_ request: URLRequest) throws -> [String: Any] {
    let body = try #require(request.httpBody)
    return try #require((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
}

private func app(_ id: String, _ name: String) -> Entry {
    Entry(id: id, name: name, aliases: [], path: "/Applications/\(name).app", kind: .app)
}

private actor SleepBackend {
    enum Outcome { case apply, cancel, reject, ignore }
    var enabled = false
    var outcome: Outcome = .apply

    func configure(_ enabled: Bool, _ outcome: Outcome = .apply) {
        self.enabled = enabled
        self.outcome = outcome
    }

    func read() -> Bool { enabled }

    func write(_ value: Bool) throws -> Bool {
        switch outcome {
        case .apply: enabled = value; return true
        case .cancel: return false
        case .reject: throw SleepSettings.Failure.command("Authorization failed")
        case .ignore: return true
        }
    }
}

@Suite struct Checks {
    @MainActor @Test func closedLidReadsSystemStateAndCancellation() async throws {
        let backend = SleepBackend()
        let lid = ClosedLid(read: { await backend.read() }, write: { try await backend.write($0) })
        try await lid.refresh()
        #expect(lid.state == .disabled)
        try await lid.set(true)
        #expect(lid.state == .enabled)
        await backend.configure(false)
        try await lid.refresh()
        #expect(lid.state == .disabled)
        await backend.configure(false, .cancel)
        try await lid.set(true)
        #expect(lid.state == .disabled)
        await backend.configure(true, .cancel)
        try await lid.set(false)
        #expect(lid.state == .enabled)
    }

    @MainActor @Test func closedLidRejectsUnappliedChanges() async {
        let backend = SleepBackend()
        let lid = ClosedLid(read: { await backend.read() }, write: { try await backend.write($0) })
        for outcome in [SleepBackend.Outcome.reject, .ignore] {
            await backend.configure(false, outcome)
            await #expect(throws: SleepSettings.Failure.self) { try await lid.set(true) }
            #expect(lid.state == .disabled)
        }
        let unreadable = ClosedLid(read: { throw SleepSettings.Failure.unreadable }, write: { _ in true })
        await #expect(throws: SleepSettings.Failure.self) { try await unreadable.set(true) }
        #expect(unreadable.state == .unknown)
    }

    @Test func systemSleepSettingCanBeRead() async throws {
        _ = try await SleepSettings.read()
    }

    @Test func searchableWindows() {
        let element = AXUIElementCreateApplication(getpid())
        func window(_ pid: pid_t, _ id: CGWindowID, _ title: String, tabs: [String] = []) -> OpenWindow {
            OpenWindow(pid: pid, id: id, element: element, title: title,
                       tabs: tabs.map { (element, $0) })
        }
        let telegram = window(1, 10, "Telegram @ samzong")
        let cursor = [window(2, 20, "launcher"), window(2, 21, "launcher")]
        let notes = [window(3, 30, "Notes"), window(3, 31, "Notes")]
        let combe = window(4, 40, "Combe", tabs: ["launcher"])
        let windows = [telegram] + cursor + notes + [combe]
        #expect(Switcher.searchableWindows(windows).map(\.id) == [20, 21, 30, 31, 40])
        #expect(Switcher.searchableWindows([cursor[0]]).isEmpty)
        #expect(Switcher.searchableWindows([]).isEmpty)
    }

    @Test func catalogDiscovery() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for (path, name, flag) in [
            ("Visible.app", "Visible", ""), ("Ghost.app", "Ghost", "LSUIElement"),
            ("Daemon.app", "Daemon", "LSBackgroundOnly"), ("Utilities/Nested.app", "Nested", ""),
            ("Visible.app/Contents/Helpers/Inner.app", "Inner", ""), ("Shout.APP", "Shout", ""),
        ] {
            var values: [String: Any] = ["CFBundleIdentifier": "dev.test.\(name)", "CFBundleName": name, "CFBundlePackageType": "APPL"]
            if !flag.isEmpty {
                values[flag] = true
            }
            try writeBundle(root, path, values)
        }
        #expect(Catalog.scan(roots: [root.path], panes: nil, extras: []).map(\.name) == ["Ghost", "Nested", "Shout", "Visible", "Quit Etui"])

        try writeBundle(root, "Pane.appex", ["CFBundleIdentifier": "dev.test.pane", "CFBundleName": "Pane",
                                             "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.Settings.extension.ui"]])
        try writeBundle(root, "Widget.appex", ["CFBundleIdentifier": "dev.test.widget", "CFBundleName": "Widget",
                                               "EXAppExtensionAttributes": ["EXExtensionPointIdentifier": "com.apple.widgetkit-extension"]])
        let panes = Catalog.scan(roots: [], panes: root.path, extras: [])
        #expect(panes.map(\.name) == ["Pane", "Quit Etui"])
        #expect(panes.first?.kind == .settings)

        try writeBundle(root, "Fresh.app", ["CFBundleName": "Fresh"])
        #expect(Catalog.scan(roots: [root.path], panes: nil, extras: []).contains { $0.name == "Fresh" })
        try FileManager.default.removeItem(at: root.appendingPathComponent("Fresh.app"))
        #expect(!Catalog.scan(roots: [root.path], panes: nil, extras: []).contains { $0.name == "Fresh" })

        try writeBundle(root, "Core/Finder.app", ["CFBundleIdentifier": "com.apple.finder", "CFBundleName": "Finder"])
        let finder = root.appendingPathComponent("Core/Finder.app").path
        #expect(Catalog.scan(roots: [], panes: nil, extras: [finder]).map(\.id) == ["com.apple.finder", "internal.quit"])
        #expect(Catalog.scan(roots: [root.path], panes: nil, extras: [finder]).filter { $0.id == "com.apple.finder" }.count == 1)
    }

    @Test func catalogMalformedPlists() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try writeBundle(root, "Legacy.app", [:])
        try Data(#"{ CFBundleName = "Legacy"; }"#.utf8)
            .write(to: root.appendingPathComponent("Legacy.app/Contents/Info.plist"))
        #expect(Catalog.parse(root.appendingPathComponent("Legacy.app").path)?.name == "Legacy")

        try writeBundle(root, "Broken.app", ["CFBundleName": "Broken"])
        let broken = root.appendingPathComponent("Broken.app/Contents/Info.plist")
        try (Data(contentsOf: broken) + Data("garbage".utf8)).write(to: broken)
        #expect(Catalog.parse(root.appendingPathComponent("Broken.app").path) == nil)
    }

    @Test func aliasesAndRecency() {
        let history = History()
        #expect(!history.remember("   ", id: "chrome"))
        #expect(history.aliasesFor("chrome").isEmpty)
        history.remember("chr", id: "chrome")
        history.remember("CHR", id: "safari")
        #expect(history.aliasesFor("safari") == ["chr"])
        #expect(history.aliasesFor("chrome").isEmpty)
        history.recordAt("old", now: 0)
        history.recordAt("old", now: 0)
        history.recordAt("new", now: 20 * 86400)
        #expect(history.score("new", now: 20 * 86400) > history.score("old", now: 20 * 86400))
    }

    @Test func matchingAndSelectionOrder() {
        let history = History()
        history.remember("chr", id: "chrome")
        let apps = [app("chrome", "Google Chrome"), app("screen", "Screen Sharing"), app("notes", "Notes"), Entry.quit]
        func hits(_ query: String) -> [String] {
            Rank.query(query, apps: apps, history: history, now: 0).map(\.id)
        }
        #expect(hits("").isEmpty)
        #expect(hits("chr") == ["chrome"])
        #expect(hits("ch") == ["chrome"])
        #expect(hits("gce").isEmpty)
        history.remember("gc", id: "chrome")
        #expect(hits("gc") == ["chrome"])

        let ties = (0 ..< 12).map { app(String($0), "Same") }
        #expect(Rank.query("same", apps: ties, history: history, now: 0).map(\.id) == (0 ..< 8).map(String.init))
    }

    @Test func unicodeMatching() {
        let history = History()
        let unicode = [app("one", "éclair"), app("two", "e\u{301}clair"), app("three", "👩‍💻 Tool"), app("four", "ΟΣ")]
        func hits(_ query: String, _ apps: [Entry]) -> [String] {
            Rank.query(query, apps: apps, history: history, now: 0).map(\.id)
        }
        #expect(hits("é", unicode) == ["one"])
        #expect(hits("e", unicode) == ["two"])
        #expect(hits("👩", unicode) == ["three"])
        #expect(hits("ος", unicode) == ["four"])

        let plain = [app("notes", "Notes")]
        #expect(hits("\u{200B}notes", plain).isEmpty)
        #expect(hits("\u{85}notes\u{85}", plain) == ["notes"])
        #expect(lowercase("A.Σ") == "a.ς")
        #expect(lowercase("\u{200B}Σ") == "\u{200B}σ")
    }

    @Test func persistenceRoundTrip() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let aliasFile = dir.appendingPathComponent("aliases.json")
        let usageFile = dir.appendingPathComponent("usage.json")
        try Data(#"{"gc":"chrome","é":"é","é":"é"}"#.utf8).write(to: aliasFile)
        try Data(#"{"apps":{"chrome":{"count":3,"last_unix":100}}}"#.utf8).write(to: usageFile)

        let loaded = History.load(dataDir: dir)
        #expect(loaded.aliasesFor("chrome") == ["gc"])
        #expect(loaded.aliasesFor("é").count == 1)
        #expect(loaded.aliasesFor("e\u{301}").count == 1)
        #expect(abs(loaded.score("chrome", now: 100) - log(4)) < 1e-12)

        loaded.record("alias", id: "id")
        loaded.record("gc", id: "notes")
        let reloaded = History.load(dataDir: dir)
        #expect(reloaded.aliasesFor("chrome").isEmpty)
        #expect(reloaded.aliasesFor("notes") == ["gc"])
        #expect(reloaded.aliasesFor("é").count == 1)
        #expect(reloaded.aliasesFor("e\u{301}").count == 1)
        #expect(reloaded.aliasesFor("id") == ["alias"])
        #expect(reloaded.score("notes", now: 0) > 0)
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("usage.json.tmp").path))
    }

    @Test func bomPrefixedKeysSurviveReload() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let history = History.load(dataDir: dir)
        history.record("alias", id: "id")
        history.record("\u{FEFF}alias", id: "\u{FEFF}id")
        let reloaded = History.load(dataDir: dir)
        #expect(reloaded.aliasesFor("\u{FEFF}id").first?.utf8.elementsEqual("\u{FEFF}alias".utf8) == true)
        #expect(reloaded.aliasesFor("id") == ["alias"])
    }

    @Test func persistenceRejectsMalformed() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let usageFile = dir.appendingPathComponent("usage.json")
        for malformed in ["{", #"{"apps":{"a":{"count":true,"last_unix":0}}}"#, #"{"apps":{"a":{"count":1.5,"last_unix":0}}}"#] {
            try Data(malformed.utf8).write(to: usageFile)
            #expect(History.load(dataDir: dir).score("a", now: 0) == 0)
        }
        try Data(#"{"valid":"chrome","invalid":1}"#.utf8).write(to: dir.appendingPathComponent("aliases.json"))
        #expect(History.load(dataDir: dir).aliasesFor("chrome").isEmpty)
    }

    @Test func clipEvictionWindow() {
        func clip(_ id: String, uses: UInt64, ageDays: Double) -> Clip {
            Clip(digest: id, kind: .text, bytes: 512,
                 lastUnix: 30 * 86400 - Int64(ageDays * 86400), uses: uses, preview: id)
        }
        let now: Int64 = 30 * 86400
        func kept(_ clips: [Clip]) -> [String] {
            Clips.retained(clips, now: now).map(\.digest)
        }
        #expect(kept([clip("fresh", uses: 1, ageDays: 1)]) == ["fresh"])
        #expect(kept([clip("stale", uses: 1, ageDays: 3)]).isEmpty)
        #expect(kept([clip("reused", uses: 5, ageDays: 5)]) == ["reused"])
        #expect(kept([clip("faded", uses: 2, ageDays: 40)]).isEmpty)
    }

    @Test func clipBudgetBreaker() {
        let now: Int64 = 0
        let clips = (0 ..< 10).map {
            Clip(digest: "c\($0)", kind: .image, bytes: 12 << 20, lastUnix: 0,
                 uses: UInt64($0 + 1), preview: "image")
        }
        let kept = Clips.retained(clips, now: now)
        #expect(kept.reduce(0) { $0 + $1.bytes } <= Clips.budget)
        #expect(kept.contains { $0.digest == "c9" })
        #expect(!kept.contains { $0.digest == "c0" })
    }

    @Test func clipQueryAndPreview() {
        func clip(_ id: String, _ preview: String, _ last: Int64) -> Clip {
            Clip(digest: id, kind: .text, bytes: preview.utf8.count, lastUnix: last, uses: 1, preview: preview)
        }
        let clips = [clip("a", "let value = 1", 10), clip("b", "SELECT * FROM users", 30), clip("c", "Let it be", 20)]
        #expect(Clips.query("", clips: clips).map(\.digest) == ["b", "c", "a"])
        #expect(Clips.query("let", clips: clips).map(\.digest) == ["c", "a"])
        #expect(Clips.query("zzz", clips: clips).isEmpty)
        #expect(Clips.preview("  let x = 1\n\n\tlet y = 2  ") == "let x = 1 let y = 2")
    }

    @MainActor @Test func clipStoreDropsBlobsWithEntries() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        let blobs = dir.appendingPathComponent("blobs")
        let clipboard = Clipboard(dir: dir)
        let later: Int64 = 5 * 86400
        clipboard.record(kind: .text, data: Data("stale".utf8), now: 0)
        clipboard.record(kind: .text, data: Data("reused".utf8), now: 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: blobs.path).count == 2)
        let stale = try #require(clipboard.recent("stale", now: 0).first)
        let reused = try #require(clipboard.recent("reused", now: 0).first)

        clipboard.record(kind: .text, data: Data("reused".utf8), now: later - 60)
        #expect(clipboard.recent("reused", now: later).map(\.uses) == [1])
        #expect(!FileManager.default.fileExists(atPath: blobs.appendingPathComponent(stale.file).path))
        #expect(FileManager.default.fileExists(atPath: blobs.appendingPathComponent(reused.file).path))
        #expect(clipboard.recent("", now: later).map(\.digest) == [reused.digest])

        let reloaded = Clipboard.load(dir: dir)
        #expect(reloaded.recent("reused", now: later).map(\.digest) == [reused.digest])
        Store.write(dir, "index.json", Data("{".utf8))
        #expect(Clipboard.load(dir: dir).recent("", now: later).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: blobs.appendingPathComponent(reused.file).path))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))
        try Data("orphan".utf8).write(to: blobs.appendingPathComponent("orphan.txt"))
        _ = Clipboard.load(dir: dir)
        #expect(!FileManager.default.fileExists(atPath: blobs.appendingPathComponent("orphan.txt").path))
    }

    @MainActor @Test func clipStoreRollsBackFailedIndexWrite() throws {
        let dir = try makeRoot()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("index.json"), withIntermediateDirectories: true)
        let clipboard = Clipboard(dir: dir)
        clipboard.record(kind: .text, data: Data("private text".utf8), now: 0)
        #expect(clipboard.recent("", now: 0).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("blobs").path).isEmpty)
    }

    @Test func translateConfigFallsBackWhenUnusable() throws {
        let root = try makeRoot()
        let missing = TranslateConfig.load(dir: root)
        #expect(missing.key.isEmpty)
        #expect(TranslateConfig.parse(Data("not json".utf8)) == nil)
        #expect(TranslateConfig.parse(Data(#"{"base": "https://my host/v1", "key": "sk-x"}"#.utf8)) == nil)
        #expect(Chat.request(missing, style: missing.styles[0], source: "hi") == nil)
    }

    @Test func translateConfigReadsAnyOpenAIEndpoint() throws {
        let root = try makeRoot()
        let body = """
        {"base": "https://api.openai.com/v1/", "key": "sk-x", "model": "gpt-4o-mini",
         "styles": [{"name": "Plain", "prompt": "Keep it plain."}, {"name": "", "prompt": "dropped"},
                    {"name": "NoPrompt"}, {"name": "Sharp", "prompt": "Be sharp.", "model": "gpt-4o", "extra": {"reasoning_effort": "max"}}]}
        """
        Store.write(root, TranslateConfig.file, Data(body.utf8))
        let config = TranslateConfig.load(dir: root)
        #expect(config.endpoint.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(config.extra.isEmpty)
        #expect(config.styles == [Style(name: "Plain", prompt: "Keep it plain.", model: nil),
                                  Style(name: "Sharp", prompt: "Be sharp.", model: "gpt-4o",
                                        extra: ["reasoning_effort": "max"])])
        let plain = try #require(Chat.request(config, style: config.styles[0], source: "hello"))
        #expect(plain.value(forHTTPHeaderField: "Authorization") == "Bearer sk-x")
        #expect(try sent(plain)["model"] as? String == "gpt-4o-mini")
        #expect(try sent(plain)["thinking"] == nil)
        let sharp = try #require(Chat.request(config, style: config.styles[1], source: "hello"))
        #expect(try sent(sharp)["model"] as? String == "gpt-4o")
        #expect(try sent(sharp)["reasoning_effort"] as? String == "max")
    }

    @MainActor @Test func translatorDropsRepliesForEditedSource() async {
        let config = TranslateConfig(endpoint: TranslateConfig.endpoint("https://api.test")!, key: "sk-x",
                                     model: "m", extra: [:], styles: TranslateConfig.defaultStyles())
        let translator = Translator(config: config) { _ in .done("你好") }
        translator.retarget("hello")
        let stale = translator.start(0) {}
        translator.retarget("goodbye")
        await stale?.value
        #expect(translator.value(0) == nil)
        let fresh = translator.start(0) {}
        #expect(translator.value(0) == .pending)
        await fresh?.value
        #expect(translator.value(0) == .done("你好"))
        translator.retire(0)
        #expect(translator.value(0) == .done("你好"))

        let broken = Translator(config: config) { _ in .failed("HTTP 401") }
        broken.retarget("hello")
        let attempt = broken.start(0) {}
        await attempt?.value
        broken.retire(0)
        #expect(broken.value(0) == nil)
    }

    @Test func tilingStageCycle() throws {
        let screen = CGRect(x: 0, y: 0, width: 1800, height: 900)
        for edge in [Edge.left, .right] {
            let stages = Tile.stages(edge, screen: screen)
            #expect(stages.map(\.width) == [900, 1200, 600, 1800])
            #expect(stages.allSatisfy { $0.height == 900 && (edge == .left ? $0.minX == 0 : $0.maxX == 1800) })
            let first = try #require(stages.first)
            #expect(Tile.next(edge, current: CGRect(x: 40, y: 40, width: 200, height: 200), screen: screen) == first)
            for (index, stage) in stages.enumerated() {
                #expect(Tile.next(edge, current: stage, screen: screen) == stages[(index + 1) % stages.count])
            }
        }
    }

    @Test func screenShift() throws {
        let left = CGRect(x: 0, y: 0, width: 1800, height: 900)
        let right = CGRect(x: 1800, y: 100, width: 1200, height: 800)
        let top = CGRect(x: 1800, y: 900, width: 1200, height: 800)
        #expect(Tile.neighbor(.left, of: left, among: [left]) == nil)
        #expect(Tile.neighbor(.right, of: left, among: [right, left]) == right)
        #expect(Tile.neighbor(.left, of: left, among: [right, left]) == right)
        #expect(Tile.neighbor(.right, of: right, among: [right, left]) == left)
        #expect(Tile.neighbor(.right, of: right, among: [top, left, right]) == top)
        #expect(Tile.neighbor(.left, of: left, among: [top, left, right]) == top)
        #expect(Tile.neighbor(.right, of: CGRect(x: 9, y: 9, width: 1, height: 1), among: [right, left]) == nil)
        let half = CGRect(x: 0, y: 0, width: 900, height: 900)
        #expect(Tile.relocated(half, from: left, to: right) == CGRect(x: 1800, y: 100, width: 600, height: 800))
        let window = CGRect(x: 450, y: 225, width: 900, height: 450)
        let moved = Tile.relocated(window, from: left, to: right)
        #expect(moved == CGRect(x: 2100, y: 300, width: 600, height: 400))
        #expect(Tile.relocated(moved, from: right, to: left) == window)
    }
}

struct ScreenshotChecks {
    private func pattern(height: Int, period: Int? = nil, unique: Bool = false) throws -> CGImage {
        let width = 256
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var value = UInt64((y % (period ?? height)) * 65537 + x * 257 + 1)
                value = (value ^ (value >> 16)) &* 0x45d9f3b
                value = (value ^ (value >> 16)) &* 0x45d9f3b
                let shade = unique && (100..<108).contains(x) ? UInt8(y / 4) : UInt8(truncatingIfNeeded: value ^ (value >> 16))
                let index = (y * width + x) * 4
                pixels.replaceSubrange(index..<index + 3, with: repeatElement(shade, count: 3))
            }
        }
        let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                   bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func slice(_ image: CGImage, _ y: Int, _ height: Int = 300) throws -> CGImage {
        try #require(image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)))
    }

    private func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
                                        windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @Test func scrollingCapturePreservesPixelsAndRejectsGaps() throws {
        let original = try pattern(height: 1000)
        var shot = try #require(ScrollShot(slice(original, 0)))
        for (y, height) in [(0, 300), (130, 430), (280, 580)] {
            #expect(shot.append(try slice(original, y)) == nil)
            #expect(shot.height == height)
        }
        #expect(shot.append(try slice(original, 0)) != nil)
        #expect(shot.append(try slice(original, 700)) != nil)
        #expect(shot.height == 580)
        #expect(ScrollFrame(try #require(shot.image()))?.rows == ScrollFrame(try slice(original, 0, 580))?.rows)
    }

    @Test(arguments: [(false, 30, 300), (true, 130, 430)])
    func scrollingCaptureRejectsOnlyAmbiguousRepetition(unique: Bool, offset: Int, height: Int) throws {
        let original = try pattern(height: 700, period: 40, unique: unique)
        var shot = try #require(ScrollShot(slice(original, 0)))
        #expect((shot.append(try slice(original, offset)) == nil) == unique)
        #expect(shot.height == height)
    }

    @Test @MainActor func scrollingCaptureMatchesRenderedText() throws {
        for (width, height, offset, font, spacing) in [(700, 600, 210, 18, 30), (1480, 1400, 388, 36, 84)] {
            let context = try #require(CGContext(data: nil, width: width, height: 3600, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: 3600))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: CGFloat(font), weight: .regular), .foregroundColor: NSColor.white,
            ]
            for i in 0..<80 {
                let y = 3600 - (i + 1) * spacing
                ("Line \(i): Native AppKit content / \(i * 7919)" as NSString).draw(at: NSPoint(x: 0, y: y), withAttributes: attributes)
                if spacing == 84 {
                    ("Every original line must appear exactly once." as NSString)
                        .draw(at: NSPoint(x: 0, y: y - spacing / 2), withAttributes: attributes)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
            let original = try #require(context.makeImage())
            var shot = try #require(ScrollShot(slice(original, offset, height)))
            #expect(shot.append(try slice(original, offset * 2, height)) == nil)
            #expect(shot.height == height + offset)
        }
    }

    @Test @MainActor func screenshotHighlightKeepsNonzeroAlpha() throws {
        let view = ShotSelection(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        view.mode = .window
        view.windows = [view.bounds]
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 320, pixelsHigh: 240,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        view.draw(view.bounds)
        #expect(try #require(bitmap.colorAt(x: 160, y: 120)).alphaComponent > 0.35)
        view.mouseMoved(with: try mouse(.mouseMoved, 160, 120))
        view.draw(view.bounds)
        let alpha = try #require(bitmap.colorAt(x: 160, y: 120)).alphaComponent
        #expect(view.area == view.bounds)
        #expect(alpha > 0 && alpha < 0.05)
    }

    @Test @MainActor func screenshotSelectionMovesResizesAndClearsWindowIdentity() throws {
        let view = ShotSelection(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.mode = .window
        view.windows = [NSRect(x: 100, y: 100, width: 400, height: 300)]
        var index: Int?
        view.selected = { _, window in index = window }
        func drag(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat)) throws {
            view.mouseDown(with: try mouse(.leftMouseDown, from.0, from.1))
            if from != to { view.mouseDragged(with: try mouse(.leftMouseDragged, to.0, to.1)) }
            view.mouseUp(with: try mouse(.leftMouseUp, to.0, to.1))
        }
        try drag((200, 200), (200, 200))
        #expect(index == 0)
        #expect(view.area == view.windows[0])
        try drag((300, 250), (900, 700))
        #expect(index == nil)
        #expect(view.area == NSRect(x: 400, y: 300, width: 400, height: 300))
        try drag((400, 300), (500, 400))
        #expect(view.area == NSRect(x: 500, y: 400, width: 300, height: 200))
        view.clear()
        #expect(view.area.isEmpty)
        view.mode = .area
        try drag((200, 200), (200, 200))
        #expect(view.area.isEmpty)
        try drag((200, 200), (500, 400))
        #expect(view.area == NSRect(x: 200, y: 200, width: 300, height: 200))
        #expect(view.windowIndex == nil)
    }

    @Test @MainActor func markupMapsPointsToPixelsAndExportsStrokes() throws {
        let white = try #require(CGContext(data: nil, width: 200, height: 160, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpaceCreateDeviceRGB(),
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        white.setFillColor(.white)
        white.fill(CGRect(x: 0, y: 0, width: 200, height: 160))
        let image = try #require(white.makeImage())
        let canvas = MarkCanvas(image: image, unit: 0.5, lineWidth: 4)
        canvas.mouseDown(with: try mouse(.leftMouseDown, 10, 20))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, 60, 50))
        canvas.mouseUp(with: try mouse(.leftMouseUp, 60, 50))
        canvas.tool = .arrow
        canvas.mouseDown(with: try mouse(.leftMouseDown, 70, 10))
        canvas.mouseUp(with: try mouse(.leftMouseUp, 71, 10))
        #expect(canvas.frame.size == NSSize(width: 100, height: 80))
        #expect(canvas.marks == [.rect(NSRect(x: 20, y: 40, width: 100, height: 60))])
        canvas.mouseDown(with: try mouse(.leftMouseDown, 70, 10))
        canvas.mouseDragged(with: try mouse(.leftMouseDragged, 90, 10))
        canvas.mouseUp(with: try mouse(.leftMouseUp, 90, 10))
        #expect(canvas.marks.last == .arrow(NSPoint(x: 140, y: 20), NSPoint(x: 180, y: 20)))
        canvas.undo(nil)
        #expect(canvas.marks.count == 1)
        canvas.redo(nil)
        let exported = try #require(canvas.exported)
        let bitmap = NSBitmapImageRep(cgImage: exported)
        #expect(exported.width == 200 && exported.height == 160)
        func red(_ x: Int, _ y: Int) throws -> Bool {
            let color = try #require(bitmap.colorAt(x: x, y: 160 - y))
            return color.redComponent > 0.8 && color.greenComponent < 0.5
        }
        #expect(try red(20, 70) && red(160, 20) && !red(70, 70))
    }

    @Test @MainActor func markupTextCommitsCancelsUndoesAndExports() throws {
        let context = try #require(CGContext(data: nil, width: 400, height: 240, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(.white)
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 240))
        let image = try #require(context.makeImage())
        let canvas = MarkCanvas(image: image, unit: 0.5, lineWidth: 6)
        canvas.tool = .text
        canvas.mouseDown(with: try mouse(.leftMouseDown, 20, 90))
        let input = try #require(canvas.subviews.first as? MarkTextView)
        input.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(input.hasMarkedText())
        input.insertText("中文 English", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!input.hasMarkedText())
        input.insertNewline(nil)
        #expect(canvas.marks == [.text("中文 English", NSPoint(x: 40, y: 180))])
        let exported = try #require(canvas.exported)
        let bitmap = NSBitmapImageRep(cgImage: exported)
        var red: [NSPoint] = []
        for y in 0..<exported.height {
            for x in 0..<exported.width {
                let color = try #require(bitmap.colorAt(x: x, y: y))
                if color.redComponent > 0.8 && color.greenComponent < 0.5 { red.append(NSPoint(x: x, y: y)) }
            }
        }
        #expect(exported.width == 400 && exported.height == 240)
        #expect(red.count > 200)
        #expect(red.allSatisfy { $0.x >= 40 && $0.y >= 60 && $0.y < 115 })
        canvas.undo(nil)
        #expect(canvas.marks.isEmpty)
        canvas.redo(nil)
        #expect(canvas.marks.count == 1)
        canvas.mouseDown(with: try mouse(.leftMouseDown, 30, 60))
        let cancelled = try #require(canvas.subviews.first as? MarkTextView)
        cancelled.insertText("discard", replacementRange: NSRange(location: NSNotFound, length: 0))
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        cancelled.keyDown(with: escape)
        #expect(canvas.marks.count == 1 && canvas.subviews.isEmpty)
        canvas.mouseDown(with: try mouse(.leftMouseDown, 30, 60))
        let empty = try #require(canvas.subviews.first as? MarkTextView)
        empty.insertNewline(nil)
        #expect(canvas.marks.count == 1)
    }

    @Test @MainActor func markupInPlaceKeepsScreenCoordinatesAndPlacesToolbar() throws {
        let context = try #require(CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let visible = NSRect(x: -1440, y: 100, width: 1440, height: 875)
        for y: CGFloat in [200, 670] {
            let region = NSRect(x: -1000, y: y, width: 400, height: 300)
            let editor = MarkEditor(image: image, scale: 2, visible: visible, region: region)
            #expect(editor.canvas.unit == 0.5)
            #expect(editor.canvas.frame.offsetBy(dx: editor.panel.frame.minX, dy: editor.panel.frame.minY) == region)
            #expect(visible.contains(editor.panel.frame))
            let toolbar = try #require(editor.panel.contentView?.subviews.last as? GlassPanel)
            let global = toolbar.frame.offsetBy(dx: editor.panel.frame.minX, dy: editor.panel.frame.minY)
            #expect(y == 200 ? global.minY > region.maxY : global.maxY < region.minY)
        }
        let tall = try #require(CGContext(data: nil, width: 800, height: 1730, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue).flatMap { $0.makeImage() })
        let region = NSRect(x: -1000, y: 105, width: 400, height: 865)
        let inside = MarkEditor(image: tall, scale: 2, visible: visible, region: region)
        let toolbar = try #require(inside.panel.contentView?.subviews.last as? GlassPanel)
        #expect(region.contains(toolbar.frame.offsetBy(dx: inside.panel.frame.minX, dy: inside.panel.frame.minY)))
        let fallback = MarkEditor(image: tall, scale: 2, visible: visible, region: region.offsetBy(dx: 0, dy: -10))
        #expect(fallback.canvas.unit < 0.5)
        #expect(visible.contains(fallback.panel.frame))
    }

    @Test @MainActor func markupEditorFitsScreenAndRoutesKeys() throws {
        let context = try #require(CGContext(data: nil, width: 4000, height: 3000, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let visible = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let editor = MarkEditor(image: image, scale: 2, visible: visible)
        #expect(visible.contains(editor.panel.frame))
        #expect(editor.canvas.frame.height >= 766 && editor.canvas.frame.height <= 767)
        #expect(abs(editor.canvas.frame.width / editor.canvas.frame.height - 4 / 3) < 0.01)
        #expect(editor.canvas.lineWidth == 6)
        var events: [String] = []
        editor.panel.onSubmit = { events.append("submit") }
        editor.panel.onCancel = { events.append("cancel") }
        func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                          context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        editor.canvas.keyDown(with: try press(36))
        editor.canvas.keyDown(with: try press(53))
        editor.panel.keyDown(with: try press(36, .shift))
        #expect(events == ["submit", "cancel", "submit"])
        let overlay = ShotPanel(size: NSSize(width: 100, height: 100))
        let selection = ShotSelection(frame: overlay.frame)
        overlay.contentView = selection
        overlay.onSubmit = { events.append("copy") }
        overlay.onMarkup = { events.append("markup") }
        selection.keyDown(with: try press(36, .shift))
        selection.keyDown(with: try press(36))
        #expect(events.suffix(2) == ["markup", "copy"])
    }
}

private func tempHome() throws -> URL {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent("etui-clean-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func fill(_ url: URL, _ name: String = "blob") throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try Data("x".utf8).write(to: url.appendingPathComponent(name))
}

private func present(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

@Suite struct CleanChecks {
    private func environment(_ home: URL, bundles: Set<String> = [], executables: [String] = []) -> CleanEnvironment {
        CleanEnvironment(home: home, runningBundles: bundles, runningExecutables: executables)
    }

    @Test func entryAnswersToItsAlias() {
        let history = History()
        let entries = [Entry.clean()]
        #expect(Rank.query("clean mac", apps: entries, history: history, now: 0).map(\.id) == ["internal.clean"])
        #expect(Rank.query("clean", apps: entries, history: history, now: 0).map(\.id) == ["internal.clean"])
    }

    @Test func sweepsCachesButKeepsExclusions() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let caches = home.appendingPathComponent("Library/Caches")
        try fill(caches.appendingPathComponent("com.example.app"))
        for name in ["go-build", "ms-playwright", "Mozilla.sccache", "com.apple.e5rt.e5bundlecache"] {
            try fill(caches.appendingPathComponent(name))
        }
        let report = Clean.execute(environment(home))
        #expect(!present(caches.appendingPathComponent("com.example.app")))
        #expect(present(caches.appendingPathComponent("go-build")))
        #expect(present(caches.appendingPathComponent("Mozilla.sccache")))
        #expect(present(caches.appendingPathComponent("com.apple.e5rt.e5bundlecache")))
        #expect(present(caches))
        #expect(report.removed.count == 1)
        #expect(report.removed.first?.hasSuffix("Library/Caches/com.example.app") == true)
        #expect(report.skipped.contains("Caches/go-build"))
    }

    @Test func refusesSymlinksThatEscapeTheRoot() throws {
        let home = try tempHome()
        let outside = try tempHome()
        defer {
            try? FileManager.default.removeItem(at: home)
            try? FileManager.default.removeItem(at: outside)
        }
        try Data("payload".utf8).write(to: outside.appendingPathComponent("payload"))
        let caches = home.appendingPathComponent("Library/Caches")
        try FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: caches.appendingPathComponent("trap"), withDestinationURL: outside)
        let report = Clean.execute(environment(home))
        #expect(present(outside.appendingPathComponent("payload")))
        #expect(report.removed.isEmpty)
        #expect(report.skipped.contains { $0.hasPrefix("trap ") })
    }

    @Test func emptiesNpxCacheAndLeavesTheTrash() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try fill(home.appendingPathComponent(".Trash/old-report"))
        try fill(home.appendingPathComponent(".npm/_npx/abc123"))
        try fill(home.appendingPathComponent(".npm/cache-keep"))
        let report = Clean.execute(environment(home))
        #expect(!present(home.appendingPathComponent(".npm/_npx")))
        #expect(present(home.appendingPathComponent(".npm/cache-keep")))
        #expect(present(home.appendingPathComponent(".npm")))
        #expect(present(home.appendingPathComponent(".Trash/old-report")))
        #expect(report.removed.count == 1)
        #expect(report.removed.contains { $0.hasSuffix(".npm/_npx") })
    }

    @Test func reportsFreedSpaceAsPositive() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/bulky")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(count: 128 << 20).write(to: cache.appendingPathComponent("blob"))
        let report = Clean.execute(environment(home))
        #expect(report.removed.count == 1)
        #expect(report.freed > 64 << 20)
    }

    @Test func recordsUnreadableDirectoryInsteadOfSilence() throws {
        let home = try tempHome()
        let users = home.appendingPathComponent("Library/Application Support/LarkShell/aha/users")
        try fill(users.appendingPathComponent("u1/profile_explorer/Service Worker/CacheStorage/abc"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: users.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: users.path)
            try? FileManager.default.removeItem(at: home)
        }
        let report = Clean.execute(environment(home))
        #expect(report.failed.contains { $0.hasPrefix(users.path + ":") })
        #expect(present(users))
        #expect(report.removed.isEmpty)
    }

    private func claudeHome(_ versions: [String], pinned: String?, running: [String] = []) throws -> (URL, CleanEnvironment) {
        let home = try tempHome()
        let root = home.appendingPathComponent(".local/share/claude/versions")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for version in versions {
            try Data("x".utf8).write(to: root.appendingPathComponent(version))
        }
        try Data("x".utf8).write(to: root.appendingPathComponent(".tmp-2.1.100-999-1788244921820"))
        if let pinned {
            let bin = home.appendingPathComponent(".local/bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: bin.appendingPathComponent("claude"),
                                                       withDestinationURL: root.appendingPathComponent(pinned))
        }
        let executables = running.map { root.appendingPathComponent($0).path }
        return (home, environment(home, executables: executables))
    }

    @Test func keepsPinnedAndTwoNewestClaudeVersions() throws {
        let (home, environment) = try claudeHome(["2.1.100", "2.1.290", "2.1.295", "2.1.296"], pinned: "2.1.296")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".local/share/claude/versions")
        let report = Clean.execute(environment)
        #expect(present(root.appendingPathComponent("2.1.296")))
        #expect(present(root.appendingPathComponent("2.1.295")))
        #expect(!present(root.appendingPathComponent("2.1.290")))
        #expect(!present(root.appendingPathComponent("2.1.100")))
        #expect(present(root.appendingPathComponent(".tmp-2.1.100-999-1788244921820")))
        #expect(report.removed.count == 2)
    }

    @Test func keepsTheRunningClaudeVersion() throws {
        let (home, environment) = try claudeHome(["2.1.200", "2.1.290", "2.1.295", "2.1.296"], pinned: "2.1.296", running: ["2.1.200"])
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".local/share/claude/versions")
        let report = Clean.execute(environment)
        #expect(!present(root.appendingPathComponent("2.1.290")))
        #expect(present(root.appendingPathComponent("2.1.200")))
        #expect(report.removed.count == 1)
    }

    @Test func skipsClaudeVersionsWhenLauncherIsMissing() throws {
        let (home, environment) = try claudeHome(["2.1.290", "2.1.296"], pinned: nil)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appendingPathComponent(".local/share/claude/versions")
        let report = Clean.execute(environment)
        #expect(present(root.appendingPathComponent("2.1.290")))
        #expect(present(root.appendingPathComponent("2.1.296")))
        #expect(report.removed.isEmpty)
        #expect(report.skipped.contains("Claude Code versions (launcher unresolved)"))
    }

    private func larkHome() throws -> URL {
        let home = try tempHome()
        let base = home.appendingPathComponent("Library/Application Support")
        try fill(base.appendingPathComponent("LarkShell/aha/users/u1/profile_explorer/Service Worker/CacheStorage/abc"))
        try fill(base.appendingPathComponent("LarkShell/aha/users/u1/profile_explorer/IndexedDB/store"))
        try fill(base.appendingPathComponent("LarkShell/iron/users/u1/profile_main/Service Worker/CacheStorage/def"))
        try fill(base.appendingPathComponent("LarkInternational/aha/users/u2/profile_explorer/Service Worker/CacheStorage/ghi"))
        try fill(base.appendingPathComponent("LarkInternational/update/update_downloading"))
        return home
    }

    @Test func removesOnlyLarkCacheStorage() throws {
        let home = try larkHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent("Library/Application Support")
        let report = Clean.execute(environment(home))
        #expect(!present(base.appendingPathComponent("LarkShell/aha/users/u1/profile_explorer/Service Worker/CacheStorage")))
        #expect(!present(base.appendingPathComponent("LarkShell/iron/users/u1/profile_main/Service Worker/CacheStorage")))
        #expect(!present(base.appendingPathComponent("LarkInternational/aha/users/u2/profile_explorer/Service Worker/CacheStorage")))
        #expect(!present(base.appendingPathComponent("LarkInternational/update")))
        #expect(present(base.appendingPathComponent("LarkShell/aha/users/u1/profile_explorer/IndexedDB/store")))
        #expect(present(base.appendingPathComponent("LarkShell/aha/users/u1/profile_explorer")))
        #expect(report.removed.count == 4)
    }

    @Test func keepsLarkDataWhileTheAppRuns() throws {
        let home = try larkHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let base = home.appendingPathComponent("Library/Application Support")
        let report = Clean.execute(environment(home, bundles: ["com.electron.lark"]))
        #expect(present(base.appendingPathComponent("LarkShell/aha/users/u1/profile_explorer/Service Worker/CacheStorage/abc")))
        #expect(present(base.appendingPathComponent("LarkInternational/update")))
        #expect(report.removed.isEmpty)
        #expect(report.skipped.contains("LarkShell (running)"))
        #expect(report.skipped.contains("LarkInternational (running)"))
    }
}
