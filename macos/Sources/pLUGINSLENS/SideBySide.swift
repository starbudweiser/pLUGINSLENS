// Comparaison côte à côte de deux enregistrements (port de SideBySideDialog et CellEditor).

import AppKit
import LensCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct CellDrag {
    let r: Record
    let s: Sub
    let key: String
}

@MainActor @Observable
final class SideBySideModel {
    var a: Record?
    var b: Record?
    var rev = 0       // reconstruction complète (redraw)
    var diffRev = 0   // couleurs seulement (refresh_diff)
    var cellDrag: CellDrag?
    var onClose: () -> Void = {}

    init(a: Record?, b: Record?) { self.a = a; self.b = b }
}

struct SideBySideView: View {
    let model: AppModel
    @Bindable var sbs: SideBySideModel
    let close: () -> Void

    var body: some View {
        let _ = sbs.rev
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(L("Comparer deux enregistrements")).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            MetaText(text: L("Choisissez deux enregistrements, ou glissez-les ici depuis l'arbre. Glissez la poignée ⠿ d'un champ pour copier sa valeur de l'autre côté."))
            HStack(spacing: Socle.M.space2) {
                slot(L("Enregistrement A"), sbs.a) { sbs.a = $0 }
                slot(L("Enregistrement B"), sbs.b) { sbs.b = $0 }
            }
            table
            HStack { Spacer(); SmallButton(L("Fermer")) { sbs.onClose(); close() } }
        }
        .padding(Socle.M.space4)
        .onExitCommand { sbs.onClose(); close() }
    }

    // MARK: Emplacements A / B

    private func slot(_ title: String, _ r: Record?, set: @escaping (Record?) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased()).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle)
            Text(r.map { "\($0.t)  \(label($0))  (\($0.plugin!.name))" } ?? "").socle(Socle.T.body).foregroundStyle(Socle.C.text).lineLimit(1)
            SmallButton(r != nil ? L("Changer…") : L("Choisir un enregistrement…")) {
                model.pickRecord { t in
                    if let t { set(t); sbs.rev += 1 }
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusMd).stroke(Socle.C.border, lineWidth: 1))
        .recordDrop {
            if let first = model.dragRecs.first { set(first); sbs.rev += 1 }
        }
    }

    // MARK: Tableau

    private func head(_ r: Record?) -> String {
        guard let r else { return "—" }
        return "\(r.t)  \(edid(r))  (\(r.plugin!.name))\(r.plugin!.locked ? L("  (verrouillé)") : "")"
    }

    private var table: some View {
        let _ = sbs.diffRev
        let a = sbs.a, b = sbs.b
        return ScrollView([.vertical]) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("").frame(width: 120)
                    Text(head(a)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                    Text(head(b)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                }
                .socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textStrong).padding(.vertical, 6)
                .background(Socle.C.surfaceRaised)
                if a != nil || b != nil { rows(a, b) }
            }
        }
        .background(Socle.C.surface)
        .overlay(Rectangle().stroke(Socle.C.border, lineWidth: 1))
    }

    @ViewBuilder
    private func rows(_ a: Record?, _ b: Record?) -> some View {
        row(L("Type"), AnyView(Text(a?.t ?? "—").socle(Socle.T.body).foregroundStyle(Socle.C.text)),
            AnyView(Text(b?.t ?? "—").socle(Socle.T.body).foregroundStyle(Socle.C.text)), diff: a != nil && b != nil && a!.t != b!.t)
        if let a, let b {
            row(L("FormID"), AnyView(hex(a, id: true)), AnyView(hex(b, id: true)), diff: a.id != b.id)
            row(L("Flags"), AnyView(hex(a, id: false)), AnyView(hex(b, id: false)), diff: a.flags != b.flags)
            row(L("Propriétaire"), AnyView(Text(owner(a.id, a.plugin!)).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)),
                AnyView(Text(owner(b.id, b.plugin!)).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)), diff: false)
            ForEach(Array(unionRows(a, b).enumerated()), id: \.offset) { _, x in
                let d = model.ws.decodeVal(a, x.a) != model.ws.decodeVal(b, x.b)
                row(x.key, AnyView(CellEditor(model: model, sbs: sbs, r: a, s: x.a, tag: x.tag, key: x.key)),
                    AnyView(CellEditor(model: model, sbs: sbs, r: b, s: x.b, tag: x.tag, key: x.key)), diff: d)
            }
        } else {
            let only = (a ?? b)!
            row(L("FormID"), idCell(a), idCell(b), diff: false)
            ForEach(Array(subRows(only).enumerated()), id: \.offset) { _, x in
                row(x.key,
                    a != nil ? AnyView(CellEditor(model: model, sbs: sbs, r: a!, s: x.sub, tag: x.tag, key: x.key)) : AnyView(absent),
                    b != nil ? AnyView(CellEditor(model: model, sbs: sbs, r: b!, s: x.sub, tag: x.tag, key: x.key)) : AnyView(absent),
                    diff: false)
            }
        }
    }

    private func idCell(_ r: Record?) -> AnyView {
        if let r { return AnyView(hex(r, id: true)) }
        return AnyView(Text("—").socle(Socle.T.body).foregroundStyle(Socle.C.text))
    }

    private var absent: some View { Text(L("(absent)")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle) }

    private func row(_ key: String, _ wa: AnyView, _ wb: AnyView, diff: Bool) -> some View {
        HStack(spacing: 0) {
            Text(key).socle(Socle.T.labelStrong).foregroundStyle(Socle.C.textMuted).padding(.horizontal, 6)
                .frame(width: 120, alignment: .leading)
            wa.frame(maxWidth: .infinity, alignment: .leading)
            wb.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .background(diff ? Socle.C.dangerBg : Color.clear)
    }

    private func hex(_ r: Record, id: Bool) -> some View {
        SBSHexField(value: id ? r.id : r.flags, locked: r.plugin!.locked) { v in
            if id { r.id = v } else { r.flags = v }
            model.setDirty(r.plugin!, L("{v} modifié (côte à côte)", ["v": id ? "FormID" : "Flags"]))
            if id { model.refreshRecordItem(r) }
            sbs.diffRev += 1
        }
    }
}

struct SBSHexField: View {
    let value: UInt32
    let locked: Bool
    let apply: (UInt32) -> Void
    @State private var text: String
    @State private var bad = false

    init(value: UInt32, locked: Bool, apply: @escaping (UInt32) -> Void) {
        self.value = value; self.locked = locked; self.apply = apply
        _text = State(initialValue: hexs(value))
    }

    var body: some View {
        TextField("", text: $text)
            .font(Socle.T.mono.font).textFieldStyle(.plain)
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(bad ? Socle.C.dangerBg : Socle.C.bgSunken)
            .disabled(locked)
            .onChange(of: text) { _, new in
                if let v = jsParseHex(new) { bad = false; apply(v) } else { bad = true }
            }
            .padding(.horizontal, 2)
    }
}

// MARK: Cellule modifiable

struct CellEditor: View {
    let model: AppModel
    let sbs: SideBySideModel
    let r: Record
    let s: Sub?
    let tag: String
    let key: String
    @State private var text = ""
    @State private var bad = false
    @State private var isTxt = false
    @State private var decoded = ""

    var body: some View {
        HStack(spacing: 4) {
            if let s {
                Text("⠿").socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)
                    .help(L("Glissez sur l'autre côté pour y copier ce champ"))
                    .onDrag {
                        sbs.cellDrag = CellDrag(r: r, s: s, key: key)
                        return NSItemProvider(object: DRAG_MARK as NSString)
                    }
                TextField("", text: $text)
                    .font(Socle.T.mono.font).textFieldStyle(.plain)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(bad ? Socle.C.dangerBg : Socle.C.bgSunken)
                    .disabled(r.plugin!.locked)
                    .onChange(of: text) { _, new in edited(new, s) }
                if s.d.count == 4 {
                    Text(decoded).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)
                    if !r.plugin!.locked { SmallButton(L("Choisir…")) { pick(s) } }
                }
            } else {
                Text(L("(absent)")).socle(Socle.T.body).foregroundStyle(Socle.C.textSubtle)
            }
        }
        .padding(2)
        .recordDrop { acceptDrop() }
        .onAppear {
            guard let s else { return }
            isTxt = isText(s.d) && s.d.count != 4
            text = isTxt ? textOf(s.d) : hexBytes(s.d)
            if s.d.count == 4 { decoded = model.ws.decode4(r.plugin, s.d) ?? "" }
        }
    }

    private func setData(_ s: Sub, _ nd: Bytes, _ msg: String) {
        s.d = nd
        model.setDirty(r.plugin!, msg)
        if nd.count == 4 { decoded = model.ws.decode4(r.plugin, nd) ?? "" }
        sbs.diffRev += 1
    }

    private func edited(_ new: String, _ s: Sub) {
        let nd: Bytes
        if isTxt {
            nd = textBytes(new)
            bad = false
        } else {
            guard let h = parseHexBytes(new) else { bad = true; return }
            nd = h
            bad = false
        }
        if nd == s.d { return }
        setData(s, nd, L("Modifié {t} sur {label} (côte à côte)", ["t": s.t, "label": label(r)]))
    }

    private func pick(_ s: Sub) {
        model.pickRecord { t in
            guard let t, let x = model.xrefWithMaster(t, r.plugin!) else { return }
            let nd = p32(x)
            text = hexBytes(nd)
            setData(s, nd, L("Modifié {t} sur {label} (côte à côte)", ["t": s.t, "label": label(r)]))
        }
    }

    /// Dépôt sur cette cellule : copie d'un champ de l'autre côté, ou enregistrement glissé depuis l'arbre.
    private func acceptDrop() {
        let win = model
        if win.locked(r.plugin) { return }
        if let cd = sbs.cellDrag, cd.key == key, cd.r !== r {
            var nd = cd.s.d
            let frm = cd.r.plugin!.name
            if nd.count == 4 && cd.r.plugin !== r.plugin {
                if let tgt = win.ws.resolve(cd.r.plugin!, u32s(nd)) {
                    guard let x = win.xrefWithMaster(tgt, r.plugin!) else { return }
                    nd = p32(x)
                }
            }
            if let s {
                setData(s, nd, L("Copié {tag} depuis {frm} (côte à côte)", ["tag": tag, "frm": frm]))
            } else {
                r.subs.append(Sub(tag, nd))
                win.setDirty(r.plugin!, L("Copié {tag} depuis {frm} (côte à côte)", ["tag": tag, "frm": frm]))
            }
            sbs.cellDrag = nil
            sbs.rev += 1
            return
        }
        if let first = win.dragRecs.first, s == nil || s!.d.count == 4 {
            guard let x = win.xrefWithMaster(first, r.plugin!) else { return }
            if let s {
                setData(s, p32(x), L("{t} défini sur {label} par glisser", ["t": s.t, "label": label(r)]))
            } else {
                r.subs.append(Sub(tag, p32(x)))
                win.setDirty(r.plugin!, L("Ajouté {tag} à {label} par glisser", ["tag": tag, "label": label(r)]))
            }
            sbs.rev += 1
        }
    }
}
