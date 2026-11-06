// Point d'entrée : fenêtre AppKit unique (1280 × 800, redimensionnable) qui héberge l'interface SwiftUI.

import AppKit
import LensCore
import SwiftUI

func windowTitle() -> String { L("{APP} · éditeur ESP/ESM", ["APP": APP]) }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let model = AppModel()
    var treeController: TreeController!
    private var quitConfirmed = false
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Socle.apply()
        // « p » dans le jaune du logo
        Socle.brand(APP, color: Color(red: 0xf5 / 255, green: 0xb9 / 255, blue: 0x21 / 255))
        treeController = TreeController(model: model)
        buildMenu()

        let host = NSHostingView(rootView: ContentView(model: model))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: WINDOW_SIZE),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = windowTitle()
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.backgroundColor = NSColor(Socle.C.bg)
        window.contentMinSize = NSSize(width: 900, height: 520)
        window.setContentSize(WINDOW_SIZE)
        window.socleCenter()
        model.window = window
        let env = ProcessInfo.processInfo.environment
        // Essais en arrière-plan : PLUGINSLENS_QUIET=1 lance l'appli sans prendre le focus
        if env["PLUGINSLENS_QUIET"] != nil {
            window.orderBack(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
        model.tree?.reload()
        model.restoreSession()

        if env["PLUGINSLENS_NOUPDATE"] == nil {
            UpdateEngine.shared.configure(repo: "pLUGINSLENS", lang: { I18n.lang })
            UpdateEngine.shared.canInstall = { [weak self] in !(self?.model.anyDirty ?? false) }
            UpdateEngine.shared.start()  // nouvelle version ? (au plus une fois par jour)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { UpdateEngine.shared.installAppMenuItem() }
        }

        // Raccourcis hors menu : « / » cherche, ⌘Y rétablit
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, e.window === self.window else { return e }
            let typing = self.window.firstResponder is NSText
            if e.charactersIgnoringModifiers == "/" && e.modifierFlags.intersection([.command, .control, .option]).isEmpty && !typing {
                self.model.focusRev += 1
                return nil
            }
            if e.charactersIgnoringModifiers == "y" && e.modifierFlags.contains(.command) {
                self.redo(nil)
                return nil
            }
            return e
        }

        // Essais : PLUGINSLENS_OPEN="chemin1|chemin2" ouvre ces plugins (lecture seule) au lancement.
        if let paths = env["PLUGINSLENS_OPEN"] {
            model.loadFiles(paths.split(separator: "|").map(String.init))
        }
        if let script = env["PLUGINSLENS_SCRIPT"] { TestScript.run(script, model: model) }
        // Vérification visuelle (développement) : PLUGINSLENS_SNAPSHOT=<fichier.png> enregistre la fenêtre après PLUGINSLENS_DELAY s (2 par défaut) et quitte.
        if let out = env["PLUGINSLENS_SNAPSHOT"] {
            let delay = Double(env["PLUGINSLENS_DELAY"] ?? "") ?? 2
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
                let view = window.contentView!
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
                }
                quitConfirmed = true
                NSApp.terminate(nil)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: Fermeture

    /// Plugins modifiés et session non mémorisée : confirmation ; sinon la session est écrite.
    private func confirmQuit() -> Bool {
        if quitConfirmed { return true }
        let dirty = model.ws.plugins.filter(\.dirty).map(\.name)
        if !dirty.isEmpty && !model.rememberPlugins {
            if !model.ask(L("Des plugins ont des modifications non enregistrées :\n") + dirty.joined(separator: "\n") + L("\n\nQuitter quand même ?")) {
                return false
            }
        }
        model.flushSession()
        quitConfirmed = true
        return true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmQuit() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        confirmQuit() ? .terminateNow : .terminateCancel
    }

    // MARK: Actions des menus

    @objc func showAbout(_ sender: Any?) { About.show() }
    @objc func openPlugins(_ s: Any?) { model.openDialog() }
    @objc func saveCopy(_ s: Any?) { model.saveCopy() }
    @objc func closeActive(_ s: Any?) { if let P = model.active { model.closePlugin(P) } }
    @objc func lockActive(_ s: Any?) { if let P = model.active { model.toggleLock(P) } }
    @objc func toggleRemember(_ s: Any?) { model.toggleRemember() }
    @objc func copyRecs(_ s: Any?) { model.copyRecords() }
    @objc func pasteRecs(_ s: Any?) { model.pasteRecords() }
    @objc func newFormlist(_ s: Any?) { model.newFormlist() }
    @objc func duplicates(_ s: Any?) { model.findDuplicates() }
    @objc func comparePlugins(_ s: Any?) { model.comparePlugins() }
    @objc func compareRecords(_ s: Any?) { model.compareRecords() }
    @objc func stats(_ s: Any?) { model.showStats() }
    @objc func log(_ s: Any?) { model.showLog() }
    @objc func toggleTree(_ s: Any?) { model.toggleTree() }
    @objc func saveWorkspace(_ s: Any?) { model.saveWorkspace() }
    @objc func loadWorkspace(_ s: NSMenuItem) { model.loadWorkspace(s.representedObject as! String) }

    /// ⌘Z / ⇧⌘Z : dans un champ de texte, annule la saisie ; sinon annule la dernière modification du plugin.
    @objc func undo(_ s: Any?) {
        if let t = window.firstResponder as? NSText { t.undoManager?.undo(); return }
        model.undo(true)
    }

    @objc func redo(_ s: Any?) {
        if let t = window.firstResponder as? NSText { t.undoManager?.redo(); return }
        model.undo(false)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let has = model.hasPlugins
        switch item.action {
        case #selector(saveCopy), #selector(newFormlist), #selector(copyRecs), #selector(pasteRecs), #selector(duplicates),
             #selector(stats), #selector(compareRecords), #selector(closeActive), #selector(lockActive), #selector(log):
            return has
        case #selector(comparePlugins): return model.ws.plugins.count >= 2
        case #selector(undo): return window.firstResponder is NSText || model.canUndo
        case #selector(redo): return window.firstResponder is NSText || model.canRedo
        case #selector(toggleRemember): item.state = model.rememberPlugins ? .on : .off; return true
        case #selector(toggleTree): item.state = model.treeVisible ? .on : .off; return true
        default: return true
        }
    }

    // MARK: Langue

    @objc func chooseLanguage(_ sender: NSMenuItem) {
        let choice = LangChoice.normalize(sender.representedObject as? String)
        model.settings.set("language", choice)
        I18n.setLang(LangChoice.resolve(choice))
        window.title = windowTitle()
        model.retranslate()
        buildMenu()
        UpdateEngine.shared.insertMenuItem()
    }

    // MARK: Menus

    private func buildMenu() {
        let main = NSMenu()
        func item(_ menu: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            if !key.isEmpty { i.keyEquivalentModifierMask = mods }
            if sel != nil, let sel, ![#selector(NSApplication.hide(_:)), #selector(NSApplication.hideOtherApplications(_:)),
                                     #selector(NSApplication.unhideAllApplications(_:)), #selector(NSApplication.terminate(_:)),
                                     #selector(NSWindow.performMiniaturize(_:))].contains(sel) { i.target = self }
            return i
        }

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        // Pas de couleur dans les menus : le nom de l'appli y est en texte normal
        _ = item(appMenu, L("À propos de pLUGINSLENS"), #selector(showAbout))
        appMenu.addItem(.separator())
        _ = item(appMenu, L("Masquer pLUGINSLENS"), #selector(NSApplication.hide(_:)), "h")
        _ = item(appMenu, L("Masquer les autres"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        _ = item(appMenu, L("Tout afficher"), #selector(NSApplication.unhideAllApplications(_:)))
        appMenu.addItem(.separator())
        _ = item(appMenu, L("Quitter pLUGINSLENS"), #selector(NSApplication.terminate(_:)), "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: L("Fichier"))
        _ = item(fileMenu, L("Ouvrir des plugins…"), #selector(openPlugins), "o")
        _ = item(fileMenu, L("Enregistrer une copie…"), #selector(saveCopy), "s")
        fileMenu.addItem(.separator())
        _ = item(fileMenu, L("Fermer le plugin actif"), #selector(closeActive), "w")
        _ = item(fileMenu, L("Verrouiller / déverrouiller le plugin actif"), #selector(lockActive))
        fileMenu.addItem(.separator())
        _ = item(fileMenu, L("Mémoriser les plugins entre les sessions"), #selector(toggleRemember))
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: L("Édition"))
        _ = item(editMenu, L("Annuler la modification"), #selector(undo), "z")
        _ = item(editMenu, L("Rétablir"), #selector(redo), "z", [.command, .shift])
        editMenu.addItem(.separator())
        _ = item(editMenu, L("Couper"), #selector(NSText.cut(_:)), "x")
        _ = item(editMenu, L("Copier"), #selector(NSText.copy(_:)), "c")
        _ = item(editMenu, L("Coller"), #selector(NSText.paste(_:)), "v")
        _ = item(editMenu, L("Tout sélectionner"), #selector(NSText.selectAll(_:)), "a")
        editMenu.addItem(.separator())
        _ = item(editMenu, L("Copier les enregistrements"), #selector(copyRecs))
        _ = item(editMenu, L("Coller les enregistrements"), #selector(pasteRecs))
        editMenu.addItem(.separator())
        _ = item(editMenu, L("Nouvelle FormList…"), #selector(newFormlist))
        editItem.submenu = editMenu
        main.addItem(editItem)

        let toolsItem = NSMenuItem()
        let toolsMenu = NSMenu(title: L("Outils"))
        _ = item(toolsMenu, L("Doublons…"), #selector(duplicates))
        _ = item(toolsMenu, L("Comparer deux plugins…"), #selector(comparePlugins))
        _ = item(toolsMenu, L("Comparer deux enregistrements…"), #selector(compareRecords))
        _ = item(toolsMenu, L("Statistiques…"), #selector(stats))
        _ = item(toolsMenu, L("Journal des modifications…"), #selector(log))
        toolsItem.submenu = toolsMenu
        main.addItem(toolsItem)

        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: L("Affichage"))
        _ = item(viewMenu, L("Afficher l'arbre"), #selector(toggleTree), "t")
        viewItem.submenu = viewMenu
        main.addItem(viewItem)

        let wsItem = NSMenuItem()
        let wsMenu = NSMenu(title: L("Espaces de travail"))
        wsMenu.delegate = workspaceMenuDelegate
        wsItem.submenu = wsMenu
        main.addItem(wsItem)
        workspaceMenuDelegate.menu = wsMenu
        workspaceMenuDelegate.refresh()

        // Menu « Langue » : Automatique + 4 langues, coche sur le choix courant
        let langItem = NSMenuItem()
        let langMenu = NSMenu(title: L("Langue"))
        let current = LangChoice.normalize(model.settings.string("language", LangChoice.auto))
        func add(_ title: String, _ code: String) {
            let i = langMenu.addItem(withTitle: title, action: #selector(chooseLanguage), keyEquivalent: "")
            i.target = self
            i.representedObject = code
            i.state = code == current ? .on : .off
        }
        add(L("Automatique (système)"), LangChoice.auto)
        langMenu.addItem(.separator())
        for (code, label) in LangChoice.menuLangs { add(label, code) }
        langItem.submenu = langMenu
        main.addItem(langItem)

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: L("Fenêtre"))
        _ = item(winMenu, L("Réduire"), #selector(NSWindow.performMiniaturize(_:)), "m")
        winItem.submenu = winMenu
        main.addItem(winItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = winMenu
    }

    lazy var workspaceMenuDelegate = WorkspaceMenu(owner: self)
}

/// Menu « Espaces de travail » : enregistrer, puis un élément par espace mémorisé (reconstruit à l'ouverture).
@MainActor
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    unowned let owner: AppDelegate
    weak var menu: NSMenu?
    init(owner: AppDelegate) { self.owner = owner }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    func refresh() {
        guard let m = menu else { return }
        m.removeAllItems()
        let save = m.addItem(withTitle: L("Enregistrer l'espace de travail…"), action: #selector(AppDelegate.saveWorkspace(_:)), keyEquivalent: "")
        save.target = owner
        let wss = owner.model.workspaces
        if !wss.isEmpty { m.addItem(.separator()) }
        for w in wss {
            let i = m.addItem(withTitle: w.name, action: #selector(AppDelegate.loadWorkspace(_:)), keyEquivalent: "")
            i.target = owner
            i.representedObject = w.name
        }
    }
}

I18n.setLang(LangChoice.resolve(AppSettings(suite: ProcessInfo.processInfo.environment["PLUGINSLENS_SUITE"]).string("language", LangChoice.auto)))

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
