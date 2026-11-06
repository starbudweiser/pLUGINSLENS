// Tests du cœur : utilitaires d'octets et de texte, lecture / écriture, maîtres, FormLists, annulation.
// Les plugins sont construits en mémoire : aucun vrai plugin n'est lu ni écrit.

import Foundation
import XCTest
@testable import LensCore

func sub(_ t: String, _ d: Bytes) -> Bytes {
    let n = d.count
    return Array(t.utf8) + [UInt8(n & 0xFF), UInt8(n >> 8)] + d
}

func rec(_ t: String, id: UInt32, flags: UInt32 = 0, _ subs: [Bytes]) -> Bytes {
    let body = subs.flatMap { $0 }
    return Array(t.utf8) + p32(body.count) + p32(flags) + p32(id) + Bytes(repeating: 0, count: 8) + body
}

func grup(_ label: String, _ kids: [Bytes]) -> Bytes {
    let body = kids.flatMap { $0 }
    return Array("GRUP".utf8) + p32(body.count + 24) + Array(label.utf8) + Bytes(repeating: 0, count: 12) + body
}

func cstr(_ s: String) -> Bytes { Array(s.utf8) + [0] }

/// TES4 (HEDR + MAST éventuels) puis groupes KYWD / FLST.
func makePlugin(masters: [String] = [], flags: UInt32 = 0, kywd: Bool = true, extra: [Bytes] = []) -> Bytes {
    var hedr = Bytes()
    hedr += f32(1.7)
    hedr += p32(0) + p32(0x800)
    var subs = [sub("HEDR", hedr)]
    for m in masters { subs += [sub("MAST", cstr(m)), sub("DATA", Bytes(repeating: 0, count: 8))] }
    let n = UInt32(masters.count) << 24
    let kw = grup("KYWD", [rec("KYWD", id: n | 0x801, [sub("EDID", cstr("KwA"))]), rec("KYWD", id: n | 0x802, [sub("EDID", cstr("KwB"))])])
    return rec("TES4", id: 0, flags: flags, subs) + (kywd ? kw : []) + extra.flatMap { $0 }
}

final class CoreTests: XCTestCase {
    func testOctetsEtTexte() {
        XCTAssertEqual(hexs(UInt32(255)), "000000FF")
        XCTAssertEqual(hexs(UInt8(5), 2), "05")
        XCTAssertEqual(stripNul("ab\0cd"), "ab")
        XCTAssertEqual(stripNul("ab\0cd\nef"), "ab\0cd\nef")  // NUL suivi d'une fin de ligne : rien à retirer
        XCTAssertEqual(stripNul("a\nb\0c"), "a\nb")
        XCTAssertTrue(isText(Array("Abc\n\0".utf8)))
        XCTAssertFalse(isText([0x41, 0x80, 0]))
        XCTAssertFalse(isText([0]))
        XCTAssertEqual(textOf(cstr("é")), "é")
        XCTAssertEqual(parseHexBytes("01 aF,ff"), [1, 0xAF, 0xFF])
        XCTAssertNil(parseHexBytes("0"))
        XCTAssertNil(parseHexBytes("zz"))
        XCTAssertEqual(parseHexBytes(""), [])
    }

    func testJsParse() {
        XCTAssertEqual(jsParseHex("0x1F"), 0x1F)
        XCTAssertEqual(jsParseHex("  ff zz"), 0xFF)
        XCTAssertEqual(jsParseHex("-1"), 0xFFFFFFFF)
        XCTAssertEqual(jsParseHex("1FFFFFFFF"), 0xFFFFFFFF)
        XCTAssertEqual(jsParseHex("0x"), 0)  // « 0 » puis « x » ignoré
        XCTAssertNil(jsParseHex("xyz"))
        XCTAssertEqual(jsParseFloat("1.5abc"), 1.5)
        XCTAssertEqual(jsParseFloat(".5"), 0.5)
        XCTAssertEqual(jsParseFloat("5."), 5)
        XCTAssertEqual(jsParseFloat("1e3"), 1000)
        XCTAssertEqual(jsParseFloat("1e"), 1)
        XCTAssertEqual(jsParseFloat("-Infinity"), -Double.infinity)
        XCTAssertNil(jsParseFloat("abc"))
        XCTAssertNil(jsParseFloat("."))
    }

    func testFloat32() {
        XCTAssertEqual(f32(1.7), [0x9A, 0x99, 0xD9, 0x3F])
        XCTAssertEqual(f32(1e40), [0, 0, 0x80, 0x7F])  // dépassement : +inf
        XCTAssertEqual(f32(-1e40), [0, 0, 0x80, 0xFF])
        XCTAssertEqual(u32Hint(p32(1)), "u32 1 · i32 1 · f32 1.401298e-45 · form 00000001")
        XCTAssertEqual(u32Hint(f32(0.5)), "u32 1056964608 · i32 1056964608 · f32 0.5 · form 3F000000")
        XCTAssertEqual(u32Hint([1, 2, 3]), "")
    }

    func testAllerRetour() throws {
        let data = makePlugin(masters: ["Skyrim.esm"])
        let P = try loadPlugin(name: "t.esp", data: data)
        XCTAssertEqual(serialize(P), data)
        XCTAssertEqual(P.masters, ["Skyrim.esm"])
        XCTAssertEqual(P.all.count, 3)
        XCTAssertEqual(edid(P.all[1]), "KwA")
        XCTAssertThrowsError(try loadPlugin(name: "x", data: Array("NOPE".utf8) + Bytes(repeating: 0, count: 30)))
    }

    func testSousEnregistrementVolumineux() throws {
        let big = Bytes(repeating: 7, count: 70000)
        let r = rec("MISC", id: 0x900, [sub("EDID", cstr("Big"))] + [Array("DATA".utf8) + [0, 0] + big])
        // XXXX attendu à l'écriture : on construit le plugin par le cœur
        let P = try loadPlugin(name: "t.esp", data: makePlugin())
        let ws = Workspace()
        ws.plugins.append(P)
        let g = Workspace.topGroup(P, "MISC")
        let m = Record("MISC", flags: 0, id: 0x900, tail: Bytes(repeating: 0, count: 8), subs: [Sub("EDID", cstr("Big")), Sub("DATA", big)])
        g.kids.items.append(m); m.parent = g.kids; m.plugin = P; P.all.append(m)
        _ = r
        let out = serialize(P)
        let Q = try loadPlugin(name: "t2.esp", data: out)
        let back = Q.all.first { $0.t == "MISC" }!
        XCTAssertEqual(back.subs[1].d.count, 70000)
        XCTAssertEqual(serialize(Q), out)
    }

    func testGroupeCompresse() throws {
        // Enregistrement compressé (zlib) : relu, puis réécrit non compressé
        let inner = sub("EDID", cstr("Zipped"))
        var z = Bytes()
        z = [0x78, 0x01]  // zlib « stored » : en-tête + bloc non compressé + Adler-32
        z += [0x01, UInt8(inner.count), 0, UInt8(~inner.count & 0xFF), 0xFF] + inner
        var a: UInt32 = 1, b: UInt32 = 0
        for x in inner { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 }
        z += (b << 16 | a).bigEndianBytes
        let rec = Array("MISC".utf8) + p32(z.count + 4) + p32(COMPRESSED) + p32(0x901) + Bytes(repeating: 0, count: 8) + p32(inner.count) + z
        let data = makePlugin(extra: [grup("MISC", [rec])])
        let P = try loadPlugin(name: "z.esp", data: data)
        XCTAssertEqual(edid(P.all.last!), "Zipped")
        let out = serialize(P)
        XCTAssertEqual(try loadPlugin(name: "z2", data: out).all.last!.flags & COMPRESSED, 0)
    }

    func testMaitreEtFormList() throws {
        let ws = Workspace()
        let P = try loadPlugin(name: "a.esp", data: makePlugin())
        let Q = try loadPlugin(name: "b.esp", data: makePlugin(kywd: false))  // plugin de FormLists seulement
        ws.plugins = [P, Q]
        let fl = ws.newFormlist(Q, "Liste")!
        XCTAssertEqual(fl.id, 0x800)
        let res = ws.addEntries(fl, [P.all[1]])  // maître manquant : a.esp devient maître de b.esp
        XCTAssertTrue(res.changed)
        XCTAssertEqual(Q.masters, ["a.esp"])
        XCTAssertEqual(ws.exportList(fl), "KwA")
        XCTAssertEqual(ws.addEntries(fl, [P.all[1]]).dup, 1)
        // les identifiants propres au plugin sont décalés d'un maître
        XCTAssertEqual(fl.id >> 24, 1)
        XCTAssertEqual(ws.flDeduped(fl).count, 1)
        let imp = ws.importList(fl, "# note\nKwB\n0x00ABCDEF\ninconnu_zz\n")
        XCTAssertEqual(imp.n, 1)
        XCTAssertEqual(imp.bad, ["inconnu_zz"])
        XCTAssertEqual(imp.raw, 1)  // FormID brut accepté (maître 0 existant), sans enregistrement associé
        XCTAssertEqual(ws.flEntries(fl).count, 3)
        XCTAssertEqual(ws.flSortedByName(fl).map { lnam($0)! }.count, 3)
    }

    func testMaitreCirculaireEtNonFormList() throws {
        let ws = Workspace(confirm: { _ in true }, alert: { _ in })
        let P = try loadPlugin(name: "a.esp", data: makePlugin())
        let Q = try loadPlugin(name: "b.esp", data: makePlugin(masters: ["a.esp"]))
        ws.plugins = [P, Q]
        var warn: [String] = [], no = Set<String>()
        XCTAssertFalse(ws.ensureMaster(P, "b.esp", &warn, &no))  // b dépend de a : circulaire
        XCTAssertEqual(warn.count, 1)
        // P contient des KYWD : pas de maître ajouté sans risque
        var w2: [String] = [], n2 = Set<String>()
        XCTAssertFalse(ws.ensureMaster(P, "c.esp", &w2, &n2))
    }

    func testAnnulation() throws {
        let ws = Workspace()
        let P = try loadPlugin(name: "a.esp", data: makePlugin())
        ws.plugins = [P]
        let before = serialize(P)
        _ = ws.newFormlist(P, "L1")
        XCTAssertTrue(Workspace.markDirty(P, "x"))
        XCTAssertFalse(Workspace.markDirty(P, "y"))  // même point d'annulation
        XCTAssertNotEqual(serialize(P), before)
        XCTAssertTrue(Workspace.undoRedo(P, back: true))
        XCTAssertEqual(serialize(P), before)
        XCTAssertTrue(Workspace.undoRedo(P, back: false))
        XCTAssertEqual(P.all.count, 4)
        XCTAssertFalse(Workspace.undoRedo(P, back: false))
        XCTAssertEqual(P.log.count, 2)
    }

    func testCopierColler() throws {
        let ws = Workspace()
        let P = try loadPlugin(name: "a.esp", data: makePlugin())
        let Q = try loadPlugin(name: "b.esp", data: makePlugin())
        ws.plugins = [P, Q]
        let (clip, skipped) = ws.copyRecords([P.all[1], P.header])
        XCTAssertEqual(clip.count, 1)
        XCTAssertEqual(skipped, 1)
        // un KYWD ne se colle pas dans un autre plugin
        let r1 = ws.pasteRecords(Q, clip)
        XCTAssertEqual(r1.n, 0)
        XCTAssertEqual(r1.warn.count, 1)
        // mais dans le même plugin, avec un EditorID unique
        let r2 = ws.pasteRecords(P, clip)
        XCTAssertEqual(r2.n, 1)
        XCTAssertEqual(edid(P.all.last!), "KwA_copy")
    }

    func testFixHedr() throws {
        let P = try loadPlugin(name: "a.esp", data: makePlugin())
        Workspace.fixHedr(P)
        let h = P.header.subs[0].d
        XCTAssertEqual(u32s(h, 4), 3)  // 1 groupe + 2 enregistrements
        XCTAssertEqual(u32s(h, 8), 0x803)
    }

    func testTri() throws {
        let P = try loadPlugin(name: "a.esp", data: makePlugin())
        let recs = Array(P.all.dropFirst().reversed())
        XCTAssertEqual(sortRecords(recs, .edid).map { edid($0) }, ["KwA", "KwB"])
        XCTAssertEqual(sortRecords(recs, .formid).map(\.id), [0x801, 0x802])
        XCTAssertEqual(glabel(P.root.items[1] as! GroupNode), "Top KYWD")
    }

    func testReglagesEtSession() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pl_test_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let st = SessionStore(dir: dir)
        let P = try loadPlugin(name: "a.esp", data: makePlugin(), dirty: true, t: 12.5)
        st.write(P)
        let idx = st.index()
        XCTAssertEqual(idx.map(\.name), ["a.esp"])
        XCTAssertEqual(idx[0].entry.t, 12.5)
        XCTAssertTrue(idx[0].entry.dirty)
        XCTAssertEqual(st.read("a.esp").map { Array($0) }, serialize(P))
        st.remove("a.esp")
        XCTAssertTrue(st.index().isEmpty)
        // format de l'index lisible par la version Python (json.load)
        st.write(P)
        let text = try String(contentsOf: dir.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertEqual(text, "{\"a.esp\": {\"t\": 12.5, \"dirty\": true}}")

        let s = AppSettings(suite: "pluginslens.tests.\(UUID().uuidString)")
        s.workspaces = [("Un", ["a.esp", "b.esp"]), ("Deux", ["c.esp"])]
        XCTAssertEqual(s.workspaces.map(\.name), ["Un", "Deux"])
        XCTAssertEqual(s.workspaces[0].plugins, ["a.esp", "b.esp"])
        s.pins = ["b|00000001", "a|00000002"]
        XCTAssertEqual(s.string("pins"), "[\"a|00000002\", \"b|00000001\"]")
        XCTAssertEqual(s.pins.count, 2)
    }
}

extension UInt32 {
    var bigEndianBytes: Bytes { [UInt8(self >> 24), UInt8((self >> 16) & 0xFF), UInt8((self >> 8) & 0xFF), UInt8(self & 0xFF)] }
}
