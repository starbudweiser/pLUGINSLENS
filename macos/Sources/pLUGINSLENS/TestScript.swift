// Scénarios d'essai pilotés par variable d'environnement (PLUGINSLENS_SCRIPT=<fichier>), sans interface à manipuler.
// Chaque ligne : « commande arguments… » ; les écritures se font uniquement vers les chemins donnés (copies d'essai).
import AppKit
import LensCore

@MainActor
enum TestScript {
    static func run(_ path: String, model: AppModel) {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") && !$0.isEmpty }
        var i = 0
        func next() {
            guard i < lines.count else { return }
            let line = lines[i]; i += 1
            var delay = 0.4
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "open": model.loadFiles(arg.split(separator: "|").map(String.init)); delay = 1.5
            case "wait": delay = Double(arg) ?? 1
            case "show": // show <type> <edid>
                let a = arg.split(separator: " ").map(String.init)
                if let P = model.active, let r = P.all.first(where: { $0.t == a[0] && edid($0) == (a.count > 1 ? a[1] : "") }) { model.showRecord(r) }
            case "first": // première enregistrement du type donné
                if let P = model.active, let r = P.all.first(where: { $0.t == arg }) { model.showRecord(r) }
            case "setsub": // setsub <TAG> <texte>
                let a = arg.split(separator: " ", maxSplits: 1).map(String.init)
                if let r = model.cur, let s = r.subs.first(where: { $0.t == a[0] }) {
                    s.d = textBytes(a.count > 1 ? a[1] : "")
                    model.setDirty(r.plugin!, "script")
                    model.showRecord(r)
                }
            case "newfl": model.newFormlist()
            case "undo": model.undo(true)
            case "redo": model.undo(false)
            case "copy": model.copyRecords()
            case "paste": model.pasteRecords()
            case "active": if let P = model.ws.plugins.first(where: { $0.name == arg }) { model.active = P; model.status() }
            case "savecopy": if let P = model.active { model.saveCopy(P, to: URL(fileURLWithPath: arg)) }
            case "lang": model.settings.set("language", arg); I18n.setLang(LangChoice.resolve(arg)); model.retranslate()
            case "quit": NSApp.terminate(nil)
            case "log": FileHandle.standardError.write(Data("SCRIPT: \(arg) | plugins=\(model.ws.plugins.map { "\($0.name)[\($0.all.count)\($0.dirty ? "*" : "")]" }) cur=\(model.cur.map { "\($0.t) \(edid($0))" } ?? "-")\n".utf8))
            default: break
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { next() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { next() }
    }
}
