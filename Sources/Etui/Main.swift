import AppKit
import Darwin

@main
struct Main {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == "--display-guardian" {
            ExternalDisplay.runGuardian()
            return
        }
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
               guard $0.processIdentifier != ProcessInfo.processInfo.processIdentifier, !$0.isTerminated else { return false }
               var path = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
               guard proc_pidpath($0.processIdentifier, &path, UInt32(path.count)) > 0 else { return false }
               return URL(fileURLWithPath: String(decoding: path.prefix { $0 != 0 }, as: UTF8.self)).lastPathComponent == "Etui"
           }) { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let launcher = Launcher()
        app.delegate = launcher
        withExtendedLifetime(launcher) { app.run() }
    }
}
