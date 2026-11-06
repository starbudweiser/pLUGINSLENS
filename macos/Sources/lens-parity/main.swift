// Rejoue le scénario de tests/test_parity.py (même suite d'opérations que le JavaScript d'origine et le Python)
// et imprime en JSON les empreintes SHA-256 de chaque étape.
// Usage : lens-parity fichier.esp vide.esp

import CryptoKit
import Foundation
import LensCore

func sha(_ P: Plugin) -> String {
    SHA256.hash(data: serialize(P)).map { String(format: "%02x", $0) }.joined()
}

func jsonString(_ s: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
    let t = String(decoding: data, as: UTF8.self)
    return String(t.dropFirst(1).dropLast(1))
}

struct Out {
    var steps: [(String, String)] = []
    var texts: [(String, String)] = []
    var error: String?
    func json() -> String {
        func obj(_ a: [(String, String)]) -> String {
            "{" + a.map { "\(jsonString($0.0)):\(jsonString($0.1))" }.joined(separator: ",") + "}"
        }
        var s = "{\"steps\":\(obj(steps)),\"texts\":\(obj(texts))"
        if let e = error { s += ",\"error\":\(jsonString(e))" }
        return s + "}"
    }
}

struct Nil: Error {}
func need<T>(_ v: T?) throws -> T { if let v { return v }; throw Nil() }

func scenario(_ pathX: String, _ pathE: String) -> Out {
    var out = Out()
    let ws = Workspace(confirm: { _ in true }, alert: { _ in })
    func h(_ k: String, _ P: Plugin) { out.steps.append((k, sha(P))) }
    func load(_ path: String) throws -> Plugin {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let P = try loadPlugin(name: (path as NSString).lastPathComponent, data: Array(data))
        ws.plugins.append(P)
        return P
    }
    do {
        let X = try load(pathX)
        h("load", X)
        Workspace.fixHedr(X); h("fixhedr", X)
        out.texts.append(("nextId", hexs(try need(ws.nextId(X)))))
        let fl = try need(ws.newFormlist(X, "PL_Test"))
        Workspace.markDirty(X); h("newfl", X)
        let body = X.all.filter { $0 !== X.header && $0 !== fl }
        if ws.addEntries(fl, Array(body.prefix(5))).changed { Workspace.markDirty(X) }
        h("addentries", X)
        let named = body.filter { !edid($0).isEmpty }
        if !named.isEmpty, ws.cloneRecord(named[min(9, named.count - 1)]) != nil { Workspace.markDirty(X) }
        h("clone", X)
        var lines = [ws.exportList(fl), "# commentaire"]
        lines += named.dropFirst(5).prefix(3).map { edid($0) }
        lines += ["0x00ABCDEF", "NotARealEditorID_zz"]
        lines += body.dropFirst(6).prefix(2).map { hexs($0.id) }
        let res = ws.importList(fl, lines.joined(separator: "\n"))
        if res.changed || res.raw > 0 { Workspace.markDirty(X) }
        h("import", X)
        out.texts.append(("export", ws.exportList(fl)))
        let tops = Array(body.filter { ws.topOf($0) != nil }.prefix(3))
        var clip = ws.copyRecords(tops).items
        let pr = ws.pasteRecords(X, clip)
        if pr.changed { Workspace.markDirty(X) }
        h("paste", X)
        Workspace.undoRedo(X, back: true); h("undo", X)
        Workspace.fixHedr(X); h("undo_save", X)
        Workspace.undoRedo(X, back: false); h("redo", X)
        let E = try load(pathE)
        let flE = try need(ws.newFormlist(E, "PL_E_List"))
        Workspace.markDirty(E); h("E_newfl", E)
        _ = ws.addEntries(flE, Array(body.prefix(4))); h("E_add", E)
        out.texts.append(("E_masters", E.masters.joined(separator: "|")))
        let newClip = ws.copyRecords([fl]).items
        if !newClip.isEmpty { clip = newClip }
        _ = ws.pasteRecords(E, clip); h("E_paste", E)
        Workspace.fixHedr(E); h("E_save", E)
        out.texts.append(("E_export", ws.exportList(flE)))
    } catch {
        out.error = "\(error)"
    }
    return out
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: lens-parity plugin.esp vide.esp\n".utf8))
    exit(2)
}
print(scenario(args[0], args[1]).json())
