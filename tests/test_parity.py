"""Parité octet pour octet entre le cœur Python et le code JavaScript d'origine de Plugin Lens.

Pour chaque plugin, le même scénario (lecture, écriture, FormList, ajout d'entrées, clonage,
import/export, copier-coller, annulation, ajout de maître, collage inter-plugins) est exécuté :
- par le code JavaScript d'origine sous Node.js (tests/parity/*.js) ;
- par plugin_core.py.
Les empreintes SHA-256 des fichiers produits à chaque étape doivent être identiques.

Usage :
    python3 tests/test_parity.py fichier.esp [...]
    python3 tests/test_parity.py --list liste.txt [--max N]
"""
import hashlib
import json
import os
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "src"))

import plugin_core as pc  # noqa: E402

PARITY = os.path.join(HERE, "parity")


def harness_path() -> str:
    path = os.path.join(tempfile.gettempdir(), "pluginlens_parity_harness.js")
    with open(path, "w", encoding="utf-8") as out:
        for part in ("harness_head.js", "pluginlens_original.js", "harness_tail.js"):
            with open(os.path.join(PARITY, part), encoding="utf-8") as f:
                out.write(f.read() + "\n")
    return path


def empty_plugin(path: str) -> None:
    subs = b"HEDR" + struct.pack("<H", 12) + struct.pack("<fII", 1.7, 0, 0x800) + b"CNAM" + struct.pack("<H", 3) + b"PL\0"
    tail = bytes(4) + struct.pack("<H", 44) + bytes(2)
    with open(path, "wb") as f:
        f.write(b"TES4" + struct.pack("<III", len(subs), 0, 0) + tail + subs)


def py_scenario(path_x: str, path_e: str) -> dict:
    out = {"steps": {}, "texts": {}, "alerts": 0}
    alerts = []
    ws = pc.Workspace(confirm=lambda m: True, alert=alerts.append)

    def h(k, P):
        out["steps"][k] = hashlib.sha256(pc.serialize(P)).hexdigest()

    def load(path):
        P = pc.load_plugin(os.path.basename(path), open(path, "rb").read())
        ws.plugins.append(P)
        return P

    X = load(path_x)
    h("load", X)
    ws.fix_hedr(X); h("fixhedr", X)
    out["texts"]["nextId"] = pc.hexs(ws.next_id(X))
    fl = ws.new_formlist(X, "PL_Test"); ws.mark_dirty(X); h("newfl", X)
    body = [r for r in X.all if r is not X.header and r is not fl]
    if ws.add_entries(fl, body[:5])["changed"]:
        ws.mark_dirty(X)
    h("addentries", X)
    named = [r for r in body if pc.edid(r)]
    if named and ws.clone_record(named[min(9, len(named) - 1)]):
        ws.mark_dirty(X)
    h("clone", X)
    lines = [ws.export_list(fl), "# commentaire", *[pc.edid(r) for r in named[5:8]], "0x00ABCDEF",
             "NotARealEditorID_zz", *[pc.hexs(r.id) for r in body[6:8]]]
    res = ws.import_list(fl, "\n".join(lines))
    if res["changed"] or res["raw"]:
        ws.mark_dirty(X)
    if res["bad"]:
        alerts.append("bad")
    h("import", X)
    out["texts"]["export"] = ws.export_list(fl)
    tops = [r for r in body if ws.top_of(r)][:3]
    clip, _ = ws.copy_records(tops)
    res = ws.paste_records(X, clip)
    if res["changed"]:
        ws.mark_dirty(X)
    h("paste", X)
    ws.undo_redo(X, True); h("undo", X)
    ws.fix_hedr(X); h("undo_save", X)
    ws.undo_redo(X, False); h("redo", X)
    E = load(path_e)
    flE = ws.new_formlist(E, "PL_E_List"); ws.mark_dirty(E); h("E_newfl", E)
    ws.add_entries(flE, body[:4]); h("E_add", E)
    out["texts"]["E_masters"] = "|".join(E.masters)
    new_clip, _ = ws.copy_records([fl])
    if new_clip:  # comme en JS : sans enregistrement copiable, le presse-papiers est conservé
        clip = new_clip
    ws.paste_records(E, clip); h("E_paste", E)
    ws.fix_hedr(E); h("E_save", E)
    out["texts"]["E_export"] = ws.export_list(flE)
    return out


def run(paths: list[str]) -> int:
    harness = harness_path()
    tmp = tempfile.mkdtemp(prefix="pl_parity_")
    path_e = os.path.join(tmp, "PL_Empty.esp")
    empty_plugin(path_e)
    ok = fail = skip = 0
    for path in paths:
        js = subprocess.run(["node", "--max-old-space-size=8192", harness, path, path_e], capture_output=True, text=True)
        try:
            ref = json.loads(js.stdout)
        except json.JSONDecodeError:
            print(f"SKIP  {path}  (sortie JS illisible : {js.stderr[-200:]})")
            skip += 1
            continue
        if ref.get("error"):
            try:
                py_scenario(path, path_e)
                print(f"DIFF  {path}  JS en erreur, Python non : {ref['error'][:160]}")
                fail += 1
            except Exception as e:  # les deux échouent : comportement identique
                print(f"SAME-ERR {path}  ({str(e)[:80]})")
                ok += 1
            continue
        try:
            mine = py_scenario(path, path_e)
        except Exception as e:
            print(f"FAIL  {path}  Python en erreur : {e!r}")
            fail += 1
            continue
        diffs = [k for k in ref["steps"] if ref["steps"][k] != mine["steps"].get(k)]
        diffs += [f"text:{k}" for k in ref["texts"] if ref["texts"][k] != mine["texts"].get(k)]
        if diffs:
            print(f"FAIL  {path}  étapes différentes : {', '.join(diffs)}")
            fail += 1
        else:
            print(f"OK    {path}  ({len(ref['steps'])} étapes)")
            ok += 1
    print(f"\n{ok} identiques, {fail} différents, {skip} ignorés")
    return 1 if fail else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--list":
        paths = [l.strip() for l in open(args[1], encoding="utf-8") if l.strip()]
        if "--max" in args:
            paths = paths[: int(args[args.index("--max") + 1])]
    else:
        paths = args
    sys.exit(run(paths))
