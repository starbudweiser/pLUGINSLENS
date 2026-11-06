// Boîtes de dialogue (feuilles attachées à la fenêtre) : PickDialog, ListDialog, TextDialog ; éditeur de texte mono.

import AppKit
import LensCore
import Observation
import SwiftUI

// MARK: Présentation

@MainActor
final class SheetHost: NSObject, NSWindowDelegate {
    let window: NSWindow
    private(set) var parent: NSWindow?
    var onResize: ((NSSize) -> Void)?
    private var closed = false

    init<V: View>(_ title: String, size: CGSize, resizable: Bool = true, @ViewBuilder content: (SheetHost) -> V) {
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: resizable ? [.titled, .closable, .resizable] : [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let hv = NSHostingView(rootView: content(self).background(Socle.C.bg))
        hv.sizingOptions = []
        window.contentView = hv
        window.setContentSize(size)
        window.contentMinSize = NSSize(width: min(size.width, 360), height: min(size.height, 240))
    }

    func present(on parent: NSWindow?) {
        self.parent = parent
        if let parent {
            parent.beginSheet(window)
        } else {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let parent, parent.attachedSheet === window { parent.endSheet(window) }
        window.orderOut(nil)
    }

    func windowDidResize(_ notification: Notification) { onResize?(window.contentLayoutRect.size) }
}

extension AppModel {
    @discardableResult
    func sheet<V: View>(_ title: String, size: CGSize, resizable: Bool = true, @ViewBuilder content: (SheetHost) -> V) -> SheetHost {
        let host = SheetHost(title, size: size, resizable: resizable, content: content)
        // Une feuille déjà ouverte reste devant : on ouvre la nouvelle sur la dernière feuille
        var top = window
        while let s = top?.attachedSheet { top = s }
        host.present(on: top)
        return host
    }

    /// Choisir un enregistrement parmi tous les plugins ouverts ; `done` reçoit le choix (nil si annulé).
    func pickRecord(hint: String? = nil, done: @escaping (Record?) -> Void) {
        var picked: Record?
        sheet(L("Choisir un enregistrement"), size: CGSize(width: 520, height: 480)) { host in
            PickView(model: self, hint: hint ?? L("Recherche dans tous les plugins ouverts.")) { r in
                picked = r
                host.close()
                done(picked)
            } cancel: {
                host.close()
                done(nil)
            }
        }
    }

    func textDialog(title: String, value: String, ok: String, hint: String = "", readOnly: Bool = false,
                    done: @escaping (String?) -> Void = { _ in }) {
        sheet(title, size: CGSize(width: 560, height: 420)) { host in
            TextDialogView(title: title, value: value, ok: ok, hint: hint, readOnly: readOnly) { text in
                host.close()
                done(text)
            }
        }
    }
}

// MARK: Éditeur de texte mono

/// NSTextView monospace : texte brut, Tab change de champ, fond rouge si invalide.
struct MonoTextView: NSViewRepresentable {
    @Binding var text: String
    var bad = false
    var readOnly = false
    var onEdit: (String) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let tv = NSTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = Socle.T.mono.nsFont
        tv.textColor = NSColor(Socle.C.textStrong)
        tv.insertionPointColor = NSColor(Socle.C.textStrong)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.delegate = context.coordinator
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .noBorder
        context.coordinator.tv = tv
        tv.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let tv = context.coordinator.tv!
        if tv.string != text { tv.string = text }
        tv.isEditable = !readOnly
        tv.backgroundColor = NSColor(bad ? Socle.C.dangerBg : Socle.C.bgSunken)
        scroll.backgroundColor = tv.backgroundColor
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MonoTextView
        weak var tv: NSTextView?
        init(_ p: MonoTextView) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv else { return }
            parent.text = tv.string
            parent.onEdit(tv.string)
        }

        func textView(_ textView: NSTextView, doCommandBy sel: Selector) -> Bool {
            if sel == #selector(NSResponder.insertTab(_:)) { textView.window?.selectNextKeyView(nil); return true }
            if sel == #selector(NSResponder.insertBacktab(_:)) { textView.window?.selectPreviousKeyView(nil); return true }
            return false
        }
    }
}

// MARK: Boutons et champs communs

struct SmallButton: View {
    let title: String
    var enabled = true
    var variant: SocleButtonStyle.Variant = .secondary
    let action: () -> Void

    init(_ title: String, enabled: Bool = true, variant: SocleButtonStyle.Variant = .secondary, action: @escaping () -> Void) {
        self.title = title; self.enabled = enabled; self.variant = variant; self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title).lineLimit(1) }
            .buttonStyle(SocleButtonStyle(variant, height: Socle.M.sizeControl))
            .fixedSize()
            .disabled(!enabled)
    }
}

struct MetaText: View {
    let text: String
    var body: some View { Text(Socle.branded(text)).socle(Socle.T.meta).foregroundStyle(Socle.C.textMuted).fixedSize(horizontal: false, vertical: true) }
}

// MARK: PickDialog

struct PickView: View {
    let model: AppModel
    let hint: String
    let pick: (Record) -> Void
    let cancel: () -> Void
    @State private var q = ""
    @FocusState private var focus: Bool

    private var results: (recs: [Record], message: String?) {
        let s = q.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return ([], L("Saisissez une recherche…")) }
        let r = model.ws.search(s, limit: 200).recs
        return (r, r.isEmpty ? L("Aucun résultat") : nil)
    }

    var body: some View {
        let res = results
        let many = model.ws.plugins.count > 1
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            MetaText(text: hint)
            TextField(L("EditorID, FormID ou type"), text: $q).socleField().focused($focus)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let m = res.message {
                        Text(m).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).padding(6)
                    }
                    ForEach(Array(res.recs.enumerated()), id: \.offset) { _, r in
                        Button { pick(r) } label: {
                            Text("\(hexs(r.id))   \(r.t)  \(edid(r))" + (many ? "   (\(r.plugin!.name))" : ""))
                                .socle(Socle.T.mono).foregroundStyle(Socle.C.text)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).padding(.horizontal, 6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .background(Socle.C.bgSunken)
            HStack { Spacer(); SmallButton(L("Annuler"), action: cancel) }
        }
        .padding(Socle.M.space4)
        .onAppear { focus = true }
        .onExitCommand(perform: cancel)
    }
}

// MARK: ListDialog

struct ListItem: Identifiable {
    enum Kind { case section(String), message(String), record(Record, String) }
    let id = UUID()
    let kind: Kind
}

@MainActor @Observable
final class ListData {
    var items: [ListItem] = []
    func clear() { items = [] }
    func section(_ t: String) { items.append(ListItem(kind: .section(t))) }
    func message(_ t: String) { items.append(ListItem(kind: .message(t))) }
    func record(_ r: Record, _ extra: String = "") { items.append(ListItem(kind: .record(r, extra))) }
}

struct ListView<Top: View>: View {
    let title: String
    let note: String
    let data: ListData
    let go: (Record) -> Void
    let close: () -> Void
    @ViewBuilder var top: Top

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            if !note.isEmpty { MetaText(text: note) }
            top
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(data.items) { it in
                        switch it.kind {
                        case .section(let t):
                            Text(t).socle(Socle.T.eyebrow).foregroundStyle(Socle.C.textSubtle).padding(.horizontal, 6).padding(.vertical, 5)
                        case .message(let t):
                            Text(t).socle(Socle.T.body).foregroundStyle(Socle.C.textMuted).padding(6)
                        case .record(let r, let extra):
                            Button { go(r) } label: {
                                Text("\(hexs(r.id))   \(r.t)  \(edid(r))\(extra)").socle(Socle.T.mono).foregroundStyle(Socle.C.text)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3).padding(.horizontal, 6)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .background(Socle.C.bgSunken)
            HStack { Spacer(); SmallButton(L("Fermer"), action: close) }
        }
        .padding(Socle.M.space4)
        .onExitCommand(perform: close)
    }
}

extension AppModel {
    func listDialog<Top: View>(title: String, note: String = "", data: ListData, @ViewBuilder top: @escaping () -> Top) {
        sheet(title, size: CGSize(width: 600, height: 520)) { host in
            ListView(title: title, note: note, data: data, go: { [unowned self] r in
                host.close()
                self.showRecord(r)
            }, close: { host.close() }, top: top)
        }
    }

    func listDialog(title: String, note: String = "", data: ListData) {
        listDialog(title: title, note: note, data: data) { EmptyView() }
    }
}

// MARK: TextDialog

struct TextDialogView: View {
    let title: String
    let ok: String
    let hint: String
    let readOnly: Bool
    let done: (String?) -> Void
    @State private var text: String

    init(title: String, value: String, ok: String, hint: String, readOnly: Bool, done: @escaping (String?) -> Void) {
        self.title = title; self.ok = ok; self.hint = hint; self.readOnly = readOnly; self.done = done
        _text = State(initialValue: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Socle.M.space2) {
            Text(title).socle(Socle.T.heading).foregroundStyle(Socle.C.textStrong)
            if !hint.isEmpty { MetaText(text: hint) }
            MonoTextView(text: $text, readOnly: readOnly)
            HStack {
                Spacer()
                if !readOnly { SmallButton(L("Annuler")) { done(nil) } }
                SmallButton(ok, variant: .primary) { done(text) }
            }
        }
        .padding(Socle.M.space4)
        .onExitCommand { done(nil) }
    }
}
