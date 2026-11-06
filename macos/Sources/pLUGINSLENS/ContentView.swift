// Fenêtre principale : barre d'en-tête (ouvrir, recherche, tri, filtre de groupes, statut) puis arbre | détail.

import AppKit
import LensCore
import SwiftUI
import UniformTypeIdentifiers

let WINDOW_SIZE = CGSize(width: 1280, height: 800)

struct ContentView: View {
    let model: AppModel
    @State private var treeW: CGFloat = 460
    @State private var dragStart: CGFloat?
    @State private var filterText = ""
    @FocusState private var searchFocus: Bool

    var body: some View {
        @Bindable var m = model
        let _ = model.langTick
        VStack(spacing: Socle.M.space2) {
            header
            HStack(spacing: 0) {
                if model.treeVisible, let tree = model.tree {
                    TreeRepresentable(controller: tree)
                        .frame(width: treeW)
                        .overlay(Rectangle().stroke(Socle.C.border, lineWidth: 1))
                    divider
                }
                DetailView(model: model)
            }
            .overlay(alignment: .center) { EmptyView() }
        }
        .padding(Socle.M.space3)
        .background(Socle.C.bg)
        .onAppear {
            if model.treeWidth > 0 { treeW = CGFloat(model.treeWidth) }
        }
        .onChange(of: model.focusRev) { _, _ in
            searchFocus = true
            DispatchQueue.main.async { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    DispatchQueue.main.async { model.loadFiles([url.path]) }
                }
            }
            return true
        }
    }

    private var divider: some View {
        Rectangle().fill(Color.clear).frame(width: 8)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    if dragStart == nil { dragStart = treeW }
                    treeW = max(200, min(900, dragStart! + g.translation.width))
                }
                .onEnded { _ in
                    dragStart = nil
                    model.treeWidth = Int(treeW)
                    model.settings.set("tree_w", Int(treeW))
                })
    }

    private var header: some View {
        @Bindable var m = model
        return HStack(spacing: Socle.M.space2) {
            Text(Socle.branded(APP)).socle(Socle.T.title).foregroundStyle(Socle.C.textStrong)
            SmallButton(L("Ouvrir des plugins"), variant: .action) { model.openDialog() }
            TextField(L("Rechercher un EditorID, un FormID ou un type"), text: $m.query)
                .socleField().frame(minWidth: 300, maxWidth: 380).focused($searchFocus)
                .disabled(!model.hasPlugins)
                .onChange(of: model.query) { _, _ in model.tree?.reload() }
            Picker("", selection: Binding(get: { model.sortMode }, set: { model.sortMode = $0; model.tree?.reload() })) {
                Text(L("Ordre du fichier")).tag(SortMode.file)
                Text(L("Tri : EditorID")).tag(SortMode.edid)
                Text(L("Tri : FormID")).tag(SortMode.formid)
            }
            .labelsHidden().fixedSize().disabled(!model.hasPlugins)
            TextField(L("Groupes : WEAP, ARMO…"), text: $filterText)
                .socleField().frame(minWidth: 170, maxWidth: 220).disabled(!model.hasPlugins)
                .onChange(of: filterText) { _, t in
                    model.typeFilter = t.split(separator: ",", omittingEmptySubsequences: true)
                        .map { pyStrip(String($0)).uppercased() }.filter { !$0.isEmpty }
                    model.tree?.reload()
                }
            Text(Socle.branded(model.statusText)).socle(Socle.T.meta)
                .foregroundStyle(model.statusTone == .warning ? Socle.C.warning : model.statusTone == .danger ? Socle.C.danger : Socle.C.textMuted)
                .lineLimit(1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Socle.C.surface, in: RoundedRectangle(cornerRadius: Socle.M.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: Socle.M.radiusMd).stroke(Socle.C.border, lineWidth: 1))
    }
}
