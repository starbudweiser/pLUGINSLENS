// Réglages et session mémorisée.
//
// Réglages : mêmes clés que les QSettings « PluginLens » de la version Python (pins, workspaces, lastdir, remember,
// notree, tree_w, sbs_w, sbs_h, language), stockées dans les préférences de l'appli. Si des QSettings existent encore
// sous l'un des noms Qt possibles, leurs valeurs sont reprises une fois.
// Session : ~/Library/Application Support/PluginLens/session (index.json + une copie de chaque plugin), même format.

import Foundation

public final class AppSettings: @unchecked Sendable {
    public static let keys = ["pins", "workspaces", "lastdir", "remember", "notree", "tree_w", "sbs_w", "sbs_h", "language"]
    private let defaults: UserDefaults

    /// `suite` : domaine de préférences d'essai (jamais celui de l'utilisateur) ; nil = préférences de l'appli.
    public init(suite: String? = nil) {
        defaults = suite.flatMap { UserDefaults(suiteName: $0) } ?? .standard
        if defaults.object(forKey: "qt_imported") == nil {
            if suite == nil { importQt() }
            defaults.set("1", forKey: "qt_imported")
        }
    }

    /// Reprise des valeurs de l'ancienne version (QSettings de Qt : domaines possibles selon l'organisation).
    private func importQt() {
        for name in ["com.PluginLens.PluginLens", "PluginLens", "pluginlens", "com.pluginlens", "PluginLens.PluginLens", "com.pluginlens.PluginLens"] {
            guard let dom = UserDefaults.standard.persistentDomain(forName: name) else { continue }
            for k in AppSettings.keys where defaults.object(forKey: k) == nil {
                if let v = dom[k] { defaults.set("\(v)", forKey: k) }
            }
        }
    }

    public func string(_ key: String, _ def: String = "") -> String {
        if let s = defaults.string(forKey: key) { return s }
        if let n = defaults.object(forKey: key) { return "\(n)" }
        return def
    }

    public func int(_ key: String, _ def: Int = 0) -> Int { Int(string(key)) ?? def }
    public func set(_ key: String, _ value: String) { defaults.set(value, forKey: key) }
    public func set(_ key: String, _ value: Int) { defaults.set(String(value), forKey: key) }
    public func remove(_ key: String) { defaults.removeObject(forKey: key) }

    // Épingles et espaces de travail : chaînes JSON, comme json.dumps de Python.
    public var pins: Set<String> {
        get {
            guard let d = string("pins", "[]").data(using: .utf8),
                  let a = try? JSONSerialization.jsonObject(with: d) as? [String] else { return [] }
            return Set(a)
        }
        set { set("pins", AppSettings.json(newValue.sorted().map { $0 as Any })) }
    }

    /// Nom → liste de plugins, dans l'ordre d'enregistrement.
    public var workspaces: [(name: String, plugins: [String])] {
        get {
            guard let d = string("workspaces", "{}").data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
            // L'ordre du JSON est conservé en relisant le texte
            let order = AppSettings.keyOrder(string("workspaces", "{}"))
            let names = order.filter { o[$0] != nil } + o.keys.filter { !order.contains($0) }.sorted()
            return names.map { n in
                (n, ((o[n] as? [String: Any])?["plugins"] as? [String]) ?? [])
            }
        }
        set {
            var parts: [String] = []
            for (n, p) in newValue {
                parts.append(AppSettings.json(n) + ": " + "{\"plugins\": " + AppSettings.json(p.map { $0 as Any }) + "}")
            }
            set("workspaces", "{" + parts.joined(separator: ", ") + "}")
        }
    }

    static func json(_ v: Any) -> String {
        if let s = v as? String {
            let d = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
            return String(String(decoding: d, as: UTF8.self).dropFirst().dropLast())
        }
        let d = try! JSONSerialization.data(withJSONObject: v, options: [.withoutEscapingSlashes])
        // Séparateurs « , » de Python
        return String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\",\"", with: "\", \"")
    }

    /// Clés de premier niveau d'un objet JSON, dans l'ordre du texte.
    static func keyOrder(_ text: String) -> [String] {
        var out: [String] = []
        var depth = 0, i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == "\"" {
                var j = text.index(after: i), s = ""
                while j < text.endIndex, text[j] != "\"" {
                    if text[j] == "\\", text.index(after: j) < text.endIndex { j = text.index(after: j) }
                    s.append(text[j]); j = text.index(after: j)
                }
                let after = text.index(after: j)
                if depth == 1, after < text.endIndex, text[after...].drop(while: { $0 == " " }).first == ":" { out.append(s) }
                i = after
                continue
            }
            if c == "{" || c == "[" { depth += 1 } else if c == "}" || c == "]" { depth -= 1 }
            i = text.index(after: i)
        }
        return out
    }
}

public struct SessionEntry {
    public var t: Double
    public var dirty: Bool
    public init(t: Double, dirty: Bool) { self.t = t; self.dirty = dirty }
}

public final class SessionStore: @unchecked Sendable {
    public let dir: URL

    public static var defaultDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/PluginLens/session")
    }

    public init(dir: URL = SessionStore.defaultDir) { self.dir = dir }

    var indexURL: URL { dir.appendingPathComponent("index.json") }

    public func index() -> [(name: String, entry: SessionEntry)] {
        guard let d = try? Data(contentsOf: indexURL),
              let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [] }
        let order = AppSettings.keyOrder(String(decoding: d, as: UTF8.self))
        let names = order.filter { o[$0] != nil }
        return names.map { n in
            let m = o[n] as? [String: Any] ?? [:]
            return (n, SessionEntry(t: (m["t"] as? NSNumber)?.doubleValue ?? 0, dirty: (m["dirty"] as? NSNumber)?.boolValue ?? false))
        }
    }

    func saveIndex(_ idx: [(name: String, entry: SessionEntry)]) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var parts: [String] = []
        for (n, e) in idx {
            parts.append("\(AppSettings.json(n)): {\"t\": \(e.t), \"dirty\": \(e.dirty ? "true" : "false")}")
        }
        try? Data(("{" + parts.joined(separator: ", ") + "}").utf8).write(to: indexURL, options: .atomic)
    }

    public func file(_ name: String) -> URL { dir.appendingPathComponent(name.replacingOccurrences(of: "/", with: "_")) }

    public func write(_ P: Plugin) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(serialize(P)).write(to: file(P.name), options: .atomic)
        var idx = index().filter { $0.name != P.name }
        idx.append((P.name, SessionEntry(t: P.t, dirty: P.dirty)))
        saveIndex(idx)
    }

    public func remove(_ name: String) {
        let idx = index()
        if idx.contains(where: { $0.name == name }) { saveIndex(idx.filter { $0.name != name }) }
        try? FileManager.default.removeItem(at: file(name))
    }

    public func read(_ name: String) -> Data? { try? Data(contentsOf: file(name)) }
}
