import AppKit
import Foundation

enum Kind: Equatable {
    case app
    case target
    case settings
    case quit
    case awake(Bool)
    case closedLid(ClosedLidState)
    case externalDisplay(Bool)
    case clean
    case calculation(String)
}

struct Entry {
    var id: String
    var name: String
    var aliases: [String]
    var path: String
    var kind: Kind

    static let quit = Entry(id: "internal.quit", name: "Quit Etui", aliases: ["quit"], path: "", kind: .quit)

    static func awake(_ on: Bool) -> Entry {
        Entry(id: "internal.awake", name: on ? "Stop Keeping Awake" : "Keep Awake",
              aliases: ["awake", "caffeinate", "sleep"], path: "", kind: .awake(on))
    }

    static func closedLid(_ state: ClosedLidState) -> Entry {
        let name = switch state {
        case .unknown: "Check Closed-Lid Sleep"
        case .checking: "Checking Closed-Lid Sleep…"
        case .disabled: "Keep Running with Lid Closed"
        case .enabled: "Allow Sleep with Lid Closed"
        case .changing: "Updating Closed-Lid Sleep…"
        }
        return Entry(id: "internal.closed-lid", name: name,
                     aliases: ["lid", "clamshell", "closed", "sleep"], path: "", kind: .closedLid(state))
    }

    static func externalDisplay(_ on: Bool) -> Entry {
        Entry(id: "internal.external-display", name: on ? "Keep Built-in Display On" : "Turn Off Built-in Display with External Monitor",
              aliases: ["display", "monitor", "screen", "external", "builtin", "内屏", "外接屏"], path: "", kind: .externalDisplay(on))
    }

    static func clean() -> Entry {
        Entry(id: "internal.clean", name: "Clean Disk", aliases: ["clean mac"], path: "", kind: .clean)
    }
}

enum Catalog {
    static let paneRoot = "/System/Library/ExtensionKit/Extensions"
    static let defaultExtras = ["com.apple.finder"].compactMap {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)?.path
    }
    private static let paneExtensionPoint = "com.apple.Settings.extension.ui"
    private static let paneNames = ["com.apple.Battery-Settings.extension": "Battery"]
    private static let skippedPanes: Set<String> = ["com.apple.HeadphoneSettings"]

    static func scan(roots: [String]? = nil, panes: String? = paneRoot, extras: [String] = defaultExtras) -> [Entry] {
        var seen = Set<NSString>()
        var apps: [Entry] = []
        for path in (roots ?? defaultRoots).flatMap({ bundles(in: $0, depth: 0) }) + extras {
            guard let entry = parse(path), seen.insert(entry.id as NSString).inserted else { continue }
            apps.append(entry)
        }
        for path in panes.map({ bundles(in: $0, depth: 1, ext: "appex") }) ?? [] {
            guard let entry = pane(path), seen.insert(entry.id as NSString).inserted else { continue }
            apps.append(entry)
        }
        var sorted = apps.enumerated()
            .map { (key: Array(lowercase($0.element.name).utf8), order: $0.offset, entry: $0.element) }
            .sorted { $0.key == $1.key ? $0.order < $1.order : $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.entry)
        sorted.append(.quit)
        return sorted
    }

    static func parse(_ path: String) -> Entry? {
        guard let dict = info(at: path) else { return nil }
        if let flag = dict["LSBackgroundOnly"], isTruthy(flag) {
            return nil
        }
        return entry(path: path, dict: dict, kind: .app)
    }

    static func pane(_ path: String) -> Entry? {
        guard let dict = info(at: path),
              let attributes = dict["EXAppExtensionAttributes"] as? [String: Any],
              attributes["EXExtensionPointIdentifier"] as? String == paneExtensionPoint,
              let id = dict["CFBundleIdentifier"] as? String, !skippedPanes.contains(id)
        else { return nil }
        var localized = dict
        localized["CFBundleDisplayName"] = paneNames[id]
            ?? Bundle(path: path)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? dict["CFBundleDisplayName"]
        return entry(path: path, dict: localized, kind: .settings)
    }

    private static func info(at path: String) -> [String: Any]? {
        let info = (path as NSString).appendingPathComponent("Contents/Info.plist")
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: info)),
              let raw = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format),
              format != .xml || XMLParser(data: data).parse()
        else { return nil }
        return raw as? [String: Any]
    }

    private static func entry(path: String, dict: [String: Any], kind: Kind) -> Entry? {
        let stem = split((path as NSString).lastPathComponent).stem
        let names = [dict["CFBundleDisplayName"] as? String, dict["CFBundleName"] as? String, stem]
            .compactMap(\.self)
            .map(cleanName)
        guard let name = names.first else { return nil }
        var aliases: [String] = []
        for extra in names.dropFirst()
            where !sameBytes(extra, name) && !aliases.contains(where: { sameBytes($0, extra) })
        {
            aliases.append(extra)
        }
        let bundleID = dict["CFBundleIdentifier"] as? String
        return Entry(id: bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? path,
                     name: name,
                     aliases: aliases,
                     path: path,
                     kind: kind)
    }

    static func applyDisplayNames(_ entries: [Entry]) -> [Entry] {
        entries.map { entry in
            guard entry.kind == .app else { return entry }
            let display = cleanName(FileManager.default.displayName(atPath: entry.path))
            guard !display.isEmpty, !sameBytes(display, entry.name) else { return entry }
            var renamed = entry
            if !renamed.aliases.contains(where: { sameBytes($0, entry.name) }) {
                renamed.aliases.append(entry.name)
            }
            renamed.name = display
            return renamed
        }
    }

    static func cleanName(_ name: String) -> String {
        for suffix in [".app", ".APP"] where name.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        return name
    }

    private static let defaultRoots = [
        NSHomeDirectory() + "/Applications",
        "/Applications",
        "/System/Applications",
        "/System/Cryptexes/App/System/Applications",
    ]

    private static func bundles(in root: String, depth: Int, ext: String = "app") -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        var out: [String] = []
        for name in names {
            let path = (root as NSString).appendingPathComponent(name)
            if split(name).ext.map({ lowercase($0) == ext }) == true {
                out.append(path)
                continue
            }
            var directory: ObjCBool = false
            if depth == 0, FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue {
                out.append(contentsOf: bundles(in: path, depth: 1))
            }
        }
        return out
    }

    private static func split(_ name: String) -> (stem: String, ext: String?) {
        guard name != "..", let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, nil) }
        return (String(name[..<dot]), String(name[name.index(after: dot)...]))
    }

    private static func isTruthy(_ value: Any) -> Bool {
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID()
                ? number.boolValue
                : plainInteger(number).flatMap({ Int64(exactly: $0) }).map { $0 != 0 } ?? false
        }
        if let text = value as? String {
            return ["1", "true", "YES", "yes"].contains(text)
        }
        return false
    }
}
