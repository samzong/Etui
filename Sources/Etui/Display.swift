import AppKit
import Darwin
import IOKit
import os

struct DisplayState: Equatable {
    var id: CGDirectDisplayID
    var builtin: Bool
    var active: Bool
    var online: Bool
    var mirrored: Bool
    var physical: Bool
    var asleep = false
}

enum DisplayPolicy {
    static func isTransient(_ displays: [DisplayState]) -> Bool {
        !displays.isEmpty && displays.allSatisfy { $0.builtin && $0.mirrored }
    }

    static func hasExternal(_ displays: [DisplayState]) -> Bool {
        displays.contains { !$0.builtin && ($0.active || $0.asleep) && $0.online && !$0.mirrored && $0.physical }
    }

    static func desired(enabled: Bool, lidClosed: Bool?, displays: [DisplayState], builtinKnown: Bool = false) -> Bool? {
        guard lidClosed == false, !isTransient(displays) else { return nil }
        let external = hasExternal(displays)
        guard displays.contains(where: \.builtin) else { return builtinKnown && !external ? true : nil }
        return !(enabled && !displays.contains(where: { $0.builtin && $0.mirrored }) && external)
    }

    static func canStopGuardian(lidClosed: Bool?, restoreVerified: Bool) -> Bool {
        lidClosed == false && restoreVerified
    }

    static func guardianShouldRestore(parentGone: Bool, lidClosed: Bool?, displays: [DisplayState]?, builtinKnown: Bool) -> Bool {
        guard lidClosed == false else { return false }
        if let displays, isTransient(displays) { return false }
        return parentGone || displays == nil || desired(enabled: true, lidClosed: false, displays: displays ?? [], builtinKnown: builtinKnown) == true
    }
}

struct DisplayBuiltinCache {
    private(set) var ids: Set<CGDirectDisplayID>
    let learns: Bool

    mutating func observe(_ displays: [DisplayState]) {
        guard learns, !DisplayPolicy.isTransient(displays) else { return }
        let current = Set(displays.filter { $0.builtin && $0.physical && !$0.mirrored }.map(\.id))
        if !current.isEmpty { ids = current }
    }
}

enum DisplayGuardianInput: Equatable {
    case watching, parentGone, stop
    static let stopByte: UInt8 = 83

    mutating func consume(_ bytes: Data) {
        guard self != .stop else { return }
        if bytes.contains(Self.stopByte) { self = .stop }
        else if bytes.isEmpty { self = .parentGone }
    }
}

struct DisplayRecovery {
    var failed = false
    private var displays: [DisplayState]?
    private var lidClosed: Bool?

    mutating func observe(_ displays: [DisplayState], lidClosed: Bool?) {
        guard !DisplayPolicy.isTransient(displays) else { return }
        let context = Self.context(displays)
        if context != self.displays || lidClosed != self.lidClosed { failed = false }
        self.displays = context
        self.lidClosed = lidClosed
    }

    static func context(_ displays: [DisplayState]) -> [DisplayState] {
        displays.map { display in
            var display = display
            if display.builtin {
                display.active = false
                display.online = false
                display.asleep = false
            }
            return display
        }.sorted { $0.id < $1.id }
    }
}

enum DisplayConfiguration {
    static func verified(_ ids: [CGDirectDisplayID], on: Bool, displays: [DisplayState]) -> Bool {
        guard !DisplayPolicy.isTransient(displays), !ids.isEmpty else { return false }
        if on {
            let present = displays.filter { ids.contains($0.id) }
            return !present.isEmpty && present.allSatisfy { $0.active && $0.online }
        }
        return ids.allSatisfy { id in !displays.contains { $0.id == id && $0.active } }
    }

    static func apply(_ ids: [CGDirectDisplayID], on: Bool, before: [DisplayState],
                      configure: (CGDirectDisplayID, Bool) throws -> Void,
                      read: () throws -> [DisplayState]) throws {
        guard !ids.isEmpty else { throw DisplaySystem.Failure.read }
        var failure: Error?
        for id in ids where !verified([id], on: on, displays: before) {
            do { try configure(id, on) } catch { failure = failure ?? error }
        }
        guard verified(ids, on: on, displays: try read()) else {
            throw failure ?? DisplaySystem.Failure.verification
        }
    }
}

struct DisplayRestoreRetry {
    private(set) var attempts = 0
    private var next: TimeInterval = 0

    mutating func takeAttempt(at now: TimeInterval) -> Bool {
        guard now >= next else { return false }
        attempts += 1
        next = now + [0.25, 0.5, 1, 2, 4, 4][min(attempts - 1, 5)]
        return true
    }
}

final class DisplaySystem {
    typealias List = @convention(c) (UInt32, UnsafeMutablePointer<UInt32>?, UnsafeMutablePointer<UInt32>?) -> Int32
    typealias Enable = @convention(c) (OpaquePointer?, UInt32, Bool) -> Int32
    typealias Info = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?
    private let list: List
    private let enable: Enable
    private let info: Info
    private var cache: DisplayBuiltinCache
    var hasBuiltin: Bool { !cache.ids.isEmpty }
    var knownBuiltinIDs: [CGDirectDisplayID] { cache.ids.sorted() }
    private static let log = Logger(subsystem: "me.samzong.etui", category: "DisplaySystem")

    enum Failure: Error { case unavailable, read, query(String, Int32), configure(String, Int32), verification, transient }

    init(builtinIDs: [CGDirectDisplayID]? = nil) throws {
        cache = DisplayBuiltinCache(ids: Set(builtinIDs ?? []), learns: builtinIDs == nil)
        guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let list = dlsym(sky, "CGSGetDisplayList"),
              let enable = dlsym(sky, "CGSConfigureDisplayEnabled"),
              let info = dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary") else { throw Failure.unavailable }
        self.list = unsafeBitCast(list, to: List.self)
        self.enable = unsafeBitCast(enable, to: Enable.self)
        self.info = unsafeBitCast(info, to: Info.self)
    }

    func displays() throws -> [DisplayState] {
        var count: UInt32 = 0
        let counted = list(0, nil, &count)
        guard counted == 0 else { throw Failure.query("count", counted) }
        guard count < 1024 else { throw Failure.read }
        var ids = [UInt32](repeating: 0, count: Int(count))
        let listed = list(count, &ids, &count)
        guard listed == 0 else { throw Failure.query("list", listed) }
        guard count <= ids.count else { throw Failure.read }
        let displays = ids.prefix(Int(count)).map { id in
            let values = info(id)?.takeRetainedValue() as? [String: Any]
            let physical = (values?["kCGDisplayIsVirtualDevice"] as? NSNumber)?.boolValue == false
                && (values?["kCGDisplayIsAirPlay"] as? NSNumber)?.boolValue == false
                && (values?["DisplayVendorID"] as? NSNumber)?.uint32Value == CGDisplayVendorNumber(id)
                && CGDisplayVendorNumber(id) != 0
                && (values?["IODisplayLocation"] as? String)?.hasPrefix("IOService:/") == true
            return DisplayState(id: id, builtin: CGDisplayIsBuiltin(id) != 0,
                                active: CGDisplayIsActive(id) != 0, online: CGDisplayIsOnline(id) != 0,
                                mirrored: CGDisplayIsInMirrorSet(id) != 0, physical: physical, asleep: CGDisplayIsAsleep(id) != 0)
        }
        cache.observe(displays)
        return displays
    }

    func setBuiltin(_ on: Bool) throws {
        var before: [DisplayState] = []
        do { before = try displays() } catch {
            Self.log.error("Refresh before configure failed: \(String(describing: error), privacy: .public); cached=\(self.knownBuiltinIDs, privacy: .public) enabled=\(on)")
            guard on && !cache.ids.isEmpty else { throw error }
        }
        guard !DisplayPolicy.isTransient(before) else { throw Failure.transient }
        let ids = knownBuiltinIDs
        Self.log.notice("Set builtin enabled=\(on) cached=\(ids, privacy: .public)")
        try DisplayConfiguration.apply(ids, on: on, before: before, configure: configure) {
            let actual = try self.displays()
            guard !DisplayPolicy.isTransient(actual) else { throw Failure.transient }
            let verified = DisplayConfiguration.verified(ids, on: on, displays: actual)
            Self.log.notice("Verify enabled=\(on) listed=\(actual, privacy: .public) verified=\(verified)")
            return actual
        }
    }

    private func configure(_ id: CGDirectDisplayID, on: Bool) throws {
        var config: CGDisplayConfigRef?
        Self.log.notice("Configuring builtin id=\(id) enabled=\(on)")
        let begin = CGBeginDisplayConfiguration(&config)
        Self.log.notice("Begin id=\(id) result=\(begin.rawValue)")
        guard begin == .success else { throw Failure.configure("begin", begin.rawValue) }
        let result = enable(config, id, on)
        Self.log.notice("Enable id=\(id) result=\(result)")
        guard result == 0 else {
            CGCancelDisplayConfiguration(config)
            throw Failure.configure("enable", result)
        }
        let completed = CGCompleteDisplayConfiguration(config, .forAppOnly)
        Self.log.notice("Complete id=\(id) result=\(completed.rawValue)")
        guard completed == .success else { throw Failure.configure("complete", completed.rawValue) }
    }

    static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return (IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? NSNumber)?.boolValue
    }
}

@MainActor final class ExternalDisplay {
    private let defaults: UserDefaults
    private let system: DisplaySystem?
    private var notifications: [NSObjectProtocol] = []
    private var port: IONotificationPortRef?
    private var interest: io_object_t = 0
    private var pending: DispatchWorkItem?
    private var started = false
    private var scheduleID = 0
    private var guardian: Process?
    private var guardianIDs: [CGDirectDisplayID] = []
    private var input: Pipe?
    private var stoppingGuardian = false
    private var recovery = DisplayRecovery()
    private var previousState: String?
    private nonisolated static let log = Logger(subsystem: "me.samzong.etui", category: "ExternalDisplay")
    private(set) var enabled: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "externalDisplayOnly") as? Bool ?? true
        system = try? DisplaySystem()
    }

    func start() {
        Self.log.debug("Start requested started=\(self.started) system=\(self.system != nil)")
        guard !started else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let registered = CGDisplayRegisterReconfigurationCallback(Self.displayChanged, context)
        Self.log.debug("Register display callback result=\(registered.rawValue)")
        guard registered == .success else {
            Self.log.error("Display callback registration failed result=\(registered.rawValue)")
            return
        }
        port = IONotificationPortCreate(kIOMainPortDefault)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard let port, service != 0 else {
            Self.log.error("Power notification service unavailable")
            if service != 0 { IOObjectRelease(service) }
            stop()
            return
        }
        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest, Self.powerChanged, context, &interest)
        IOObjectRelease(service)
        Self.log.debug("Register power interest result=\(result)")
        guard result == KERN_SUCCESS else {
            Self.log.error("Power interest registration failed result=\(result)")
            stop()
            return
        }
        IONotificationPortSetDispatchQueue(port, .main)
        started = true
        Self.log.debug("Started enabled=\(self.enabled)")
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            notifications.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedule("workspace wake") }
            })
        }
        reconcile()
    }

    private nonisolated static let displayChanged: CGDisplayReconfigurationCallBack = { id, flags, context in
        log.debug("Display callback id=\(id) flags=\(flags.rawValue) begin=\(flags.contains(.beginConfigurationFlag)) context=\(context != nil)")
        guard !flags.contains(.beginConfigurationFlag), let context else { return }
        let controller = Unmanaged<ExternalDisplay>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in
            ExternalDisplay.log.debug("Display callback reached main actor")
            controller.schedule("display callback")
        }
    }

    private nonisolated static let powerChanged: IOServiceInterestCallback = { context, _, message, _ in
        log.debug("Power callback message=\(message) context=\(context != nil)")
        guard let context else { return }
        let controller = Unmanaged<ExternalDisplay>.fromOpaque(context).takeUnretainedValue()
        Task { @MainActor in controller.schedule("power callback") }
    }

    private func schedule(_ reason: String) {
        Self.log.debug("Schedule reason=\(reason, privacy: .public) started=\(self.started)")
        guard started else { return }
        pending?.cancel()
        scheduleID += 1
        let id = scheduleID
        Self.log.debug("Scheduled id=\(id); previous work coalesced")
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                Self.log.debug("Scheduled reconcile fired id=\(id)")
                self.pending = nil
                self.reconcile()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    func set(_ value: Bool) throws {
        guard started, let system else { throw DisplaySystem.Failure.unavailable }
        if !value, DisplaySystem.lidClosed() == false {
            try system.setBuiltin(true)
            guard releaseGuardian() else { throw DisplaySystem.Failure.unavailable }
        }
        enabled = value
        defaults.set(value, forKey: "externalDisplayOnly")
        recovery.failed = false
        reconcile()
        if value && recovery.failed { throw DisplaySystem.Failure.verification }
    }

    func stop() {
        Self.log.notice("Stopping")
        started = false
        CGDisplayRemoveReconfigurationCallback(Self.displayChanged, Unmanaged.passUnretained(self).toOpaque())
        if interest != 0 { IOObjectRelease(interest); interest = 0 }
        if let port { IONotificationPortDestroy(port); self.port = nil }
        for notification in notifications { NSWorkspace.shared.notificationCenter.removeObserver(notification) }
        notifications.removeAll()
        pending?.cancel()
        pending = nil
        let lidClosed = DisplaySystem.lidClosed()
        var restored = false
        do {
            if lidClosed == false, let system {
                try system.setBuiltin(true)
                restored = true
            }
        } catch {
            Self.log.error("Exit restore failed; leaving guardian to recover: \(String(describing: error), privacy: .public)")
        }
        if DisplayPolicy.canStopGuardian(lidClosed: lidClosed, restoreVerified: restored) {
            releaseGuardian()
        } else {
            Self.log.notice("Exit restore unverified; closing pipe for guardian recovery on lid open")
            input?.fileHandleForWriting.closeFile()
            input = nil
        }
    }

    @discardableResult private func releaseGuardian() -> Bool {
        guard let guardian else { return true }
        stoppingGuardian = true
        Self.log.notice("Stopping guardian pid=\(guardian.processIdentifier)")
        if guardian.isRunning, let input {
            do { try input.fileHandleForWriting.write(contentsOf: Data([DisplayGuardianInput.stopByte])) }
            catch { guardian.terminate() }
        }
        input?.fileHandleForWriting.closeFile()
        input = nil
        for _ in 0..<100 {
            if !guardian.isRunning { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if guardian.isRunning {
            Self.log.error("Guardian stop timed out; sending SIGTERM pid=\(guardian.processIdentifier)")
            guardian.terminate()
            for _ in 0..<100 {
                if !guardian.isRunning { break }
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        guard !guardian.isRunning else {
            Self.log.error("Guardian still running pid=\(guardian.processIdentifier); refusing another disable")
            return false
        }
        guardian.waitUntilExit()
        Self.log.notice("Guardian exited pid=\(guardian.processIdentifier) status=\(guardian.terminationStatus)")
        self.guardian = nil
        guardianIDs = []
        stoppingGuardian = false
        return true
    }

    private func reconcile() {
        Self.log.debug("Reconcile entered started=\(self.started) enabled=\(self.enabled) failed=\(self.recovery.failed)")
        guard let system else { Self.log.error("Reconcile has no display system"); return }
        var restoring = false
        do {
            let displays = try system.displays()
            let lidClosed = DisplaySystem.lidClosed()
            let state = "lid=\(String(describing: lidClosed)) cached=\(system.knownBuiltinIDs) displays=\(displays)"
            if state != previousState {
                Self.log.debug("State \(state, privacy: .public)")
                previousState = state
            }
            guard !DisplayPolicy.isTransient(displays) else { return }
            recovery.observe(displays, lidClosed: lidClosed)
            if stoppingGuardian, !releaseGuardian() { return }
            if let guardian, !guardian.isRunning {
                if guardian.terminationStatus != 0 || !DisplayConfiguration.verified(system.knownBuiltinIDs, on: true, displays: displays) {
                    recovery.failed = true
                }
                releaseGuardian()
            }
            let desired = DisplayPolicy.desired(enabled: enabled && !recovery.failed,
                                                lidClosed: lidClosed, displays: displays, builtinKnown: system.hasBuiltin)
            Self.log.debug("Decision desired=\(String(describing: desired), privacy: .public) failed=\(self.recovery.failed) cached=\(system.knownBuiltinIDs, privacy: .public)")
            guard let on = desired else { return }
            restoring = on
            if on && DisplayConfiguration.verified(system.knownBuiltinIDs, on: true, displays: displays) {
                releaseGuardian()
                return
            }
            if on && recovery.failed && guardian?.isRunning == true {
                Self.log.debug("Restore pending in guardian")
                return
            }
            if !on {
                if guardian != nil && guardianIDs != system.knownBuiltinIDs {
                    try system.setBuiltin(true)
                    guard releaseGuardian() else { throw DisplaySystem.Failure.unavailable }
                }
                if guardian == nil { try protect() }
                guard guardian?.isRunning == true else { throw DisplaySystem.Failure.unavailable }
            }
            try system.setBuiltin(on)
            if on { releaseGuardian() }
            if !on && (guardian?.isRunning != true || guardianIDs != system.knownBuiltinIDs) {
                throw DisplaySystem.Failure.unavailable
            }
        } catch DisplaySystem.Failure.transient {
            Self.log.debug("Transient display list; waiting for next event")
        } catch {
            Self.log.error("Configuration failed: \(String(describing: error), privacy: .public)")
            recovery.failed = true
            if !restoring && DisplaySystem.lidClosed() == false {
                do {
                    try system.setBuiltin(true)
                    releaseGuardian()
                } catch {
                    Self.log.error("Recovery failed: \(String(describing: error), privacy: .public)")
                }
            }
            fputs("Etui: display configuration failed: \(error)\n", stderr)
        }
    }

    private func protect() throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        guard let executable = Bundle.main.executableURL else { throw DisplaySystem.Failure.unavailable }
        process.executableURL = executable.deletingLastPathComponent().appendingPathComponent("DisplayGuardian")
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                guard self?.guardian === process else { return }
                self?.schedule("guardian exit")
            }
        }
        let ids = system?.knownBuiltinIDs ?? []
        process.arguments = ["--display-guardian"] + ids.map(String.init)
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        self.input = input
        guardian = process
        guardianIDs = ids
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
        guard poll(&descriptor, 1, 2000) > 0,
              output.fileHandleForReading.readData(ofLength: 1) == Data([1]), process.isRunning else {
            output.fileHandleForReading.closeFile()
            do {
                guard let system else { throw DisplaySystem.Failure.unavailable }
                try system.setBuiltin(true)
                releaseGuardian()
            } catch {
                input.fileHandleForWriting.closeFile()
                self.input = nil
                Self.log.error("Guardian handshake failed; restore unverified: \(String(describing: error), privacy: .public)")
            }
            throw DisplaySystem.Failure.unavailable
        }
        output.fileHandleForReading.closeFile()
        Self.log.notice("Guardian ready pid=\(process.processIdentifier)")
    }

    private nonisolated static let guardianLog = Logger(subsystem: "me.samzong.etui", category: "DisplayGuardian")

    private nonisolated static let guardianDisplayChanged: CGDisplayReconfigurationCallBack = { id, flags, _ in
        guardianLog.debug("Reconfiguration id=\(id) flags=\(flags.rawValue)")
    }

    static func runGuardian() {
        setpgid(0, 0)
        signal(SIGTERM) { _ in _exit(0) }
        signal(SIGINT) { _ in _exit(0) }
        do {
            let ids = CommandLine.arguments.dropFirst(2).compactMap(UInt32.init)
            let system = try DisplaySystem(builtinIDs: ids)
            _ = try? system.displays()
            guard system.hasBuiltin else { throw DisplaySystem.Failure.read }
            let registered = CGDisplayRegisterReconfigurationCallback(guardianDisplayChanged, nil)
            guard registered == .success else { throw DisplaySystem.Failure.configure("callback", registered.rawValue) }
            defer { CGDisplayRemoveReconfigurationCallback(guardianDisplayChanged, nil) }
            let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + 0.25, 0.25, 0, 0) { _ in }
            CFRunLoopAddTimer(CFRunLoopGetCurrent(), timer, .defaultMode)
            defer { CFRunLoopTimerInvalidate(timer) }
            FileHandle.standardOutput.write(Data([1]))
            var control = DisplayGuardianInput.watching
            var previous: String?
            var retryContext: String?
            var retry = DisplayRestoreRetry()
            var readFailures: Set<String> = []
            while true {
                CFRunLoopRunInMode(.defaultMode, 0.25, false)
                var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
                let result = poll(&descriptor, 1, 0)
                if result > 0 || (result < 0 && errno == EBADF) {
                    var byte: UInt8 = 0
                    let count = Darwin.read(STDIN_FILENO, &byte, 1)
                    if count >= 0 { control.consume(count == 0 ? Data() : Data([byte])) }
                    else if errno == EBADF { control.consume(Data()) }
                }
                if control == .stop {
                    guardianLog.notice("Explicit stop received; exiting without restore")
                    return
                }
                let parentGone = control == .parentGone
                let lid = DisplaySystem.lidClosed()
                var displays: [DisplayState]?
                do { displays = try system.displays() } catch {
                    let message = String(describing: error)
                    if readFailures.insert(message).inserted {
                        guardianLog.error("Read failed: \(message, privacy: .public)")
                    }
                }
                let state = "parentGone=\(parentGone) lid=\(String(describing: lid)) cached=\(system.knownBuiltinIDs) displays=\(String(describing: displays))"
                if state != previous {
                    guardianLog.debug("State \(state, privacy: .public)")
                    previous = state
                }
                if let displays, DisplayPolicy.isTransient(displays) { continue }
                let context = "\(parentGone) \(String(describing: lid)) \(String(describing: displays.map(DisplayRecovery.context)))"
                if context != retryContext {
                    retryContext = context
                    retry = DisplayRestoreRetry()
                }
                guard DisplayPolicy.guardianShouldRestore(parentGone: parentGone, lidClosed: lid, displays: displays, builtinKnown: system.hasBuiltin) else { continue }
                if retry.attempts > 0, let displays,
                   DisplayConfiguration.verified(system.knownBuiltinIDs, on: true, displays: displays) {
                    guardianLog.notice("Builtin verified in display list; exiting")
                    return
                }
                guard retry.takeAttempt(at: ProcessInfo.processInfo.systemUptime) else { continue }
                guardianLog.notice("Restoring builtin attempt=\(retry.attempts) parentGone=\(parentGone)")
                do {
                    try system.setBuiltin(true)
                    guardianLog.notice("Builtin verified in display list; exiting")
                    return
                } catch {
                    guardianLog.error("Restore attempt=\(retry.attempts) failed: \(String(describing: error), privacy: .public)")
                    if retry.attempts == 6 {
                        guardianLog.error("Fast restore attempts failed; retrying every 4 seconds until verified")
                    }
                }
            }
        } catch {
            guardianLog.fault("Guardian startup failed: \(String(describing: error), privacy: .public)")
        }
    }
}
