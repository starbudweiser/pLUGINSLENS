"""Cœur de Plugin Lens : lecture, écriture et modification des plugins Skyrim (.esp/.esm/.esl).

Ce module ne dépend pas de l'interface. Il reprend à l'identique la logique de la version
JavaScript d'origine (mêmes octets produits), vérifiée par tests/test_parity.py.
"""
from __future__ import annotations

import re
import struct
import zlib
from dataclasses import dataclass, field
from typing import Callable, Iterable

from i18n import L, N_

COMPRESSED = 0x40000
ESL_FLAG = 0x200

RFLAGS = [(0x20, N_("Supprimé")), (0x400, N_("Persistant (surtout REFR)")), (0x800, N_("Désactivé au départ")),
          (0x1000, N_("Ignoré")), (0x40000, N_("Compressé"))]
TES4FLAGS = [(0x1, N_("Fichier maître")), (0x80, N_("Chaînes localisées")), (0x200, N_("Maître léger (ESL)"))]
GROUP_TYPES = ["Top", "World children", "Interior block", "Interior sub-block", "Exterior block",
               "Exterior sub-block", "Cell children", "Topic children", "Cell persistent",
               "Cell temporary", "Cell visible distant"]


# ---------------------------------------------------------------------------
# Modèle
# ---------------------------------------------------------------------------
@dataclass(eq=False)
class Sub:
    t: str
    d: bytes
    m: str | None = None  # mode d'affichage : 't' texte, 'h' hexadécimal
    bad: bool = False


@dataclass(eq=False)
class Record:
    t: str
    flags: int
    id: int
    tail: bytes
    subs: list[Sub]
    parent: list | None = None
    plugin: "Plugin | None" = None
    k: str = "r"


@dataclass(eq=False)
class Group:
    label: bytes
    tail: bytes
    kids: list
    parent: list | None = None
    plugin: "Plugin | None" = None
    k: str = "g"


Node = Record | Group


@dataclass(eq=False)
class Plugin:
    name: str
    root: list
    all: list[Record] = field(default_factory=list)
    idx: dict | None = None
    dirty: bool = False
    masters: list[str] = field(default_factory=list)
    undo: list = field(default_factory=list)
    redo: list = field(default_factory=list)
    pend: bool = False
    base: list = field(default_factory=list)
    log: list[str] = field(default_factory=list)
    locked: bool = False
    t: float = 0.0

    @property
    def header(self) -> Record:
        return self.root[0]


# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
def hexs(n: int, w: int = 8) -> str:
    return format(n, "X").zfill(w)


def s4(b: bytes, p: int = 0) -> str:
    return bytes(b[p:p + 4]).decode("latin-1")


def te(s: str) -> bytes:
    return s.encode("utf-8")


def td(b: bytes) -> str:
    return bytes(b).decode("utf-8", errors="replace")


def lc(s: str) -> str:
    return s.lower()


def u32(b: bytes, p: int = 0) -> int:
    return struct.unpack_from("<I", b, p)[0]


def p32(v: int) -> bytes:
    return struct.pack("<I", v & 0xFFFFFFFF)


def _type_bytes(t: str) -> bytes:
    return te(t)[:4].ljust(4, b"\0")


_NUL_TAIL = re.compile(r"\x00[^\n\r  ]*\Z")


def strip_nul(s: str) -> str:
    """Équivalent de .replace(/\\0.*$/, '') en JavaScript."""
    return _NUL_TAIL.sub("", s, count=1)


def is_text(d: bytes) -> bool:
    return len(d) > 1 and d[-1] == 0 and all((32 <= b < 127) or b in (9, 10, 13) for b in d[:-1])


def text_of(d: bytes) -> str:
    return td(d[:-1] if d and d[-1] == 0 else d)


def text_bytes(s: str) -> bytes:
    return te(s) + b"\0"


def hex_bytes(d: bytes) -> str:
    return " ".join(hexs(x, 2) for x in d)


_HEXCLEAN = re.compile(r"[\s,]")
_HEXPAIRS = re.compile(r"^(?:[0-9a-fA-F]{2})*$")


def parse_hex_bytes(s: str) -> bytes | None:
    c = _HEXCLEAN.sub("", s)
    if not _HEXPAIRS.match(c):
        return None
    return bytes.fromhex(c)


_JS_INT16 = re.compile(r"^\s*([+-]?)(?:0[xX])?([0-9a-fA-F]+)")


def js_parse_hex(s: str) -> int | None:
    """parseInt(s, 16) >>> 0 de JavaScript (None si NaN)."""
    m = _JS_INT16.match(s)
    if not m:
        return None
    v = int(m.group(2), 16)
    if m.group(1) == "-":
        v = -v
    return v & 0xFFFFFFFF


_JS_FLOAT = re.compile(r"^\s*[+-]?(?:Infinity|(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)")


def js_parse_float(s: str) -> float | None:
    m = _JS_FLOAT.match(s)
    if not m:
        return None
    txt = m.group(0).strip()
    return float(txt.replace("Infinity", "inf"))


def f32(v: float) -> bytes:
    try:
        return struct.pack("<f", v)
    except OverflowError:
        return struct.pack("<f", float("inf") if v > 0 else float("-inf"))


# ---------------------------------------------------------------------------
# Lecture / écriture
# ---------------------------------------------------------------------------
def parse_subs(d: bytes) -> list[Sub]:
    out, q, xx, n = [], 0, None, len(d)
    while q + 6 <= n:
        t = s4(d, q)
        s = struct.unpack_from("<H", d, q + 4)[0]
        if t == "XXXX":
            xx = struct.unpack_from("<I", d, q + 6)[0]
            q += 10
            continue
        if xx is not None:
            s, xx = xx, None
        data = d[q + 6:q + 6 + s]
        # HEDR est modifié sur place par fix_hedr (comme en JavaScript, où les instantanés
        # d'annulation partagent ce tableau) : on le garde mutable.
        out.append(Sub(t, bytearray(data) if t == "HEDR" else bytes(data)))
        q += 6 + s
    return out


def parse(u: bytes, p: int, end: int) -> list:
    out = []
    while p + 24 <= end:
        t = s4(u, p)
        sz = u32(u, p + 4)
        if t == "GRUP":
            out.append(Group(bytes(u[p + 8:p + 12]), bytes(u[p + 12:p + 24]), parse(u, p + 24, p + sz)))
            p += sz
            continue
        fl = u32(u, p + 8)
        d = u[p + 24:p + 24 + sz]
        if fl & COMPRESSED:
            d = zlib.decompress(bytes(d[4:]))
        out.append(Record(t, fl, u32(u, p + 12), bytes(u[p + 16:p + 24]), parse_subs(d)))
        p += 24 + sz
    return out


def ser(n: Node) -> bytes:
    if n.k == "g":
        body = b"".join(ser(x) for x in n.kids)
        return b"GRUP" + p32(len(body) + 24) + n.label[:4] + n.tail[:12] + body
    parts = []
    for s in n.subs:
        big = len(s.d) > 65535
        if big:
            parts.append(b"XXXX" + struct.pack("<HI", 4, len(s.d)))
        parts.append(_type_bytes(s.t) + struct.pack("<H", 0 if big else len(s.d)))
        parts.append(s.d)
    body = b"".join(parts)
    return _type_bytes(n.t) + p32(len(body)) + p32(n.flags & ~COMPRESSED) + p32(n.id) + n.tail[:8] + body


def serialize(P: Plugin) -> bytes:
    return b"".join(ser(n) for n in P.root)


def clone_node(n: Node) -> Node:
    if n.k == "g":
        return Group(n.label, n.tail, [clone_node(x) for x in n.kids])
    return Record(n.t, n.flags, n.id, n.tail, [Sub(x.t, x.d, x.m) for x in n.subs])


def snapshot(P: Plugin) -> list:
    return [clone_node(n) for n in P.root]


def index(lst: list, P: Plugin) -> None:
    for n in lst:
        n.parent = lst
        n.plugin = P
        if n.k == "g":
            index(n.kids, P)
        else:
            P.all.append(n)


def read_masters(P: Plugin) -> list[str]:
    return [strip_nul(td(x.d)) for x in P.header.subs if x.t == "MAST"]


def load_plugin(name: str, data: bytes, dirty: bool = False, t: float = 0.0) -> Plugin:
    if s4(data, 0) != "TES4":
        raise ValueError(L("en-tête TES4 absent : ce n'est pas un plugin au format Skyrim"))
    P = Plugin(name=name, root=parse(memoryview(data), 0, len(data)), dirty=dirty, t=t)
    index(P.root, P)
    P.base = snapshot(P)
    P.masters = read_masters(P)
    return P


# ---------------------------------------------------------------------------
# Lecture des enregistrements
# ---------------------------------------------------------------------------
def edid(r: Record) -> str:
    for s in r.subs:
        if s.t == "EDID":
            return strip_nul(td(s.d))
    return ""


def glabel(g: Group) -> str:
    gt = u32(g.tail, 0)
    if gt == 0:
        v = s4(g.label, 0)
    elif gt in (1, 6, 7, 8, 9, 10):
        v = hexs(u32(g.label, 0))
    else:
        v = str(struct.unpack_from("<i", g.label, 0)[0])
    name = GROUP_TYPES[gt] if gt < len(GROUP_TYPES) else "Group"
    return f"{name} {v}"


def group_type(g: Group) -> str:
    return s4(g.label, 0)


def owner(id_: int, P: Plugin) -> str:
    i = id_ >> 24
    return P.masters[i] if i < len(P.masters) else P.name + L(" (ce fichier)")


def origin(P: Plugin, id_: int) -> str:
    i = id_ >> 24
    return P.masters[i] if i < len(P.masters) else P.name


def by_id(P: Plugin, id_: int) -> Record | None:
    if P.idx is None:
        P.idx = {r.id: r for r in P.all}
    return P.idx.get(id_)


def has_records(n: Node) -> bool:
    return True if n.k == "r" else any(has_records(x) for x in n.kids)


def is_top(g: Node) -> bool:
    return g.k == "g" and u32(g.tail, 0) == 0


def lnam(s: Sub) -> int | None:
    return u32(s.d, 0) if len(s.d) == 4 else None


def label(r: Record) -> str:
    return edid(r) or hexs(r.id)


class Workspace:
    """Ensemble des plugins ouverts et opérations qui les relient."""

    def __init__(self, confirm: Callable[[str], bool] = lambda m: True, alert: Callable[[str], None] = lambda m: None):
        self.plugins: list[Plugin] = []
        self.confirm = confirm
        self.alert = alert

    def find(self, name: str) -> Plugin | None:
        k = lc(name)
        return next((q for q in self.plugins if lc(q.name) == k), None)

    # -- résolution des FormID -------------------------------------------
    def resolve(self, P: Plugin, id_: int | None) -> Record | None:
        if id_ is None:
            return None
        o = origin(P, id_)
        if o == P.name:
            return by_id(P, id_)
        Q = self.find(o)
        return by_id(Q, ((len(Q.masters) << 24) | (id_ & 0xFFFFFF)) & 0xFFFFFFFF) if Q else None

    @staticmethod
    def remap_id(Q: Plugin, v: int, P: Plugin) -> dict:
        o, obj = origin(Q, v), v & 0xFFFFFF
        if lc(o) == lc(P.name):
            return {"id": ((len(P.masters) << 24) | obj) & 0xFFFFFFFF}
        for j, m in enumerate(P.masters):
            if lc(m) == lc(o):
                return {"id": ((j << 24) | obj) & 0xFFFFFFFF}
        return {"need": o}

    def xref(self, src: Record, P: Plugin) -> dict:
        return self.remap_id(src.plugin, src.id, P)

    # -- maîtres ----------------------------------------------------------
    @staticmethod
    def add_master(P: Plugin, name: str) -> None:
        n = len(P.masters)

        def fix(v: int) -> int:
            return (((n + 1) << 24) | (v & 0xFFFFFF)) & 0xFFFFFFFF if v >> 24 == n else v

        for r in P.all:
            if r is P.header:
                continue
            r.id = fix(r.id)
            for s in r.subs:
                if s.t == "LNAM" and len(s.d) == 4:
                    s.d = p32(fix(u32(s.d)))
        subs = P.header.subs
        at = -1
        for i, s in enumerate(subs):
            if s.t in ("HEDR", "CNAM", "SNAM", "MAST", "DATA"):
                at = i
        subs[at + 1:at + 1] = [Sub("MAST", text_bytes(name)), Sub("DATA", bytes(8))]
        P.masters.append(name)
        P.idx = None

    def ensure_master(self, P: Plugin, o: str, warn: list, no: set) -> bool:
        k = lc(o)
        if k in no:
            return False
        Q = self.find(o)
        if Q and any(lc(m) == lc(P.name) for m in Q.masters):
            bad = L("{o} dépend de {name} : en faire un maître de {name} serait circulaire.", o=o, name=P.name)
        elif not all(r is P.header or r.t == "FLST" for r in P.all):
            bad = L("{name} ne déclare pas {o} comme maître et contient d'autres enregistrements que des "
                    "FormLists. Un maître ne peut être ajouté sans risque qu'à un plugin composé de FormLists, "
                    "car les références internes des autres enregistrements devraient être renumérotées. "
                    "Ajoutez le maître dans xEdit, puis rouvrez le plugin ici.", name=P.name, o=o)
        elif len(P.masters) >= 253:
            bad = L("Trop de maîtres.")
        else:
            bad = None
        if bad:
            if bad not in warn:
                warn.append(bad)
            no.add(k)
            return False
        if not self.confirm(L("Ajouter {o} comme maître de {name} ?", o=o, name=P.name)):
            no.add(k)
            return False
        self.add_master(P, o)
        return True

    # -- FormID libres ----------------------------------------------------
    def next_id(self, P: Plugin) -> int | None:
        n = len(P.masters)
        mx = 0x7FF
        for r in P.all:
            if r.id >> 24 == n:
                mx = max(mx, r.id & 0xFFFFFF)
        h = next((x for x in P.header.subs if x.t == "HEDR"), None)
        if h and len(h.d) >= 12:
            mx = max(mx, (u32(h.d, 8) - 1) & 0xFFFFFF)
        o = mx + 1
        if (P.header.flags & ESL_FLAG) and o > 0xFFF:
            self.alert(L("Ce plugin marqué ESL n'a plus de FormID libre (limite 0xFFF)."))
            return None
        if o > 0xFFFFFF or n > 0xFF:
            self.alert(L("Plus aucun FormID libre."))
            return None
        return ((n << 24) | o) & 0xFFFFFFFF

    @staticmethod
    def fix_hedr(P: Plugin) -> None:
        h = next((x for x in P.header.subs if x.t == "HEDR"), None)
        if not h or len(h.d) < 12:
            return
        count, mx = 0, 0

        def walk(lst):
            nonlocal count, mx
            for x in lst:
                if x.k == "g":
                    count += 1
                    walk(x.kids)
                elif x is not P.header:
                    count += 1
                    if x.id >> 24 == len(P.masters):
                        mx = max(mx, x.id & 0xFFFFFF)

        walk(P.root)
        if not isinstance(h.d, bytearray):
            h.d = bytearray(h.d)
        h.d[4:8] = p32(count)
        h.d[8:12] = p32(max(u32(h.d, 8), mx + 1))

    # -- historique -------------------------------------------------------
    @staticmethod
    def mark_dirty(P: Plugin, msg: str | None = None, when: str = "") -> bool:
        """Marque le plugin modifié. Renvoie True si un nouveau point d'annulation a été ouvert
        (l'interface doit alors programmer commit_base() après 700 ms)."""
        P.idx = None
        P.dirty = True
        if msg:
            P.log.append(f"{when}  {msg}" if when else msg)
        if not P.pend:
            P.undo.append(P.base)
            if len(P.undo) > 50:
                P.undo.pop(0)
            P.redo = []
            P.pend = True
            return True
        return False

    @staticmethod
    def commit_base(P: Plugin) -> None:
        P.base = snapshot(P)
        P.pend = False

    @staticmethod
    def undo_redo(P: Plugin, back: bool) -> bool:
        src, dst = (P.undo, P.redo) if back else (P.redo, P.undo)
        if not src:
            return False
        dst.append(snapshot(P))
        snap = src.pop()
        P.root = [clone_node(n) for n in snap]
        P.base = snap
        P.pend = False
        P.all = []
        index(P.root, P)
        P.idx = None
        P.masters = read_masters(P)
        P.dirty = True
        return True

    # -- groupes et identifiants ------------------------------------------
    @staticmethod
    def top_group(P: Plugin, t: str) -> Group:
        g = next((n for n in P.root if is_top(n) and group_type(n) == t), None)
        if not g:
            src = next((n for n in P.root if is_top(n)), None)
            tl = bytearray(src.tail if src else bytes(12))
            tl[0:4] = p32(0)
            g = Group(te(t)[:4], bytes(tl), [], parent=P.root, plugin=P)
            P.root.append(g)
        return g

    @staticmethod
    def new_edid(P: Plugin, b: str) -> str:
        n, i = b + "_copy", 1
        names = {edid(r) for r in P.all}
        while n in names:
            i += 1
            n = f"{b}_copy{i}"
        return n

    @staticmethod
    def set_edid(x: Record, t: str) -> None:
        e = next((s for s in x.subs if s.t == "EDID"), None)
        if e:
            e.d = text_bytes(t)

    def top_of(self, r: Record) -> Group | None:
        return next((g for g in r.plugin.root if is_top(g) and g.kids is r.parent), None)

    # -- opérations sur les enregistrements -------------------------------
    def new_formlist(self, P: Plugin, name: str) -> Record | None:
        id_ = self.next_id(P)
        if id_ is None:
            return None
        tail = bytearray(8)
        tail[4:6] = P.header.tail[4:6]
        r = Record("FLST", 0, id_, bytes(tail), [Sub("EDID", text_bytes(name))])
        g = next((n for n in P.root if n.k == "g" and group_type(n) == "FLST" and u32(n.tail, 0) == 0), None)
        if not g:
            src = next((n for n in P.root if n.k == "g"), None)
            tl = bytearray(src.tail if src else bytes(12))
            tl[0:4] = p32(0)
            g = Group(b"FLST", bytes(tl), [], parent=P.root, plugin=P)
            P.root.append(g)
        r.parent, r.plugin = g.kids, P
        g.kids.append(r)
        P.all.append(r)
        return r

    def clone_record(self, r: Record) -> Record | None:
        P = r.plugin
        if r is P.header:
            return None
        id_ = self.next_id(P)
        if id_ is None:
            return None
        c = clone_node(r)
        c.id, c.plugin, c.parent = id_, P, r.parent
        if edid(r):
            self.set_edid(c, self.new_edid(P, edid(r)))
        r.parent.insert(r.parent.index(r) + 1, c)
        P.all.append(c)
        return c

    @staticmethod
    def delete_record(r: Record) -> None:
        P = r.plugin
        if r in r.parent:
            r.parent.remove(r)
        P.all = [x for x in P.all if x is not r]
        P.idx = None

    def add_entries(self, fl: Record, recs: Iterable[Record]) -> dict:
        """Ajoute des enregistrements à une FormList. Renvoie {n, dup, changed, warn}."""
        P = fl.plugin
        warn, no = [], set()
        n = dup = 0
        changed = False
        for src in recs:
            if src is fl:
                continue
            x = self.xref(src, P)
            if "need" in x:
                if not self.ensure_master(P, x["need"], warn, no):
                    continue
                changed = True
                x = self.xref(src, P)
            if any(s.t == "LNAM" and lnam(s) == x["id"] for s in fl.subs):
                dup += 1
                continue
            fl.subs.append(Sub("LNAM", p32(x["id"])))
            n += 1
            changed = True
        return {"n": n, "dup": dup, "changed": changed, "warn": warn}

    def copy_records(self, recs: list[Record]) -> tuple[list, int]:
        ok = [r for r in recs if r.plugin and r is not r.plugin.header and self.top_of(r)]
        return [(clone_node(r), r.plugin) for r in ok], len(recs) - len(ok)

    def paste_records(self, P: Plugin, clip: list) -> dict:
        warn, no = [], set()
        m0, n = len(P.masters), 0
        groups = []
        for c, Q in clip:
            if Q is not P and c.t != "FLST":
                msg = L("Seules les FormLists peuvent être collées dans un autre plugin. Les autres types "
                        "contiennent des références impossibles à renuméroter sans connaître leur structure. "
                        "Dans le même plugin, tous les types fonctionnent.")
                if msg not in warn:
                    warn.append(msg)
                continue
            x = clone_node(c)
            x.plugin = P
            if Q is not P:
                for s in x.subs:
                    if s.t == "LNAM" and len(s.d) == 4:
                        v = lnam(s)
                        m = self.remap_id(Q, v, P)
                        if "need" in m:
                            if not self.ensure_master(P, m["need"], warn, no):
                                s.bad = True
                                continue
                            m = self.remap_id(Q, v, P)
                        s.d = p32(m["id"])
            x.subs = [s for s in x.subs if not s.bad]
            id_ = self.next_id(P)
            if id_ is None:
                break
            x.id = id_
            nm = edid(c)
            if nm and any(edid(r) == nm for r in P.all):
                self.set_edid(x, self.new_edid(P, nm))
            g = self.top_group(P, c.t)
            x.parent = g.kids
            g.kids.append(x)
            P.all.append(x)
            groups.append(g)
            n += 1
        return {"n": n, "warn": warn, "changed": bool(n) or len(P.masters) != m0, "groups": groups}

    # -- FormLists --------------------------------------------------------
    def export_list(self, fl: Record) -> str:
        out = []
        for s in fl.subs:
            if s.t != "LNAM":
                continue
            v = lnam(s)
            if v is None:
                out.append("# invalid entry")
                continue
            t = self.resolve(fl.plugin, v)
            out.append(edid(t) if t and edid(t) else "0x" + hexs(v))
        return "\n".join(out)

    def import_list(self, fl: Record, txt: str) -> dict:
        P = fl.plugin
        recs, bad, raw = [], [], 0
        by_e: dict[str, Record] = {}
        for q in [P] + [x for x in self.plugins if x is not P]:
            for r in q.all:
                e = lc(edid(r))
                if e and e not in by_e:
                    by_e[e] = r
        for line in re.split(r"\r?\n", txt):
            line = re.sub(r"#.*", "", line).strip()
            if not line:
                continue
            m = re.match(r"^(?:0x)?([0-9a-fA-F]{8})$", line)
            if m:
                id_ = int(m.group(1), 16)
                t = self.resolve(P, id_)
                if t:
                    recs.append(t)
                elif id_ >> 24 <= len(P.masters) and not any(s.t == "LNAM" and lnam(s) == id_ for s in fl.subs):
                    fl.subs.append(Sub("LNAM", p32(id_)))
                    raw += 1
                else:
                    bad.append(line)
            else:
                t = by_e.get(lc(line))
                (recs.append(t) if t else bad.append(line))
        res = self.add_entries(fl, recs) if recs else {"n": 0, "dup": 0, "changed": False, "warn": []}
        res["raw"], res["bad"] = raw, bad
        return res

    def fl_entries(self, fl: Record) -> list[Sub]:
        return [s for s in fl.subs if s.t == "LNAM"]

    def fl_set(self, fl: Record, entries: list[Sub]) -> int:
        """Remplace les entrées LNAM (placées en fin de liste). Renvoie le nombre d'entrées retirées."""
        removed = len(self.fl_entries(fl)) - len(entries)
        fl.subs = [s for s in fl.subs if s.t != "LNAM"] + entries
        return removed

    def fl_sorted_by_name(self, fl: Record) -> list[Sub]:
        P = fl.plugin

        def name(s):
            t = self.resolve(P, lnam(s))
            return edid(t) if t else ""

        def key(s):
            n = name(s) or "￿"
            v = lnam(s)
            return (n.lower(), n, -1 if v is None else v)

        return sorted(self.fl_entries(fl), key=key)

    def fl_sorted_by_formid(self, fl: Record) -> list[Sub]:
        return sorted(self.fl_entries(fl), key=lambda s: -1 if lnam(s) is None else lnam(s))

    def fl_deduped(self, fl: Record) -> list[Sub]:
        seen, out = set(), []
        for s in self.fl_entries(fl):
            v = lnam(s)
            if v in seen:
                continue
            seen.add(v)
            out.append(s)
        return out

    def fl_without_broken(self, fl: Record) -> list[Sub]:
        P = fl.plugin
        out = []
        for s in self.fl_entries(fl):
            v = lnam(s)
            if v is None:
                continue
            o = origin(P, v)
            if not (o == P.name or self.find(o)) or self.resolve(P, v):
                out.append(s)
        return out

    # -- mots-clés et globales --------------------------------------------
    @staticmethod
    def keywords(r: Record) -> list[int]:
        d = next((x for x in r.subs if x.t == "KWDA"), None)
        if not d:
            return []
        return [u32(d.d, i * 4) for i in range(len(d.d) // 4)]

    @staticmethod
    def set_keywords(r: Record, ids: list[int]) -> None:
        r.subs = [x for x in r.subs if x.t not in ("KWDA", "KSIZ")]
        if ids:
            r.subs.append(Sub("KSIZ", p32(len(ids))))
            r.subs.append(Sub("KWDA", b"".join(p32(v) for v in ids)))

    @staticmethod
    def glob_type(r: Record) -> str:
        fn = next((x for x in r.subs if x.t == "FNAM"), None)
        return chr(fn.d[0]) if fn and fn.d else "f"

    @staticmethod
    def set_glob_type(r: Record, c: str) -> None:
        fn = next((x for x in r.subs if x.t == "FNAM"), None)
        d = bytes([ord(c)])
        if fn:
            fn.d = d
        else:
            r.subs.insert(0, Sub("FNAM", d))

    @staticmethod
    def glob_value(r: Record) -> float | None:
        fl = next((x for x in r.subs if x.t == "FLTV"), None)
        return struct.unpack("<f", fl.d)[0] if fl and len(fl.d) == 4 else None

    @staticmethod
    def set_glob_value(r: Record, v: float) -> None:
        fl = next((x for x in r.subs if x.t == "FLTV"), None)
        if fl:
            fl.d = f32(v)
        else:
            r.subs.append(Sub("FLTV", f32(v)))

    # -- recherche et analyses --------------------------------------------
    def search(self, q: str, sort_mode: str = "file", limit: int = 300) -> tuple[list[Record], int]:
        l, u = q.lower(), q.upper()
        matches = [r for P in self.plugins for r in P.all
                   if r.t.lower() == l or l in edid(r).lower() or u in hexs(r.id)]
        if sort_mode != "file":
            matches.sort(key=sort_key(sort_mode))
        return matches[:limit], len(matches)

    def where_used(self, r: Record, limit: int = 300) -> list[tuple[Record, Sub]]:
        P, hits = r.plugin, []
        for Q in self.plugins:
            x = self.remap_id(P, r.id, Q)
            if "need" in x:
                continue
            target = p32(x["id"])
            for rec in Q.all:
                if rec is r:
                    continue
                for s in rec.subs:
                    if len(s.d) == 4 and s.d == target:
                        hits.append((rec, s))
                        break
        return hits[:limit]

    def find_duplicates(self) -> tuple[list[list[Record]], list[list[Record]]]:
        by_edid: dict[str, list] = {}
        by_id: dict[str, list] = {}
        for P in self.plugins:
            for r in P.all:
                if r is P.header:
                    continue
                e = lc(edid(r))
                if e:
                    by_edid.setdefault(e, []).append(r)
                by_id.setdefault(f"{P.name}|{r.id}", []).append(r)
        return ([l for l in by_id.values() if len(l) > 1], [l for l in by_edid.values() if len(l) > 1])

    @staticmethod
    def compare_plugins(A: Plugin, B: Plugin) -> tuple[list, list, list]:
        def key(r):
            return f"{r.t}|{lc(edid(r))}"

        am = {key(r): r for r in A.all if r is not A.header}
        bm = {key(r): r for r in B.all if r is not B.header}
        added = [r for k, r in bm.items() if k not in am]
        removed = [r for k, r in am.items() if k not in bm]
        changed = []
        for k, ra in am.items():
            rb = bm.get(k)
            if rb is None:
                continue
            sa = [(s.t, s.d) for s in ra.subs if s.t != "EDID"]
            sb = [(s.t, s.d) for s in rb.subs if s.t != "EDID"]
            if sa != sb:
                changed.append(rb)
        return added, removed, changed

    @staticmethod
    def stats(P: Plugin) -> list[tuple[str, int]]:
        counts: dict[str, int] = {}
        for r in P.all:
            if r is P.header:
                continue
            counts[r.t] = counts.get(r.t, 0) + 1
        return sorted(counts.items(), key=lambda x: -x[1])

    # -- comparaison côte à côte ------------------------------------------
    def decode4(self, P: Plugin | None, d: bytes) -> str | None:
        if len(d) != 4 or P is None:
            return None
        t = self.resolve(P, u32(d))
        return f"{t.t} {edid(t)}".strip() if t else None

    def decode_val(self, r: Record | None, s: Sub | None) -> str:
        if not s:
            return ""
        nm = self.decode4(r.plugin if r else None, s.d)
        if nm:
            return f"{hexs(u32(s.d))}  — {nm}"
        if is_text(s.d):
            return text_of(s.d)
        return " ".join(hexs(x, 2) for x in s.d[:20]) + (" …" if len(s.d) > 20 else "")


def sort_key(mode: str):
    if mode == "formid":
        return lambda r: r.id
    # Tri stable : à EditorID égal, l'ordre d'origine est conservé (comme en JavaScript)
    return lambda r: (0, edid(r).lower(), 0) if edid(r) else (1, "", r.id)


def sub_rows(r: Record) -> list[dict]:
    groups: dict[str, list[Sub]] = {}
    for s in r.subs:
        groups.setdefault(s.t, []).append(s)
    rows = []
    for t, arr in groups.items():
        for i, s in enumerate(arr):
            rows.append({"tag": t, "key": t + (f" #{i + 1}" if len(arr) > 1 else ""), "sub": s})
    return rows


def union_rows(a: Record, b: Record) -> list[dict]:
    ra, rb = sub_rows(a), sub_rows(b)
    bm = {x["key"]: x for x in rb}
    seen, out = set(), []
    for x in ra:
        out.append({"key": x["key"], "tag": x["tag"], "a": x["sub"], "b": bm[x["key"]]["sub"] if x["key"] in bm else None})
        seen.add(x["key"])
    for x in rb:
        if x["key"] not in seen:
            out.append({"key": x["key"], "tag": x["tag"], "a": None, "b": x["sub"]})
    return out


def filtered_root(P: Plugin, type_filter: list[str]) -> list:
    return [n for n in P.root if n is P.header or n.k == "r"
            or (n.k == "g" and has_records(n) and (not type_filter or group_type(n).upper() in type_filter))]


def u32_hint(d: bytes) -> str:
    if len(d) != 4:
        return ""
    u = u32(d)
    i = struct.unpack("<i", d)[0]
    f = struct.unpack("<f", d)[0]
    return f"u32 {u} · i32 {i} · f32 {f:.7g} · form {hexs(u)}"
