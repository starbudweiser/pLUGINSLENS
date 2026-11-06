// Arbre des plugins (port de RecordTree + rebuild_tree/fill de MainWindow) : NSOutlineView paresseux.
// Glisser des enregistrements vers une FormList ou vers un autre panneau, déposer des fichiers plugin.

import AppKit
import LensCore
import SwiftUI

let RECORD_TYPE = NSPasteboard.PasteboardType("application/x-pluginlens-record")

final class TreeItem: NSObject {
    enum Kind {
        case section(String, clear: Bool)
        case plugin(Plugin)
        case group(GroupNode)
        case record(Record, showPlugin: Bool)
        case info(String)
    }

    let kind: Kind
    weak var parent: TreeItem?
    var children: [TreeItem]?

    init(_ kind: Kind) { self.kind = kind }

    var record: Record? { if case .record(let r, _) = kind { return r }; return nil }

    var expandable: Bool {
        switch kind {
        case .section, .plugin, .group: return true
        default: return false
        }
    }

    /// Clé stable pour conserver les nœuds ouverts d'une reconstruction à l'autre.
    var key: AnyHashable? {
        switch kind {
        case .plugin(let p): return ObjectIdentifier(p)
        case .group(let g): return ObjectIdentifier(g)
        case .section(let t, _): return t
        default: return nil
        }
    }
}

final class FlippedOutline: NSOutlineView {
    var onDelete: () -> Void = {}
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { onDelete(); return }  // ⌫ ou ⌦
        super.keyDown(with: event)
    }
}

@MainActor
final class TreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    unowned let model: AppModel
    let outline = FlippedOutline()
    let scroll = NSScrollView()
    private var roots: [TreeItem] = []
    private var recordItems: [ObjectIdentifier: TreeItem] = [:]
    private var pluginItems: [ObjectIdentifier: TreeItem] = [:]
    private var suppressSelection = false

    init(model: AppModel) {
        self.model = model
        super.init()
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.allowsMultipleSelection = true
        outline.indentationPerLevel = 14
        outline.rowHeight = 22
        outline.usesAutomaticRowHeights = false
        outline.backgroundColor = NSColor(Socle.C.surface)
        outline.style = .plain
        outline.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked(_:))
        outline.setDraggingSourceOperationMask(.copy, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.registerForDraggedTypes([RECORD_TYPE, .fileURL])
        outline.draggingDestinationFeedbackStyle = .regular
        outline.onDelete = { [unowned model] in model.deleteCurrent() }
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(Socle.C.surface)
        model.tree = self
    }

    // MARK: Construction

    func reload() {
        let expanded = expandedKeys()
        recordItems = [:]
        pluginItems = [:]
        roots = []
        let q = model.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let (recs, total) = model.ws.search(q, sort: model.sortMode)
            for r in recs { roots.append(recordItem(r, showPlugin: model.ws.plugins.count > 1)) }
            if total > 300 { roots.append(TreeItem(.info(L("Seuls les 300 premiers résultats sont affichés. Affinez la recherche.")))) }
            if total == 0 { roots.append(TreeItem(.info(L("Aucun résultat")))) }
            outline.reloadData()
            return
        }
        addSection(L("Récemment consultés"), model.recentRecords, clear: true)
        addSection(L("Épinglés"), model.pinnedRecords, clear: false)
        for P in model.ws.plugins { roots.append(pluginItem(P)) }
        outline.reloadData()
        for s in roots { if case .section = s.kind { outline.expandItem(s) } }
        restoreExpanded(expanded)
    }

    private func addSection(_ title: String, _ recs: [Record], clear: Bool) {
        if recs.isEmpty { return }
        let head = TreeItem(.section(title, clear: clear))
        head.children = recs.map { recordItem($0, showPlugin: model.ws.plugins.count > 1, register: false) }
        head.children!.forEach { $0.parent = head }
        roots.append(head)
    }

    private func recordItem(_ r: Record, showPlugin: Bool, register: Bool = true) -> TreeItem {
        let it = TreeItem(.record(r, showPlugin: showPlugin))
        if register { recordItems[ObjectIdentifier(r)] = it }
        return it
    }

    private func pluginItem(_ P: Plugin) -> TreeItem {
        let it = TreeItem(.plugin(P))
        pluginItems[ObjectIdentifier(P)] = it
        return it
    }

    private func loadChildren(_ item: TreeItem) {
        guard item.children == nil else { return }
        switch item.kind {
        case .plugin(let P): item.children = fill(filteredRoot(P, model.typeFilter))
        case .group(let g): item.children = fill(g.kids.items)
        default: item.children = []
        }
        item.children!.forEach { $0.parent = item }
    }

    private func fill(_ lst: [Node]) -> [TreeItem] {
        var items = lst
        if model.sortMode != .file, !lst.isEmpty, lst.allSatisfy({ $0 is Record }) {
            items = sortRecords(lst as! [Record], model.sortMode)
        }
        var out: [TreeItem] = []
        for n in items {
            if let g = n as? GroupNode {
                if hasRecords(g) { out.append(TreeItem(.group(g))) }
            } else {
                out.append(recordItem(n as! Record, showPlugin: false))
            }
        }
        return out
    }

    private func expandedKeys() -> Set<AnyHashable> {
        var out = Set<AnyHashable>()
        func walk(_ items: [TreeItem]) {
            for it in items where it.children != nil {
                if let k = it.key, outline.isItemExpanded(it) {
                    out.insert(k)
                    walk(it.children!)
                }
            }
        }
        walk(roots)
        return out
    }

    private func restoreExpanded(_ keys: Set<AnyHashable>) {
        func walk(_ items: [TreeItem]) {
            for it in items {
                guard let k = it.key, keys.contains(k), it.expandable else { continue }
                outline.expandItem(it)
                if let c = it.children { walk(c) }
            }
        }
        walk(roots)
    }

    // MARK: Actions de l'appli

    func addPlugin(_ P: Plugin) {
        let it = pluginItem(P)
        let at = roots.count
        roots.append(it)
        outline.insertItems(at: IndexSet(integer: at), inParent: nil, withAnimation: [])
        outline.expandItem(it)
    }

    func forget(_ P: Plugin) { pluginItems[ObjectIdentifier(P)] = nil }

    func refreshPlugin(_ P: Plugin) {
        if let it = pluginItems[ObjectIdentifier(P)] { outline.reloadItem(it) }
    }

    func refreshRecord(_ r: Record) {
        if let it = recordItems[ObjectIdentifier(r)] { outline.reloadItem(it) }
    }

    func refreshIds(_ P: Plugin) {
        outline.reloadData(forRowIndexes: IndexSet(0..<outline.numberOfRows), columnIndexes: IndexSet(integer: 0))
    }

    func select(_ r: Record) {
        guard let it = recordItems[ObjectIdentifier(r)] else { return }
        let row = outline.row(forItem: it)
        guard row >= 0 else { return }
        suppressSelection = true
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        suppressSelection = false
    }

    func insertAfter(_ r: Record, _ c: Record) {
        guard let it = recordItems[ObjectIdentifier(r)], let parent = it.parent, var kids = parent.children,
              let i = kids.firstIndex(where: { $0 === it }) else { return }
        let n = recordItem(c, showPlugin: false)
        n.parent = parent
        kids.insert(n, at: i + 1)
        parent.children = kids
        outline.insertItems(at: IndexSet(integer: i + 1), inParent: parent, withAnimation: [])
    }

    func remove(_ r: Record) {
        guard let it = recordItems.removeValue(forKey: ObjectIdentifier(r)) else { return }
        if let parent = it.parent {
            guard var kids = parent.children, let i = kids.firstIndex(where: { $0 === it }) else { return }
            kids.remove(at: i)
            parent.children = kids
            outline.removeItems(at: IndexSet(integer: i), inParent: parent, withAnimation: [])
        } else if let i = roots.firstIndex(where: { $0 === it }) {
            roots.remove(at: i)
            outline.removeItems(at: IndexSet(integer: i), inParent: nil, withAnimation: [])
        }
    }

    func expand(_ P: Plugin) {
        if let it = pluginItems[ObjectIdentifier(P)] { outline.expandItem(it) }
    }

    func expand(group list: NodeList?) {
        guard let list else { return }
        func walk(_ items: [TreeItem]) {
            for it in items {
                if case .group(let g) = it.kind, g.kids === list { outline.expandItem(it); return }
                if let c = it.children, outline.isItemExpanded(it) { walk(c) }
            }
        }
        walk(roots)
    }

    func selectedRecords() -> [Record] {
        outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? TreeItem)?.record }
    }

    // MARK: NSOutlineViewDataSource

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let it = item as? TreeItem else { return roots.count }
        loadChildren(it)
        return it.children!.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let it = item as? TreeItem else { return roots[index] }
        loadChildren(it)
        return it.children![index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! TreeItem).expandable }

    // MARK: Glisser-déposer

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard (item as! TreeItem).record != nil else { return nil }
        let pb = NSPasteboardItem()
        pb.setString("1", forType: RECORD_TYPE)
        pb.setString(DRAG_MARK, forType: .string)  // reconnu par les panneaux SwiftUI (SideBySide, FormList…)
        return pb
    }

    func outlineView(_ outlineView: NSOutlineView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint, forItems draggedItems: [Any]) {
        var recs = selectedRecords()
        if recs.isEmpty { recs = draggedItems.compactMap { ($0 as? TreeItem)?.record } }
        model.dragRecs = recs
    }

    private func flst(_ item: Any?) -> Record? {
        guard let r = (item as? TreeItem)?.record, r.t == "FLST" else { return nil }
        return r
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo, proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        let pb = info.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
            outlineView.setDropItem(nil, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        if pb.types?.contains(RECORD_TYPE) == true, flst(item) != nil {
            outlineView.setDropItem(item, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .copy
        }
        return []
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo, item: Any?, childIndex index: Int) -> Bool {
        let pb = info.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            model.loadFiles(urls.map(\.path))
            return true
        }
        if let fl = flst(item), !model.dragRecs.isEmpty, !model.locked(fl.plugin) {
            model.addEntries(fl, model.dragRecs)
        }
        return true
    }

    // MARK: Sélection et clics

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as! TreeItem).record != nil }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, outline.selectedRowIndexes.count <= 1,
              let it = outline.item(atRow: outline.selectedRow) as? TreeItem, let r = it.record, r !== model.cur else { return }
        model.showRecord(r, select: false)
    }

    @objc func clicked(_ sender: Any?) {
        let row = outline.clickedRow
        guard row >= 0, let it = outline.item(atRow: row) as? TreeItem else { return }
        let mods = NSEvent.modifierFlags
        switch it.kind {
        case .plugin(let P):
            toggle(it)
            model.showRecord(P.header)
        case .group:
            toggle(it)
        case .record(let r, _):
            if mods.isDisjoint(with: [.shift, .command, .control]) { model.showRecord(r) }
        default: break
        }
        let n = selectedRecords().count
        if n > 1 { model.flash(L("{n} enregistrements sélectionnés. Glissez-les sur une FormList.", ["n": n])) }
    }

    private func toggle(_ it: TreeItem) {
        if outline.isItemExpanded(it) { outline.collapseItem(it) } else { outline.expandItem(it) }
    }

    // MARK: Cellules

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let it = item as! TreeItem
        switch it.kind {
        case .record(let r, let showPlugin): return RecordCell(r, showPlugin: showPlugin)
        case .plugin(let P): return PluginCell(P, model: model)
        case .group(let g): return textCell(glabel(g), font: Socle.T.body.nsFont, color: NSColor(Socle.C.text))
        case .section(let title, let clear): return SectionCell(title: title, clear: clear, model: model)
        case .info(let text): return textCell(text, font: Socle.T.body.nsFont, color: NSColor(Socle.C.textSubtle))
        }
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as! TreeItem).kind {
        case .plugin: return 26
        case .section(_, let clear): return clear ? 26 : 22
        default: return 22
        }
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SocleRowView() }

    private func textCell(_ text: String, font: NSFont, color: NSColor) -> NSView {
        let f = NSTextField(labelWithString: text)
        f.font = font
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        let v = NSTableCellView()
        v.addSubview(f)
        f.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 2),
            f.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -4),
            f.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        return v
    }
}

final class SocleRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        NSColor(Socle.C.surfaceSelected).setFill()
        bounds.fill()
    }
}

private func mono(_ s: String, _ color: Color) -> NSTextField {
    let f = NSTextField(labelWithString: s)
    f.font = Socle.T.mono.nsFont
    f.textColor = NSColor(color)
    f.lineBreakMode = .byClipping
    return f
}

final class RecordCell: NSTableCellView {
    init(_ r: Record, showPlugin: Bool) {
        super.init(frame: .zero)
        let type = mono(r.t, Socle.C.accentText)
        let name = NSTextField(labelWithString: edid(r))
        name.font = Socle.T.body.nsFont
        name.textColor = NSColor(Socle.C.text)
        name.lineBreakMode = .byTruncatingTail
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let id = mono(hexs(r.id) + (showPlugin ? "   \(r.plugin!.name)" : ""), Socle.C.textSubtle)
        id.setContentCompressionResistancePriority(.required, for: .horizontal)
        for v in [type, name, id] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            type.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            type.widthAnchor.constraint(equalToConstant: 46),
            type.centerYAnchor.constraint(equalTo: centerYAnchor),
            name.leadingAnchor.constraint(equalTo: type.trailingAnchor, constant: 6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            id.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            id.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            id.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

final class PluginCell: NSTableCellView {
    private let model: AppModel
    private let plugin: Plugin

    init(_ P: Plugin, model: AppModel) {
        self.model = model
        plugin = P
        super.init(frame: .zero)
        let lab = NSTextField(labelWithString: P.name + (P.dirty ? " •" : "") + (P.locked ? L("   (verrouillé)") : ""))
        lab.font = Socle.T.labelStrong.nsFont
        lab.textColor = NSColor(Socle.C.textStrong)
        lab.lineBreakMode = .byTruncatingMiddle
        lab.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let lock = small(P.locked ? L("Déverrouiller") : L("Verrouiller"), #selector(lockTapped))
        let close = small(L("Fermer"), #selector(closeTapped))
        for v in [lab, lock, close] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            lab.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            lab.centerYAnchor.constraint(equalTo: centerYAnchor),
            lock.leadingAnchor.constraint(greaterThanOrEqualTo: lab.trailingAnchor, constant: 6),
            close.leadingAnchor.constraint(equalTo: lock.trailingAnchor, constant: 6),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            lock.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func small(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .recessed
        b.controlSize = .small
        b.font = Socle.T.meta.nsFont
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    @objc private func lockTapped() { model.toggleLock(plugin) }
    @objc private func closeTapped() { model.closePlugin(plugin) }
}

final class SectionCell: NSTableCellView {
    private let model: AppModel

    init(title: String, clear: Bool, model: AppModel) {
        self.model = model
        super.init(frame: .zero)
        let lab = NSTextField(labelWithString: title.uppercased())
        lab.font = Socle.T.eyebrow.nsFont
        lab.textColor = NSColor(Socle.C.textSubtle)
        lab.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lab)
        NSLayoutConstraint.activate([
            lab.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            lab.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if clear {
            let b = NSButton(title: L("Effacer"), target: self, action: #selector(clearTapped))
            b.bezelStyle = .recessed
            b.controlSize = .small
            b.font = Socle.T.meta.nsFont
            b.translatesAutoresizingMaskIntoConstraints = false
            addSubview(b)
            NSLayoutConstraint.activate([
                b.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
                b.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clearTapped() { model.clearRecent() }
}

struct TreeRepresentable: NSViewRepresentable {
    let controller: TreeController

    func makeNSView(context: Context) -> NSScrollView { controller.scroll }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}
