// État et logique de l'appli (port de MainWindow, hors dessin) : plugins ouverts, enregistrement courant, session,
// espaces de travail, annulation, presse-papiers, outils.

import AppKit
import LensCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

let APP = "pLUGINSLENS"
let SPECIES = ["esp", "esm", "esl"]

enum Detail {
    case welcome
    case message(String)
    case record(Record)
}

enum StatusTone { case none, warning, danger }

/// Réponses automatiques aux questions (essais en arrière-plan) : PLUGINSLENS_AUTO=yes|no
let autoAnswer: Bool? = {
    switch ProcessInfo.processInfo.environment["PLUGINSLENS_AUTO"] {
    case "yes": return true
    case "no": return false
    default: return nil
    }
}()

@MainActor @Observable
final class AppModel {
    let ws: Workspace
    let settings: AppSettings
    let session: SessionStore

    var active: Plugin?
    var cur: Record?
    var detail: Detail = .welcome
    var dragRecs: [Record] = []
    var clip: [ClipItem] = []
    var recent: [String] = []
    var pins: Set<String>
    var sortMode: SortMode = .file
    var typeFilter: [String] = []
    var query = ""
    var rememberPlugins: Bool
    var treeVisible: Bool
    var treeWidth: Int

    var flashText: String?
    var loadingName: String?
    var failure: String?
    // Compteurs d'invalidation observés par les vues
    var detailRev = 0
    var statusRev = 0
    var langTick = 0
    var wsRev = 0

    weak var tree: TreeController?
    weak var window: NSWindow?
    var focusRev = 0

    private var commitTimers: [ObjectIdentifier: Timer] = [:]
    private var persistTimers: [ObjectIdentifier: Timer] = [:]
    private var loadQueue: [() -> Void] = []
    private var loading = false

    init() {
        let env = ProcessInfo.processInfo.environment
        settings = AppSettings(suite: env["PLUGINSLENS_SUITE"])
        session = env["PLUGINSLENS_SESSION_DIR"].map { SessionStore(dir: URL(fileURLWithPath: $0)) } ?? SessionStore()
        pins = settings.pins
        rememberPlugins = settings.string("remember", "1") == "1"
        treeVisible = settings.string("notree", "0") != "1"
        treeWidth = settings.int("tree_w", 0)
        ws = Workspace()
        ws.confirm = { [unowned self] in self.ask($0) }
        ws.alert = { [unowned self] in self.alert($0) }
    }

    // MARK: Messages

    func ask(_ msg: String) -> Bool {
        if let a = autoAnswer { return a }
        let al = NSAlert()
        al.messageText = APP
        al.informativeText = msg
        al.addButton(withTitle: L("Oui"))
        al.addButton(withTitle: L("Non"))
        return al.runModal() == .alertFirstButtonReturn
    }

    func alert(_ msg: String) {
        if autoAnswer != nil {
            FileHandle.standardError.write(Data("ALERTE: \(msg)\n".utf8))
            return
        }
        let al = NSAlert()
        al.alertStyle = .warning
        al.messageText = APP
        al.informativeText = msg
        al.addButton(withTitle: L("OK"))
        al.runModal()
    }

    func flash(_ msg: String) {
        flashText = msg
        statusRev += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.8) { [weak self] in
            guard let self, self.flashText == msg else { return }
            self.flashText = nil
            self.statusRev += 1
        }
    }

    func locked(_ P: Plugin?) -> Bool {
        if let P, P.locked {
            flash(L("{name} est verrouillé : déverrouillez-le pour le modifier.", ["name": P.name]))
            return true
        }
        return false
    }

    // MARK: Statut

    var hasPlugins: Bool { !ws.plugins.isEmpty }
    var anyDirty: Bool { ws.plugins.contains { $0.dirty } }

    var statusText: String {
        _ = statusRev
        if let f = flashText { return f }
        if let f = failure { return f }
        if let n = loadingName { return L("Analyse de {name}…", ["name": n]) }
        let P = active, n = ws.plugins.count
        if n == 0 { return L("Aucun fichier chargé") }
        if let P {
            return L("{name} · {v} enregistrements · {n} maîtres", ["name": P.name, "v": fmtInt(P.all.count - 1), "n": P.masters.count])
                + (P.dirty ? L(" · modifié") : "") + (n > 1 ? L(" · {n} plugins ouverts", ["n": n]) : "")
        }
        return L("{n} plugins ouverts", ["n": n])
    }

    var statusTone: StatusTone {
        _ = statusRev
        if flashText == nil, failure != nil { return .danger }
        return anyDirty ? .warning : .none
    }

    func status() { statusRev += 1 }

    var canUndo: Bool { if let P = active { return !P.undo.isEmpty || P.pend }; return false }
    var canRedo: Bool { if let P = active { return !P.redo.isEmpty }; return false }

    // MARK: Modifications

    func setDirty(_ P: Plugin, _ msg: String? = nil) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        Workspace.markDirty(P, msg, when: f.string(from: Date()))
        let id = ObjectIdentifier(P)
        commitTimers[id]?.invalidate()
        commitTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: false) { [weak self, weak P] _ in
            MainActor.assumeIsolated {
                guard let P else { return }
                Workspace.commitBase(P)
                self?.status()
            }
        }
        mark(P)
        persist(P)
        status()
    }

    func mark(_ P: Plugin) { tree?.refreshPlugin(P) }

    func xrefWithMaster(_ t: Record, _ P: Plugin) -> UInt32? {
        var x = ws.xref(t, P)
        if case .need(let need) = x {
            if !ask(L("Ajouter {need} comme maître de {name} ?", ["need": need, "name": P.name])) { return nil }
            Workspace.addMaster(P, need)
            x = ws.xref(t, P)
        }
        if case .id(let i) = x { return i }
        return nil
    }

    func addEntries(_ fl: Record, _ recs: [Record]) {
        let P = fl.plugin!
        if locked(P) { return }
        let res = ws.addEntries(fl, recs)
        if res.changed {
            setDirty(P, L("Ajouté {n} entrée(s) à {label}", ["n": res.n, "label": label(fl)]))
            tree?.refreshIds(P)
            if let c = cur, c.plugin === P { showRecord(c) }
        }
        if !res.warn.isEmpty { alert(res.warn.joined(separator: "\n\n")) }
        flash(L("{n} enregistrement(s) ajouté(s) à {label}", ["n": res.n, "label": label(fl)])
            + (res.dup > 0 ? L(" ({dup} déjà dans la liste)", ["dup": res.dup]) : ""))
    }

    // MARK: Récents et épingles

    func touchRecent(_ r: Record) {
        let k = "\(r.plugin!.name)|\(hexs(r.id))"
        recent = [k] + recent.filter { $0 != k }
        if recent.count > 15 { recent = Array(recent.prefix(15)) }
    }

    func recordFor(key k: String) -> Record? {
        guard let bar = k.firstIndex(of: "|") else { return nil }
        let name = String(k[..<bar]), hid = String(k[k.index(after: bar)...])
        guard let P = ws.plugins.first(where: { $0.name == name }), let id = UInt32(hid, radix: 16) else { return nil }
        return byId(P, id)
    }

    var recentRecords: [Record] { recent.prefix(15).compactMap(recordFor) }
    var pinnedRecords: [Record] { pins.sorted().compactMap(recordFor) }

    func clearRecent() {
        recent = []
        tree?.reload()
    }

    func pinKey(_ r: Record) -> String { "\(r.plugin!.name)|\(hexs(r.id))" }
    func isPinned(_ r: Record) -> Bool { pins.contains(pinKey(r)) }

    func togglePin(_ r: Record) {
        let k = pinKey(r)
        if pins.contains(k) { pins.remove(k) } else { pins.insert(k) }
        settings.pins = pins
        if query.trimmingCharacters(in: .whitespaces).isEmpty { tree?.reload() }
    }

    // MARK: Détail

    func showRecord(_ r: Record, select: Bool = true) {
        cur = r
        active = r.plugin
        touchRecent(r)
        status()
        if select { tree?.select(r) }
        detail = .record(r)
        detailRev += 1
    }

    func emptyDetail(_ text: String?) {
        detail = text.map { .message($0) } ?? .welcome
        detailRev += 1
    }

    func refreshRecordItem(_ r: Record) { tree?.refreshRecord(r) }

    func addSub(_ r: Record) {
        if locked(r.plugin) { return }
        guard let raw = promptText(L("Type de sous-enregistrement (quatre caractères, ex. FULL) :")) else { return }
        let t = pyStrip(raw)
        if t.unicodeScalars.count != 4 { return }
        r.subs.append(Sub(t, []))
        setDirty(r.plugin!, L("Ajouté {t} à {label}", ["t": t, "label": label(r)]))
        showRecord(r)
    }

    func cloneRecord(_ r: Record) {
        if locked(r.plugin) { return }
        guard let c = ws.cloneRecord(r) else { return }
        setDirty(r.plugin!, L("Cloné {label} en {hexs}", ["label": label(r), "hexs": hexs(c.id)]))
        tree?.insertAfter(r, c)
        showRecord(c)
        flash(L("Cloné en {hexs}", ["hexs": hexs(c.id)]))
    }

    func deleteRecord(_ r: Record) {
        let P = r.plugin!
        if locked(P) || r === P.header { return }
        if !ask(L("Supprimer cet enregistrement ? Les enregistrements qui y font référence seront cassés.")) { return }
        tree?.remove(r)
        Workspace.deleteRecord(r)
        setDirty(P, L("Supprimé {t} {label}", ["t": r.t, "label": label(r)]))
        cur = nil
        emptyDetail(L("Enregistrement supprimé."))
    }

    func deleteCurrent() {
        if let c = cur, c !== c.plugin!.header { deleteRecord(c) }
    }

    func setFlag(_ r: Record, bit: UInt32, name: String, on: Bool) {
        if locked(r.plugin) { return }
        r.flags = on ? (r.flags | bit) : (r.flags & ~bit)
        setDirty(r.plugin!, L("{v} « {name} » sur {label}", ["v": on ? L("Activé") : L("Désactivé"), "name": L(name), "label": label(r)]))
    }

    // MARK: Fichiers

    var lastDir: String { settings.string("lastdir") }

    func openDialog() {
        let p = NSOpenPanel()
        p.title = L("Ouvrir des plugins")
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = SPECIES.compactMap { UTType(filenameExtension: $0) }
        if !lastDir.isEmpty { p.directoryURL = URL(fileURLWithPath: lastDir) }
        guard p.runModal() == .OK, let first = p.urls.first else { return }
        settings.set("lastdir", first.deletingLastPathComponent().path)
        loadFiles(p.urls.map(\.path))
    }

    func loadFiles(_ paths: [String]) {
        for p in paths where SPECIES.contains((p as NSString).pathExtension.lowercased()) {
            do {
                let d = try Data(contentsOf: URL(fileURLWithPath: p))
                load(name: (p as NSString).lastPathComponent, data: d)
            } catch {
                alert(L("Impossible de lire {basename} : {strerror}",
                        ["basename": (p as NSString).lastPathComponent, "strerror": (error as NSError).localizedFailureReason ?? error.localizedDescription]))
            }
        }
    }

    /// Lecture en arrière-plan (un seul chargement à la fois) ; `done` reçoit le plugin ouvert.
    func load(name: String, data: Data, dirty: Bool = false, t: Double? = nil, persist: Bool = true, done: ((Plugin?) -> Void)? = nil) {
        if ws.find(name) != nil {
            flash(L("{name} est déjà ouvert", ["name": name]))
            done?(nil)
            return
        }
        let job = { [unowned self] in
            self.loading = true
            self.loadingName = name
            self.status()
            let stamp = t ?? Date().timeIntervalSince1970
            DispatchQueue.global(qos: .userInitiated).async {
                let result: Result<Plugin, Error> = Result { try loadPlugin(name: name, data: Array(data), dirty: dirty, t: stamp) }
                let box = UncheckedBox(result)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self.finishLoad(name: name, box.value, persist: persist, done: done)
                } }
            }
        }
        if loading { loadQueue.append(job) } else { job() }
    }

    private func finishLoad(name: String, _ result: Result<Plugin, Error>, persist: Bool, done: ((Plugin?) -> Void)?) {
        loading = false
        loadingName = nil
        var opened: Plugin?
        switch result {
        case .failure(let e):
            failure = L("Impossible de lire {name} : {e}", ["name": name, "e": "\(e)"])
            status()
        case .success(let P):
            failure = nil
            ws.plugins.append(P)
            active = P
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                tree?.addPlugin(P)
                showRecord(P.header)
            } else {
                tree?.reload()
                showRecord(P.header)
            }
            status()
            if persist { self.persist(P) }
            opened = P
        }
        done?(opened)
        if !loadQueue.isEmpty { loadQueue.removeFirst()() }
    }

    func saveCopy() {
        guard let P = active else { return }
        let sp = NSSavePanel()
        sp.title = L("Enregistrer une copie")
        sp.nameFieldStringValue = P.name
        sp.allowedContentTypes = SPECIES.compactMap { UTType(filenameExtension: $0) }
        if !lastDir.isEmpty { sp.directoryURL = URL(fileURLWithPath: lastDir) }
        guard sp.runModal() == .OK, let url = sp.url else { return }
        saveCopy(P, to: url)
    }

    func saveCopy(_ P: Plugin, to url: URL) {
        Workspace.fixHedr(P)
        do {
            try Data(serialize(P)).write(to: url)
        } catch {
            alert(L("Impossible d'enregistrer : {strerror}. Vérifiez les droits d'écriture du dossier.",
                    ["strerror": (error as NSError).localizedFailureReason ?? error.localizedDescription]))
            return
        }
        settings.set("lastdir", url.deletingLastPathComponent().path)
        P.dirty = false
        mark(P)
        status()
        persist(P)
        flash(L("Copie de {name} enregistrée", ["name": P.name]))
    }

    @discardableResult
    func closePlugin(_ P: Plugin, ask askFirst: Bool = true) -> Bool {
        if askFirst && P.dirty {
            let others = ws.plugins.filter { $0 !== P && $0.dirty }.count
            var msg = L("{name} a des modifications non enregistrées. Le fermer quand même ?", ["name": P.name])
            if others > 0 { msg += L(" ({others} autre(s) plugin(s) ont aussi des modifications non enregistrées.)", ["others": others]) }
            if !ask(msg) { return false }
        }
        let id = ObjectIdentifier(P)
        commitTimers[id]?.invalidate(); commitTimers[id] = nil
        persistTimers[id]?.invalidate(); persistTimers[id] = nil
        session.remove(P.name)
        ws.plugins.removeAll { $0 === P }
        if active === P { active = ws.plugins.first }
        recent = recent.filter { !$0.hasPrefix(P.name + "|") }
        if let c = cur, c.plugin === P {
            cur = nil
            emptyDetail(L("Plugin fermé."))
        }
        tree?.reload()
        tree?.forget(P)
        status()
        return true
    }

    func toggleLock(_ P: Plugin) {
        P.locked.toggle()
        mark(P)
        flash(P.locked ? L("{name} verrouillé", ["name": P.name]) : L("{name} déverrouillé", ["name": P.name]))
        if let c = cur, c.plugin === P { showRecord(c) }
    }

    func toggleTree() {
        treeVisible.toggle()
        settings.set("notree", treeVisible ? "0" : "1")
    }

    // MARK: Session

    func toggleRemember() {
        rememberPlugins.toggle()
        settings.set("remember", rememberPlugins ? "1" : "0")
        if rememberPlugins {
            for P in ws.plugins { persist(P) }
        } else {
            for e in session.index() { session.remove(e.name) }
        }
    }

    func persist(_ P: Plugin) {
        guard rememberPlugins else { return }
        let id = ObjectIdentifier(P)
        persistTimers[id]?.invalidate()
        persistTimers[id] = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self, weak P] _ in
            MainActor.assumeIsolated {
                guard let self, let P, self.ws.plugins.contains(where: { $0 === P }) else { return }
                self.sessionWrite(P)
            }
        }
    }

    func sessionWrite(_ P: Plugin) {
        guard rememberPlugins else { return }
        session.write(P)
    }

    func flushSession() {
        for t in commitTimers.values { t.invalidate() }
        for t in persistTimers.values { t.invalidate() }
        for P in ws.plugins { sessionWrite(P) }
    }

    func sessionLoad(_ name: String, _ meta: SessionEntry, done: ((Plugin?) -> Void)? = nil) {
        guard let d = session.read(name) else { done?(nil); return }
        load(name: name, data: d, dirty: meta.dirty, t: meta.t == 0 ? nil : meta.t, persist: false, done: done)
    }

    func restoreSession() {
        guard rememberPlugins else { return }
        let rows = session.index().sorted { $0.entry.t < $1.entry.t }
        var pending = rows.count, restored = 0
        if pending == 0 { return }
        for r in rows {
            sessionLoad(r.name, r.entry) { [weak self] P in
                if P != nil { restored += 1 }
                pending -= 1
                if pending == 0, restored > 0 {
                    self?.flash(L("{n} plugin(s) restauré(s) depuis votre dernière session", ["n": restored]))
                }
            }
        }
    }

    // MARK: Espaces de travail

    var workspaces: [(name: String, plugins: [String])] { _ = wsRev; return settings.workspaces }

    func saveWorkspace() {
        if ws.plugins.isEmpty { flash(L("Ouvrez d'abord des plugins")); return }
        guard let raw = promptText(L("Nom de l'espace de travail (les plugins ouverts) :")) else { return }
        let name = pyStrip(raw)
        if name.isEmpty { return }
        var all = settings.workspaces
        if let i = all.firstIndex(where: { $0.name == name }) {
            all[i] = (name, ws.plugins.map(\.name))
        } else {
            all.append((name, ws.plugins.map(\.name)))
        }
        settings.workspaces = all
        wsRev += 1
        flash(L("Espace de travail « {name} » enregistré", ["name": name]))
    }

    func loadWorkspace(_ name: String) {
        guard let w = settings.workspaces.first(where: { $0.name == name }) else { return }
        for P in ws.plugins where !w.plugins.contains(P.name) { closePlugin(P) }
        let idx = session.index()
        var missing: [String] = []
        var pending = 0
        for nm in w.plugins {
            if ws.find(nm) != nil { continue }
            guard let e = idx.first(where: { $0.name == nm }), session.read(nm) != nil else { missing.append(nm); continue }
            pending += 1
            sessionLoad(nm, e.entry) { _ in pending -= 1 }
        }
        if !missing.isEmpty {
            alert(L("Ces plugins font partie de « {name} » mais ne sont pas mémorisés : rouvrez-les manuellement.\n", ["name": name])
                + missing.joined(separator: "\n"))
        }
        flash(L("Espace de travail « {name} » chargé", ["name": name]))
    }

    // MARK: Édition

    func undo(_ back: Bool) {
        guard let P = active, !locked(P) else { return }
        let id = ObjectIdentifier(P)
        commitTimers[id]?.invalidate(); commitTimers[id] = nil
        let key = (cur != nil && cur!.plugin === P) ? (cur!.id, cur!.t) : nil
        if !Workspace.undoRedo(P, back: back) { return }
        tree?.reload()
        let r = P.all.first { x in key != nil && x.id == key!.0 && x.t == key!.1 }
        if let r {
            showRecord(r)
        } else if key != nil {
            cur = nil
            emptyDetail(L("Aucune sélection."))
        }
        mark(P)
        persist(P)
        status()
        flash(back ? L("Dernière modification annulée") : L("Modification rétablie"))
    }

    func copyRecords() {
        let sel = tree?.selectedRecords() ?? []
        let recs = !sel.isEmpty ? sel : (cur.map { [$0] } ?? [])
        let (items, skipped) = ws.copyRecords(recs)
        if items.isEmpty {
            flash(!recs.isEmpty ? L("Seuls les enregistrements de premier niveau peuvent être copiés, pas le contenu des cellules")
                : L("Sélectionnez d'abord des enregistrements"))
            return
        }
        clip = items
        flash(L("{n} enregistrement(s) copié(s)", ["n": items.count]) + (skipped > 0 ? L(" ({skipped} ignoré(s))", ["skipped": skipped]) : ""))
    }

    func pasteRecords() {
        guard let P = active, !locked(P) else { return }
        if clip.isEmpty { flash(L("Rien n'a encore été copié")); return }
        let res = ws.pasteRecords(P, clip)
        if res.changed {
            setDirty(P, L("Collé {n} enregistrement(s)", ["n": res.n]))
            tree?.reload()
            tree?.expand(P)
            flash(L("{n} enregistrement(s) collé(s) dans {name}", ["n": res.n, "name": P.name]))
        }
        if !res.warn.isEmpty { alert(res.warn.joined(separator: "\n\n")) }
    }

    func newFormlist() {
        guard let P = active, !locked(P) else { return }
        guard let raw = promptText(L("EditorID de la nouvelle FormList dans {name} :", ["name": P.name])) else { return }
        let name = pyStrip(raw)
        if name.isEmpty { return }
        if P.all.contains(where: { scalarEq(edid($0), name) }) && !ask(L("Un enregistrement porte déjà cet EditorID. Créer quand même ?")) { return }
        guard let r = ws.newFormlist(P, name) else { return }
        setDirty(P)
        query = ""
        tree?.reload()
        tree?.expand(P)
        tree?.expand(group: r.parent)
        showRecord(r)
    }

    // MARK: Saisie de texte

    func promptText(_ message: String, value: String = "") -> String? {
        if let s = ProcessInfo.processInfo.environment["PLUGINSLENS_INPUT"], autoAnswer != nil { return s }
        let al = NSAlert()
        al.messageText = APP
        al.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = value
        al.accessoryView = field
        al.addButton(withTitle: L("OK"))
        al.addButton(withTitle: L("Annuler"))
        al.window.initialFirstResponder = field
        return al.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    // MARK: Langue

    func retranslate() {
        langTick += 1
        tree?.reload()
        detailRev += 1
        status()
    }
}

final class UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ v: T) { value = v }
}
