// Modèle des plugins : Sub / Record / GroupNode / Plugin (src/plugin_core.py).
//
// Les listes de nœuds sont des objets (NodeList) pour garder l'identité de la liste parente,
// comme les listes Python (`g.kids is r.parent`).

import Foundation

/// Octets partagés. Le sous-enregistrement HEDR est modifié sur place par fixHedr (comme en JavaScript, où les
/// instantanés d'annulation partagent ce tableau) : `isArray` reproduit le bytearray de Python.
public final class Buf {
    public var b: Bytes
    public var isArray: Bool
    public init(_ b: Bytes, isArray: Bool = false) { self.b = b; self.isArray = isArray }
}

public final class Sub {
    public var t: String
    public var buf: Buf
    /// mode d'affichage : "t" texte, "h" hexadécimal
    public var m: String?
    public var bad = false

    public init(_ t: String, _ d: Bytes, m: String? = nil) {
        self.t = t
        buf = Buf(d)
        self.m = m
    }

    init(t: String, buf: Buf, m: String?) {
        self.t = t
        self.buf = buf
        self.m = m
    }

    /// Affecter `d` crée de nouveaux octets (ne touche pas aux copies qui partageaient les anciens).
    public var d: Bytes {
        get { buf.b }
        set { buf = Buf(newValue) }
    }
}

public final class NodeList {
    public var items: [Node]
    public init(_ items: [Node] = []) { self.items = items }
    public func index(of n: Node) -> Int? { items.firstIndex { $0 === n } }
}

public class Node {
    public var parent: NodeList?
    public var plugin: Plugin?
    public let isGroup: Bool
    init(isGroup: Bool) { self.isGroup = isGroup }
    public var k: String { isGroup ? "g" : "r" }
}

public final class Record: Node {
    public var t: String
    public var flags: UInt32
    public var id: UInt32
    public var tail: Bytes
    public var subs: [Sub]

    public init(_ t: String, flags: UInt32, id: UInt32, tail: Bytes, subs: [Sub]) {
        self.t = t; self.flags = flags; self.id = id; self.tail = tail; self.subs = subs
        super.init(isGroup: false)
    }
}

public final class GroupNode: Node {
    public var label: Bytes
    public var tail: Bytes
    public var kids: NodeList

    public init(label: Bytes, tail: Bytes, kids: NodeList) {
        self.label = label; self.tail = tail; self.kids = kids
        super.init(isGroup: true)
    }
}

public final class Plugin {
    public var name: String
    public var root: NodeList
    public var all: [Record] = []
    public var idx: [UInt32: Record]?
    public var dirty = false
    public var masters: [String] = []
    public var undo: [[Node]] = []
    public var redo: [[Node]] = []
    public var pend = false
    public var base: [Node] = []
    public var log: [String] = []
    public var locked = false
    public var t: Double = 0

    public init(name: String, root: NodeList, dirty: Bool = false, t: Double = 0) {
        self.name = name; self.root = root; self.dirty = dirty; self.t = t
    }

    public var header: Record { root.items[0] as! Record }

    /// Casse les références parent/plugin (cycles) quand le plugin est fermé.
    public func dispose() {
        func walk(_ l: [Node]) {
            for n in l {
                n.parent = nil
                n.plugin = nil
                if let g = n as? GroupNode { walk(g.kids.items) }
            }
        }
        walk(root.items)
        all = []; idx = nil; undo = []; redo = []; base = []
    }
}

public func cloneNode(_ n: Node) -> Node {
    if let g = n as? GroupNode {
        return GroupNode(label: g.label, tail: g.tail, kids: NodeList(g.kids.items.map(cloneNode)))
    }
    let r = n as! Record
    return Record(r.t, flags: r.flags, id: r.id, tail: r.tail,
                  subs: r.subs.map { Sub(t: $0.t, buf: $0.buf, m: $0.m) })
}

public func snapshot(_ P: Plugin) -> [Node] { P.root.items.map(cloneNode) }

func indexNodes(_ lst: NodeList, _ P: Plugin) {
    for n in lst.items {
        n.parent = lst
        n.plugin = P
        if let g = n as? GroupNode { indexNodes(g.kids, P) } else { P.all.append(n as! Record) }
    }
}
