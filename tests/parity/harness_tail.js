
// --- Scénario de référence (exécuté sur le code d'origine) -------------------
const sha = P => crypto.createHash("sha256").update(cat(P.root.map(ser))).digest("hex");
async function loadPath(path) {
  const buf = fs.readFileSync(path);
  const name = path.split("/").pop();
  await load({ name, arrayBuffer: async () => buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength) });
  return plugins.find(p => p.name === name);
}
(async () => {
  const [pathX, pathE] = process.argv.slice(2);
  const out = { steps: {}, texts: {}, alerts: 0 };
  const h = (k, P) => { out.steps[k] = sha(P); };
  try {
    const X = await loadPath(pathX);
    if (!X) throw new Error("load failed: " + document.querySelector("#st").textContent);
    h("load", X);
    fixHedr(X); h("fixhedr", X);
    out.texts.nextId = hex(nextId(X));
    PROMPTS.push("PL_Test"); newFormList();
    const fl = X.all[X.all.length - 1]; h("newfl", X);
    const body = X.all.filter(r => r !== X.root[0] && r !== fl);
    addEntries(fl, body.slice(0, 5)); h("addentries", X);
    const named = body.filter(r => edid(r));
    if (named.length) { cloneRec(named[Math.min(9, named.length - 1)]); }
    h("clone", X);
    const lines = [exportList(fl), "# commentaire", ...named.slice(5, 8).map(edid), "0x00ABCDEF", "NotARealEditorID_zz",
      ...body.slice(6, 8).map(r => hex(r.id))];
    importList(fl, lines.join("\n")); h("import", X);
    out.texts.export = exportList(fl);
    const tops = body.filter(r => topOf(r)).slice(0, 3);
    sel = new Set(tops); cur = null; copy(); activeP = X; paste(); h("paste", X);
    undo(X, true); h("undo", X); fixHedr(X); h("undo_save", X);
    undo(X, false); h("redo", X);
    // Plugin vide : ajout de maître, collage inter-plugins
    const E = await loadPath(pathE);
    PROMPTS.push("PL_E_List"); newFormList();
    const flE = E.all[E.all.length - 1]; h("E_newfl", E);
    addEntries(flE, body.slice(0, 4)); h("E_add", E);
    out.texts.E_masters = E.masters.join("|");
    sel = new Set([fl]); cur = null; copy(); activeP = E; paste(); h("E_paste", E);
    fixHedr(E); h("E_save", E);
    out.texts.E_export = exportList(flE);
  } catch (e) { out.error = String(e && e.stack || e); }
  out.alerts = ALERTS.length;
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
})();
