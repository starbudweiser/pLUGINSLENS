// Lecture des enregistrements (fonctions autonomes de plugin_core.py).

import Foundation

public func edid(_ r: Record) -> String {
    for s in r.subs where s.t == "EDID" { return stripNul(td(s.d)) }
    return ""
}

public func glabel(_ g: GroupNode) -> String {
    let gt = Int(u32s(g.tail, 0))
    let v: String
    if gt == 0 {
        v = s4(g.label, 0)
    } else if [1, 6, 7, 8, 9, 10].contains(gt) {
        v = hexs(u32s(g.label, 0))
    } else {
        v = String(Int32(bitPattern: u32s(g.label, 0)))
    }
    let name = gt < GROUP_TYPES.count ? GROUP_TYPES[gt] : "GroupNode"
    return "\(name) \(v)"
}

public func groupType(_ g: GroupNode) -> String { s4(g.label, 0) }

public func owner(_ id: UInt32, _ P: Plugin) -> String {
    let i = Int(id >> 24)
    return i < P.masters.count ? P.masters[i] : P.name + L(" (ce fichier)")
}

public func origin(_ P: Plugin, _ id: UInt32) -> String {
    let i = Int(id >> 24)
    return i < P.masters.count ? P.masters[i] : P.name
}

public func byId(_ P: Plugin, _ id: UInt32) -> Record? {
    if P.idx == nil {
        var d: [UInt32: Record] = [:]
        for r in P.all { d[r.id] = r }  // le dernier l'emporte, comme un dict Python
        P.idx = d
    }
    return P.idx![id]
}

public func hasRecords(_ n: Node) -> Bool {
    if n is Record { return true }
    return (n as! GroupNode).kids.items.contains(where: hasRecords)
}

public func isTop(_ g: Node) -> Bool {
    guard let g = g as? GroupNode else { return false }
    return u32s(g.tail, 0) == 0
}

public func lnam(_ s: Sub) -> UInt32? { s.d.count == 4 ? u32s(s.d, 0) : nil }

public func label(_ r: Record) -> String {
    let e = edid(r)
    return e.isEmpty ? hexs(r.id) : e
}

public struct SubRow {
    public let tag: String
    public let key: String
    public let sub: Sub
}

public struct UnionRow {
    public let key: String
    public let tag: String
    public let a: Sub?
    public let b: Sub?
}

public func subRows(_ r: Record) -> [SubRow] {
    var order: [String] = []
    var groups: [String: [Sub]] = [:]
    for s in r.subs {
        if groups[s.t] == nil { order.append(s.t) }
        groups[s.t, default: []].append(s)
    }
    var rows: [SubRow] = []
    for t in order {
        let arr = groups[t]!
        for (i, s) in arr.enumerated() {
            rows.append(SubRow(tag: t, key: t + (arr.count > 1 ? " #\(i + 1)" : ""), sub: s))
        }
    }
    return rows
}

public func unionRows(_ a: Record, _ b: Record) -> [UnionRow] {
    let ra = subRows(a), rb = subRows(b)
    var bm: [Key: SubRow] = [:]
    for x in rb { bm[Key(x.key)] = x }
    var seen = Set<Key>()
    var out: [UnionRow] = []
    for x in ra {
        out.append(UnionRow(key: x.key, tag: x.tag, a: x.sub, b: bm[Key(x.key)]?.sub))
        seen.insert(Key(x.key))
    }
    for x in rb where !seen.contains(Key(x.key)) {
        out.append(UnionRow(key: x.key, tag: x.tag, a: nil, b: x.sub))
    }
    return out
}

public func filteredRoot(_ P: Plugin, _ typeFilter: [String]) -> [Node] {
    P.root.items.filter { n in
        n === P.header || n is Record
            || (n is GroupNode && hasRecords(n) && (typeFilter.isEmpty || typeFilter.contains(groupType(n as! GroupNode).uppercased())))
    }
}

public enum SortMode: String {
    case file, formid, edid
}

/// Tri stable (à clé égale, l'ordre d'origine est conservé).
public func stableSorted<T>(_ a: [T], less: (T, T) -> Bool) -> [T] {
    a.enumerated().sorted { x, y in
        if less(x.element, y.element) { return true }
        if less(y.element, x.element) { return false }
        return x.offset < y.offset
    }.map { $0.element }
}

public func sortRecords(_ a: [Record], _ mode: SortMode) -> [Record] {
    switch mode {
    case .file: return a
    case .formid: return stableSorted(a) { $0.id < $1.id }
    case .edid:
        // clé (0, edid.lower(), 0) si EditorID, sinon (1, "", id)
        return stableSorted(a) { x, y in
            let ex = edid(x).lowercased(), ey = edid(y).lowercased()
            let gx = ex.isEmpty ? 1 : 0, gy = ey.isEmpty ? 1 : 0
            if gx != gy { return gx < gy }
            if gx == 0 { return scalarLess(ex, ey) }
            return x.id < y.id
        }
    }
}
