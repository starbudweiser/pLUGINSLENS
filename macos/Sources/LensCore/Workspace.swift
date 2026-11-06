// Ensemble des plugins ouverts et opérations qui les relient (classe Workspace de plugin_core.py).

import Foundation

public enum Remap {
    case id(UInt32)
    case need(String)
}

public struct AddResult {
    public var n = 0, dup = 0
    public var changed = false
    public var warn: [String] = []
}

public struct ImportResult {
    public var n = 0, dup = 0
    public var changed = false
    public var warn: [String] = []
    public var raw = 0
    public var bad: [String] = []
}

public struct PasteResult {
    public var n = 0
    public var warn: [String] = []
    public var changed = false
    public var groups: [GroupNode] = []
}

public typealias ClipItem = (node: Record, plugin: Plugin)

public final class Workspace {
    public var plugins: [Plugin] = []
    public var confirm: (String) -> Bool
    public var alert: (String) -> Void

    public init(confirm: @escaping (String) -> Bool = { _ in true }, alert: @escaping (String) -> Void = { _ in }) {
        self.confirm = confirm
        self.alert = alert
    }

    public func find(_ name: String) -> Plugin? {
        let k = lc(name)
        return plugins.first { lc($0.name) == k }
    }

    // MARK: résolution des FormID

    public func resolve(_ P: Plugin, _ id: UInt32?) -> Record? {
        guard let id else { return nil }
        let o = origin(P, id)
        if o == P.name { return byId(P, id) }
        guard let Q = find(o) else { return nil }
        return byId(Q, (UInt32(truncatingIfNeeded: Q.masters.count) << 24 | (id & 0xFFFFFF)))
    }

    public static func remapId(_ Q: Plugin, _ v: UInt32, _ P: Plugin) -> Remap {
        let o = origin(Q, v), obj = v & 0xFFFFFF
        if lc(o) == lc(P.name) { return .id(UInt32(truncatingIfNeeded: P.masters.count) << 24 | obj) }
        for (j, m) in P.masters.enumerated() where lc(m) == lc(o) {
            return .id(UInt32(truncatingIfNeeded: j) << 24 | obj)
        }
        return .need(o)
    }

    public func xref(_ src: Record, _ P: Plugin) -> Remap { Workspace.remapId(src.plugin!, src.id, P) }

    // MARK: maîtres

    public static func addMaster(_ P: Plugin, _ name: String) {
        let n = P.masters.count
        func fix(_ v: UInt32) -> UInt32 {
            Int(v >> 24) == n ? (UInt32(truncatingIfNeeded: n + 1) << 24 | (v & 0xFFFFFF)) : v
        }
        for r in P.all {
            if r === P.header { continue }
            r.id = fix(r.id)
            for s in r.subs where s.t == "LNAM" && s.d.count == 4 { s.d = p32(fix(u32s(s.d))) }
        }
        var at = -1
        for (i, s) in P.header.subs.enumerated() where ["HEDR", "CNAM", "SNAM", "MAST", "DATA"].contains(s.t) { at = i }
        P.header.subs.insert(contentsOf: [Sub("MAST", textBytes(name)), Sub("DATA", Bytes(repeating: 0, count: 8))], at: at + 1)
        P.masters.append(name)
        P.idx = nil
    }

    public func ensureMaster(_ P: Plugin, _ o: String, _ warn: inout [String], _ no: inout Set<String>) -> Bool {
        let k = lc(o)
        if no.contains(k) { return false }
        let Q = find(o)
        let bad: String?
        if let Q, Q.masters.contains(where: { lc($0) == lc(P.name) }) {
            bad = L("{o} dépend de {name} : en faire un maître de {name} serait circulaire.", ["o": o, "name": P.name])
        } else if !P.all.allSatisfy({ $0 === P.header || $0.t == "FLST" }) {
            bad = L("{name} ne déclare pas {o} comme maître et contient d'autres enregistrements que des FormLists. Un maître ne peut être ajouté sans risque qu'à un plugin composé de FormLists, car les références internes des autres enregistrements devraient être renumérotées. Ajoutez le maître dans xEdit, puis rouvrez le plugin ici.", ["name": P.name, "o": o])
        } else if P.masters.count >= 253 {
            bad = L("Trop de maîtres.")
        } else {
            bad = nil
        }
        if let bad {
            if !warn.contains(bad) { warn.append(bad) }
            no.insert(k)
            return false
        }
        if !confirm(L("Ajouter {o} comme maître de {name} ?", ["o": o, "name": P.name])) {
            no.insert(k)
            return false
        }
        Workspace.addMaster(P, o)
        return true
    }

    // MARK: FormID libres

    public func nextId(_ P: Plugin) -> UInt32? {
        let n = P.masters.count
        var mx = 0x7FF
        for r in P.all where Int(r.id >> 24) == n { mx = max(mx, Int(r.id & 0xFFFFFF)) }
        if let h = P.header.subs.first(where: { $0.t == "HEDR" }), h.d.count >= 12 {
            mx = max(mx, Int((u32s(h.d, 8) &- 1) & 0xFFFFFF))
        }
        let o = mx + 1
        if P.header.flags & ESL_FLAG != 0 && o > 0xFFF {
            alert(L("Ce plugin marqué ESL n'a plus de FormID libre (limite 0xFFF)."))
            return nil
        }
        if o > 0xFFFFFF || n > 0xFF {
            alert(L("Plus aucun FormID libre."))
            return nil
        }
        return UInt32(truncatingIfNeeded: n) << 24 | UInt32(o)
    }

    public static func fixHedr(_ P: Plugin) {
        guard let h = P.header.subs.first(where: { $0.t == "HEDR" }), h.d.count >= 12 else { return }
        var count = 0, mx = 0
        func walk(_ lst: [Node]) {
            for x in lst {
                if let g = x as? GroupNode {
                    count += 1
                    walk(g.kids.items)
                } else if x !== P.header {
                    count += 1
                    let r = x as! Record
                    if Int(r.id >> 24) == P.masters.count { mx = max(mx, Int(r.id & 0xFFFFFF)) }
                }
            }
        }
        walk(P.root.items)
        if !h.buf.isArray { h.buf = Buf(h.buf.b, isArray: true) }
        let c = p32(count)
        let m = p32(max(Int(u32s(h.buf.b, 8)), mx + 1))
        h.buf.b.replaceSubrange(4..<8, with: c)
        h.buf.b.replaceSubrange(8..<12, with: m)
    }

    // MARK: historique

    /// Marque le plugin modifié. Renvoie true si un nouveau point d'annulation a été ouvert
    /// (l'interface doit alors programmer commitBase() après 700 ms).
    @discardableResult
    public static func markDirty(_ P: Plugin, _ msg: String? = nil, when: String = "") -> Bool {
        P.idx = nil
        P.dirty = true
        if let msg, !msg.isEmpty { P.log.append(when.isEmpty ? msg : "\(when)  \(msg)") }
        if !P.pend {
            P.undo.append(P.base)
            if P.undo.count > 50 { P.undo.removeFirst() }
            P.redo = []
            P.pend = true
            return true
        }
        return false
    }

    public static func commitBase(_ P: Plugin) {
        P.base = snapshot(P)
        P.pend = false
    }

    @discardableResult
    public static func undoRedo(_ P: Plugin, back: Bool) -> Bool {
        if (back ? P.undo : P.redo).isEmpty { return false }
        if back {
            P.redo.append(snapshot(P))
        } else {
            P.undo.append(snapshot(P))
        }
        let snap = back ? P.undo.removeLast() : P.redo.removeLast()
        // (ordre Python : dst.append(snapshot) puis src.pop() ; la pile source n'est pas touchée par l'ajout)
        P.root = NodeList(snap.map(cloneNode))
        P.base = snap
        P.pend = false
        P.all = []
        indexNodes(P.root, P)
        P.idx = nil
        P.masters = readMasters(P)
        P.dirty = true
        return true
    }

    // MARK: groupes et identifiants

    public static func topGroup(_ P: Plugin, _ t: String) -> GroupNode {
        if let g = P.root.items.first(where: { isTop($0) && groupType($0 as! GroupNode) == t }) as? GroupNode { return g }
        let src = P.root.items.first(where: isTop) as? GroupNode
        var tl = src?.tail ?? Bytes(repeating: 0, count: 12)
        if tl.count >= 4 { tl.replaceSubrange(0..<4, with: p32(0)) }
        let g = GroupNode(label: Array(te(t).prefix(4)), tail: tl, kids: NodeList())
        g.parent = P.root
        g.plugin = P
        P.root.items.append(g)
        return g
    }

    public static func newEdid(_ P: Plugin, _ b: String) -> String {
        var n = b + "_copy", i = 1
        let names = Set(P.all.map { Key(edid($0)) })
        while names.contains(Key(n)) {
            i += 1
            n = "\(b)_copy\(i)"
        }
        return n
    }

    public static func setEdid(_ x: Record, _ t: String) {
        if let e = x.subs.first(where: { $0.t == "EDID" }) { e.d = textBytes(t) }
    }

    public func topOf(_ r: Record) -> GroupNode? {
        r.plugin!.root.items.first { isTop($0) && ($0 as! GroupNode).kids === r.parent } as? GroupNode
    }

    // MARK: opérations sur les enregistrements

    public func newFormlist(_ P: Plugin, _ name: String) -> Record? {
        guard let id = nextId(P) else { return nil }
        var tail = Bytes(repeating: 0, count: 8)
        let ht = P.header.tail
        if ht.count >= 6 { tail.replaceSubrange(4..<6, with: ht[4..<6]) }
        let r = Record("FLST", flags: 0, id: id, tail: tail, subs: [Sub("EDID", textBytes(name))])
        var g = P.root.items.first(where: { $0 is GroupNode && groupType($0 as! GroupNode) == "FLST" && u32s(($0 as! GroupNode).tail, 0) == 0 }) as? GroupNode
        if g == nil {
            let src = P.root.items.first(where: { $0 is GroupNode }) as? GroupNode
            var tl = src?.tail ?? Bytes(repeating: 0, count: 12)
            if tl.count >= 4 { tl.replaceSubrange(0..<4, with: p32(0)) }
            let ng = GroupNode(label: Array("FLST".utf8), tail: tl, kids: NodeList())
            ng.parent = P.root
            ng.plugin = P
            P.root.items.append(ng)
            g = ng
        }
        r.parent = g!.kids
        r.plugin = P
        g!.kids.items.append(r)
        P.all.append(r)
        return r
    }

    public func cloneRecord(_ r: Record) -> Record? {
        let P = r.plugin!
        if r === P.header { return nil }
        guard let id = nextId(P) else { return nil }
        let c = cloneNode(r) as! Record
        c.id = id
        c.plugin = P
        c.parent = r.parent
        let e = edid(r)
        if !e.isEmpty { Workspace.setEdid(c, Workspace.newEdid(P, e)) }
        r.parent!.items.insert(c, at: r.parent!.index(of: r)! + 1)
        P.all.append(c)
        return c
    }

    public static func deleteRecord(_ r: Record) {
        let P = r.plugin!
        if let l = r.parent, let i = l.index(of: r) { l.items.remove(at: i) }
        P.all = P.all.filter { $0 !== r }
        P.idx = nil
    }

    /// Ajoute des enregistrements à une FormList.
    public func addEntries(_ fl: Record, _ recs: [Record]) -> AddResult {
        let P = fl.plugin!
        var res = AddResult()
        var no = Set<String>()
        for src in recs {
            if src === fl { continue }
            var x = xref(src, P)
            if case .need(let o) = x {
                if !ensureMaster(P, o, &res.warn, &no) { continue }
                res.changed = true
                x = xref(src, P)
            }
            guard case .id(let id) = x else { continue }
            if fl.subs.contains(where: { $0.t == "LNAM" && lnam($0) == id }) {
                res.dup += 1
                continue
            }
            fl.subs.append(Sub("LNAM", p32(id)))
            res.n += 1
            res.changed = true
        }
        return res
    }

    public func copyRecords(_ recs: [Record]) -> (items: [ClipItem], skipped: Int) {
        let ok = recs.filter { r in
            if let p = r.plugin, r !== p.header, topOf(r) != nil { return true }
            return false
        }
        return (ok.map { (cloneNode($0) as! Record, $0.plugin!) }, recs.count - ok.count)
    }

    public func pasteRecords(_ P: Plugin, _ clip: [ClipItem]) -> PasteResult {
        var res = PasteResult()
        var no = Set<String>()
        let m0 = P.masters.count
        for (c, Q) in clip {
            if Q !== P && c.t != "FLST" {
                let msg = L("Seules les FormLists peuvent être collées dans un autre plugin. Les autres types contiennent des références impossibles à renuméroter sans connaître leur structure. Dans le même plugin, tous les types fonctionnent.")
                if !res.warn.contains(msg) { res.warn.append(msg) }
                continue
            }
            let x = cloneNode(c) as! Record
            x.plugin = P
            if Q !== P {
                for s in x.subs where s.t == "LNAM" && s.d.count == 4 {
                    let v = lnam(s)!
                    var m = Workspace.remapId(Q, v, P)
                    if case .need(let o) = m {
                        if !ensureMaster(P, o, &res.warn, &no) {
                            s.bad = true
                            continue
                        }
                        m = Workspace.remapId(Q, v, P)
                    }
                    if case .id(let i) = m { s.d = p32(i) }
                }
            }
            x.subs = x.subs.filter { !$0.bad }
            guard let id = nextId(P) else { break }
            x.id = id
            let nm = edid(c)
            if !nm.isEmpty && P.all.contains(where: { scalarEq(edid($0), nm) }) {
                Workspace.setEdid(x, Workspace.newEdid(P, nm))
            }
            let g = Workspace.topGroup(P, c.t)
            x.parent = g.kids
            g.kids.items.append(x)
            P.all.append(x)
            res.groups.append(g)
            res.n += 1
        }
        res.changed = res.n > 0 || P.masters.count != m0
        return res
    }

    // MARK: FormLists

    public func exportList(_ fl: Record) -> String {
        var out: [String] = []
        for s in fl.subs where s.t == "LNAM" {
            guard let v = lnam(s) else {
                out.append("# invalid entry")
                continue
            }
            if let t = resolve(fl.plugin!, v), !edid(t).isEmpty {
                out.append(edid(t))
            } else {
                out.append("0x" + hexs(v))
            }
        }
        return out.joined(separator: "\n")
    }

    public func importList(_ fl: Record, _ txt: String) -> ImportResult {
        let P = fl.plugin!
        var recs: [Record] = [], bad: [String] = []
        var raw = 0
        var byE: [Key: Record] = [:]
        for q in [P] + plugins.filter({ $0 !== P }) {
            for r in q.all {
                let e = lc(edid(r))
                if !e.isEmpty && byE[Key(e)] == nil { byE[Key(e)] = r }
            }
        }
        for rawLine in splitLines(txt) {
            // re.sub(r"#.*", "", line) : coupe au premier « # » ; « . » ne couvre pas \n (absent ici)
            var line = rawLine
            if let h = line.unicodeScalars.firstIndex(of: "#") { line = String(line.unicodeScalars[..<h]) }
            line = pyStrip(line)
            if line.isEmpty { continue }
            if let id = parseFormId(line) {
                if let t = resolve(P, id) {
                    recs.append(t)
                } else if Int(id >> 24) <= P.masters.count && !fl.subs.contains(where: { $0.t == "LNAM" && lnam($0) == id }) {
                    fl.subs.append(Sub("LNAM", p32(id)))
                    raw += 1
                } else {
                    bad.append(line)
                }
            } else if let t = byE[Key(lc(line))] {
                recs.append(t)
            } else {
                bad.append(line)
            }
        }
        var res = ImportResult()
        if !recs.isEmpty {
            let a = addEntries(fl, recs)
            res.n = a.n; res.dup = a.dup; res.changed = a.changed; res.warn = a.warn
        }
        res.raw = raw
        res.bad = bad
        return res
    }

    /// re.split(r"\r?\n", txt)
    func splitLines(_ txt: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        let sc = Array(txt.unicodeScalars)
        var i = 0
        while i < sc.count {
            if sc[i] == "\n" {
                out.append(String(cur)); cur = String.UnicodeScalarView()
            } else if sc[i] == "\r", i + 1 < sc.count, sc[i + 1] == "\n" {
                out.append(String(cur)); cur = String.UnicodeScalarView(); i += 1
            } else {
                cur.append(sc[i])
            }
            i += 1
        }
        out.append(String(cur))
        return out
    }

    /// ^(?:0x)?([0-9a-fA-F]{8})$
    func parseFormId(_ line: String) -> UInt32? {
        var sc = Array(line.unicodeScalars)
        if sc.count == 10, sc[0] == "0", sc[1] == "x" { sc.removeFirst(2) }
        guard sc.count == 8 else { return nil }
        var v: UInt32 = 0
        for c in sc {
            guard c.isASCII, let h = Character(c).hexDigitValue else { return nil }
            v = v << 4 | UInt32(h)
        }
        return v
    }

    public func flEntries(_ fl: Record) -> [Sub] { fl.subs.filter { $0.t == "LNAM" } }

    /// Remplace les entrées LNAM (placées en fin de liste). Renvoie le nombre d'entrées retirées.
    public func flSet(_ fl: Record, _ entries: [Sub]) -> Int {
        let removed = flEntries(fl).count - entries.count
        fl.subs = fl.subs.filter { $0.t != "LNAM" } + entries
        return removed
    }

    public func flSortedByName(_ fl: Record) -> [Sub] {
        let P = fl.plugin!
        func name(_ s: Sub) -> String {
            if let t = resolve(P, lnam(s)) { return edid(t) }
            return ""
        }
        struct K { let lower: String, n: String, v: Int64 }
        let keyed = flEntries(fl).map { s -> (Sub, K) in
            let n0 = name(s)
            let n = n0.isEmpty ? "\u{FFFF}" : n0
            return (s, K(lower: n.lowercased(), n: n, v: lnam(s).map { Int64($0) } ?? -1))
        }
        return stableSorted(keyed) { a, b in
            if !scalarEq(a.1.lower, b.1.lower) { return scalarLess(a.1.lower, b.1.lower) }
            if !scalarEq(a.1.n, b.1.n) { return scalarLess(a.1.n, b.1.n) }
            return a.1.v < b.1.v
        }.map { $0.0 }
    }

    public func flSortedByFormid(_ fl: Record) -> [Sub] {
        stableSorted(flEntries(fl)) { (lnam($0).map { Int64($0) } ?? -1) < (lnam($1).map { Int64($0) } ?? -1) }
    }

    public func flDeduped(_ fl: Record) -> [Sub] {
        var seen = Set<UInt32?>(), out: [Sub] = []
        for s in flEntries(fl) {
            let v = lnam(s)
            if seen.contains(v) { continue }
            seen.insert(v)
            out.append(s)
        }
        return out
    }

    public func flWithoutBroken(_ fl: Record) -> [Sub] {
        let P = fl.plugin!
        var out: [Sub] = []
        for s in flEntries(fl) {
            guard let v = lnam(s) else { continue }
            let o = origin(P, v)
            if !(o == P.name || find(o) != nil) || resolve(P, v) != nil { out.append(s) }
        }
        return out
    }

    // MARK: mots-clés et globales

    public static func keywords(_ r: Record) -> [UInt32] {
        guard let d = r.subs.first(where: { $0.t == "KWDA" }) else { return [] }
        return (0..<(d.d.count / 4)).map { u32s(d.d, $0 * 4) }
    }

    public static func setKeywords(_ r: Record, _ ids: [UInt32]) {
        r.subs = r.subs.filter { $0.t != "KWDA" && $0.t != "KSIZ" }
        if !ids.isEmpty {
            r.subs.append(Sub("KSIZ", p32(ids.count)))
            r.subs.append(Sub("KWDA", ids.flatMap { p32($0) }))
        }
    }

    public static func globType(_ r: Record) -> String {
        if let fn = r.subs.first(where: { $0.t == "FNAM" }), let b = fn.d.first {
            return String(Unicode.Scalar(b))
        }
        return "f"
    }

    public static func setGlobType(_ r: Record, _ c: String) {
        let d: Bytes = [c.unicodeScalars.first.map { UInt8(truncatingIfNeeded: $0.value) } ?? 0]
        if let fn = r.subs.first(where: { $0.t == "FNAM" }) { fn.d = d } else { r.subs.insert(Sub("FNAM", d), at: 0) }
    }

    public static func globValue(_ r: Record) -> Float? {
        if let fl = r.subs.first(where: { $0.t == "FLTV" }), fl.d.count == 4 { return floatOf(fl.d) }
        return nil
    }

    public static func setGlobValue(_ r: Record, _ v: Double) {
        if let fl = r.subs.first(where: { $0.t == "FLTV" }) { fl.d = f32(v) } else { r.subs.append(Sub("FLTV", f32(v))) }
    }

    // MARK: recherche et analyses

    public func search(_ q: String, sort: SortMode = .file, limit: Int = 300) -> (recs: [Record], total: Int) {
        let l = q.lowercased(), u = q.uppercased()
        var matches: [Record] = []
        for P in plugins {
            for r in P.all where r.t.lowercased() == l || edid(r).lowercased().contains(l) || hexs(r.id).contains(u) {
                matches.append(r)
            }
        }
        if sort != .file { matches = sortRecords(matches, sort) }
        return (Array(matches.prefix(limit)), matches.count)
    }

    public func whereUsed(_ r: Record, limit: Int = 300) -> [(Record, Sub)] {
        let P = r.plugin!
        var hits: [(Record, Sub)] = []
        for Q in plugins {
            guard case .id(let id) = Workspace.remapId(P, r.id, Q) else { continue }
            let target = p32(id)
            for rec in Q.all where rec !== r {
                if let s = rec.subs.first(where: { $0.d.count == 4 && $0.d == target }) { hits.append((rec, s)) }
            }
        }
        return Array(hits.prefix(limit))
    }

    /// (doublons de FormID, doublons d'EditorID) ; groupes dans l'ordre de première apparition.
    public func findDuplicates() -> (byId: [[Record]], byEdid: [[Record]]) {
        var eOrder: [Key] = [], iOrder: [Key] = []
        var byE: [Key: [Record]] = [:], byI: [Key: [Record]] = [:]
        for P in plugins {
            for r in P.all where r !== P.header {
                let e = lc(edid(r))
                if !e.isEmpty {
                    if byE[Key(e)] == nil { eOrder.append(Key(e)) }
                    byE[Key(e), default: []].append(r)
                }
                let k = Key("\(P.name)|\(r.id)")
                if byI[k] == nil { iOrder.append(k) }
                byI[k, default: []].append(r)
            }
        }
        return (iOrder.compactMap { byI[$0]! }.filter { $0.count > 1 }, eOrder.compactMap { byE[$0]! }.filter { $0.count > 1 })
    }

    public static func comparePlugins(_ A: Plugin, _ B: Plugin) -> (added: [Record], removed: [Record], changed: [Record]) {
        func key(_ r: Record) -> Key { Key("\(r.t)|\(lc(edid(r)))") }
        func table(_ P: Plugin) -> (order: [Key], map: [Key: Record]) {
            var order: [Key] = [], map: [Key: Record] = [:]
            for r in P.all where r !== P.header {
                let k = key(r)
                if map[k] == nil { order.append(k) }
                map[k] = r
            }
            return (order, map)
        }
        let a = table(A), b = table(B)
        let added = b.order.filter { a.map[$0] == nil }.map { b.map[$0]! }
        let removed = a.order.filter { b.map[$0] == nil }.map { a.map[$0]! }
        var changed: [Record] = []
        for k in a.order {
            guard let ra = a.map[k], let rb = b.map[k] else { continue }
            let sa = ra.subs.filter { $0.t != "EDID" }, sb = rb.subs.filter { $0.t != "EDID" }
            if sa.count != sb.count || zip(sa, sb).contains(where: { $0.t != $1.t || $0.d != $1.d }) { changed.append(rb) }
        }
        return (added, removed, changed)
    }

    public static func stats(_ P: Plugin) -> [(String, Int)] {
        var order: [String] = [], counts: [String: Int] = [:]
        for r in P.all where r !== P.header {
            if counts[r.t] == nil { order.append(r.t) }
            counts[r.t, default: 0] += 1
        }
        return stableSorted(order.map { ($0, counts[$0]!) }) { $0.1 > $1.1 }
    }

    // MARK: comparaison côte à côte

    public func decode4(_ P: Plugin?, _ d: Bytes) -> String? {
        guard d.count == 4, let P else { return nil }
        guard let t = resolve(P, u32s(d)) else { return nil }
        return pyStrip("\(t.t) \(edid(t))")
    }

    public func decodeVal(_ r: Record?, _ s: Sub?) -> String {
        guard let s else { return "" }
        if let nm = decode4(r?.plugin, s.d) { return "\(hexs(u32s(s.d)))  — \(nm)" }
        if isText(s.d) { return textOf(s.d) }
        return s.d.prefix(20).map { hexs($0, 2) }.joined(separator: " ") + (s.d.count > 20 ? " …" : "")
    }
}
