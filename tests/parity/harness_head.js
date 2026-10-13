// Faux DOM minimal pour exécuter le code JavaScript d'origine de Plugin Lens sous Node.js.
"use strict";
const fs = require("fs");
const crypto = require("crypto");

class El {
  constructor(tag) {
    this.tag = tag || "div"; this._cls = new Set(); this.dataset = {}; this.style = {}; this.children = [];
    this.childNodes = [{}, {}, {}]; this.textContent = ""; this.value = ""; this.checked = false; this.disabled = false;
    const self = this;
    this.classList = {
      add: c => self._cls.add(c), remove: c => self._cls.delete(c), contains: c => self._cls.has(c),
      toggle: (c, f) => { const on = f === undefined ? !self._cls.has(c) : !!f; on ? self._cls.add(c) : self._cls.delete(c); return on; },
    };
    return new Proxy(this, { get: (t, p) => (p in t ? t[p] : (typeof p === "symbol" ? undefined : () => new El())) });
  }
  set className(v) { this._cls = new Set(String(v).split(/\s+/).filter(Boolean)); }
  get className() { return [...this._cls].join(" "); }
  append(...n) { this.children.push(...n); }
  appendChild(n) { this.children.push(n); return n; }
  prepend(...n) { this.children.unshift(...n); }
  replaceChildren(...n) { this.children = n; }
  replaceWith() {} after() {} remove() {} focus() {} scrollIntoView() {} showModal() {} close() {} setDragImage() {}
  addEventListener() {} setPointerCapture() {}
  click() { if (this.onclick) this.onclick({ stopPropagation() {}, preventDefault() {}, shiftKey: false }); }
  querySelector() { return new El(); }
  querySelectorAll() { return []; }
  get parentNode() { return null; }
  get offsetWidth() { return 0; } get offsetHeight() { return 0; }
}
const ids = {};
globalThis.document = {
  createElement: t => new El(t),
  querySelector: s => (ids[s] || (ids[s] = new El())),
  querySelectorAll: () => [],
  body: new El("body"),
  get activeElement() { return { tagName: "BODY" }; },
};
globalThis.window = globalThis;
globalThis.localStorage = {};
globalThis.indexedDB = { open() { return {}; } };
globalThis.getComputedStyle = () => ({ flexDirection: "row" });
globalThis.ResizeObserver = class { observe() {} };
globalThis.addEventListener = () => {};
globalThis.ALERTS = [];
globalThis.alert = m => ALERTS.push(String(m));
globalThis.confirm = () => true;
globalThis.PROMPTS = [];
globalThis.prompt = () => PROMPTS.shift() || "";
URL.createObjectURL = () => "blob:x"; URL.revokeObjectURL = () => {};
