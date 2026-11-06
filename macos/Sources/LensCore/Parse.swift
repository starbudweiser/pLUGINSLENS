// Lecture / écriture binaire (parse, ser, serialize).

import CZlib
import Foundation

func inflateData(_ src: ArraySlice<UInt8>) throws -> Bytes {
    var stream = z_stream()
    guard inflateInit_(&stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw LensError.zlib(-2) }
    defer { inflateEnd(&stream) }
    var input = Array(src)
    var out = Bytes()
    var chunk = Bytes(repeating: 0, count: max(1 << 16, input.count * 3))
    var status: Int32 = Z_OK
    try input.withUnsafeMutableBufferPointer { inp in
        stream.next_in = inp.baseAddress
        stream.avail_in = UInt32(inp.count)
        repeat {
            let produced: Int = chunk.withUnsafeMutableBufferPointer { o in
                stream.next_out = o.baseAddress
                stream.avail_out = UInt32(o.count)
                status = inflate(&stream, Z_NO_FLUSH)
                return o.count - Int(stream.avail_out)
            }
            out.append(contentsOf: chunk[0..<produced])
            if status != Z_OK && status != Z_STREAM_END { throw LensError.zlib(status) }
            // Flux incomplet : plus d'entrée mais pas de fin de flux
            if status == Z_OK && stream.avail_in == 0 && produced == 0 { throw LensError.zlib(Z_BUF_ERROR) }
        } while status != Z_STREAM_END
    }
    return out
}

/// Tranche bornée (comme les tranches Python).
func sl(_ u: Bytes, _ a: Int, _ b: Int) -> Bytes {
    let lo = max(0, min(a, u.count)), hi = max(lo, min(b, u.count))
    return Array(u[lo..<hi])
}

func parseSubs(_ d: Bytes) throws -> [Sub] {
    var out: [Sub] = []
    var q = 0
    var xx: Int?
    let n = d.count
    while q + 6 <= n {
        let t = s4(d, q)
        var s = Int(d[q + 4]) | Int(d[q + 5]) << 8
        if t == "XXXX" {
            xx = Int(try u32(d, q + 6))
            q += 10
            continue
        }
        if let x = xx { s = x; xx = nil }
        let lo = min(q + 6, n), hi = min(q + 6 + s, n)
        let data = Array(d[lo..<hi])
        let sub = Sub(t, data)
        // HEDR est modifié sur place par fixHedr : on le garde mutable
        if t == "HEDR" { sub.buf.isArray = true }
        out.append(sub)
        q += 6 + s
    }
    return out
}

func parseNodes(_ u: Bytes, _ start: Int, _ end: Int) throws -> [Node] {
    var out: [Node] = []
    var p = start
    while p + 24 <= end {
        let t = s4(u, p)
        let sz = Int(try u32(u, p + 4))
        if t == "GRUP" {
            guard sz >= 24 else { throw LensError.invalid("groupe de taille \(sz)") }
            let kids = try parseNodes(u, p + 24, p + sz)
            out.append(GroupNode(label: sl(u, p + 8, p + 12), tail: sl(u, p + 12, p + 24),
                             kids: NodeList(kids)))
            p += sz
            continue
        }
        let fl = try u32(u, p + 8)
        var d: Bytes
        let lo = min(p + 24, u.count), hi = min(p + 24 + sz, u.count)
        if fl & COMPRESSED != 0 {
            d = try inflateData(u[min(lo + 4, hi)..<hi])
        } else {
            d = Array(u[lo..<hi])
        }
        out.append(Record(t, flags: fl, id: try u32(u, p + 12), tail: sl(u, p + 16, p + 24),
                          subs: try parseSubs(d)))
        p += 24 + sz
    }
    return out
}

func ser(_ n: Node, into out: inout Bytes) {
    if let g = n as? GroupNode {
        var body = Bytes()
        for x in g.kids.items { ser(x, into: &body) }
        out += Array("GRUP".utf8)
        out += p32(body.count + 24)
        out += Array(g.label.prefix(4))
        out += Array(g.tail.prefix(12))
        out += body
        return
    }
    let r = n as! Record
    var body = Bytes()
    for s in r.subs {
        let d = s.buf.b
        let big = d.count > 65535
        if big { body += Array("XXXX".utf8) + [4, 0] + p32(d.count) }
        body += typeBytes(s.t)
        let l = big ? 0 : d.count
        body += [UInt8(l & 0xFF), UInt8(l >> 8)]
        body += d
    }
    out += typeBytes(r.t)
    out += p32(body.count)
    out += p32(r.flags & ~COMPRESSED)
    out += p32(r.id)
    out += Array(r.tail.prefix(8))
    out += body
}

public func serialize(_ P: Plugin) -> Bytes {
    var out = Bytes()
    for n in P.root.items { ser(n, into: &out) }
    return out
}

public func readMasters(_ P: Plugin) -> [String] {
    P.header.subs.filter { $0.t == "MAST" }.map { stripNul(td($0.d)) }
}

public func loadPlugin(name: String, data: Bytes, dirty: Bool = false, t: Double = 0) throws -> Plugin {
    guard s4(data, 0) == "TES4" else { throw LensError.notPlugin }
    let P = Plugin(name: name, root: NodeList(try parseNodes(data, 0, data.count)), dirty: dirty, t: t)
    indexNodes(P.root, P)
    P.base = snapshot(P)
    P.masters = readMasters(P)
    return P
}
