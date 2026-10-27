"""pLUGINSLENS — éditeur de plugins Skyrim (.esp / .esm / .esl) pour macOS, en PyQt6.

Interface native (design system Socle). Toute la logique de lecture, d'écriture et de
modification des plugins est dans plugin_core.py, vérifiée octet pour octet contre la
version JavaScript d'origine (tests/test_parity.py).
"""
from __future__ import annotations

import json
import os
import sys
import time

from PyQt6.QtCore import QMimeData, QProcess, QSettings, QSize, Qt, QTimer, pyqtSignal
from PyQt6.QtGui import QAction, QDrag, QKeySequence, QShortcut
from PyQt6.QtWidgets import (
    QAbstractItemView, QApplication, QCheckBox, QComboBox, QDialog, QFileDialog, QFrame, QHBoxLayout,
    QInputDialog, QLabel, QLineEdit, QListWidget, QListWidgetItem, QMainWindow, QMessageBox,
    QPlainTextEdit, QPushButton, QScrollArea, QSizePolicy, QSplitter, QTableWidget, QTableWidgetItem, QTreeWidget,
    QTreeWidgetItem, QVBoxLayout, QWidget,
)

import plugin_core as pc
import socle_qt
import update_check
from i18n import get_lang
from i18n import L
from lang_button import LangButton, init_lang

APP = "pLUGINSLENS"
DATA_NAME = "PluginLens"  # réglages et session déjà enregistrés sous ce nom : ne pas renommer
MIME = "application/x-pluginlens-record"
ROLE = Qt.ItemDataRole.UserRole
SESSION_DIR = os.path.join(os.path.expanduser("~/Library/Application Support"), DATA_NAME, "session")


def mono_label(text: str, color: str = "accent-text") -> QLabel:
    lbl = QLabel(text)
    lbl.setFont(socle_qt.font("mono"))
    lbl.setStyleSheet(f"color: {socle_qt.c(color)}; background: transparent;")
    return lbl


def zw(px: int) -> int:
    """Largeur fixe d'un champ mono, à l'échelle des textes Socle (110 %)."""
    return round(px * max(1.0, socle_qt.scale()))


def compact(b: QPushButton) -> QPushButton:
    """Bouton bas pour une ligne de l'arbre : sa hauteur suit le texte au lieu de la hauteur Socle."""
    b.setStyleSheet("min-height: 0; padding: 1px 8px;")
    return b


def small_button(text: str, slot=None, enabled: bool = True) -> QPushButton:
    b = QPushButton(text)
    b.setCursor(Qt.CursorShape.PointingHandCursor)
    b.setEnabled(enabled)
    if slot:
        b.clicked.connect(slot)
    return b


class DropFrame(QFrame):
    """Panneau qui accepte les enregistrements glissés depuis l'arbre."""

    def __init__(self, on_drop, panel: str = "true"):
        super().__init__()
        self.on_drop = on_drop
        self.setProperty("panel", panel)
        self.setAcceptDrops(True)

    def _hover(self, on: bool):
        self.setProperty("over", on)
        self.setStyleSheet(f"QFrame {{ border: 1px dashed {socle_qt.c('accent')}; }}" if on else "")

    def dragEnterEvent(self, e):
        if e.mimeData().hasFormat(MIME):
            e.acceptProposedAction()
            self._hover(True)

    def dragLeaveEvent(self, e):
        self._hover(False)

    def dropEvent(self, e):
        self._hover(False)
        e.acceptProposedAction()
        self.on_drop()


class RecordTree(QTreeWidget):
    """Arbre des plugins : glisser des enregistrements, déposer sur une FormList ou des fichiers."""

    def __init__(self, win: "MainWindow"):
        super().__init__()
        self.win = win
        self.setHeaderHidden(True)
        self.setColumnCount(3)
        self.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.setDragEnabled(True)
        self.setAcceptDrops(True)
        self.setDropIndicatorShown(False)
        self.setUniformRowHeights(True)
        self.setIndentation(14)
        self.setAnimated(False)
        hdr = self.header()
        hdr.setStretchLastSection(False)
        hdr.setSectionResizeMode(0, hdr.ResizeMode.ResizeToContents)
        hdr.setSectionResizeMode(1, hdr.ResizeMode.Stretch)
        hdr.setSectionResizeMode(2, hdr.ResizeMode.ResizeToContents)

    def startDrag(self, actions):
        recs = [it.data(0, ROLE) for it in self.selectedItems()]
        recs = [r for r in recs if isinstance(r, pc.Record)]
        if not recs:
            return
        self.win.drag_recs = recs
        mime = QMimeData()
        mime.setData(MIME, b"1")
        drag = QDrag(self)
        drag.setMimeData(mime)
        drag.exec(Qt.DropAction.CopyAction)

    def _target(self, e) -> pc.Record | None:
        it = self.itemAt(e.position().toPoint())
        r = it.data(0, ROLE) if it else None
        return r if isinstance(r, pc.Record) and r.t == "FLST" else None

    def dragEnterEvent(self, e):
        if e.mimeData().hasFormat(MIME) or e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dragMoveEvent(self, e):
        if e.mimeData().hasUrls() or (e.mimeData().hasFormat(MIME) and self._target(e)):
            e.acceptProposedAction()
        else:
            e.ignore()

    def dropEvent(self, e):
        if e.mimeData().hasUrls():
            self.win.load_files([u.toLocalFile() for u in e.mimeData().urls()])
            e.acceptProposedAction()
            return
        fl = self._target(e)
        if fl and self.win.drag_recs and not self.win.locked(fl.plugin):
            self.win.add_entries(fl, self.win.drag_recs)
        e.acceptProposedAction()


class PickDialog(QDialog):
    """Choisir un enregistrement parmi tous les plugins ouverts."""

    def __init__(self, win: "MainWindow", hint: str | None = None):
        super().__init__(win)
        self.win, self.result_rec = win, None
        self.setWindowTitle(L("Choisir un enregistrement"))
        self.resize(520, 480)
        lay = QVBoxLayout(self)
        lay.addWidget(socle_qt.role(QLabel(hint or L("Recherche dans tous les plugins ouverts.")), "meta"))
        self.inp = QLineEdit()
        self.inp.setPlaceholderText(L("EditorID, FormID ou type"))
        self.inp.textChanged.connect(self.run)
        lay.addWidget(self.inp)
        self.lst = QListWidget()
        self.lst.itemActivated.connect(self.pick)
        self.lst.itemClicked.connect(self.pick)
        lay.addWidget(self.lst)
        cancel = small_button(L("Annuler"), self.reject)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(cancel)
        lay.addLayout(row)
        self.run("")

    def run(self, q: str):
        self.lst.clear()
        q = q.strip()
        if not q:
            self.lst.addItem(L("Saisissez une recherche…"))
            return
        recs, _ = self.win.ws.search(q, limit=200)
        many = len(self.win.ws.plugins) > 1
        for r in recs:
            it = QListWidgetItem(f"{pc.hexs(r.id)}   {r.t}  {pc.edid(r)}" + (f"   ({r.plugin.name})" if many else ""))
            it.setData(ROLE, r)
            self.lst.addItem(it)
        if not recs:
            self.lst.addItem(L("Aucun résultat"))

    def pick(self, it: QListWidgetItem):
        r = it.data(ROLE)
        if isinstance(r, pc.Record):
            self.result_rec = r
            self.accept()

    @staticmethod
    def get(win, hint=None) -> pc.Record | None:
        d = PickDialog(win, hint) if hint else PickDialog(win)
        d.inp.setFocus()
        return d.result_rec if d.exec() else None


class ListDialog(QDialog):
    """Fenêtre de résultats cliquables (doublons, utilisations, comparaison…)."""

    def __init__(self, win, title: str, note: str = ""):
        super().__init__(win)
        self.win = win
        self.setWindowTitle(title)
        self.resize(600, 520)
        self.lay = QVBoxLayout(self)
        head = socle_qt.role(QLabel(title), "heading")
        self.lay.addWidget(head)
        if note:
            n = socle_qt.role(QLabel(note), "meta")
            n.setWordWrap(True)
            self.lay.addWidget(n)
        self.top = QHBoxLayout()
        self.lay.addLayout(self.top)
        self.lst = QListWidget()
        self.lst.itemActivated.connect(self.go)
        self.lst.itemClicked.connect(self.go)
        self.lay.addWidget(self.lst)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(small_button(L("Fermer"), self.reject))
        self.lay.addLayout(row)

    def section(self, text: str):
        it = QListWidgetItem(text)
        it.setFlags(Qt.ItemFlag.NoItemFlags)
        f = socle_qt.font("eyebrow")
        it.setFont(f)
        self.lst.addItem(it)

    def message(self, text: str):
        it = QListWidgetItem(text)
        it.setFlags(Qt.ItemFlag.NoItemFlags)
        self.lst.addItem(it)

    def record(self, r: pc.Record, extra: str = ""):
        it = QListWidgetItem(f"{pc.hexs(r.id)}   {r.t}  {pc.edid(r)}{extra}")
        it.setData(ROLE, r)
        self.lst.addItem(it)

    def go(self, it):
        r = it.data(ROLE)
        if isinstance(r, pc.Record):
            self.accept()
            self.win.show_record(r)


class TextDialog(QDialog):
    def __init__(self, win, title: str, value: str, ok: str, hint: str = "", read_only: bool = False):
        super().__init__(win)
        self.setWindowTitle(title)
        self.resize(560, 420)
        lay = QVBoxLayout(self)
        lay.addWidget(socle_qt.role(QLabel(title), "heading"))
        if hint:
            h = socle_qt.role(QLabel(hint), "meta")
            h.setWordWrap(True)
            lay.addWidget(h)
        self.ed = QPlainTextEdit(value)
        self.ed.setFont(socle_qt.font("mono"))
        self.ed.setReadOnly(read_only)
        lay.addWidget(self.ed)
        row = QHBoxLayout()
        row.addStretch(1)
        if not read_only:
            row.addWidget(small_button(L("Annuler"), self.reject))
        row.addWidget(socle_qt.variant(small_button(ok, self.accept), "primary"))
        lay.addLayout(row)


class SubEditor(QFrame):
    """Éditeur d'un sous-enregistrement : texte ou hexadécimal."""

    def __init__(self, win: "MainWindow", r: pc.Record, s: pc.Sub):
        super().__init__()
        self.win, self.r, self.s = win, r, s
        self.setProperty("panel", "true")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(10, 6, 10, 8)
        lay.setSpacing(4)
        head = QHBoxLayout()
        head.addWidget(mono_label(s.t))
        self.info = socle_qt.role(QLabel(""), "meta")
        self.hint = socle_qt.role(QLabel(""), "meta")
        head.addWidget(self.info)
        head.addWidget(self.hint)
        head.addStretch(1)
        if s.m is None:
            s.m = "t" if pc.is_text(s.d) else "h"
        self.toggle = small_button("", self.flip)
        head.addWidget(self.toggle)
        if len(s.d) == 4:
            head.addWidget(small_button(L("Choisir…"), self.pick))
        head.addWidget(small_button(L("Retirer"), self.remove))
        lay.addLayout(head)
        self.ed = QPlainTextEdit()
        self.ed.setFont(socle_qt.font("mono"))
        self.ed.setTabChangesFocus(True)
        self.ed.textChanged.connect(self.edited)
        lay.addWidget(self.ed)
        self._painting = False
        self.paint()

    def paint(self):
        self._painting = True
        s = self.s
        txt = pc.text_of(s.d) if s.m == "t" else pc.hex_bytes(s.d)
        self.ed.setPlainText(txt)
        lines = txt.count("\n") + 1 + (len(txt) // 90 if s.m == "h" else 0)
        rows = min(12, max(1, lines))
        self.ed.setFixedHeight(int(rows * self.ed.fontMetrics().lineSpacing() + 30))
        self.toggle.setText(L("Hexadécimal") if s.m == "t" else L("Texte"))
        self.meta()
        self._painting = False

    def meta(self):
        self.info.setText(L("{n} octets", n=len(self.s.d)))
        self.hint.setText(pc.u32_hint(self.s.d))

    def flip(self):
        self.s.m = "h" if self.s.m == "t" else "t"
        self.paint()

    def edited(self):
        if self._painting:
            return
        if self.win.locked(self.r.plugin):
            return
        if self.s.m == "t":
            nd = pc.text_bytes(self.ed.toPlainText())
        else:
            nd = pc.parse_hex_bytes(self.ed.toPlainText())
            self.ed.setProperty("bad", nd is None)
            self.ed.setStyleSheet(f"background-color: {socle_qt.c('danger-bg')};" if nd is None else "")
            if nd is None:
                return
        self.s.d = nd
        self.win.set_dirty(self.r.plugin, L("Modifié {t} dans {label}", t=self.s.t, label=pc.label(self.r)))
        self.meta()
        if self.s.t == "EDID":
            self.win.refresh_record_item(self.r)

    def pick(self):
        if self.win.locked(self.r.plugin):
            return
        t = PickDialog.get(self.win)
        if not t:
            return
        x = self.win.xref_with_master(t, self.r.plugin)
        if x is None:
            return
        self.s.d = pc.p32(x)
        self.win.set_dirty(self.r.plugin, L("{t} défini sur {label} via le sélecteur", t=self.s.t, label=pc.label(self.r)))
        self.paint()
        if self.s.t == "EDID":
            self.win.refresh_record_item(self.r)

    def remove(self):
        if self.win.locked(self.r.plugin):
            return
        self.r.subs.remove(self.s)
        self.win.set_dirty(self.r.plugin, L("Retiré {t} de {label}", t=self.s.t, label=pc.label(self.r)))
        self.setParent(None)
        self.deleteLater()


class CellEditor(QWidget):
    """Cellule modifiable de la comparaison côte à côte, avec poignée de glisser-copier."""

    changed = pyqtSignal()

    def __init__(self, dlg: "SideBySideDialog", r: pc.Record, s: pc.Sub | None, tag: str, key: str):
        super().__init__()
        self.dlg, self.r, self.s, self.tag, self.key = dlg, r, s, tag, key
        self.setAcceptDrops(True)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(2, 2, 2, 2)
        lay.setSpacing(4)
        if s is None:
            lay.addWidget(socle_qt.role(QLabel(L("(absent)")), "subtle"))
            return
        grip = QLabel("⠿")
        grip.setToolTip(L("Glissez sur l'autre côté pour y copier ce champ"))
        grip.setCursor(Qt.CursorShape.OpenHandCursor)
        grip.mousePressEvent = self._start_drag
        lay.addWidget(grip)
        self.inp = QLineEdit()
        self.inp.setFont(socle_qt.font("mono"))
        self.inp.setEnabled(not r.plugin.locked)
        self.is_txt = pc.is_text(s.d) and len(s.d) != 4
        self.inp.setText(pc.text_of(s.d) if self.is_txt else pc.hex_bytes(s.d))
        self.inp.textEdited.connect(self.edited)
        lay.addWidget(self.inp, 1)
        if len(s.d) == 4:
            self.dec = socle_qt.role(QLabel(dlg.win.ws.decode4(r.plugin, s.d) or ""), "subtle")
            lay.addWidget(self.dec)
            if not r.plugin.locked:
                lay.addWidget(small_button(L("Choisir…"), self.pick))

    def _start_drag(self, _e):
        self.dlg.cell_drag = {"r": self.r, "s": self.s, "key": self.key}
        mime = QMimeData()
        mime.setData(MIME, b"cell")
        drag = QDrag(self)
        drag.setMimeData(mime)
        drag.exec(Qt.DropAction.CopyAction)
        self.dlg.cell_drag = None

    def set_data(self, nd: bytes, msg: str):
        self.s.d = nd
        self.dlg.win.set_dirty(self.r.plugin, msg)
        self.changed.emit()

    def edited(self, text: str):
        if self.is_txt:
            nd = pc.text_bytes(text)
        else:
            nd = pc.parse_hex_bytes(text)
            self.inp.setStyleSheet(f"background-color: {socle_qt.c('danger-bg')};" if nd is None else "")
            if nd is None:
                return
        self.set_data(nd, L("Modifié {t} sur {label} (côte à côte)", t=self.s.t, label=pc.label(self.r)))

    def pick(self):
        t = PickDialog.get(self.dlg.win)
        if not t:
            return
        x = self.dlg.win.xref_with_master(t, self.r.plugin)
        if x is None:
            return
        nd = pc.p32(x)
        self.inp.setText(pc.hex_bytes(nd))
        self.set_data(nd, L("Modifié {t} sur {label} (côte à côte)", t=self.s.t, label=pc.label(self.r)))

    def dragEnterEvent(self, e):
        if e.mimeData().hasFormat(MIME):
            e.acceptProposedAction()

    def dropEvent(self, e):
        e.acceptProposedAction()
        self.dlg.accept_drop(self)


class SideBySideDialog(QDialog):
    def __init__(self, win: "MainWindow", a: pc.Record | None, b: pc.Record | None):
        super().__init__(win)
        self.win, self.a, self.b, self.cell_drag = win, a, b, None
        self.setWindowTitle(L("Comparer deux enregistrements"))
        st = win.settings
        self.resize(int(st.value("sbs_w", 760)), int(st.value("sbs_h", 520)))
        lay = QVBoxLayout(self)
        lay.addWidget(socle_qt.role(QLabel(L("Comparer deux enregistrements")), "heading"))
        note = socle_qt.role(QLabel(L("Choisissez deux enregistrements, ou glissez-les ici depuis l'arbre. Glissez la poignée ⠿ d'un champ pour copier sa valeur de l'autre côté.")), "meta")
        note.setWordWrap(True)
        lay.addWidget(note)
        slots = QHBoxLayout()
        self.slot_a = self._slot(L("Enregistrement A"), lambda: self.a, lambda r: setattr(self, "a", r))
        self.slot_b = self._slot(L("Enregistrement B"), lambda: self.b, lambda r: setattr(self, "b", r))
        slots.addWidget(self.slot_a)
        slots.addWidget(self.slot_b)
        lay.addLayout(slots)
        self.table = QTableWidget(0, 3)
        self.table.setHorizontalHeaderLabels(["", "A", "B"])
        self.table.verticalHeader().setVisible(False)
        self.table.horizontalHeader().setStretchLastSection(True)
        self.table.setSelectionMode(QAbstractItemView.SelectionMode.NoSelection)
        lay.addWidget(self.table, 1)
        row = QHBoxLayout()
        row.addStretch(1)
        row.addWidget(small_button(L("Fermer"), self.reject))
        lay.addLayout(row)
        self.redraw()

    def resizeEvent(self, e):
        super().resizeEvent(e)
        self.win.settings.setValue("sbs_w", self.width())
        self.win.settings.setValue("sbs_h", self.height())

    def _slot(self, title, get, set_):
        frame = DropFrame(lambda: (set_(self.win.drag_recs[0]), self.redraw()) if self.win.drag_recs else None)
        lay = QVBoxLayout(frame)
        frame._title = socle_qt.role(QLabel(title), "eyebrow")
        frame._line = QLabel("")
        frame._btn = small_button("", lambda: self._pick(set_))
        lay.addWidget(frame._title)
        lay.addWidget(frame._line)
        lay.addWidget(frame._btn, alignment=Qt.AlignmentFlag.AlignLeft)
        frame._get = get
        return frame

    def _pick(self, set_):
        t = PickDialog.get(self.win)
        if t:
            set_(t)
            self.redraw()

    def _head(self, r):
        return f"{r.t}  {pc.edid(r)}  ({r.plugin.name}){L("  (verrouillé)") if r.plugin.locked else ''}" if r else "—"

    def redraw(self):
        for f in (self.slot_a, self.slot_b):
            r = f._get()
            f._line.setText(f"{r.t}  {pc.label(r)}  ({r.plugin.name})" if r else "")
            f._btn.setText(L("Changer…") if r else L("Choisir un enregistrement…"))
        a, b = self.a, self.b
        self.table.setRowCount(0)
        self.table.setHorizontalHeaderLabels(["", self._head(a), self._head(b)])
        self.rows = []
        if not a and not b:
            return
        self._row(L("Type"), QLabel(a.t if a else "—"), QLabel(b.t if b else "—"), bool(a and b and a.t != b.t))
        if a and b:
            self.id_row = self._row(L("FormID"), self._hex(a, "id"), self._hex(b, "id"), a.id != b.id)
            self.fl_row = self._row(L("Flags"), self._hex(a, "flags"), self._hex(b, "flags"), a.flags != b.flags)
            self._row(L("Propriétaire"), socle_qt.role(QLabel(pc.owner(a.id, a.plugin)), "subtle"),
                      socle_qt.role(QLabel(pc.owner(b.id, b.plugin)), "subtle"), False)
            for x in pc.union_rows(a, b):
                ca = CellEditor(self, a, x["a"], x["tag"], x["key"])
                cb = CellEditor(self, b, x["b"], x["tag"], x["key"])
                ca.changed.connect(self.refresh_diff)
                cb.changed.connect(self.refresh_diff)
                i = self._row(x["key"], ca, cb, self.win.ws.decode_val(a, x["a"]) != self.win.ws.decode_val(b, x["b"]))
                self.rows.append((i, x))
        else:
            only = a or b
            self._row(L("FormID"), self._hex(a, "id") if a else QLabel("—"), self._hex(b, "id") if b else QLabel("—"), False)
            for x in pc.sub_rows(only):
                ca = CellEditor(self, a, x["sub"], x["tag"], x["key"]) if a else QLabel(L("(absent)"))
                cb = CellEditor(self, b, x["sub"], x["tag"], x["key"]) if b else QLabel(L("(absent)"))
                self._row(x["key"], ca, cb, False)
        self.table.resizeRowsToContents()
        self.table.setColumnWidth(0, 120)
        self.table.setColumnWidth(1, max(200, (self.table.viewport().width() - 120) // 2))

    def _hex(self, r, attr):
        e = QLineEdit(pc.hexs(getattr(r, attr)))
        e.setFont(socle_qt.font("mono"))
        e.setEnabled(not r.plugin.locked)

        def edited(text):
            v = pc.js_parse_hex(text)
            e.setStyleSheet(f"background-color: {socle_qt.c('danger-bg')};" if v is None else "")
            if v is None:
                return
            setattr(r, attr, v)
            self.win.set_dirty(r.plugin, L("{v} modifié (côte à côte)", v='FormID' if attr == 'id' else 'Flags'))
            if attr == "id":
                self.win.refresh_record_item(r)
            self.refresh_diff()

        e.textEdited.connect(edited)
        return e

    def _row(self, key, wa, wb, diff) -> int:
        i = self.table.rowCount()
        self.table.insertRow(i)
        k = QLabel(key)
        k.setFont(socle_qt.font("label-strong"))
        k.setStyleSheet(f"color: {socle_qt.c('text-muted')}; padding: 0 6px;")
        self.table.setCellWidget(i, 0, k)
        self.table.setCellWidget(i, 1, wa)
        self.table.setCellWidget(i, 2, wb)
        self._paint(i, diff)
        return i

    def _paint(self, i, diff):
        from PyQt6.QtGui import QBrush, QColor
        brush = QBrush(QColor(socle_qt.c("danger-bg"))) if diff else QBrush()
        for col in range(3):
            it = self.table.item(i, col)
            if it is None:
                it = QTableWidgetItem()
                it.setFlags(Qt.ItemFlag.NoItemFlags)
                self.table.setItem(i, col, it)
            it.setBackground(brush)
            w = self.table.cellWidget(i, col)
            if w is not None and not w.objectName():
                w.setObjectName(f"cell_{i}_{col}")
                base = w.styleSheet() or ""
                # Fond transparent : la couleur de la cellule (différence) reste visible
                w.setStyleSheet(f"#{w.objectName()} {{ {base} background: transparent; }}")

    def refresh_diff(self):
        a, b = self.a, self.b
        if not (a and b):
            return
        self._paint(self.id_row, a.id != b.id)
        self._paint(self.fl_row, a.flags != b.flags)
        for i, x in self.rows:
            self._paint(i, self.win.ws.decode_val(a, x["a"]) != self.win.ws.decode_val(b, x["b"]))

    def accept_drop(self, cell: CellEditor):
        r, s, win = cell.r, cell.s, self.win
        if win.locked(r.plugin):
            return
        cd = self.cell_drag
        if cd and cd["key"] == cell.key and cd["r"] is not r:
            nd, frm = bytes(cd["s"].d), cd["r"].plugin.name
            if len(nd) == 4 and cd["r"].plugin is not r.plugin:
                tgt = win.ws.resolve(cd["r"].plugin, pc.u32(nd))
                if tgt:
                    x = win.xref_with_master(tgt, r.plugin)
                    if x is None:
                        return
                    nd = pc.p32(x)
            if s:
                cell.set_data(nd, L("Copié {tag} depuis {frm} (côte à côte)", tag=cell.tag, frm=frm))
                self.redraw()
            else:
                r.subs.append(pc.Sub(cell.tag, nd))
                win.set_dirty(r.plugin, L("Copié {tag} depuis {frm} (côte à côte)", tag=cell.tag, frm=frm))
                self.redraw()
            return
        if win.drag_recs and (not s or len(s.d) == 4):
            x = win.xref_with_master(win.drag_recs[0], r.plugin)
            if x is None:
                return
            if s:
                cell.set_data(pc.p32(x), L("{t} défini sur {label} par glisser", t=s.t, label=pc.label(r)))
            else:
                r.subs.append(pc.Sub(cell.tag, pc.p32(x)))
                win.set_dirty(r.plugin, L("Ajouté {tag} à {label} par glisser", tag=cell.tag, label=pc.label(r)))
            self.redraw()


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.settings = QSettings(DATA_NAME, DATA_NAME)
        self.ws = pc.Workspace(confirm=self.ask, alert=self.alert)
        self.active: pc.Plugin | None = None
        self.cur: pc.Record | None = None
        self.drag_recs: list[pc.Record] = []
        self.clip: list = []
        self.recent: list[str] = []
        self.sort_mode = "file"
        self.type_filter: list[str] = []
        self.items: dict = {}
        self.plugin_items: dict = {}
        self.timers: dict = {}
        self.pins: set[str] = set(json.loads(self.settings.value("pins", "[]")))
        self.setWindowTitle(L("{APP} · éditeur ESP/ESM", APP=APP))
        self.resize(1280, 800)
        self.setAcceptDrops(True)
        self._build()
        self._menus()
        self.refresh_ws_menu()
        self.status()
        QTimer.singleShot(0, self.restore_session)

    # ------------------------------------------------------------------ UI
    def _build(self):
        central = QWidget()
        root = QVBoxLayout(central)
        root.setContentsMargins(socle_qt.m("space-3"), socle_qt.m("space-3"), socle_qt.m("space-3"), socle_qt.m("space-3"))
        root.setSpacing(socle_qt.m("space-2"))

        bar = QFrame()
        bar.setObjectName("HeaderBar")
        hb = QHBoxLayout(bar)
        hb.setContentsMargins(10, 6, 10, 6)
        hb.setSpacing(socle_qt.m("space-2"))
        hb.addWidget(socle_qt.role(QLabel(APP), "title"))
        self.btn_open = socle_qt.variant(small_button(L("Ouvrir des plugins"), self.open_dialog), "action")
        self.btn_open.setStyleSheet(f"min-height: {socle_qt.m('size-control') - 2}px;")
        hb.addWidget(self.btn_open)
        self.q = QLineEdit()
        self.q.setPlaceholderText(L("Rechercher un EditorID, un FormID ou un type"))
        self.q.setClearButtonEnabled(True)
        self.q.setMinimumWidth(260)
        self.q.textChanged.connect(lambda _: self.rebuild_tree())
        hb.addWidget(self.q)
        self.sortmode = QComboBox()
        self.sortmode.addItems([L("Ordre du fichier"), L("Tri : EditorID"), L("Tri : FormID")])
        self.sortmode.currentIndexChanged.connect(self.change_sort)
        hb.addWidget(self.sortmode)
        self.typefilter = QLineEdit()
        self.typefilter.setPlaceholderText(L("Filtrer les groupes : WEAP, ARMO…"))
        self.typefilter.setMaximumWidth(220)
        self.typefilter.textChanged.connect(self.change_filter)
        hb.addWidget(self.typefilter)
        # Statut : prend la place libre et se laisse rogner quand l'en-tête est serré
        self.st = socle_qt.role(QLabel(""), "meta")
        self.st.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Preferred)
        self.st.setAlignment(Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter)
        hb.addWidget(self.st, 1)
        self.btn_lang = LangButton(self.settings, self.language_changed)
        hb.addWidget(self.btn_lang)
        root.addWidget(bar)

        self.split = QSplitter(Qt.Orientation.Horizontal)
        self.split.setHandleWidth(8)
        self.tree = RecordTree(self)
        self.tree.itemExpanded.connect(self.expand_item)
        self.tree.itemClicked.connect(self.click_item)
        self.tree.currentItemChanged.connect(self.current_item)
        self.split.addWidget(self.tree)
        self.detail_scroll = QScrollArea()
        self.detail_scroll.setWidgetResizable(True)
        self.detail_scroll.setFrameShape(QFrame.Shape.NoFrame)
        self.split.addWidget(self.detail_scroll)
        self.split.setStretchFactor(1, 1)
        w = int(self.settings.value("tree_w", 0) or 0)
        self.split.setSizes([w or 460, 820])
        self.split.splitterMoved.connect(lambda *_: self.settings.setValue("tree_w", self.split.sizes()[0]))
        root.addWidget(self.split, 1)
        self.setCentralWidget(central)
        self.tree.setVisible(self.settings.value("notree", "0") != "1")
        self.empty_detail()

        QShortcut(QKeySequence("/"), self, activated=self.focus_search)
        QShortcut(QKeySequence(Qt.Key.Key_Backspace), self.tree, activated=self.delete_current)
        QShortcut(QKeySequence(Qt.Key.Key_Delete), self.tree, activated=self.delete_current)

    def _menus(self):
        mb = self.menuBar()

        def act(menu, text, slot, shortcut=None, checkable=False):
            a = QAction(text, self)
            if shortcut:
                a.setShortcut(QKeySequence(shortcut))
            a.setCheckable(checkable)
            a.triggered.connect(slot)
            menu.addAction(a)
            return a

        f = mb.addMenu(L("Fichier"))
        act(f, L("Ouvrir des plugins…"), self.open_dialog, "Ctrl+O")
        self.a_save = act(f, L("Enregistrer une copie…"), self.save_copy, "Ctrl+S")
        f.addSeparator()
        self.a_close = act(f, L("Fermer le plugin actif"), lambda: self.active and self.close_plugin(self.active), "Ctrl+W")
        self.a_lock = act(f, L("Verrouiller / déverrouiller le plugin actif"), lambda: self.active and self.toggle_lock(self.active))
        f.addSeparator()
        self.a_rem = act(f, L("Mémoriser les plugins entre les sessions"), self.toggle_remember, checkable=True)
        self.a_rem.setChecked(self.settings.value("remember", "1") == "1")

        e = mb.addMenu(L("Édition"))
        self.a_undo = act(e, L("Annuler la modification"), lambda: self.undo(True), "Ctrl+Z")
        self.a_redo = act(e, L("Rétablir"), lambda: self.undo(False), "Ctrl+Shift+Z")
        QShortcut(QKeySequence("Ctrl+Y"), self, activated=lambda: self.undo(False))
        e.addSeparator()
        self.a_copy = act(e, L("Copier les enregistrements"), self.copy_records)
        self.a_paste = act(e, L("Coller les enregistrements"), self.paste_records)
        e.addSeparator()
        self.a_newfl = act(e, L("Nouvelle FormList…"), self.new_formlist)

        t = mb.addMenu(L("Outils"))
        self.a_dup = act(t, L("Doublons…"), self.find_duplicates)
        self.a_cmp = act(t, L("Comparer deux plugins…"), self.compare_plugins)
        self.a_sbs = act(t, L("Comparer deux enregistrements…"), self.compare_records)
        self.a_stats = act(t, L("Statistiques…"), self.show_stats)
        self.a_log = act(t, L("Journal des modifications…"), self.show_log)

        v = mb.addMenu(L("Affichage"))
        self.a_tree = act(v, L("Afficher l'arbre"), self.toggle_tree, "Ctrl+T", checkable=True)
        self.a_tree.setChecked(self.tree.isVisible())

        self.ws_menu = mb.addMenu(L("Espaces de travail"))

    def focus_search(self):
        if not isinstance(QApplication.focusWidget(), (QLineEdit, QPlainTextEdit)):
            self.q.setFocus()
            self.q.selectAll()

    def toggle_tree(self):
        on = not self.tree.isVisible()
        self.tree.setVisible(on)
        self.a_tree.setChecked(on)
        self.settings.setValue("notree", "0" if on else "1")

    # ------------------------------------------------------- messages
    def ask(self, msg: str) -> bool:
        return QMessageBox.question(self, APP, msg) == QMessageBox.StandardButton.Yes

    def alert(self, msg: str) -> None:
        QMessageBox.warning(self, APP, msg)

    def flash(self, msg: str):
        self.st.setText(msg)
        QTimer.singleShot(2800, lambda: self.st.text() == msg and self.status())

    def locked(self, P: pc.Plugin | None) -> bool:
        if P and P.locked:
            self.flash(L("{name} est verrouillé : déverrouillez-le pour le modifier.", name=P.name))
            return True
        return False

    def status(self):
        P, n = self.active, len(self.ws.plugins)
        has = bool(n)
        for a in (self.a_save, self.a_newfl, self.a_copy, self.a_paste, self.a_dup, self.a_stats, self.a_sbs,
                  self.a_close, self.a_lock, self.a_log):
            a.setEnabled(has)
        for w in (self.q, self.sortmode, self.typefilter):
            w.setEnabled(has)
        self.a_cmp.setEnabled(n >= 2)
        self.a_undo.setEnabled(bool(P and (P.undo or P.pend)))
        self.a_redo.setEnabled(bool(P and P.redo))
        dirty = any(p.dirty for p in self.ws.plugins)
        socle_qt.status(self.st, "warning" if dirty else "none")
        if not n:
            self.st.setText(L("Aucun fichier chargé"))
        elif P:
            self.st.setText(L("{name} · {v:,} enregistrements · {n} maîtres", name=P.name, v=len(P.all) - 1, n=len(P.masters)).replace(",", " ")
                            + (L(" · modifié") if P.dirty else "") + (L(" · {n} plugins ouverts", n=n) if n > 1 else ""))
        else:
            self.st.setText(L("{n} plugins ouverts", n=n))

    # ------------------------------------------------------- modifications
    def set_dirty(self, P: pc.Plugin, msg: str | None = None):
        if pc.Workspace.mark_dirty(P, msg, time.strftime("%H:%M:%S")):
            pass
        t = self.timers.get(id(P))
        if t is None:
            t = QTimer(self)
            t.setSingleShot(True)
            t.timeout.connect(lambda P=P: (pc.Workspace.commit_base(P), self.status()))
            self.timers[id(P)] = t
        t.start(700)
        self.mark(P)
        self.persist(P)
        self.status()

    def mark(self, P: pc.Plugin):
        it = self.plugin_items.get(id(P))
        if it:
            self.paint_plugin_item(it, P)

    def xref_with_master(self, t: pc.Record, P: pc.Plugin) -> int | None:
        x = self.ws.xref(t, P)
        if "need" in x:
            if not self.ask(L("Ajouter {need} comme maître de {name} ?", need=x['need'], name=P.name)):
                return None
            self.ws.add_master(P, x["need"])
            x = self.ws.xref(t, P)
        return x["id"]

    def add_entries(self, fl: pc.Record, recs):
        P = fl.plugin
        if self.locked(P):
            return
        res = self.ws.add_entries(fl, recs)
        if res["changed"]:
            self.set_dirty(P, L("Ajouté {n} entrée(s) à {label}", n=res['n'], label=pc.label(fl)))
            self.refresh_ids(P)
            if self.cur and self.cur.plugin is P:
                self.show_record(self.cur)
        if res["warn"]:
            self.alert("\n\n".join(res["warn"]))
        self.flash(L("{n} enregistrement(s) ajouté(s) à {label}", n=res['n'], label=pc.label(fl))
                   + (L(" ({dup} déjà dans la liste)", dup=res['dup']) if res["dup"] else ""))

    # ------------------------------------------------------- arbre
    def rebuild_tree(self):
        expanded = self._expanded_nodes()
        self.tree.clear()
        self.items.clear()
        self.plugin_items.clear()
        q = self.q.text().strip()
        if q:
            recs, total = self.ws.search(q, self.sort_mode)
            for r in recs:
                self.tree.addTopLevelItem(self.record_item(r, show_plugin=len(self.ws.plugins) > 1))
            if total > 300:
                self._info_item(L("Seuls les 300 premiers résultats sont affichés. Affinez la recherche."))
            if not total:
                self._info_item(L("Aucun résultat"))
            return
        self._section(L("Récemment consultés"), self._recent_records(), clear=True)
        self._section(L("Épinglés"), self._pinned_records())
        for P in self.ws.plugins:
            self.plugin_item(P)
        self._restore_expanded(expanded)

    def _expanded_nodes(self) -> set:
        out = set()

        def walk(it):
            for i in range(it.childCount()):
                ch = it.child(i)
                if ch.isExpanded():
                    out.add(id(ch.data(0, ROLE)))
                    walk(ch)

        walk(self.tree.invisibleRootItem())
        return out

    def _restore_expanded(self, ids: set):
        def walk(it):
            for i in range(it.childCount()):
                ch = it.child(i)
                if id(ch.data(0, ROLE)) in ids:
                    ch.setExpanded(True)
                    walk(ch)

        walk(self.tree.invisibleRootItem())

    def _info_item(self, text: str, parent=None):
        it = QTreeWidgetItem([text])
        it.setFlags(Qt.ItemFlag.ItemIsEnabled)
        it.setForeground(0, self.tree.palette().placeholderText())
        (parent.addChild(it) if parent else self.tree.addTopLevelItem(it))
        it.setFirstColumnSpanned(True)
        return it

    def _section(self, title: str, recs: list, clear: bool = False):
        if not recs:
            return
        head = QTreeWidgetItem([title.upper()])
        head.setFont(0, socle_qt.font("eyebrow"))
        head.setForeground(0, self.tree.palette().placeholderText())
        head.setFlags(Qt.ItemFlag.ItemIsEnabled)
        head.setData(0, ROLE, title)
        self.tree.addTopLevelItem(head)
        head.setFirstColumnSpanned(True)
        if clear:
            btn = compact(small_button(L("Effacer"), self.clear_recent))
            wrap = QWidget()
            lay = QHBoxLayout(wrap)
            lay.setContentsMargins(0, 0, 4, 0)
            lay.addStretch(1)
            lay.addWidget(btn)
            self.tree.setItemWidget(head, 2, wrap)
            head.setFirstColumnSpanned(False)
            head.setSizeHint(0, QSize(0, wrap.sizeHint().height()))
        for r in recs:
            head.addChild(self.record_item(r, show_plugin=len(self.ws.plugins) > 1, register=False))
        head.setExpanded(True)

    def _recent_records(self):
        out = []
        for k in self.recent[:15]:
            name, _, hid = k.partition("|")
            P = next((p for p in self.ws.plugins if p.name == name), None)
            r = P and pc.by_id(P, int(hid, 16))
            if r:
                out.append(r)
        return out

    def _pinned_records(self):
        out = []
        for k in sorted(self.pins):
            name, _, hid = k.partition("|")
            P = next((p for p in self.ws.plugins if p.name == name), None)
            r = P and pc.by_id(P, int(hid, 16))
            if r:
                out.append(r)
        return out

    def clear_recent(self):
        self.recent = []
        self.rebuild_tree()

    def record_item(self, r: pc.Record, show_plugin: bool = False, register: bool = True) -> QTreeWidgetItem:
        it = QTreeWidgetItem([r.t, pc.edid(r), pc.hexs(r.id) + (f"   {r.plugin.name}" if show_plugin else "")])
        it.setData(0, ROLE, r)
        it.setFont(0, socle_qt.font("mono"))
        it.setFont(2, socle_qt.font("mono"))
        it.setForeground(0, self._brush("accent-text"))
        it.setForeground(2, self._brush("text-subtle"))
        it.setFlags(Qt.ItemFlag.ItemIsEnabled | Qt.ItemFlag.ItemIsSelectable | Qt.ItemFlag.ItemIsDragEnabled
                    | (Qt.ItemFlag.ItemIsDropEnabled if r.t == "FLST" else Qt.ItemFlag.NoItemFlags))
        if register:
            self.items[id(r)] = it
        return it

    def _brush(self, token):
        from PyQt6.QtGui import QBrush, QColor
        return QBrush(QColor(socle_qt.c(token)))

    def refresh_record_item(self, r: pc.Record):
        it = self.items.get(id(r))
        if it:
            it.setText(1, pc.edid(r))
            it.setText(2, pc.hexs(r.id))

    def refresh_ids(self, P: pc.Plugin):
        for r in P.all:
            self.refresh_record_item(r)

    def plugin_item(self, P: pc.Plugin):
        it = QTreeWidgetItem([""])
        it.setData(0, ROLE, P)
        it.setFlags(Qt.ItemFlag.ItemIsEnabled)
        it.setChildIndicatorPolicy(QTreeWidgetItem.ChildIndicatorPolicy.ShowIndicator)
        self.tree.addTopLevelItem(it)
        it.setFirstColumnSpanned(True)
        wrap = QWidget()
        lay = QHBoxLayout(wrap)
        lay.setContentsMargins(0, 0, 4, 0)
        lay.setSpacing(6)
        wrap._lab = QLabel("")
        wrap._lab.setFont(socle_qt.font("label-strong"))
        wrap._lock = small_button("", lambda: self.toggle_lock(P))
        wrap._close = small_button(L("Fermer"), lambda: self.close_plugin(P))
        for b in (wrap._lock, wrap._close):
            compact(b)
        lay.addWidget(wrap._lab, 1)
        lay.addWidget(wrap._lock)
        lay.addWidget(wrap._close)
        self.tree.setItemWidget(it, 0, wrap)
        it.setSizeHint(0, QSize(0, wrap.sizeHint().height()))
        it._wrap = wrap
        self.plugin_items[id(P)] = it
        self.paint_plugin_item(it, P)
        return it

    def paint_plugin_item(self, it, P: pc.Plugin):
        w = it._wrap
        w._lab.setText(P.name + (" •" if P.dirty else "") + (L("   (verrouillé)") if P.locked else ""))
        w._lock.setText(L("Déverrouiller") if P.locked else L("Verrouiller"))

    def expand_item(self, it: QTreeWidgetItem):
        node = it.data(0, ROLE)
        if it.childCount():
            return
        if isinstance(node, pc.Plugin):
            self.fill(it, pc.filtered_root(node, self.type_filter))
        elif isinstance(node, pc.Group):
            self.fill(it, node.kids)

    def fill(self, parent: QTreeWidgetItem, lst: list):
        items = lst
        if self.sort_mode != "file" and lst and all(n.k == "r" for n in lst):
            items = sorted(lst, key=pc.sort_key(self.sort_mode))
        for n in items:
            if n.k == "g":
                if not pc.has_records(n):
                    continue
                g = QTreeWidgetItem([pc.glabel(n)])
                g.setData(0, ROLE, n)
                g.setFlags(Qt.ItemFlag.ItemIsEnabled)
                g.setChildIndicatorPolicy(QTreeWidgetItem.ChildIndicatorPolicy.ShowIndicator)
                parent.addChild(g)
                g.setFirstColumnSpanned(True)
            else:
                parent.addChild(self.record_item(n))

    def click_item(self, it: QTreeWidgetItem, _col: int):
        node = it.data(0, ROLE)
        mods = QApplication.keyboardModifiers()
        if isinstance(node, pc.Plugin):
            it.setExpanded(not it.isExpanded())
            self.show_record(node.header)
        elif isinstance(node, pc.Group):
            it.setExpanded(not it.isExpanded())
        elif isinstance(node, pc.Record) and not (mods & (Qt.KeyboardModifier.ShiftModifier | Qt.KeyboardModifier.ControlModifier | Qt.KeyboardModifier.MetaModifier)):
            self.show_record(node)
        n = len([x for x in self.tree.selectedItems() if isinstance(x.data(0, ROLE), pc.Record)])
        if n > 1:
            self.flash(L("{n} enregistrements sélectionnés. Glissez-les sur une FormList.", n=n))

    def current_item(self, it, _prev):
        if it is None:
            return
        node = it.data(0, ROLE)
        if isinstance(node, pc.Record) and node is not self.cur and len(self.tree.selectedItems()) <= 1:
            self.show_record(node, select=False)

    def selected_records(self) -> list[pc.Record]:
        return [it.data(0, ROLE) for it in self.tree.selectedItems() if isinstance(it.data(0, ROLE), pc.Record)]

    def change_sort(self, i):
        self.sort_mode = ["file", "edid", "formid"][i]
        self.rebuild_tree()

    def change_filter(self, text):
        self.type_filter = [x.strip().upper() for x in text.split(",") if x.strip()]
        self.rebuild_tree()

    # ------------------------------------------------------- détail
    def empty_detail(self, text: str | None = None):
        self._empty_text = text
        w = QWidget()
        lay = QVBoxLayout(w)
        lay.addStretch(1)
        if text:
            lay.addWidget(socle_qt.role(QLabel(text), "muted"), alignment=Qt.AlignmentFlag.AlignCenter)
        else:
            card = QFrame()
            card.setProperty("panel", "true")
            cl = QVBoxLayout(card)
            cl.setContentsMargins(32, 32, 32, 32)
            t = socle_qt.role(QLabel(L("Glissez un ou plusieurs fichiers .ESP, .ESM ou .ESL ici")), "display")
            t.setAlignment(Qt.AlignmentFlag.AlignCenter)
            m = socle_qt.role(QLabel(L("Tout est analysé localement. Aucune installation de Skyrim n'est nécessaire.")), "muted")
            m.setAlignment(Qt.AlignmentFlag.AlignCenter)
            cl.addWidget(t)
            cl.addWidget(m)
            b = socle_qt.variant(small_button(L("Ouvrir des plugins"), self.open_dialog), "action")
            cl.addWidget(b, alignment=Qt.AlignmentFlag.AlignCenter)
            lay.addWidget(card, alignment=Qt.AlignmentFlag.AlignCenter)
        lay.addStretch(2)
        self.detail_scroll.setWidget(w)

    def touch_recent(self, r: pc.Record):
        k = f"{r.plugin.name}|{pc.hexs(r.id)}"
        self.recent = [k] + [x for x in self.recent if x != k]
        del self.recent[15:]

    def show_record(self, r: pc.Record, select: bool = True):
        self.cur, self.active = r, r.plugin
        self.touch_recent(r)
        self.status()
        if select:
            it = self.items.get(id(r))
            if it:
                self.tree.blockSignals(True)
                self.tree.setCurrentItem(it)
                self.tree.scrollToItem(it)
                self.tree.blockSignals(False)
        P = r.plugin
        page = QWidget()
        lay = QVBoxLayout(page)
        lay.setContentsMargins(20, 16, 20, 16)
        lay.setSpacing(8)
        if P.locked:
            ban = QLabel(L("{name} est verrouillé. Déverrouillez-le depuis l'arbre pour le modifier.", name=P.name))
            ban.setStyleSheet(f"background: {socle_qt.c('warning-bg')}; color: {socle_qt.c('warning-soft')}; "
                              f"border: 1px solid {socle_qt.c('warning-border')}; border-radius: 4px; padding: 6px 10px;")
            lay.addWidget(ban)
        title = socle_qt.role(QLabel(f"{r.t}  {pc.edid(r)}"), "heading")
        title.setTextInteractionFlags(Qt.TextInteractionFlag.TextSelectableByMouse)
        lay.addWidget(title)
        hd = QHBoxLayout()
        hd.setSpacing(16)
        self._id_inp = self._hex_field(hd, L("FormID (hex)"), r.id, lambda v: (setattr(r, "id", v), self.refresh_record_item(r)))
        self._flag_inp = self._hex_field(hd, L("Flags (hex)"), r.flags, lambda v: (setattr(r, "flags", v), self._sync_flags(r)))
        hd.addStretch(1)
        lay.addLayout(hd)
        lay.addWidget(socle_qt.role(QLabel(L("{name} · Propriétaire : {owner}", name=P.name, owner=pc.owner(r.id, P))), "meta"))
        btns = QHBoxLayout()
        ro = []
        ro.append(small_button(L("Ajouter un sous-enregistrement"), lambda: self.add_sub(r)))
        ro.append(small_button(L("Cloner"), lambda: self.clone_record(r)))
        ro.append(small_button(L("Supprimer"), lambda: self.delete_record(r)))
        for b in ro:
            b.setEnabled(not P.locked)
            btns.addWidget(b)
        self._pin_btn = small_button(L("Désépingler") if self.is_pinned(r) else L("Épingler"), lambda: self.toggle_pin(r))
        btns.addWidget(self._pin_btn)
        btns.addWidget(small_button(L("Où est-il utilisé ?"), lambda: self.where_used(r)))
        btns.addStretch(1)
        lay.addLayout(btns)

        flags = QHBoxLayout()
        flags.setSpacing(18)
        self._flag_boxes = []
        for bit, name in (pc.TES4FLAGS if r.t == "TES4" else pc.RFLAGS):
            cb = QCheckBox(L(name))
            cb.setChecked(bool(r.flags & bit))
            cb.setEnabled(not P.locked)
            cb.toggled.connect(lambda on, bit=bit, name=name: self.set_flag(r, bit, name, on))
            flags.addWidget(cb)
            self._flag_boxes.append((bit, cb))
        flags.addStretch(1)
        lay.addLayout(flags)

        if r.t == "FLST":
            lay.addWidget(self.fl_panel(r))
        if r.t == "GLOB":
            lay.addWidget(self.glob_panel(r))
        if any(x.t in ("KSIZ", "KWDA") for x in r.subs):
            lay.addWidget(self.kwda_panel(r))

        def skip(s):
            return ((r.t == "FLST" and s.t == "LNAM") or (r.t == "GLOB" and s.t in ("FNAM", "FLTV"))
                    or s.t in ("KSIZ", "KWDA"))

        for s in r.subs:
            if not skip(s):
                ed = SubEditor(self, r, s)
                ed.setEnabled(not P.locked)
                lay.addWidget(ed)
        lay.addStretch(1)
        self.detail_scroll.setWidget(page)

    def _hex_field(self, row, name, value, fn):
        box = QVBoxLayout()
        box.addWidget(socle_qt.role(QLabel(name), "subtle"))
        inp = QLineEdit(pc.hexs(value))
        inp.setFont(socle_qt.font("mono"))
        inp.setFixedWidth(zw(130))
        inp.setEnabled(not (self.cur and self.cur.plugin.locked))

        def edited(text):
            v = pc.js_parse_hex(text)
            inp.setStyleSheet(f"background-color: {socle_qt.c('danger-bg')};" if v is None else "")
            if v is None:
                return
            fn(v)
            self.set_dirty(self.cur.plugin)

        inp.textEdited.connect(edited)
        box.addWidget(inp)
        row.addLayout(box)
        return inp

    def _sync_flags(self, r):
        for bit, cb in self._flag_boxes:
            cb.blockSignals(True)
            cb.setChecked(bool(r.flags & bit))
            cb.blockSignals(False)

    def set_flag(self, r, bit, name, on):
        if self.locked(r.plugin):
            return
        r.flags = (r.flags | bit) if on else (r.flags & ~bit) & 0xFFFFFFFF
        self._flag_inp.setText(pc.hexs(r.flags))
        self.set_dirty(r.plugin, L("{v} « {name} » sur {label}", v=L("Activé") if on else L("Désactivé"), name=L(name), label=pc.label(r)))

    def add_sub(self, r):
        if self.locked(r.plugin):
            return
        t, ok = QInputDialog.getText(self, APP, L("Type de sous-enregistrement (quatre caractères, ex. FULL) :"))
        t = t.strip()
        if not ok or len(t) != 4:
            return
        r.subs.append(pc.Sub(t, b""))
        self.set_dirty(r.plugin, L("Ajouté {t} à {label}", t=t, label=pc.label(r)))
        self.show_record(r)

    def clone_record(self, r):
        if self.locked(r.plugin):
            return
        c = self.ws.clone_record(r)
        if not c:
            return
        self.set_dirty(r.plugin, L("Cloné {label} en {hexs}", label=pc.label(r), hexs=pc.hexs(c.id)))
        it = self.items.get(id(r))
        if it and it.parent():
            p = it.parent()
            p.insertChild(p.indexOfChild(it) + 1, self.record_item(c))
        self.show_record(c)
        self.flash(L("Cloné en {hexs}", hexs=pc.hexs(c.id)))

    def delete_record(self, r):
        P = r.plugin
        if self.locked(P) or r is P.header:
            return
        if not self.ask(L("Supprimer cet enregistrement ? Les enregistrements qui y font référence seront cassés.")):
            return
        self.ws.delete_record(r)
        it = self.items.pop(id(r), None)
        if it:
            (it.parent() or self.tree.invisibleRootItem()).removeChild(it)
        self.set_dirty(P, L("Supprimé {t} {label}", t=r.t, label=pc.label(r)))
        self.cur = None
        self.empty_detail(L("Enregistrement supprimé."))

    def delete_current(self):
        if self.cur and self.cur is not self.cur.plugin.header:
            self.delete_record(self.cur)

    # -- panneaux spécialisés
    def _panel(self, title: str, on_drop=None) -> tuple[QFrame, QVBoxLayout]:
        fr = DropFrame(on_drop) if on_drop else QFrame()
        fr.setProperty("panel", "true")
        lay = QVBoxLayout(fr)
        lay.setContentsMargins(10, 8, 10, 8)
        lay.addWidget(socle_qt.role(QLabel(title), "title"))
        return fr, lay

    def fl_panel(self, r):
        P = r.plugin
        ents = self.ws.fl_entries(r)
        fr, lay = self._panel(L("Entrées ({n}). Glissez des enregistrements depuis l'arbre, y compris d'autres plugins ouverts.", n=len(ents)),
                              lambda: (not self.locked(P)) and self.drag_recs and self.add_entries(r, self.drag_recs))
        tools = QHBoxLayout()

        def set_l(lst, msg=None):
            if self.locked(P):
                return
            k = self.ws.fl_set(r, lst)
            self.set_dirty(P, msg or L("Entrées réordonnées dans {label}", label=pc.label(r)))
            self.show_record(r)
            if k > 0:
                self.flash(L("{k} entrée(s) retirée(s)", k=k))

        tools.addWidget(small_button(L("Importer…"), lambda: self.import_list(r), not P.locked))
        tools.addWidget(small_button(L("Exporter…"), lambda: self.export_list(r)))
        tools.addWidget(small_button(L("Trier par nom"), lambda: set_l(self.ws.fl_sorted_by_name(r)), not P.locked))
        tools.addWidget(small_button(L("Trier par FormID"), lambda: set_l(self.ws.fl_sorted_by_formid(r)), not P.locked))
        tools.addWidget(small_button(L("Retirer les doublons"), lambda: set_l(self.ws.fl_deduped(r), L("Doublons retirés de {label}", label=pc.label(r))), not P.locked))
        tools.addWidget(small_button(L("Retirer les entrées cassées"), lambda: set_l(self.ws.fl_without_broken(r), L("Entrées cassées retirées de {label}", label=pc.label(r))), not P.locked))
        tools.addStretch(1)
        lay.addLayout(tools)
        if not ents:
            lay.addWidget(socle_qt.role(QLabel(L("Vide. Déposez des enregistrements ici.")), "muted"))
        for i, s in enumerate(ents):
            v = pc.lnam(s)
            t = self.ws.resolve(P, v)
            row = QHBoxLayout()
            ix = mono_label(f"{i + 1}.", "text-subtle")
            ix.setFixedWidth(zw(36))
            ix.setAlignment(Qt.AlignmentFlag.AlignRight)
            row.addWidget(ix)
            row.addWidget(mono_label(L("invalide") if v is None else pc.hexs(v)))
            if v is None:
                txt = L("L'entrée ne fait pas 4 octets")
            elif t:
                txt = f"{t.t}  {pc.edid(t)}" + (f"  ({t.plugin.name})" if t.plugin is not P else "")
            elif v >> 24 < len(P.masters):
                txt = L("de {v} (non ouvert)", v=P.masters[v >> 24])
            else:
                txt = L("introuvable dans ce fichier")
            nm = QPushButton(txt) if t else QLabel(txt)
            if t:
                nm.setFlat(True)
                nm.setStyleSheet("text-align: left; border: none; background: transparent; padding: 0;")
                nm.setCursor(Qt.CursorShape.PointingHandCursor)
                nm.clicked.connect(lambda _=False, t=t: self.show_record(t))
            row.addWidget(nm, 1)

            def mv(j, s=s):
                a, z = r.subs.index(s), r.subs.index(ents[j])
                r.subs[a], r.subs[z] = r.subs[z], r.subs[a]
                self.set_dirty(P)
                self.show_record(r)

            def rm(_=False, s=s):
                r.subs.remove(s)
                self.set_dirty(P)
                self.show_record(r)

            row.addWidget(small_button(L("Monter"), lambda _=False, i=i: mv(i - 1), i > 0 and not P.locked))
            row.addWidget(small_button(L("Descendre"), lambda _=False, i=i: mv(i + 1), i < len(ents) - 1 and not P.locked))
            row.addWidget(small_button(L("Retirer"), rm, not P.locked))
            lay.addLayout(row)
        return fr

    def import_list(self, r):
        if self.locked(r.plugin):
            return
        d = TextDialog(self, L("Importer dans {label}", label=pc.label(r)), "", "Importer",
                       L("Un EditorID ou un FormID hexadécimal à 8 chiffres par ligne. Les FormID suivent la numérotation de ce plugin. Les lignes commençant par # sont ignorées."))
        if not d.exec():
            return
        res = self.ws.import_list(r, d.ed.toPlainText())
        if res["changed"]:
            self.set_dirty(r.plugin, L("Ajouté {n} entrée(s) à {label}", n=res['n'], label=pc.label(r)))
        elif res["raw"]:
            self.set_dirty(r.plugin, L("Importé {raw} entrée(s) brute(s) dans {label}", raw=res['raw'], label=pc.label(r)))
        if res["warn"]:
            self.alert("\n\n".join(res["warn"]))
        self.show_record(r)
        self.flash(L("{v} entrée(s) ajoutée(s)", v=res['n'] + res['raw']))
        if res["bad"]:
            bad = res["bad"]
            self.alert(L("Introuvables ({n}) :\n", n=len(bad)) + "\n".join(bad[:30]) + ("\n…" if len(bad) > 30 else ""))

    def export_list(self, r):
        TextDialog(self, L("Exporter {label}", label=pc.label(r)), self.ws.export_list(r), "Fermer",
                   L("EditorID quand il est connu, sinon FormID hexadécimal."), read_only=True).exec()

    def glob_panel(self, r):
        P = r.plugin
        fr, lay = self._panel(L("Variable globale"))
        row = QHBoxLayout()
        row.addWidget(QLabel(L("Type")))
        tsel = QComboBox()
        for v, t in (("s", "Short"), ("l", "Long"), ("f", "Float")):
            tsel.addItem(t, v)
        tsel.setCurrentIndex(max(0, tsel.findData(self.ws.glob_type(r))))
        tsel.setEnabled(not P.locked)

        def tchange(_):
            if self.locked(P):
                return
            self.ws.set_glob_type(r, tsel.currentData())
            self.set_dirty(P, L("Type modifié pour {label}", label=pc.label(r)))

        tsel.currentIndexChanged.connect(tchange)
        row.addWidget(tsel)
        row.addWidget(QLabel(L("Valeur")))
        v = self.ws.glob_value(r)
        vin = QLineEdit("" if v is None else repr(v) if v != int(v) else str(int(v)) if abs(v) < 1e15 else repr(v))
        vin.setFixedWidth(zw(140))
        vin.setEnabled(not P.locked)

        def vchange(text):
            if self.locked(P):
                return
            f = pc.js_parse_float(text)
            if f is None:
                return
            self.ws.set_glob_value(r, f)
            self.set_dirty(P, L("Valeur modifiée pour {label}", label=pc.label(r)))

        vin.textEdited.connect(vchange)
        row.addWidget(vin)
        row.addStretch(1)
        lay.addLayout(row)
        lay.addWidget(socle_qt.role(QLabel(L("Toutes les globales stockent leur valeur en flottant, quel que soit leur type.")), "meta"))
        return fr

    def kwda_panel(self, r):
        P = r.plugin
        ids = self.ws.keywords(r)

        def setv(lst, msg=None):
            if self.locked(P):
                return
            self.ws.set_keywords(r, lst)
            self.set_dirty(P, msg or L("Mots-clés modifiés sur {label}", label=pc.label(r)))
            self.show_record(r)

        def drop():
            if self.locked(P) or not self.drag_recs:
                return
            lst = self.ws.keywords(r)
            n = 0
            for src in self.drag_recs:
                x = self.ws.xref(src, P)
                if "need" in x:
                    continue
                if x["id"] not in lst:
                    lst.append(x["id"])
                    n += 1
            if n:
                setv(lst, L("Ajouté {n} mot(s)-clé(s) à {label}", n=n, label=pc.label(r)))

        fr, lay = self._panel(L("Mots-clés ({n})", n=len(ids)), drop)
        for i, v in enumerate(ids):
            t = self.ws.resolve(P, v)
            row = QHBoxLayout()
            row.addWidget(mono_label(pc.hexs(v)))
            txt = (pc.edid(t) or t.t) if t else (L("de {master}", master=P.masters[v >> 24]) if v >> 24 < len(P.masters) else L("introuvable"))
            nm = QPushButton(txt) if t else QLabel(txt)
            if t:
                nm.setFlat(True)
                nm.setStyleSheet("text-align: left; border: none; background: transparent; padding: 0;")
                nm.clicked.connect(lambda _=False, t=t: self.show_record(t))
            row.addWidget(nm, 1)

            def rm(_=False, i=i):
                lst = self.ws.keywords(r)
                lst.pop(i)
                setv(lst, L("Mot-clé retiré de {label}", label=pc.label(r)))

            row.addWidget(small_button(L("Retirer"), rm, not P.locked))
            lay.addLayout(row)

        def add():
            t = PickDialog.get(self, "Choisissez un enregistrement KYWD.")
            if not t:
                return
            x = self.xref_with_master(t, P)
            if x is None:
                return
            lst = self.ws.keywords(r)
            if x in lst:
                return self.flash(L("Ce mot-clé est déjà présent"))
            lst.append(x)
            setv(lst, L("Mot-clé ajouté à {label}", label=pc.label(r)))

        lay.addWidget(small_button(L("Ajouter un mot-clé…"), add, not P.locked), alignment=Qt.AlignmentFlag.AlignLeft)
        return fr

    # ------------------------------------------------------- épingles
    def pin_key(self, r):
        return f"{r.plugin.name}|{pc.hexs(r.id)}"

    def is_pinned(self, r):
        return self.pin_key(r) in self.pins

    def toggle_pin(self, r):
        k = self.pin_key(r)
        self.pins.symmetric_difference_update({k})
        self.settings.setValue("pins", json.dumps(sorted(self.pins)))
        self._pin_btn.setText(L("Désépingler") if self.is_pinned(r) else L("Épingler"))
        if not self.q.text().strip():
            self.rebuild_tree()

    # ------------------------------------------------------- fichiers
    def open_dialog(self):
        files, _ = QFileDialog.getOpenFileNames(self, L("Ouvrir des plugins"), self.settings.value("lastdir", ""),
                                                L("Plugins Skyrim (*.esp *.esm *.esl)"))
        if files:
            self.settings.setValue("lastdir", os.path.dirname(files[0]))
            self.load_files(files)

    def dragEnterEvent(self, e):
        if e.mimeData().hasUrls():
            e.acceptProposedAction()

    def dropEvent(self, e):
        self.load_files([u.toLocalFile() for u in e.mimeData().urls()])

    def load_files(self, paths):
        for p in paths:
            if p.lower().endswith((".esp", ".esm", ".esl")):
                try:
                    with open(p, "rb") as f:
                        self.load(os.path.basename(p), f.read())
                except OSError as e:
                    self.alert(L("Impossible de lire {basename} : {strerror}", basename=os.path.basename(p), strerror=e.strerror))

    def load(self, name: str, data: bytes, dirty: bool = False, t: float | None = None, persist: bool = True):
        if self.ws.find(name):
            return self.flash(L("{name} est déjà ouvert", name=name))
        self.st.setText(L("Analyse de {name}…", name=name))
        self.st.repaint()  # pas de processEvents : il permettrait un second chargement en parallèle
        try:
            P = pc.load_plugin(name, data, dirty=dirty, t=t or time.time())
        except Exception as e:
            self.st.setText(L("Impossible de lire {name} : {e}", name=name, e=e))
            socle_qt.status(self.st, "danger")
            return None
        self.ws.plugins.append(P)
        self.active = P
        if self.q.text().strip():
            self.rebuild_tree()
            self.show_record(P.header)
        else:
            it = self.plugin_item(P)
            it.setExpanded(True)
            self.show_record(P.header)
        self.status()
        if persist:
            self.persist(P)
        return P

    def save_copy(self):
        P = self.active
        if not P:
            return
        path, _ = QFileDialog.getSaveFileName(self, L("Enregistrer une copie"), os.path.join(self.settings.value("lastdir", ""), P.name),
                                              L("Plugins Skyrim (*.esp *.esm *.esl)"))
        if not path:
            return
        self.ws.fix_hedr(P)
        try:
            with open(path, "wb") as f:
                f.write(pc.serialize(P))
        except OSError as e:
            return self.alert(L("Impossible d'enregistrer : {strerror}. Vérifiez les droits d'écriture du dossier.", strerror=e.strerror))
        self.settings.setValue("lastdir", os.path.dirname(path))
        P.dirty = False
        self.mark(P)
        self.status()
        self.persist(P)
        self.flash(L("Copie de {name} enregistrée", name=P.name))

    def close_plugin(self, P: pc.Plugin, ask: bool = True) -> bool:
        if ask and P.dirty:
            others = len([q for q in self.ws.plugins if q is not P and q.dirty])
            msg = L("{name} a des modifications non enregistrées. Le fermer quand même ?", name=P.name)
            if others:
                msg += L(" ({others} autre(s) plugin(s) ont aussi des modifications non enregistrées.)", others=others)
            if not self.ask(msg):
                return False
        self._session_remove(P.name)
        self.ws.plugins.remove(P)
        if self.active is P:
            self.active = self.ws.plugins[0] if self.ws.plugins else None
        self.recent = [k for k in self.recent if not k.startswith(P.name + "|")]
        if self.cur and self.cur.plugin is P:
            self.cur = None
            self.empty_detail(L("Plugin fermé."))
        self.rebuild_tree()
        self.status()
        return True

    def toggle_lock(self, P: pc.Plugin):
        P.locked = not P.locked
        self.mark(P)
        self.flash(L("{name} verrouillé", name=P.name) if P.locked else L("{name} déverrouillé", name=P.name))
        if self.cur and self.cur.plugin is P:
            self.show_record(self.cur)

    def language_changed(self):
        """La nouvelle langue s'applique au prochain lancement : propose de relancer tout de suite."""
        if not self.ask(L("La langue sera appliquée au prochain lancement de {app}. Relancer maintenant ?", app=APP)):
            return
        args = sys.argv[1:] if getattr(sys, "frozen", False) else sys.argv
        if self.close():
            QProcess.startDetached(sys.executable, args)

    def closeEvent(self, e):
        dirty = [p.name for p in self.ws.plugins if p.dirty]
        if dirty and not self.a_rem.isChecked():
            if not self.ask(L("Des plugins ont des modifications non enregistrées :\n") + "\n".join(dirty) + L("\n\nQuitter quand même ?")):
                e.ignore()
                return
        for t in self.timers.values():
            t.stop()
        for P in self.ws.plugins:
            self._session_write(P)
        e.accept()

    # ------------------------------------------------------- session (mémoriser les plugins)
    def toggle_remember(self):
        on = self.a_rem.isChecked()
        self.settings.setValue("remember", "1" if on else "0")
        if on:
            for P in self.ws.plugins:
                self.persist(P)
        else:
            for name in self._session_index():
                self._session_remove(name)

    def _session_index(self) -> dict:
        try:
            with open(os.path.join(SESSION_DIR, "index.json"), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError):
            return {}

    def _session_save_index(self, idx: dict):
        os.makedirs(SESSION_DIR, exist_ok=True)
        with open(os.path.join(SESSION_DIR, "index.json"), "w", encoding="utf-8") as f:
            json.dump(idx, f)

    def _session_file(self, name: str) -> str:
        return os.path.join(SESSION_DIR, name.replace("/", "_"))

    def persist(self, P: pc.Plugin):
        if not self.a_rem.isChecked():
            return
        key = ("persist", id(P))
        t = self.timers.get(key)
        if t is None:
            t = QTimer(self)
            t.setSingleShot(True)
            t.timeout.connect(lambda P=P: P in self.ws.plugins and self._session_write(P))
            self.timers[key] = t
        t.start(600)

    def _session_write(self, P: pc.Plugin):
        if not self.a_rem.isChecked():
            return
        os.makedirs(SESSION_DIR, exist_ok=True)
        with open(self._session_file(P.name), "wb") as f:
            f.write(pc.serialize(P))
        idx = self._session_index()
        idx[P.name] = {"t": P.t, "dirty": P.dirty}
        self._session_save_index(idx)

    def _session_remove(self, name: str):
        idx = self._session_index()
        if name in idx:
            del idx[name]
            self._session_save_index(idx)
        try:
            os.remove(self._session_file(name))
        except OSError:
            pass

    def _session_load(self, name: str, meta: dict) -> pc.Plugin | None:
        try:
            with open(self._session_file(name), "rb") as f:
                data = f.read()
        except OSError:
            return None
        return self.load(name, data, dirty=meta.get("dirty", False), t=meta.get("t"), persist=False)

    def restore_session(self):
        if not self.a_rem.isChecked():
            return
        rows = sorted(self._session_index().items(), key=lambda kv: kv[1].get("t", 0))
        n = sum(1 for name, meta in rows if self._session_load(name, meta))
        if n:
            self.flash(L("{n} plugin(s) restauré(s) depuis votre dernière session", n=n))

    # ------------------------------------------------------- espaces de travail
    def _workspaces(self) -> dict:
        try:
            return json.loads(self.settings.value("workspaces", "{}"))
        except ValueError:
            return {}

    def refresh_ws_menu(self):
        m = self.ws_menu
        m.clear()
        save = QAction(L("Enregistrer l'espace de travail…"), self)
        save.triggered.connect(self.save_workspace)
        m.addAction(save)
        wss = self._workspaces()
        if wss:
            m.addSeparator()
        for name in wss:
            a = QAction(name, self)
            a.triggered.connect(lambda _=False, n=name: self.load_workspace(n))
            m.addAction(a)

    def save_workspace(self):
        if not self.ws.plugins:
            return self.flash(L("Ouvrez d'abord des plugins"))
        name, ok = QInputDialog.getText(self, APP, L("Nom de l'espace de travail (les plugins ouverts) :"))
        name = name.strip()
        if not ok or not name:
            return
        wss = self._workspaces()
        wss[name] = {"plugins": [P.name for P in self.ws.plugins]}
        self.settings.setValue("workspaces", json.dumps(wss))
        self.refresh_ws_menu()
        self.flash(L("Espace de travail « {name} » enregistré", name=name))

    def load_workspace(self, name: str):
        ws = self._workspaces().get(name)
        if not ws:
            return
        for P in [P for P in self.ws.plugins if P.name not in ws["plugins"]]:
            self.close_plugin(P)
        idx, missing = self._session_index(), []
        for nm in ws["plugins"]:
            if self.ws.find(nm):
                continue
            if nm not in idx or not self._session_load(nm, idx[nm]):
                missing.append(nm)
        if missing:
            self.alert(L("Ces plugins font partie de « {name} » mais ne sont pas mémorisés : rouvrez-les manuellement.\n", name=name)
                       + "\n".join(missing))
        self.flash(L("Espace de travail « {name} » chargé", name=name))

    # ------------------------------------------------------- édition
    def undo(self, back: bool):
        fw = QApplication.focusWidget()
        if isinstance(fw, (QLineEdit, QPlainTextEdit)):
            (fw.undo() if back else fw.redo())
            return
        P = self.active
        if not P or self.locked(P):
            return
        t = self.timers.get(id(P))
        if t:
            t.stop()
        key = (self.cur.id, self.cur.t) if self.cur and self.cur.plugin is P else None
        if not pc.Workspace.undo_redo(P, back):
            return
        self.rebuild_tree()
        r = next((x for x in P.all if key and x.id == key[0] and x.t == key[1]), None)
        if r:
            self.show_record(r)
        elif key:
            self.cur = None
            self.empty_detail(L("Aucune sélection."))
        self.mark(P)
        self.persist(P)
        self.status()
        self.flash(L("Dernière modification annulée") if back else L("Modification rétablie"))

    def copy_records(self):
        recs = self.selected_records() or ([self.cur] if self.cur else [])
        clip, skipped = self.ws.copy_records(recs)
        if not clip:
            return self.flash(L("Seuls les enregistrements de premier niveau peuvent être copiés, pas le contenu des cellules")
                              if recs else L("Sélectionnez d'abord des enregistrements"))
        self.clip = clip
        self.flash(L("{n} enregistrement(s) copié(s)", n=len(clip)) + (L(" ({skipped} ignoré(s))", skipped=skipped) if skipped else ""))

    def paste_records(self):
        P = self.active
        if not P or self.locked(P):
            return
        if not self.clip:
            return self.flash(L("Rien n'a encore été copié"))
        res = self.ws.paste_records(P, self.clip)
        if res["changed"]:
            self.set_dirty(P, L("Collé {n} enregistrement(s)", n=res['n']))
            self.rebuild_tree()
            it = self.plugin_items.get(id(P))
            if it:
                it.setExpanded(True)
            self.flash(L("{n} enregistrement(s) collé(s) dans {name}", n=res['n'], name=P.name))
        if res["warn"]:
            self.alert("\n\n".join(res["warn"]))

    def new_formlist(self):
        P = self.active
        if not P or self.locked(P):
            return
        name, ok = QInputDialog.getText(self, APP, L("EditorID de la nouvelle FormList dans {name} :", name=P.name))
        name = name.strip()
        if not ok or not name:
            return
        if any(pc.edid(r) == name for r in P.all) and not self.ask(L("Un enregistrement porte déjà cet EditorID. Créer quand même ?")):
            return
        r = self.ws.new_formlist(P, name)
        if not r:
            return
        self.set_dirty(P)
        self.q.clear()
        self.rebuild_tree()
        pit = self.plugin_items.get(id(P))
        if pit:
            pit.setExpanded(True)
            for i in range(pit.childCount()):
                g = pit.child(i)
                if g.data(0, ROLE) is r.parent or (isinstance(g.data(0, ROLE), pc.Group) and g.data(0, ROLE).kids is r.parent):
                    g.setExpanded(True)
        self.show_record(r)

    # ------------------------------------------------------- outils
    def where_used(self, r):
        d = ListDialog(self, L("Où est utilisé : {label}", label=pc.label(r)),
                       L("Heuristique : tout sous-enregistrement de 4 octets dont la valeur égale ce FormID (renuméroté pour chaque plugin). Peut inclure des faux positifs et ignore les champs qui ne font pas 4 octets."))
        hits = self.ws.where_used(r)
        many = len(self.ws.plugins) > 1
        for rec, s in hits:
            d.record(rec, f"  ·{s.t}" + (f"  ({rec.plugin.name})" if many else ""))
        if not hits:
            d.message(L("Aucun enregistrement ouvert n'a de champ de 4 octets égal à ce FormID."))
        d.exec()

    def find_duplicates(self):
        dup_i, dup_e = self.ws.find_duplicates()
        d = ListDialog(self, "Doublons", L("Des FormID en double dans un même plugin sont invalides et doivent être corrigés. Des EditorID partagés entre plugins sont souvent normaux (surcharges)."))
        if dup_i:
            d.section(L("FORMID EN DOUBLE DANS UN PLUGIN"))
            for l in dup_i:
                for r in l:
                    d.record(r, f"  ({r.plugin.name})")
        if dup_e:
            d.section(L("EDITORID PARTAGÉS (MÊME NOM, ENREGISTREMENTS DIFFÉRENTS)"))
            for l in dup_e:
                for r in l:
                    d.record(r, f"  ({r.plugin.name})")
        if not dup_i and not dup_e:
            d.message(L("Aucun EditorID ni FormID en double dans les plugins ouverts."))
        d.exec()

    def compare_plugins(self):
        if len(self.ws.plugins) < 2:
            return self.flash(L("Ouvrez au moins deux plugins pour les comparer"))
        d = ListDialog(self, L("Comparer deux plugins"),
                       L("Associe les enregistrements par type et EditorID : idéal pour deux versions d'un même plugin."))
        sa, sb = QComboBox(), QComboBox()
        for s in (sa, sb):
            s.addItems([P.name for P in self.ws.plugins])
        sb.setCurrentIndex(min(1, len(self.ws.plugins) - 1))

        def go():
            d.lst.clear()
            A, B = self.ws.plugins[sa.currentIndex()], self.ws.plugins[sb.currentIndex()]
            if A is B:
                return d.message(L("Choisissez deux plugins différents."))
            added, removed, changed = self.ws.compare_plugins(A, B)
            for title, lst in ((L("Seulement dans {name}", name=B.name), added), (L("Seulement dans {name}", name=A.name), removed),
                               (L("Modifiés (même EditorID, sous-enregistrements différents)"), changed)):
                if lst:
                    d.section(f"{title.upper()} ({len(lst)})")
                    for r in lst[:200]:
                        d.record(r)
            if not (added or removed or changed):
                d.message(L("Aucune différence trouvée par EditorID."))

        d.top.addWidget(QLabel("A :"))
        d.top.addWidget(sa, 1)
        d.top.addWidget(QLabel("B :"))
        d.top.addWidget(sb, 1)
        d.top.addWidget(socle_qt.variant(small_button(L("Comparer"), go), "primary"))
        go()
        d.exec()

    def compare_records(self):
        sel = self.selected_records()
        a, b = (sel[0], sel[1]) if len(sel) >= 2 else (self.cur if len(sel) < 1 or sel == [self.cur] else sel[0], None)
        SideBySideDialog(self, a, b).exec()
        if self.cur:
            self.show_record(self.cur)

    def show_stats(self):
        P = self.active
        if not P:
            return
        d = ListDialog(self, P.name)
        d.message(L("Enregistrements : {v:,}", v=len(P.all) - 1).replace(",", " "))
        d.message(L("Maîtres : ") + (", ".join(P.masters) if P.masters else L("aucun")))
        d.section(L("ENREGISTREMENTS PAR TYPE"))
        for t, n in self.ws.stats(P):
            d.message(f"{t}    {n:,}".replace(",", " "))
        d.exec()

    def show_log(self):
        P = self.active
        if not P:
            return
        TextDialog(self, L("Journal des modifications — {name}", name=P.name),
                   "\n".join(P.log) if P.log else L("Aucune modification enregistrée pendant cette session."),
                   "Fermer", L("Session en cours uniquement."), read_only=True).exec()


def main():
    app = QApplication(sys.argv)
    app.setApplicationName(APP)
    socle_qt.apply(app)
    socle_qt.brand(app, "pLUGINSLENS", "#f5b921")  # « p » dans le jaune du logo
    init_lang(QSettings(DATA_NAME, DATA_NAME))
    win = MainWindow()
    win.show()
    update_check.start_qt(win, "pLUGINSLENS", lang=get_lang)  # nouvelle version ? (au plus une fois par jour)
    sys.exit(app.exec())


if __name__ == "__main__":
    main()
