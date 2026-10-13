import AppKit
import Darwin
import Foundation

struct CleanEnvironment {
    var home: URL
    var runningBundles: Set<String> = []
    var runningExecutables: [String] = []
    var docker = false
}

struct CleanReport {
    var freed: Int64 = 0
    var removed: [String] = []
    var skipped: [String] = []
    var failed: [String] = []
    var docker = ""

    var logged: [String: Any] {
        [
            "at": Store.now(), "freed": freed, "removed_total": removed.count,
            "removed": removed.prefix(500).map { $0 },
            "skipped": skipped, "failed": failed, "docker": docker,
        ]
    }
}

enum Clean {
    static let cacheExclusions: Set<String> = [
        "go-build", "ms-playwright", "Mozilla.sccache", "com.apple.e5rt.e5bundlecache",
        "com.apple.finder", "CloudKit", "com.apple.FontRegistry",
        "com.apple.spotlight", "com.apple.Spotlight",
        "ws.stash.app.mac", "io.tailscale.ipn.macsys",
    ]

    private static let appData = ["LarkShell", "LarkInternational"]
    private static let dockerBinaries = ["/opt/homebrew/bin/docker", "/usr/local/bin/docker"]
    private static let dataVolume = "/System/Volumes/Data"

    @MainActor static func run() {
        let environment = CleanEnvironment(
            home: URL(fileURLWithPath: NSHomeDirectory()),
            runningBundles: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)),
            runningExecutables: Processes.paths(),
            docker: true)
        Task {
            let report = await Task.detached(priority: .utility) { execute(environment) }.value
            record(report)
            announce(report)
        }
    }

    @MainActor private static func announce(_ report: CleanReport) {
        let summary = summary(for: report)
        let alert = NSAlert()
        alert.messageText = summary.title
        alert.informativeText = summary.detail
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    static func summary(for report: CleanReport) -> (title: String, detail: String) {
        let title = switch (report.freed > 0, report.removed.isEmpty) {
        case (true, _): "Freed \(ByteCountFormatter.string(fromByteCount: report.freed, countStyle: .file))"
        case (false, true): "Nothing to Clean"
        case (false, false): "Cleaned \(report.removed.count) items"
        }
        let detail = switch report.failed.count {
        case 0: ""
        case 1: "One item could not be removed. Its path is in clean.jsonl."
        case let count: "\(count) items could not be removed. Their paths are in clean.jsonl."
        }
        return (title, detail)
    }

    static func execute(_ env: CleanEnvironment) -> CleanReport {
        var report = CleanReport()
        let before = freeBytes()
        sweepCaches(env, &report)
        sweepNpx(env, &report)
        sweepAppData(env, &report)
        sweepClaudeVersions(env, &report)
        if env.docker {
            sweepDocker(&report)
        }
        if let before, let after = freeBytes() {
            report.freed = after - before
        } else {
            report.failed.append("free space could not be measured")
        }
        return report
    }

    private static func sweepCaches(_ env: CleanEnvironment, _ report: inout CleanReport) {
        let root = env.home.appendingPathComponent("Library/Caches")
        for target in children(of: root, &report) {
            let name = target.lastPathComponent
            if cacheExclusions.contains(name) {
                report.skipped.append("Caches/\(name)")
                continue
            }
            remove(target, under: root, &report)
        }
    }

    private static func sweepNpx(_ env: CleanEnvironment, _ report: inout CleanReport) {
        let root = env.home.appendingPathComponent(".npm")
        let target = root.appendingPathComponent("_npx")
        guard isDirectory(target) else { return }
        remove(target, under: root, &report)
    }

    private static func sweepAppData(_ env: CleanEnvironment, _ report: inout CleanReport) {
        for app in appData {
            let base = env.home.appendingPathComponent("Library/Application Support/\(app)")
            guard isDirectory(base) else { continue }
            if larkIsRunning(env) {
                report.skipped.append("\(app) (running)")
                continue
            }
            for tree in ["aha", "iron"] {
                for user in children(of: base.appendingPathComponent("\(tree)/users"), &report) {
                    for profile in children(of: user, &report) where profile.lastPathComponent.hasPrefix("profile_") {
                        let cache = profile.appendingPathComponent("Service Worker/CacheStorage")
                        guard isDirectory(cache) else { continue }
                        remove(cache, under: base, &report)
                    }
                }
            }
            let update = base.appendingPathComponent("update")
            if isDirectory(update) {
                remove(update, under: base, &report)
            }
        }
    }

    private static func sweepClaudeVersions(_ env: CleanEnvironment, _ report: inout CleanReport) {
        let root = env.home.appendingPathComponent(".local/share/claude")
        let versions = root.appendingPathComponent("versions")
        let link = env.home.appendingPathComponent(".local/bin/claude")
        guard isDirectory(versions) else { return }
        guard let pinned = pinnedVersion(link, under: versions) else {
            report.skipped.append("Claude Code versions (launcher unresolved)")
            return
        }
        let resolved = versions.resolvingSymlinksInPath().standardizedFileURL.path
        let installed = children(of: versions, &report)
            .map(\.lastPathComponent)
            .filter(isVersion)
            .sorted { versionKey($0).lexicographicallyPrecedes(versionKey($1)) }
        var keep = Set([pinned])
        keep.formUnion(env.runningExecutables.compactMap { versionName(of: $0, under: resolved) })
        keep.formUnion(installed.suffix(2))
        for name in installed where !keep.contains(name) {
            remove(versions.appendingPathComponent(name), under: versions, &report)
        }
    }

    private static func versionName(of executable: String, under root: String) -> String? {
        let path = URL(fileURLWithPath: executable).resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(root + "/") else { return nil }
        let name = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return isVersion(name) ? name : nil
    }

    private static func isVersion(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix(".")
            && name.split(separator: ".").allSatisfy { Int($0) != nil }
    }

    private static func sweepDocker(_ report: inout CleanReport) {
        guard let docker = dockerBinaries.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            report.skipped.append("docker (not installed)")
            return
        }
        guard let host = command(docker, ["context", "inspect", "colima", "--format", "{{.Endpoints.docker.Host}}"])?.output,
              host.hasPrefix("unix:///Users/") else {
            report.skipped.append("docker (colima context is not a local socket)")
            return
        }
        guard let builders = command(docker, ["--context", "colima", "buildx", "ls"])?.output,
              builders.split(separator: "\n").contains(where: { $0.hasPrefix("colima") }) else {
            report.skipped.append("docker (colima builder missing)")
            return
        }
        let before = command(docker, ["--context", "colima", "system", "df"])?.output ?? ""
        prune(docker, ["--context", "colima", "container", "prune", "--force"], "container prune", &report)
        prune(docker, ["--context", "colima", "image", "prune", "--force"], "image prune", &report)
        prune(docker, ["--context", "colima", "buildx", "prune", "--builder", "colima", "--filter", "until=24h", "--force"], "buildx prune", &report)
        let after = command(docker, ["--context", "colima", "system", "df"])?.output ?? ""
        report.docker = "before [\(flat(before))] after [\(flat(after))]"
    }

    private static func prune(_ docker: String, _ arguments: [String], _ label: String, _ report: inout CleanReport) {
        guard let result = command(docker, arguments, capture: false) else {
            report.failed.append("docker \(label): could not run")
            return
        }
        if result.status != 0 {
            report.failed.append("docker \(label): exit \(result.status)")
        }
    }

    private static func remove(_ target: URL, under root: URL, _ report: inout CleanReport) {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL.path
        let name = target.lastPathComponent
        guard resolved.hasPrefix(base + "/"), resolved != base else {
            report.skipped.append("\(name) (outside \(base))")
            return
        }
        do {
            try FileManager.default.removeItem(at: target)
            report.removed.append(target.path)
        } catch {
            report.failed.append("\(name): \(error.localizedDescription)")
        }
    }

    private static func pinnedVersion(_ link: URL, under versions: URL) -> String? {
        guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { return nil }
        let target = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
        let resolved = target.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.deletingLastPathComponent().path == versions.resolvingSymlinksInPath().standardizedFileURL.path else { return nil }
        return resolved.lastPathComponent
    }

    private static func larkIsRunning(_ env: CleanEnvironment) -> Bool {
        if env.runningBundles.contains(where: { $0.hasPrefix("com.electron.lark") }) {
            return true
        }
        return env.runningExecutables.contains {
            let name = URL(fileURLWithPath: $0).lastPathComponent.lowercased()
            return name.contains("lark") || name.contains("feishu")
        }
    }

    private static func versionKey(_ name: String) -> [Int] {
        name.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
    }

    private static func children(of root: URL, _ report: inout CleanReport) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        } catch {
            let missing = [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains((error as NSError).code)
            if !missing {
                report.failed.append("\(root.path): \(error.localizedDescription)")
            }
            return []
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func flat(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " | ")
    }

    private static func freeBytes() -> Int64? {
        var stats = statfs()
        let path = FileManager.default.fileExists(atPath: dataVolume) ? dataVolume : "/"
        guard statfs(path, &stats) == 0 else { return nil }
        return Int64(stats.f_bavail) * Int64(stats.f_bsize)
    }

    private static func record(_ report: CleanReport) {
        guard let data = try? JSONSerialization.data(withJSONObject: report.logged) else {
            fputs("Etui: could not encode the clean run\n", stderr)
            return
        }
        let payload = Data((String(decoding: data, as: UTF8.self) + "\n").utf8)
        let dir = Store.dataDir()
        let url = dir.appendingPathComponent("clean.jsonl")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            do {
                try handle.write(contentsOf: payload)
                return
            } catch {
                fputs("Etui: could not append clean.jsonl: \(error.localizedDescription)\n", stderr)
            }
        }
        do {
            try payload.write(to: url)
        } catch {
            fputs("Etui: could not write clean.jsonl: \(error.localizedDescription)\n", stderr)
        }
    }

    private static func command(_ tool: String, _ arguments: [String], capture: Bool = true, timeout: TimeInterval = 120) -> (status: Int32, output: String)? {
        let process = Process()
        let pipe = capture ? Pipe() : nil
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let pipe {
            process.standardOutput = pipe
            process.standardError = pipe
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            return nil
        }
        let descriptor = pipe?.fileHandleForReading.fileDescriptor
        if let descriptor {
            _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        }
        var buffer = Data()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            if let descriptor, readable(descriptor), drain(descriptor, into: &buffer) {
                continue
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            for _ in 0..<10 where process.isRunning {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        if let descriptor {
            var rounds = 0
            while rounds < 20, drain(descriptor, into: &buffer) {
                rounds += 1
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: buffer, as: UTF8.self))
    }

    private static func readable(_ descriptor: Int32) -> Bool {
        var entry = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        return poll(&entry, 1, 50) > 0
    }

    private static func drain(_ descriptor: Int32, into buffer: inout Data) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        guard count > 0 else { return false }
        buffer.append(contentsOf: bytes[0..<count])
        return true
    }
}

enum Processes {
    static func paths() -> [String] {
        var pids = [pid_t](repeating: 0, count: 8192)
        let listed = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard listed > 0 else { return [] }
        var paths: [String] = []
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for index in 0..<min(Int(listed), pids.count) where pids[index] > 0 {
            guard proc_pidpath(pids[index], &buffer, UInt32(buffer.count)) > 0 else { continue }
            paths.append(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return paths
    }
}
