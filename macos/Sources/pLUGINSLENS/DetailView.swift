// Panneau de détail d'un enregistrement (port de show_record, SubEditor, fl_panel, glob_panel, kwda_panel).

import AppKit
import LensCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: Dépôt d'enregistrements glissés depuis l'arbre

/// Marque de nos glissés (l'arbre et les poignées de la comparaison écrivent aussi ce texte).
let DRAG_MARK = "pluginlens-record"

struct RecordDropDelegate: DropDelegate {
    @Binding var over: Bool
    let perform: () -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { over = true }
    func dropExited(info: DropInfo) { over = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .copy) }

    func performDrop(info: DropInfo) -> Bool {
        over = false
        guard let p = info.itemProviders(for: [.plainText]).first else { return false }
        _ = p.loadObject(ofClass: NSString.self) { s, _ in
            guard let s = s as? String, s.hasPrefix(DRAG_MARK) else { return }
            DispatchQueue.main.async { perform() }
        }
        return true
    }
}

extension View {
    /// Panneau qui accepte les enregistrements glissés (contour pointillé au survol).
    func recordDrop(perform: @escaping () -> Void) -> some View { modifier(RecordDropModifier(perform: perform)) }
}

struct RecordDropModifier: ViewModifier {
    let perform: () -> Void
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .overlay(Rectangle().strokeBorder(Socle.C.accent, style: StrokeStyle(lineWidth: 1, dash: [4, 3])).opacity(over ? 1 : 0).allowsHitTesting(false))
            .onDrop(of: [.plainText], delegate: RecordDropDelegate(over: $over, perform: perform))
    }
}

// MARK: Panneau (cadre Socle)

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) { content }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusMd).stroke(Socle.C.border, lineWidth: 1))
    }
}

struct MonoLabel: View {
    let text: String
    var color: Color = Socle.C.accentText
    var body: some View { Text(text).socle(Socle.T.mono).foregroundStyle(color).textSelection(.enabled) }
}

// MARK: Détail

struct DetailView: View {
    let model: AppModel

    var body: some View {
        let _ = model.langTick
        let _ = model.detailRev
        Group {
            switch model.detail {
            case .welcome: Welcome(model: model)
            case .message(let t):
                VStack { Spacer(); Text(t).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted); Spacer() }.frame(maxWidth: .infinity)
            case .record(let r): ScrollView { RecordPage(model: model, r: r).padding(.horizontal, 20).padding(.vertical, 16) }
            }
        }
        .id(model.detailRev)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Socle.C.bg)
    }
}

struct Welcome: View {
    let model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: Socle.M.space3) {
                Text(L("Glissez un ou plusieurs fichiers .ESP, .ESM ou .ESL ici")).socle(Socle.T.display)
                    .foregroundStyle(Socle.C.textStrong).multilineTextAlignment(.center)
                Text(L("Tout est analysé localement. Aucune installation de Skyrim n'est nécessaire."))
                    .socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).multilineTextAlignment(.center)
                SmallButton(L("Ouvrir des plugins"), variant: .action) { model.openDialog() }
            }
            .padding(32)
            .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusMd).stroke(Socle.C.border, lineWidth: 1))
            .padding(20)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

struct RecordPage: View {
    let model: AppModel
    let r: Record
    @State private var flagsRev = 0

    private var P: Plugin { r.plugin! }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if P.locked {
                Text(L("{name} est verrouillé. Déverrouillez-le depuis l'arbre pour le modifier.", ["name": P.name]))
                    .socle(Socle.T.body).foregroundStyle(Socle.C.warningSoft)
                    .padding(.horizontal, 10).padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Socle.C.warningBg, in: RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Socle.C.warningBorder, lineWidth: 1))
            }
            Text("\(r.t)  \(edid(r))").socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong).textSelection(.enabled)
            HStack(alignment: .top, spacing: 16) {
                HexField(name: L("FormID (hex)"), value: r.id, locked: P.locked) { v in
                    r.id = v
                    model.refreshRecordItem(r)
                    model.setDirty(P)
                }
                HexField(name: L("Flags (hex)"), value: r.flags, locked: P.locked, rev: flagsRev) { v in
                    r.flags = v
                    flagsRev += 1
                    model.setDirty(P)
                }
                Spacer(minLength: 0)
            }
            MetaText(text: L("{name} · Propriétaire : {owner}", ["name": P.name, "owner": owner(r.id, P)]))
            HStack(spacing: Socle.M.space2) {
                SmallButton(L("Ajouter un sous-enregistrement"), enabled: !P.locked) { model.addSub(r) }
                SmallButton(L("Cloner"), enabled: !P.locked) { model.cloneRecord(r) }
                SmallButton(L("Supprimer"), enabled: !P.locked) { model.deleteRecord(r) }
                PinButton(model: model, r: r)
                SmallButton(L("Où est-il utilisé ?")) { model.whereUsed(r) }
                Spacer(minLength: 0)
            }
            HStack(spacing: 18) {
                ForEach(r.t == "TES4" ? TES4FLAGS : RFLAGS, id: \.0) { bit, name in
                    FlagBox(label: L(name), on: r.flags & bit != 0, enabled: !P.locked, rev: flagsRev) { on in
                        model.setFlag(r, bit: bit, name: name, on: on)
                        flagsRev += 1
                    }
                }
                Spacer(minLength: 0)
            }
            if r.t == "FLST" { FormListPanel(model: model, r: r) }
            if r.t == "GLOB" { GlobPanel(model: model, r: r) }
            if r.subs.contains(where: { $0.t == "KSIZ" || $0.t == "KWDA" }) { KeywordPanel(model: model, r: r) }
            ForEach(Array(visibleSubs.enumerated()), id: \.element.id) { _, s in
                SubEditor(model: model, r: r, s: s.sub).disabled(P.locked)
            }
        }
    }

    struct SubRef: Identifiable { let id: ObjectIdentifier; let sub: Sub }

    private var visibleSubs: [SubRef] {
        r.subs.filter { s in
            !((r.t == "FLST" && s.t == "LNAM") || (r.t == "GLOB" && (s.t == "FNAM" || s.t == "FLTV")) || s.t == "KSIZ" || s.t == "KWDA")
        }.map { SubRef(id: ObjectIdentifier($0), sub: $0) }
    }
}

struct PinButton: View {
    let model: AppModel
    let r: Record
    var body: some View {
        SmallButton(model.isPinned(r) ? L("Désépingler") : L("Épingler")) { model.togglePin(r) }
    }
}

struct FlagBox: View {
    let label: String
    let on: Bool
    let enabled: Bool
    var rev = 0
    let toggle: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { toggle($0) })) {
            Text(label).socle(Socle.T.body).foregroundStyle(Socle.C.text)
        }
        .toggleStyle(.checkbox)
        .disabled(!enabled)
        .id(rev)
    }
}

struct HexField: View {
    let name: String
    let value: UInt32
    let locked: Bool
    var rev = 0
    let apply: (UInt32) -> Void
    @State private var text: String
    @State private var bad = false

    init(name: String, value: UInt32, locked: Bool, rev: Int = 0, apply: @escaping (UInt32) -> Void) {
        self.name = name; self.value = value; self.locked = locked; self.rev = rev; self.apply = apply
        _text = State(initialValue: hexs(value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name).socle(Socle.T.meta).foregroundStyle(Socle.C.textSubtle)
            TextField("", text: $text)
                .font(Socle.T.mono.font)
                .textFieldStyle(.plain)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(width: 130 * Socle.scale)
                .background(bad ? Socle.C.dangerBg : Socle.C.bgSunken)
                .disabled(locked)
                .onChange(of: text) { _, new in
                    guard new != hexs(value) || bad else { return }
                    if let v = jsParseHex(new) {
                        bad = false
                        if v != value || new != hexs(v) { apply(v) }
                    } else {
                        bad = true
                    }
                }
                .onChange(of: rev) { _, _ in text = hexs(value) }
        }
    }
}

// MARK: Éditeur d'un sous-enregistrement

struct SubEditor: View {
    let model: AppModel
    let r: Record
    let s: Sub
    @State private var text = ""
    @State private var mode = "t"
    @State private var bad = false
    @State private var rev = 0
    @State private var removed = false

    var body: some View {
        let _ = rev
        if !removed {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    MonoLabel(text: s.t)
                    MetaText(text: L("{n} octets", ["n": s.d.count]))
                    MetaText(text: u32Hint(s.d))
                    Spacer(minLength: 0)
                    SmallButton(mode == "t" ? L("Hexadécimal") : L("Texte")) { flip() }
                    if s.d.count == 4 { SmallButton(L("Choisir…")) { pick() } }
                    SmallButton(L("Retirer")) { remove() }
                }
                MonoTextView(text: $text, bad: bad, onEdit: edited)
                    .frame(height: height)
            }
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 8)
            .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
            .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusMd).stroke(Socle.C.border, lineWidth: 1))
            .onAppear {
                if s.m == nil { s.m = isText(s.d) ? "t" : "h" }
                mode = s.m!
                paint()
            }
        }
    }

    private var height: CGFloat {
        let lines = text.filter { $0 == "\n" }.count + 1 + (mode == "h" ? text.count / 90 : 0)
        return CGFloat(min(12, max(1, lines))) * (Socle.T.mono.pointSize * 1.25) + 30
    }

    private func paint() {
        text = mode == "t" ? textOf(s.d) : hexBytes(s.d)
        bad = false
    }

    private func flip() {
        s.m = s.m == "t" ? "h" : "t"
        mode = s.m!
        paint()
    }

    private func edited(_ new: String) {
        if model.locked(r.plugin) { return }
        let nd: Bytes
        if mode == "t" {
            nd = textBytes(new)
        } else {
            guard let h = parseHexBytes(new) else { bad = true; return }
            nd = h
            bad = false
        }
        s.d = nd
        model.setDirty(r.plugin!, L("Modifié {t} dans {label}", ["t": s.t, "label": label(r)]))
        rev += 1
        if s.t == "EDID" { model.refreshRecordItem(r) }
    }

    private func pick() {
        if model.locked(r.plugin) { return }
        model.pickRecord { t in
            guard let t, let x = model.xrefWithMaster(t, r.plugin!) else { return }
            s.d = p32(x)
            model.setDirty(r.plugin!, L("{t} défini sur {label} via le sélecteur", ["t": s.t, "label": label(r)]))
            paint()
            rev += 1
            if s.t == "EDID" { model.refreshRecordItem(r) }
        }
    }

    private func remove() {
        if model.locked(r.plugin) { return }
        r.subs.removeAll { $0 === s }
        model.setDirty(r.plugin!, L("Retiré {t} de {label}", ["t": s.t, "label": label(r)]))
        removed = true
    }
}

// MARK: Lien vers un enregistrement (bouton plat)

struct RecordLink: View {
    let text: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).socle(Socle.T.body).foregroundStyle(Socle.C.accentText).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: FormList

struct FormListPanel: View {
    let model: AppModel
    let r: Record
    private var P: Plugin { r.plugin! }

    var body: some View {
        let ents = model.ws.flEntries(r)
        Panel {
            Text(L("Entrées ({n}). Glissez des enregistrements depuis l'arbre, y compris d'autres plugins ouverts.", ["n": ents.count]))
                .socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            HStack(spacing: Socle.M.space2) {
                SmallButton(L("Importer…"), enabled: !P.locked) { importList() }
                SmallButton(L("Exporter…")) { exportList() }
                SmallButton(L("Trier par nom"), enabled: !P.locked) { setL(model.ws.flSortedByName(r)) }
                SmallButton(L("Trier par FormID"), enabled: !P.locked) { setL(model.ws.flSortedByFormid(r)) }
                SmallButton(L("Retirer les doublons"), enabled: !P.locked) {
                    setL(model.ws.flDeduped(r), L("Doublons retirés de {label}", ["label": label(r)]))
                }
                SmallButton(L("Retirer les entrées cassées"), enabled: !P.locked) {
                    setL(model.ws.flWithoutBroken(r), L("Entrées cassées retirées de {label}", ["label": label(r)]))
                }
                Spacer(minLength: 0)
            }
            if ents.isEmpty {
                Text(L("Vide. Déposez des enregistrements ici.")).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted)
            }
            ForEach(Array(ents.enumerated()), id: \.offset) { i, s in
                row(i, s, ents)
            }
        }
        .recordDrop { if !model.locked(P), !model.dragRecs.isEmpty { model.addEntries(r, model.dragRecs) } }
    }

    @ViewBuilder
    private func row(_ i: Int, _ s: Sub, _ ents: [Sub]) -> some View {
        let v = lnam(s)
        let t = model.ws.resolve(P, v)
        HStack(spacing: 8) {
            Text("\(i + 1).").socle(Socle.T.mono).foregroundStyle(Socle.C.textSubtle)
                .frame(width: 36 * Socle.scale, alignment: .trailing)
            MonoLabel(text: v == nil ? L("invalide") : hexs(v!))
            if let t {
                RecordLink(text: "\(t.t)  \(edid(t))" + (t.plugin !== P ? "  (\(t.plugin!.name))" : "")) { model.showRecord(t) }
            } else {
                Text(v == nil ? L("L'entrée ne fait pas 4 octets")
                     : Int(v! >> 24) < P.masters.count ? L("de {v} (non ouvert)", ["v": P.masters[Int(v! >> 24)]])
                     : L("introuvable dans ce fichier"))
                    .socle(Socle.T.body).foregroundStyle(Socle.C.text).frame(maxWidth: .infinity, alignment: .leading)
            }
            SmallButton(L("Monter"), enabled: i > 0 && !P.locked) { move(s, ents[i - 1]) }
            SmallButton(L("Descendre"), enabled: i < ents.count - 1 && !P.locked) { move(s, ents[i + 1]) }
            SmallButton(L("Retirer"), enabled: !P.locked) {
                r.subs.removeAll { $0 === s }
                model.setDirty(P)
                model.showRecord(r)
            }
        }
    }

    private func setL(_ lst: [Sub], _ msg: String? = nil) {
        if model.locked(P) { return }
        let k = model.ws.flSet(r, lst)
        model.setDirty(P, msg ?? L("Entrées réordonnées dans {label}", ["label": label(r)]))
        model.showRecord(r)
        if k > 0 { model.flash(L("{k} entrée(s) retirée(s)", ["k": k])) }
    }

    private func move(_ a: Sub, _ b: Sub) {
        guard let ia = r.subs.firstIndex(where: { $0 === a }), let ib = r.subs.firstIndex(where: { $0 === b }) else { return }
        r.subs.swapAt(ia, ib)
        model.setDirty(P)
        model.showRecord(r)
    }

    private func importList() {
        if model.locked(P) { return }
        model.textDialog(title: L("Importer dans {label}", ["label": label(r)]), value: "", ok: L("Importer"),
                         hint: L("Un EditorID ou un FormID hexadécimal à 8 chiffres par ligne. Les FormID suivent la numérotation de ce plugin. Les lignes commençant par # sont ignorées.")) { text in
            guard let text else { return }
            let res = model.ws.importList(r, text)
            if res.changed {
                model.setDirty(P, L("Ajouté {n} entrée(s) à {label}", ["n": res.n, "label": label(r)]))
            } else if res.raw > 0 {
                model.setDirty(P, L("Importé {raw} entrée(s) brute(s) dans {label}", ["raw": res.raw, "label": label(r)]))
            }
            if !res.warn.isEmpty { model.alert(res.warn.joined(separator: "\n\n")) }
            model.showRecord(r)
            model.flash(L("{v} entrée(s) ajoutée(s)", ["v": res.n + res.raw]))
            if !res.bad.isEmpty {
                model.alert(L("Introuvables ({n}) :\n", ["n": res.bad.count]) + res.bad.prefix(30).joined(separator: "\n") + (res.bad.count > 30 ? "\n…" : ""))
            }
        }
    }

    private func exportList() {
        model.textDialog(title: L("Exporter {label}", ["label": label(r)]), value: model.ws.exportList(r), ok: L("Fermer"),
                         hint: L("EditorID quand il est connu, sinon FormID hexadécimal."), readOnly: true)
    }
}

// MARK: Variable globale

struct GlobPanel: View {
    let model: AppModel
    let r: Record
    @State private var type: String
    @State private var value: String

    private var P: Plugin { r.plugin! }

    init(model: AppModel, r: Record) {
        self.model = model; self.r = r
        _type = State(initialValue: Workspace.globType(r))
        let v = Workspace.globValue(r)
        _value = State(initialValue: GlobPanel.format(v))
    }

    /// repr(v) de Python pour un flottant 32 bits lu en double ; entier affiché sans « .0 ».
    static func format(_ f: Float?) -> String {
        guard let f else { return "" }
        let v = Double(f)
        if v.isNaN { return "nan" }
        if v.isInfinite { return v < 0 ? "-inf" : "inf" }
        if v != v.rounded(.towardZero) { return pyRepr(v) }
        if abs(v) < 1e15 { return String(Int64(v)) }
        return pyRepr(v)
    }

    var body: some View {
        Panel {
            Text(L("Variable globale")).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            HStack(spacing: 8) {
                Text(L("Type")).socle(Socle.T.body).foregroundStyle(Socle.C.text)
                Picker("", selection: $type) {
                    Text("Short").tag("s"); Text("Long").tag("l"); Text("Float").tag("f")
                }
                .labelsHidden().frame(width: 100).disabled(P.locked)
                .onChange(of: type) { _, new in
                    if model.locked(P) { return }
                    Workspace.setGlobType(r, new)
                    model.setDirty(P, L("Type modifié pour {label}", ["label": label(r)]))
                }
                Text(L("Valeur")).socle(Socle.T.body).foregroundStyle(Socle.C.text)
                TextField("", text: $value)
                    .textFieldStyle(.plain).padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(width: 140 * Socle.scale).background(Socle.C.bgSunken).disabled(P.locked)
                    .onChange(of: value) { _, new in
                        if model.locked(P) { return }
                        guard let f = jsParseFloat(new) else { return }
                        Workspace.setGlobValue(r, f)
                        model.setDirty(P, L("Valeur modifiée pour {label}", ["label": label(r)]))
                    }
                Spacer(minLength: 0)
            }
            MetaText(text: L("Toutes les globales stockent leur valeur en flottant, quel que soit leur type."))
        }
    }
}

/// repr() de Python pour un float : le plus court texte qui se relit à l'identique.
func pyRepr(_ v: Double) -> String {
    var s = "\(v)"  // Swift donne aussi le plus court texte aller-retour ; formes « 1e-05 » alignées sur Python
    if s.contains("e") {
        // Swift : 1e-05 ; Python : 1e-05 (même forme) ; exposant sur au moins 2 chiffres
        let parts = s.split(separator: "e", omittingEmptySubsequences: false)
        if parts.count == 2 {
            var exp = String(parts[1])
            let sign = exp.hasPrefix("-") ? "-" : "+"
            exp = exp.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            if exp.count < 2 { exp = "0" + exp }
            var mant = String(parts[0])
            if mant.hasSuffix(".0") { mant.removeLast(2) }
            s = mant + "e" + sign + exp
        }
    }
    return s
}

// MARK: Mots-clés

struct KeywordPanel: View {
    let model: AppModel
    let r: Record
    private var P: Plugin { r.plugin! }

    var body: some View {
        let ids = Workspace.keywords(r)
        Panel {
            Text(L("Mots-clés ({n})", ["n": ids.count])).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            ForEach(Array(ids.enumerated()), id: \.offset) { i, v in
                let t = model.ws.resolve(P, v)
                HStack(spacing: 8) {
                    MonoLabel(text: hexs(v))
                    if let t {
                        RecordLink(text: edid(t).isEmpty ? t.t : edid(t)) { model.showRecord(t) }
                    } else {
                        Text(Int(v >> 24) < P.masters.count ? L("de {master}", ["master": P.masters[Int(v >> 24)]]) : L("introuvable"))
                            .socle(Socle.T.body).foregroundStyle(Socle.C.text).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    SmallButton(L("Retirer"), enabled: !P.locked) {
                        var lst = Workspace.keywords(r)
                        lst.remove(at: i)
                        setv(lst, L("Mot-clé retiré de {label}", ["label": label(r)]))
                    }
                }
            }
            SmallButton(L("Ajouter un mot-clé…"), enabled: !P.locked) { add() }
        }
        .recordDrop { drop() }
    }

    private func setv(_ lst: [UInt32], _ msg: String? = nil) {
        if model.locked(P) { return }
        Workspace.setKeywords(r, lst)
        model.setDirty(P, msg ?? L("Mots-clés modifiés sur {label}", ["label": label(r)]))
        model.showRecord(r)
    }

    private func drop() {
        if model.locked(P) || model.dragRecs.isEmpty { return }
        var lst = Workspace.keywords(r)
        var n = 0
        for src in model.dragRecs {
            guard case .id(let id) = model.ws.xref(src, P) else { continue }
            if !lst.contains(id) { lst.append(id); n += 1 }
        }
        if n > 0 { setv(lst, L("Ajouté {n} mot(s)-clé(s) à {label}", ["n": n, "label": label(r)])) }
    }

    private func add() {
        model.pickRecord(hint: L("Choisissez un enregistrement KYWD.")) { t in
            guard let t, let x = model.xrefWithMaster(t, P) else { return }
            var lst = Workspace.keywords(r)
            if lst.contains(x) { model.flash(L("Ce mot-clé est déjà présent")); return }
            lst.append(x)
            setv(lst, L("Mot-clé ajouté à {label}", ["label": label(r)]))
        }
    }
}
