// Menu Outils : utilisations, doublons, comparaison de plugins, statistiques, journal.

import AppKit
import LensCore
import SwiftUI

extension AppModel {
    func whereUsed(_ r: Record) {
        let d = ListData()
        let hits = ws.whereUsed(r)
        let many = ws.plugins.count > 1
        for (rec, s) in hits { d.record(rec, "  ·\(s.t)" + (many ? "  (\(rec.plugin!.name))" : "")) }
        if hits.isEmpty { d.message(L("Aucun enregistrement ouvert n'a de champ de 4 octets égal à ce FormID.")) }
        listDialog(title: L("Où est utilisé : {label}", ["label": label(r)]),
                   note: L("Heuristique : tout sous-enregistrement de 4 octets dont la valeur égale ce FormID (renuméroté pour chaque plugin). Peut inclure des faux positifs et ignore les champs qui ne font pas 4 octets."),
                   data: d)
    }

    func findDuplicates() {
        let (dupI, dupE) = ws.findDuplicates()
        let d = ListData()
        if !dupI.isEmpty {
            d.section(L("FORMID EN DOUBLE DANS UN PLUGIN"))
            for l in dupI { for r in l { d.record(r, "  (\(r.plugin!.name))") } }
        }
        if !dupE.isEmpty {
            d.section(L("EDITORID PARTAGÉS (MÊME NOM, ENREGISTREMENTS DIFFÉRENTS)"))
            for l in dupE { for r in l { d.record(r, "  (\(r.plugin!.name))") } }
        }
        if dupI.isEmpty && dupE.isEmpty { d.message(L("Aucun EditorID ni FormID en double dans les plugins ouverts.")) }
        listDialog(title: L("Doublons"),
                   note: L("Des FormID en double dans un même plugin sont invalides et doivent être corrigés. Des EditorID partagés entre plugins sont souvent normaux (surcharges)."),
                   data: d)
    }

    func comparePlugins() {
        if ws.plugins.count < 2 { flash(L("Ouvrez au moins deux plugins pour les comparer")); return }
        let d = ListData()
        let sel = CompareSelection(count: ws.plugins.count)
        let names = ws.plugins.map(\.name)
        let go = { [unowned self] in
            d.clear()
            let A = self.ws.plugins[sel.a], B = self.ws.plugins[sel.b]
            if A === B { d.message(L("Choisissez deux plugins différents.")); return }
            let (added, removed, changed) = Workspace.comparePlugins(A, B)
            for (title, lst) in [(L("Seulement dans {name}", ["name": B.name]), added),
                                 (L("Seulement dans {name}", ["name": A.name]), removed),
                                 (L("Modifiés (même EditorID, sous-enregistrements différents)"), changed)] where !lst.isEmpty {
                d.section("\(title.uppercased()) (\(lst.count))")
                for r in lst.prefix(200) { d.record(r) }
            }
            if added.isEmpty && removed.isEmpty && changed.isEmpty { d.message(L("Aucune différence trouvée par EditorID.")) }
        }
        go()
        listDialog(title: L("Comparer deux plugins"),
                   note: L("Associe les enregistrements par type et EditorID : idéal pour deux versions d'un même plugin."),
                   data: d) {
            CompareBar(names: names, sel: sel, go: go)
        }
    }

    func compareRecords() {
        let sel = tree?.selectedRecords() ?? []
        var a: Record?, b: Record?
        if sel.count >= 2 {
            a = sel[0]; b = sel[1]
        } else {
            a = (sel.isEmpty || (sel.count == 1 && sel[0] === cur)) ? cur : sel[0]
        }
        let m = SideBySideModel(a: a, b: b)
        let size = CGSize(width: settings.int("sbs_w", 760), height: settings.int("sbs_h", 520))
        let host = sheet(L("Comparer deux enregistrements"), size: size) { host in
            SideBySideView(model: self, sbs: m) { host.close() }
        }
        host.onResize = { [unowned self] s in
            self.settings.set("sbs_w", Int(s.width))
            self.settings.set("sbs_h", Int(s.height))
        }
        m.onClose = { [unowned self] in
            if let c = self.cur { self.showRecord(c) }
        }
    }

    func showStats() {
        guard let P = active else { return }
        let d = ListData()
        d.message(L("Enregistrements : {v}", ["v": fmtInt(P.all.count - 1)]))
        d.message(L("Maîtres : ") + (P.masters.isEmpty ? L("aucun") : P.masters.joined(separator: ", ")))
        d.section(L("ENREGISTREMENTS PAR TYPE"))
        for (t, n) in Workspace.stats(P) { d.message("\(t)    \(fmtInt(n))") }
        listDialog(title: P.name, data: d)
    }

    func showLog() {
        guard let P = active else { return }
        textDialog(title: L("Journal des modifications — {name}", ["name": P.name]),
                   value: P.log.isEmpty ? L("Aucune modification enregistrée pendant cette session.") : P.log.joined(separator: "\n"),
                   ok: L("Fermer"), hint: L("Session en cours uniquement."), readOnly: true)
    }
}

@MainActor @Observable
final class CompareSelection {
    var a = 0
    var b = 0
    init(count: Int) { b = min(1, count - 1) }
}

struct CompareBar: View {
    let names: [String]
    let sel: CompareSelection
    let go: () -> Void

    var body: some View {
        @Bindable var s = sel
        HStack(spacing: 8) {
            Text(L("A :")).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Picker("", selection: $s.a) { ForEach(Array(names.enumerated()), id: \.offset) { Text($1).tag($0) } }.labelsHidden()
            Text(L("B :")).socle(Socle.T.body).foregroundStyle(Socle.C.text)
            Picker("", selection: $s.b) { ForEach(Array(names.enumerated()), id: \.offset) { Text($1).tag($0) } }.labelsHidden()
            SmallButton(L("Comparer"), variant: .primary, action: go)
        }
    }
}
