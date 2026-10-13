
const $=s=>document.querySelector(s),td=new TextDecoder(),te=new TextEncoder();
const hex=(n,w=8)=>n.toString(16).toUpperCase().padStart(w,'0');
const s4=(u,p)=>String.fromCharCode(u[p],u[p+1],u[p+2],u[p+3]);
const cat=a=>{const o=new Uint8Array(a.reduce((s,x)=>s+x.length,0));let p=0;for(const x of a){o.set(x,p);p+=x.length}return o};
let plugins=[],activeP=null,selRow=null,cur=null,dragRecs=[],sel=new Set(),anchor=null,clip=[],sortMode='file',recent=[],typeFilter=[],cellDrag=null;
const cl=n=>n.k==='g'?{k:'g',label:n.label,tail:n.tail,kids:n.kids.map(cl)}:{k:'r',t:n.t,flags:n.flags,id:n.id,tail:n.tail,subs:n.subs.map(x=>({t:x.t,d:x.d,m:x.m}))};
const MIME='application/x-pluginlens-record';

async function inflate(b){return new Uint8Array(await new Response(new Blob([b]).stream().pipeThrough(new DecompressionStream('deflate'))).arrayBuffer())}
function subs(d){const dv=new DataView(d.buffer,d.byteOffset,d.byteLength),o=[];let q=0,xx=null;
 while(q+6<=d.length){const t=s4(d,q);let s=dv.getUint16(q+4,true);
  if(t==='XXXX'){xx=dv.getUint32(q+6,true);q+=10;continue}
  if(xx!==null){s=xx;xx=null}
  o.push({t,d:d.slice(q+6,q+6+s)});q+=6+s}
 return o}
async function parse(u,p,end){const dv=new DataView(u.buffer),o=[];
 while(p+24<=end){const t=s4(u,p),sz=dv.getUint32(p+4,true);
  if(t==='GRUP'){o.push({k:'g',label:u.slice(p+8,p+12),tail:u.slice(p+12,p+24),kids:await parse(u,p+24,p+sz)});p+=sz;continue}
  const fl=dv.getUint32(p+8,true);let d=u.subarray(p+24,p+24+sz);
  if(fl&0x40000)d=await inflate(d.subarray(4));
  o.push({k:'r',t,flags:fl,id:dv.getUint32(p+12,true),tail:u.slice(p+16,p+24),subs:subs(d)});p+=24+sz}
 return o}
function ser(n){
 if(n.k==='g'){const ch=n.kids.map(ser),len=ch.reduce((a,b)=>a+b.length,0),h=new Uint8Array(24),dv=new DataView(h.buffer);
  h.set(te.encode('GRUP'));dv.setUint32(4,len+24,true);h.set(n.label,8);h.set(n.tail,12);return cat([h,...ch])}
 const parts=[];
 for(const s of n.subs){const big=s.d.length>65535;
  if(big){const x=new Uint8Array(10),v=new DataView(x.buffer);x.set(te.encode('XXXX'));v.setUint16(4,4,true);v.setUint32(6,s.d.length,true);parts.push(x)}
  const h=new Uint8Array(6);h.set(te.encode(s.t));new DataView(h.buffer).setUint16(4,big?0:s.d.length,true);parts.push(h,s.d)}
 const body=cat(parts),h=new Uint8Array(24),dv=new DataView(h.buffer);
 h.set(te.encode(n.t));dv.setUint32(4,body.length,true);dv.setUint32(8,(n.flags&~0x40000)>>>0,true);dv.setUint32(12,n.id,true);h.set(n.tail,16);
 return cat([h,body])}

const edid=r=>{const s=r.subs.find(x=>x.t==='EDID');return s?td.decode(s.d).replace(/\0.*$/,''):''};
const GT=['Top','World children','Interior block','Interior sub-block','Exterior block','Exterior sub-block','Cell children','Topic children','Cell persistent','Cell temporary','Cell visible distant'];
function glabel(g){const gt=new DataView(g.tail.buffer).getUint32(0,true),l=g.label;
 const v=gt===0?s4(l,0):[1,6,7,8,9,10].includes(gt)?hex(new DataView(l.buffer).getUint32(0,true)):new DataView(l.buffer).getInt32(0,true);
 return (GT[gt]||'Group')+' '+v}
function owner(id,P){const i=id>>>24;return i<P.masters.length?P.masters[i]:P.name+' (this file)'}

function setDirty(P=activeP,msg){if(!P)return;P.idx=null;P.dirty=true;mark(P);
 if(!P.log)P.log=[];if(msg)P.log.push(new Date().toLocaleTimeString()+'  '+msg);
 if(!P.pend){P.undo.push(P.base);if(P.undo.length>50)P.undo.shift();P.redo=[];P.pend=true}
 clearTimeout(P._bt);P._bt=setTimeout(()=>{P.base=P.root.map(cl);P.pend=false;status()},700);persist(P);status()}
function index(list,P){for(const n of list){n._p=list;n._P=P;if(n.k==='g')index(n.kids,P);else P.all.push(n)}}
const mk=(c,t)=>{const d=document.createElement('div');if(c)d.className=c;if(t!=null)d.textContent=t;return d};

function rrow(r){const e=mk('row');const t=document.createElement('span');t.className='rt';t.textContent=r.t;
 e.append(t,edid(r)||'',Object.assign(document.createElement('span'),{className:'mut id',textContent:' '+hex(r.id)}));
 e._r=r;e.onmousedown=ev=>{if(ev.shiftKey)ev.preventDefault()};e.onclick=ev=>pick(ev,r,e);r._el=e;
 e.draggable=true;e.ondragstart=ev=>dragStart(ev,r,e);
 if(r.t==='FLST')dropZone(e,r);return e}
function sortCmp(a,b){if(sortMode==='formid')return a.id-b.id;
 const ea=(edid(a)||'').toLowerCase(),eb=(edid(b)||'').toLowerCase();
 if(ea&&eb)return ea<eb?-1:ea>eb?1:0;if(ea)return-1;if(eb)return 1;return a.id-b.id}
function build(list,host){const items=(sortMode!=='file'&&list.length&&list.every(n=>n.k==='r'))?[...list].sort(sortCmp):list;
 for(const n of items){n._p=list;
 if(n.k==='g'&&!hasRecords(n))continue;
 if(n.k==='g'){const w=mk(),body=mk('kids'),h=mk('row grp',glabel(n));
  h.onclick=()=>{w.classList.toggle('open');if(!w.dataset.d){w.dataset.d=1;build(n.kids,body)}};n._w=w;n._h=h;w.append(h,body);host.append(w)}
 else host.append(rrow(n))}}

const RFLAGS=[[0x20,'Deleted'],[0x400,'Persistent (mainly REFR)'],[0x800,'Initially disabled'],[0x1000,'Ignored'],[0x40000,'Compressed']];
const TES4FLAGS=[[0x1,'Master file'],[0x80,'Localized strings'],[0x200,'Light master (ESL)']];
function touchRecent(r){const k=r._P.name+'|'+hex(r.id);recent=recent.filter(x=>x!==k);recent.unshift(k);if(recent.length>15)recent.pop()}
function show(r,el){
 cur=r;activeP=r._P;touchRecent(r);renderRecent();status();if(selRow)selRow.classList.remove('sel');selRow=el||r._el||null;if(selRow)selRow.classList.add('sel');
 const d=$('#detail');d.replaceChildren();
 const P=r._P;
 if(P.locked){const b=mk('robanner','🔒 '+P.name+' is locked. Unlock it from the tree to make changes.');d.append(b)}
 const hd=mk('hd'),h2=document.createElement('h2');h2.textContent=r.t+'  '+edid(r);hd.append(h2);
 const lab=(name,val,fn)=>{const l=document.createElement('label'),i=document.createElement('input');i.className='fld';i.value=val;i.spellcheck=false;
  i.oninput=()=>{const v=parseInt(i.value,16);if(isNaN(v)){i.classList.add('bad');return}i.classList.remove('bad');fn(v>>>0);setDirty(P)};l.append(name,i);hd.append(l);return i};
 lab('FormID (hex)',hex(r.id),v=>{r.id=v;if(r._el)r._el.querySelector('.id').textContent=' '+hex(v)});
 const flagInp=lab('Flags (hex)',hex(r.flags),v=>r.flags=v);
 const ow=mk('mut',P.name+' · Owner: '+owner(r.id,P));ow.style.fontSize='12px';hd.append(ow);
 const add=document.createElement('button');add.textContent='Add subrecord';
 add.onclick=()=>{if(locked(P))return;const t=(prompt('Four-character subrecord type, e.g. FULL')||'').trim();if(t.length!==4)return;r.subs.push({t,d:new Uint8Array(0)});setDirty(P,'Added '+t+' to '+(edid(r)||hex(r.id)));show(r,selRow)};
 const del=document.createElement('button');del.textContent='Delete record';
 del.onclick=()=>{if(locked(P))return;if(!confirm('Delete this record? Other records that reference it will break.'))return;
  const i=r._p.indexOf(r);if(i>=0)r._p.splice(i,1);P.all=P.all.filter(x=>x!==r);sel.delete(r);if(r._el)r._el.remove();setDirty(P,'Deleted '+r.t+' '+(edid(r)||hex(r.id)));selRow=null;d.replaceChildren(mk('mut','Record deleted.'))};
 const cln=document.createElement('button');cln.textContent='Clone record';cln.onclick=()=>cloneRec(r);hd.append(add,cln,del);d.append(hd);
 const pin=document.createElement('button');pin.className='ro-ok';pin.textContent=isPinned(r)?'Unpin':'Pin';
 pin.onclick=()=>{togglePin(r);pin.textContent=isPinned(r)?'Unpin':'Pin';renderPins()};
 const wu=document.createElement('button');wu.className='ro-ok';wu.textContent='Where used';wu.onclick=()=>whereUsed(r);
 hd.append(pin,wu);
 const flegend=mk('flagchk'),bits=(r.t==='TES4'?TES4FLAGS:RFLAGS);
 bits.forEach(([bit,name])=>{const l=document.createElement('label'),cb=document.createElement('input');cb.type='checkbox';cb.checked=!!(r.flags&bit);
  cb.onchange=()=>{if(locked(P)){cb.checked=!cb.checked;return}r.flags=cb.checked?(r.flags|bit)>>>0:(r.flags&~bit)>>>0;flagInp.value=hex(r.flags);setDirty(P,(cb.checked?'Set ':'Cleared ')+name+' on '+(edid(r)||hex(r.id)))};
  l.append(cb,name);flegend.append(l)});
 d.append(flegend);
 if(r.t==='FLST')d.append(flPanel(r));
 if(r.t==='GLOB')d.append(globPanel(r));
 if(r.subs.some(x=>x.t==='KSIZ')||r.subs.some(x=>x.t==='KWDA'))d.append(kwdaPanel(r));
 const skip=s=>(r.t==='FLST'&&s.t==='LNAM')||(r.t==='GLOB'&&(s.t==='FNAM'||s.t==='FLTV'))||(s.t==='KSIZ'||s.t==='KWDA');
 r.subs.forEach(s=>{if(!skip(s))d.append(subEl(r,s))});
 if(P.locked)d.querySelectorAll('input,textarea,button,select').forEach(x=>{if(!x.classList.contains('ro-ok'))x.disabled=true})}

const TXT=d=>d.length>1&&d[d.length-1]===0&&d.subarray(0,-1).every(b=>(b>=32&&b<127)||b===10||b===13||b===9);
function subEl(r,s){const w=mk('sub'),h=mk('sh'),ta=document.createElement('textarea'),info=document.createElement('span'),hint=document.createElement('span');
 ta.spellcheck=false;if(s.m===undefined)s.m=TXT(s.d)?'t':'h';
 const b=document.createElement('b');b.textContent=s.t;
 const tg=document.createElement('button'),rm=document.createElement('button'),sp=mk('sp');rm.textContent='Remove';
 const paint=()=>{ta.value=s.m==='t'?td.decode(s.d.subarray(0,s.d.length-(s.d[s.d.length-1]===0?1:0))):[...s.d].map(x=>hex(x,2)).join(' ');
  ta.rows=Math.min(12,Math.max(1,ta.value.split('\n').length+(s.m==='h'?Math.floor(ta.value.length/90):0)));meta()};
 const meta=()=>{info.textContent=s.d.length+' bytes';hint.textContent='';
  if(s.d.length===4){const v=new DataView(s.d.buffer,s.d.byteOffset,4);hint.textContent='u32 '+v.getUint32(0,true)+' · i32 '+v.getInt32(0,true)+' · f32 '+v.getFloat32(0,true).toPrecision(7)+' · form '+hex(v.getUint32(0,true))}};
 ta.oninput=()=>{let nd;
  if(s.m==='t'){nd=cat([te.encode(ta.value),new Uint8Array(1)])}
  else{const c=ta.value.replace(/[\s,]/g,'');if(!/^([0-9a-f]{2})*$/i.test(c)){ta.classList.add('bad');return}nd=new Uint8Array(c.length/2);for(let i=0;i<nd.length;i++)nd[i]=parseInt(c.substr(i*2,2),16)}
  ta.classList.remove('bad');s.d=nd;setDirty(r._P,'Edited '+s.t+' in '+(edid(r)||hex(r.id)));meta();if(s.t==='EDID'&&r._el){r._el.childNodes[1].textContent=edid(r)}};
 tg.onclick=()=>{s.m=s.m==='t'?'h':'t';paint()};
 rm.onclick=()=>{r.subs.splice(r.subs.indexOf(s),1);setDirty(r._P,'Removed '+s.t+' from '+(edid(r)||hex(r.id)));w.remove()};
 h.append(b,info,hint,sp,tg,rm);addPickButton(h,s,r,()=>{paint();if(s.t==='EDID'&&r._el)r._el.childNodes[1].textContent=edid(r)});w.append(h,ta);paint();return w}

function byId(P,id){if(!P.idx){P.idx=new Map();for(const r of P.all)P.idx.set(r.id,r)}return P.idx.get(id)}
function flash(m){const st=$('#st'),old=st.textContent;st.textContent=m;setTimeout(()=>{if(st.textContent===m)st.textContent=old},2800)}
const lnam=s=>s.d.length===4?new DataView(s.d.buffer,s.d.byteOffset,4).getUint32(0,true):null;
const lc=x=>x.toLowerCase(),origin=(P,id)=>{const i=id>>>24;return i<P.masters.length?P.masters[i]:P.name};
function resolve(P,id){const o=origin(P,id);if(o===P.name)return byId(P,id);
 const Q=plugins.find(q=>lc(q.name)===lc(o));return Q&&byId(Q,((Q.masters.length<<24)|(id&0xFFFFFF))>>>0)}
function remapId(Q,v,P){const o=origin(Q,v),obj=v&0xFFFFFF;
 if(lc(o)===lc(P.name))return{id:((P.masters.length<<24)|obj)>>>0};
 const j=P.masters.findIndex(m=>lc(m)===lc(o));return j>=0?{id:((j<<24)|obj)>>>0}:{need:o}}
const xref=(src,P)=>remapId(src._P,src.id,P);
function addMaster(P,name){const n=P.masters.length,fix=v=>v>>>24===n?(((n+1)<<24)|(v&0xFFFFFF))>>>0:v;
 for(const r of P.all){if(r===P.root[0])continue;r.id=fix(r.id);const e=r._el&&r._el.querySelector('.id');if(e)e.textContent=' '+hex(r.id);
  for(const s of r.subs)if(s.t==='LNAM'&&s.d.length===4){s.d=s.d.slice();const v=new DataView(s.d.buffer,s.d.byteOffset,4);v.setUint32(0,fix(v.getUint32(0,true)),true)}}
 const subs=P.root[0].subs;let at=-1;subs.forEach((s,i)=>{if(['HEDR','CNAM','SNAM','MAST','DATA'].includes(s.t))at=i});
 subs.splice(at+1,0,{t:'MAST',d:cat([te.encode(name),new Uint8Array(1)])},{t:'DATA',d:new Uint8Array(8)});P.masters.push(name);P.idx=null}
function dropZone(el,r){
 el.ondragover=e=>{if(e.dataTransfer.types.includes(MIME)){e.preventDefault();e.stopPropagation();el.classList.add('over')}};
 el.ondragleave=()=>el.classList.remove('over');
 el.ondrop=e=>{e.preventDefault();e.stopPropagation();el.classList.remove('over');if(locked(r._P))return;if(dragRecs.length)addEntries(r,dragRecs)}}
function paintSel(){document.querySelectorAll('.msel').forEach(x=>x.classList.remove('msel'));for(const r of sel)if(r._el)r._el.classList.add('msel')}
function pick(ev,r,e){
 if(ev.shiftKey&&anchor&&anchor.parentNode===e.parentNode){const rows=[...e.parentNode.children].filter(x=>x._r),a=rows.indexOf(anchor),b=rows.indexOf(e);
  sel=new Set(rows.slice(Math.min(a,b),Math.max(a,b)+1).map(x=>x._r))}
 else if(ev.ctrlKey||ev.metaKey){if(!sel.delete(r))sel.add(r);anchor=e}
 else{sel=new Set([r]);anchor=e;show(r,e)}
 paintSel();if(sel.size>1)flash(sel.size+' records selected. Drag them onto a FormList.')}
function dragStart(ev,r,e){
 if(!sel.has(r)){sel=new Set([r]);anchor=e;paintSel()}
 dragRecs=[...sel];ev.dataTransfer.setData(MIME,'1');ev.dataTransfer.effectAllowed='copy';
 if(dragRecs.length>1){const g=mk('',dragRecs.length+' records');g.style.cssText='position:absolute;top:-999px;padding:4px 10px;background:#1f6f6b;color:#fff;border-radius:5px';
  document.body.append(g);ev.dataTransfer.setDragImage(g,10,10);setTimeout(()=>g.remove())}}
function ensureMaster(P,o,warn,no){const k=lc(o);if(no.has(k))return false;
 const Q=plugins.find(q=>lc(q.name)===k);
 const bad=Q&&Q.masters.some(m=>lc(m)===lc(P.name))?o+' depends on '+P.name+', so making it a master of '+P.name+' would be circular.'
  :!P.all.every(r=>r===P.root[0]||r.t==='FLST')?P.name+' does not list '+o+' as a master, and it holds records other than FormLists. Masters can only be added safely to plugins made up of FormLists, because other records\' internal references would need renumbering. Add the master in xEdit first, then reopen the plugin here.'
  :P.masters.length>=253?'Too many masters.':null;
 if(bad){warn.add(bad);no.add(k);return false}
 if(!confirm('Add '+o+' as a master of '+P.name+'?')){no.add(k);return false}
 addMaster(P,o);return true}
function addEntries(fl,recs){const P=fl._P;if(locked(P))return;const warn=new Set(),no=new Set();let n=0,dup=0,changed=false;
 for(const src of recs){if(src===fl)continue;
  let x=xref(src,P);
  if(x.need){if(!ensureMaster(P,x.need,warn,no))continue;changed=true;x=xref(src,P)}
  if(fl.subs.some(s=>s.t==='LNAM'&&lnam(s)===x.id)){dup++;continue}
  const d=new Uint8Array(4);new DataView(d.buffer).setUint32(0,x.id,true);fl.subs.push({t:'LNAM',d});n++;changed=true}
 if(changed){setDirty(P,'Added '+n+(n===1?' entry':' entries')+' to '+(edid(fl)||hex(fl.id)));if(cur&&cur._P===P)show(cur,selRow)}
 if(warn.size)alert([...warn].join('\n\n'));
 flash('Added '+n+(n===1?' record':' records')+' to '+(edid(fl)||hex(fl.id))+(dup?' ('+dup+' already in the list)':''))}
const isTop=g=>g.k==='g'&&new DataView(g.tail.buffer,g.tail.byteOffset,4).getUint32(0,true)===0;
const topOf=r=>r._P.root.find(g=>isTop(g)&&g.kids===r._p);
function topGroup(P,t){let g=P.root.find(n=>isTop(n)&&s4(n.label,0)===t);
 if(!g){const src=P.root.find(isTop),tl=src?src.tail.slice():new Uint8Array(12);new DataView(tl.buffer).setUint32(0,0,true);
  g={k:'g',label:te.encode(t),tail:tl,kids:[],_p:P.root,_P:P};P.root.push(g)}return g}
function newEdid(P,b){let n=b+'_copy',i=1;while(P.all.some(r=>edid(r)===n))n=b+'_copy'+(++i);return n}
const setEdid=(x,t)=>{const e=x.subs.find(s=>s.t==='EDID');if(e)e.d=cat([te.encode(t),new Uint8Array(1)])};
function cloneRec(r){const P=r._P;if(locked(P))return;if(r===P.root[0])return;const id=nextId(P);if(id==null)return;
 const c=cl(r);c.id=id;c._P=P;c._p=r._p;if(edid(r))setEdid(c,newEdid(P,edid(r)));
 r._p.splice(r._p.indexOf(r)+1,0,c);P.all.push(c);setDirty(P,'Cloned '+(edid(r)||hex(r.id))+' as '+hex(id));
 if(r._el&&r._el.parentNode)r._el.after(rrow(c));show(c,c._el);flash('Cloned as '+hex(id))}
function copy(){const rs=sel.size?[...sel]:cur?[cur]:[];
 const ok=rs.filter(r=>r._P&&r!==r._P.root[0]&&topOf(r));
 if(!ok.length)return flash(rs.length?'Only top-level records can be copied, not cell contents':'Select records first');
 clip=ok.map(r=>({r:cl(r),P:r._P}));flash('Copied '+ok.length+(ok.length===1?' record':' records')+(ok.length<rs.length?' ('+(rs.length-ok.length)+' skipped)':''))}
function paste(){const P=activeP;if(!P)return;if(locked(P))return;if(!clip.length)return flash('Nothing copied yet');
 const warn=new Set(),no=new Set(),open=new Set(),m0=P.masters.length;collect(P.root,'',open);let n=0;
 for(const {r:c,P:Q} of clip){
  if(Q!==P&&c.t!=='FLST'){warn.add('Only FormLists can be pasted into a different plugin. Other record types hold references that cannot be remapped without their layouts. Copies within the same plugin work for any type.');continue}
  const x=cl(c);x._P=P;
  if(Q!==P)for(const s of x.subs)if(s.t==='LNAM'&&s.d.length===4){
   const v=lnam(s);let m=remapId(Q,v,P);
   if(m.need){if(!ensureMaster(P,m.need,warn,no)){s.bad=1;continue}m=remapId(Q,v,P)}
   s.d=new Uint8Array(4);new DataView(s.d.buffer).setUint32(0,m.id,true)}
  x.subs=x.subs.filter(s=>!s.bad);
  const id=nextId(P);if(id==null)break;x.id=id;
  const nm=edid(c);if(nm&&P.all.some(r=>edid(r)===nm))setEdid(x,newEdid(P,nm));
  const g=topGroup(P,c.t);x._p=g.kids;g.kids.push(x);P.all.push(x);open.add(String(P.root.indexOf(g)));n++}
 if(n||P.masters.length!==m0){setDirty(P,'Pasted '+n+(n===1?' record':' records'));rebuildPlugin(P,open,true);flash('Pasted '+n+(n===1?' record':' records')+' into '+P.name)}
 if(warn.size)alert([...warn].join('\n\n'))}
function collect(l,pre,o){l.forEach((n,i)=>{if(n.k==='g'&&n._w&&n._w.classList.contains('open')){o.add(pre+i);collect(n.kids,pre+i+'/',o)}})}
function reopen(l,pre,o){l.forEach((n,i)=>{if(n.k==='g'&&o.has(pre+i)){n._h.click();reopen(n.kids,pre+i+'/',o)}})}
function rebuildPlugin(P,open,po){const q=$('#q').value.trim();if(q){search(q);return}
 const body=P._w.querySelector(':scope>.kids');body.replaceChildren();
 if(po){P._w.classList.add('open');P._w.dataset.d=1;build(P.root,body);reopen(P.root,'',open)}else delete P._w.dataset.d}
function undo(P,back){if(!P)return;if(locked(P))return;const from=back?P.undo:P.redo,to=back?P.redo:P.undo;if(!from.length)return;
 clearTimeout(P._bt);to.push(P.root.map(cl));const snap=from.pop();
 const open=new Set(),po=P._w.classList.contains('open'),key=cur&&cur._P===P?[cur.id,cur.t]:null;collect(P.root,'',open);
 P.root=snap.map(cl);P.base=snap;P.pend=false;P.all=[];index(P.root,P);P.idx=null;
 P.masters=P.root[0].subs.filter(x=>x.t==='MAST').map(x=>td.decode(x.d).replace(/\0.*$/,''));
 rebuildPlugin(P,open,po);
 const r=key&&P.all.find(x=>x.id===key[0]&&x.t===key[1]);
 if(r)show(r,r._el);else if(key){cur=null;selRow=null;$('#detail').replaceChildren(mk('mut','Nothing selected.'))}
 P.dirty=true;mark(P);persist(P);status();flash(back?'Undid last change':'Redid change')}
function textBox(title,val,ok,fn,hint){const d=document.createElement('dialog');
 d.style.cssText='width:min(560px,92vw);background:var(--pn);color:var(--ink);border:1px solid var(--ln);border-radius:8px';
 d.innerHTML='<form method="dialog" style="display:flex;flex-direction:column;gap:8px"><b></b><small class="mut"></small><textarea rows="12" spellcheck="false" style="font:12.5px ui-monospace,monospace;background:var(--bg);border:1px solid var(--ln);border-radius:5px;padding:6px;color:inherit"></textarea><div style="display:flex;gap:8px;justify-content:flex-end"><button value="x">Cancel</button><button class="pri" value="ok"></button></div></form>';
 d.querySelector('b').textContent=title;d.querySelector('small').textContent=hint||'';d.querySelector('textarea').value=val;d.querySelector('.pri').textContent=ok;
 d.onclose=()=>{if(d.returnValue==='ok'&&fn)fn(d.querySelector('textarea').value);d.remove()};document.body.append(d);d.showModal()}
function exportList(fl){const P=fl._P;return fl.subs.filter(s=>s.t==='LNAM').map(s=>{const v=lnam(s);if(v==null)return'# invalid entry';const t=resolve(P,v);return t&&edid(t)?edid(t):'0x'+hex(v)}).join('\n')}
function importList(fl,txt){const P=fl._P,recs=[],bad=[];let raw=0;
 const byE=new Map();for(const q of [P,...plugins.filter(x=>x!==P)])for(const r of q.all){const e=lc(edid(r));if(e&&!byE.has(e))byE.set(e,r)}
 for(let l of txt.split(/\r?\n/)){l=l.replace(/#.*/,'').trim();if(!l)continue;
  const m=l.match(/^(?:0x)?([0-9a-f]{8})$/i);
  if(m){const id=parseInt(m[1],16)>>>0,t=resolve(P,id);
   if(t)recs.push(t);
   else if(id>>>24<=P.masters.length&&!fl.subs.some(s=>s.t==='LNAM'&&lnam(s)===id)){const d=new Uint8Array(4);new DataView(d.buffer).setUint32(0,id,true);fl.subs.push({t:'LNAM',d});raw++}
   else bad.push(l)}
  else{const t=byE.get(lc(l));t?recs.push(t):bad.push(l)}}

 if(recs.length)addEntries(fl,recs);else if(raw){setDirty(P,'Imported '+raw+' raw entries into '+(edid(fl)||hex(fl.id)));show(fl,selRow);flash('Added '+raw+' entries')}
 if(bad.length)alert('Not found ('+bad.length+'):\n'+bad.slice(0,30).join('\n')+(bad.length>30?'\n…':''))}
function locked(P){if(P&&P.locked){flash(P.name+' is locked — unlock it to edit.');return true}return false}
function flTools(r){const P=r._P,w=mk('');w.style.cssText='display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px';
 const ents=()=>r.subs.filter(s=>s.t==='LNAM'),nm=s=>{const t=resolve(P,lnam(s));return t?edid(t):''};
 const setL=(l,msg)=>{if(locked(P))return;const k=ents().length-l.length;r.subs=r.subs.filter(s=>s.t!=='LNAM').concat(l);setDirty(P,msg||('Reordered entries in '+(edid(r)||hex(r.id))));show(r,selRow);if(k>0)flash(k+' entries removed')};
 const b=(t,fn,ro)=>{const x=document.createElement('button');if(ro)x.className='ro-ok';x.textContent=t;x.onclick=fn;w.append(x)};
 b('Import…',()=>{if(locked(P))return;textBox('Import into '+(edid(r)||hex(r.id)),'','Import',t=>importList(r,t),'One EditorID or 8-digit hex FormID per line. Hex FormIDs use this plugin\'s numbering. Lines starting with # are ignored.')});
 b('Export…',()=>textBox('Export '+(edid(r)||hex(r.id)),exportList(r),'Close',null,'EditorIDs where known, otherwise hex FormIDs.'),true);
 b('Sort by name',()=>setL(ents().sort((a,z)=>(nm(a)||'\uffff').localeCompare(nm(z)||'\uffff')||lnam(a)-lnam(z))));
 b('Sort by FormID',()=>setL(ents().sort((a,z)=>lnam(a)-lnam(z))));
 b('Remove duplicates',()=>{const seen=new Set();setL(ents().filter(s=>{const v=lnam(s);if(seen.has(v))return false;seen.add(v);return true}),'Removed duplicate entries from '+(edid(r)||hex(r.id)))});
 b('Remove broken',()=>setL(ents().filter(s=>{const v=lnam(s);if(v==null)return false;const o=origin(P,v);
  return !(o===P.name||plugins.some(q=>lc(q.name)===lc(o)))||!!resolve(P,v)}),'Removed broken entries from '+(edid(r)||hex(r.id))));
 return w}
function flPanel(r){const P=r._P,p=mk('fl'),ents=r.subs.filter(s=>s.t==='LNAM');
 p.append(mk('flh','Entries ('+ents.length+'). Drag records from the tree, including other open plugins, onto this box.'));
 dropZone(p,r);p.append(flTools(r));
 if(!ents.length)p.append(mk('mut','Empty. Drop records here.'));
 ents.forEach((s,i)=>{const id=lnam(s),t=id==null?null:resolve(P,id),row=mk('fe'),ix=document.createElement('span'),c=document.createElement('code'),nm=mk('nm');
  ix.className='mut';ix.style.cssText='min-width:2em;text-align:right;font:12px ui-monospace,monospace';ix.textContent=(i+1)+'.';
  c.textContent=id==null?'invalid':hex(id);
  nm.textContent=id==null?'Entry is not 4 bytes':t?t.t+'  '+(edid(t)||'')+(t._P!==P?'  ('+t._P.name+')':''):(id>>>24<P.masters.length?'from '+P.masters[id>>>24]+' (not open)':'not found in this file');
  if(t)nm.onclick=()=>show(t,t._el);
  const b=(txt,fn,dis)=>{const x=document.createElement('button');x.textContent=txt;x.disabled=!!dis;x.onclick=fn;return x};
  const mv=j=>{const a=r.subs.indexOf(s),z=r.subs.indexOf(ents[j]);[r.subs[a],r.subs[z]]=[r.subs[z],r.subs[a]];setDirty(P);show(r,selRow)};
  row.append(ix,c,nm,b('Up',()=>mv(i-1),i===0),b('Down',()=>mv(i+1),i===ents.length-1),
   b('Remove',()=>{r.subs.splice(r.subs.indexOf(s),1);setDirty(P);show(r,selRow)}));
  p.append(row)});
 return p}
function nextId(P){const n=P.masters.length;let mx=0x7FF;
 for(const r of P.all)if(r.id>>>24===n)mx=Math.max(mx,r.id&0xFFFFFF);
 const h=P.root[0].subs.find(x=>x.t==='HEDR');if(h&&h.d.length>=12)mx=Math.max(mx,(new DataView(h.d.buffer,h.d.byteOffset,h.d.byteLength).getUint32(8,true)-1)&0xFFFFFF);
 const o=mx+1;
 if((P.root[0].flags&0x200)&&o>0xFFF){alert('This ESL-flagged plugin has run out of FormIDs (limit 0xFFF).');return null}
 if(o>0xFFFFFF||n>0xFF){alert('No free FormIDs left.');return null}
 return ((n<<24)|o)>>>0}
function newFormList(){const P=activeP;if(!P)return;if(locked(P))return;
 const name=(prompt('EditorID for the new FormList in '+P.name)||'').trim();if(!name)return;
 if(P.all.some(r=>edid(r)===name)&&!confirm('A record with this EditorID already exists. Create anyway?'))return;
 const id=nextId(P);if(id==null)return;
 const tail=new Uint8Array(8);tail.set(P.root[0].tail.slice(4,6),4);
 const r={k:'r',t:'FLST',flags:0,id,tail,subs:[{t:'EDID',d:cat([te.encode(name),new Uint8Array(1)])}]};
 let g=P.root.find(n=>n.k==='g'&&s4(n.label,0)==='FLST'&&new DataView(n.tail.buffer).getUint32(0,true)===0);
 if(!g){const src=P.root.find(n=>n.k==='g'),tl=src?src.tail.slice():new Uint8Array(12);new DataView(tl.buffer).setUint32(0,0,true);
  g={k:'g',label:te.encode('FLST'),tail:tl,kids:[],_p:P.root,_P:P};P.root.push(g)}
 r._p=g.kids;r._P=P;g.kids.push(r);P.all.push(r);setDirty(P);
 $('#q').value='';search('');
 if(!P._w.classList.contains('open'))P._h.click();
 if(!g._w.classList.contains('open'))g._h.click();
 show(r,r._el);if(r._el)r._el.scrollIntoView({block:'center'})}
function fixHedr(P){const h=P.root[0].subs.find(x=>x.t==='HEDR');if(!h||h.d.length<12)return;
 const dv=new DataView(h.d.buffer,h.d.byteOffset,h.d.byteLength);let n=0,mx=0;
 const w=l=>{for(const x of l){if(x.k==='g'){n++;w(x.kids)}else if(x!==P.root[0]){n++;if(x.id>>>24===P.masters.length)mx=Math.max(mx,x.id&0xFFFFFF)}}};w(P.root);
 dv.setUint32(4,n,true);dv.setUint32(8,Math.max(dv.getUint32(8,true),mx+1),true)}
function status(){const st=$('#st'),P=activeP;for(const i of ['q','save','newfl','copy','paste','dup','stats','wssave','sortmode','typefilter','cmprec'])$('#'+i).disabled=!plugins.length;$('#cmp').disabled=plugins.length<2;$('#undo').disabled=!P||!(P.undo.length||P.pend);$('#redo').disabled=!P||!P.redo.length;st.className=plugins.some(p=>p.dirty)?'d':'';
 st.textContent=!plugins.length?'No file loaded':P?P.name+' · '+(P.all.length-1).toLocaleString()+' records · '+P.masters.length+' masters'+(P.dirty?' · modified':'')+(plugins.length>1?' · '+plugins.length+' plugins open':''):plugins.length+' plugins open'}
function mark(P){if(P._lab)P._lab.textContent=P.name+(P.dirty?' •':'')}
function hasRecords(n){return n.k==='r'?true:n.kids.some(hasRecords)}
function filteredRoot(P){const tf=typeFilter;
 return P.root.filter(n=>n===P.root[0]||(n.k==='r')||(n.k==='g'&&hasRecords(n)&&(!tf.length||tf.includes(s4(n.label,0).toUpperCase()))))}
function pluginRow(P,host){const w=mk(),body=mk('kids'),h=mk('row grp'),lab=document.createElement('span'),lk=document.createElement('button'),x=document.createElement('button');
 lab.style.cssText='flex:1;overflow:hidden;text-overflow:ellipsis';x.textContent='Close';x.style.cssText='padding:0 8px;font-size:12px';
 lk.style.cssText='padding:0 8px;font-size:12px';lk.className='lockbtn';lk.textContent=P.locked?'Unlock':'Lock';
 h.style.cssText='display:flex;gap:8px;align-items:center';h.append(lab,lk,x);
 h.onclick=()=>{w.classList.toggle('open');if(!w.dataset.d){w.dataset.d=1;build(filteredRoot(P),body)}show(P.root[0],null)};
 x.onclick=e=>{e.stopPropagation();closePlugin(P)};
 lk.onclick=e=>{e.stopPropagation();P.locked=!P.locked;lk.textContent=P.locked?'Unlock':'Lock';w.classList.toggle('plocked',P.locked);
  flash(P.name+(P.locked?' locked':' unlocked'));if(cur&&cur._P===P)show(cur,selRow)};
 w.classList.toggle('plocked',!!P.locked);
 P._w=w;P._h=h;P._lab=lab;mark(P);w.append(h,body);host.append(w)}
function closePlugin(P){const others=plugins.filter(q=>q!==P&&q.dirty).length;
 if(P.dirty){const msg=P.name+' has unsaved changes. Close anyway?'+(others?' ('+others+' other plugin'+(others>1?'s':'')+' also '+(others>1?'have':'has')+' unsaved changes.)':'');
  if(!confirm(msg))return}
 clearTimeout(P._ps);clearTimeout(P._bt);dbDo('readwrite',x=>x.delete(P.name));plugins=plugins.filter(q=>q!==P);if(activeP===P)activeP=plugins[0]||null;
 recent=recent.filter(k=>!k.startsWith(P.name+'|'));renderRecent();
 if(cur&&cur._P===P){cur=null;selRow=null;$('#detail').replaceChildren(mk('mut','Plugin closed.'))}
 search($('#q').value.trim());if(!plugins.length)$('#q').disabled=$('#save').disabled=$('#newfl').disabled=true;status()}
function search(q){const t=$('#tree');t.replaceChildren();sel=new Set();anchor=null;
 if(!q){t.append(recentSection());t.append(pinSection());plugins.forEach(P=>pluginRow(P,t));return}
 const l=q.toLowerCase(),u=q.toUpperCase(),matches=[];
 for(const P of plugins)for(const r of P.all)if(r.t.toLowerCase()===l||edid(r).toLowerCase().includes(l)||hex(r.id).includes(u))matches.push({r,P});
 if(sortMode!=='file')matches.sort((a,b)=>sortCmp(a.r,b.r));
 matches.slice(0,300).forEach(({r,P})=>{const e=rrow(r);if(plugins.length>1)e.append(Object.assign(document.createElement('span'),{className:'mut',textContent:'  '+P.name}));t.append(e)});
 if(matches.length>300)t.append(mk('row mut','First 300 matches shown. Refine the search.'));
 if(!matches.length)t.append(mk('row mut','No matches'))}
async function load(f,pre){
 if(plugins.some(p=>lc(p.name)===lc(f.name)))return flash(f.name+' is already open');
 try{const u=pre?pre.bytes:new Uint8Array(await f.arrayBuffer());
  if(s4(u,0)!=='TES4')throw new Error('missing TES4 header, so this is not a Skyrim-format plugin');
  $('#st').textContent='Parsing '+f.name+'…';
  const P={name:f.name,root:await parse(u,0,u.length),all:[],idx:null,dirty:!!(pre&&pre.dirty),masters:[],undo:[],redo:[],pend:false,t:pre?pre.t:Date.now()};
  index(P.root,P);P.base=P.root.map(cl);P.masters=P.root[0].subs.filter(x=>x.t==='MAST').map(x=>td.decode(x.d).replace(/\0.*$/,''));
  plugins.push(P);activeP=P;$('#q').disabled=$('#save').disabled=$('#newfl').disabled=false;
  const q=$('#q').value.trim();if(q){search(q);show(P.root[0],null)}else{pluginRow(P,$('#tree'));P._h.click()}
  status();if(!pre)persist(P)}
 catch(e){$('#st').textContent='Could not read '+f.name+': '+e.message;$('#st').className='d'}}
async function loadAll(fs){for(const f of fs)await load(f)}
$('#newfl').onclick=newFormList;$('#undo').onclick=()=>undo(activeP,true);$('#redo').onclick=()=>undo(activeP,false);$('#copy').onclick=copy;$('#paste').onclick=paste;
$('#open').onclick=()=>$('#file').click();
try{if(localStorage.pl_notree==='1')document.body.classList.add('notree')}catch(e){}
$('#toggletree').textContent=document.body.classList.contains('notree')?'Show tree':'Hide tree';
$('#toggletree').onclick=()=>{document.body.classList.toggle('notree');const on=document.body.classList.contains('notree');
 $('#toggletree').textContent=on?'Show tree':'Hide tree';try{localStorage.pl_notree=on?'1':'0'}catch(e){}};

(()=>{const sp=$('#splitter'),tree=$('#tree'),main=document.querySelector('main');
 const vertical=()=>getComputedStyle(main).flexDirection==='column';
 const apply=px=>{if(vertical())tree.style.height=px+'px';else tree.style.width=px+'px'};
 try{const saved=vertical()?localStorage.pl_tree_h:localStorage.pl_tree_w;if(saved)apply(parseInt(saved,10))}catch(e){}
 let dragging=false,startPos=0,startSize=0;
 sp.addEventListener('pointerdown',e=>{dragging=true;sp.classList.add('dragging');sp.setPointerCapture(e.pointerId);
  const v=vertical();startPos=v?e.clientY:e.clientX;startSize=v?tree.offsetHeight:tree.offsetWidth;e.preventDefault()});
 sp.addEventListener('pointermove',e=>{if(!dragging)return;const v=vertical(),pos=v?e.clientY:e.clientX,delta=pos-startPos;
  const bound=v?main.offsetHeight:main.offsetWidth,min=120,max=Math.max(min,bound-200);
  const size=Math.min(max,Math.max(min,startSize+delta));apply(size)});
 const end=()=>{if(!dragging)return;dragging=false;sp.classList.remove('dragging');
  const v=vertical();try{if(v)localStorage.pl_tree_h=tree.offsetHeight;else localStorage.pl_tree_w=tree.offsetWidth}catch(e){}};
 sp.addEventListener('pointerup',end);sp.addEventListener('pointercancel',end);
 sp.addEventListener('dblclick',()=>{tree.style.width='';tree.style.height='';try{localStorage.removeItem('pl_tree_w');localStorage.removeItem('pl_tree_h')}catch(e){}});
})();
$('#file').onchange=async e=>{await loadAll([...e.target.files]);e.target.value=''};
$('#q').oninput=e=>search(e.target.value.trim());
$('#save').onclick=()=>{const P=activeP;if(!P)return;fixHedr(P);const a=document.createElement('a');a.href=URL.createObjectURL(new Blob([cat(P.root.map(ser))]));a.download=P.name;a.click();
 setTimeout(()=>URL.revokeObjectURL(a.href),4000);P.dirty=false;mark(P);status();persist(P);flash('Saved a copy of '+P.name)};
addEventListener('dragover',e=>{if(e.dataTransfer.types.includes('Files')){e.preventDefault();document.body.classList.add('drag')}});
addEventListener('dragleave',()=>document.body.classList.remove('drag'));
addEventListener('drop',e=>{e.preventDefault();document.body.classList.remove('drag');if(e.dataTransfer.files.length)loadAll([...e.dataTransfer.files])});
addEventListener('beforeunload',e=>{if(plugins.some(p=>p.dirty)){e.preventDefault();e.returnValue=''}});
const DBP=()=>new Promise((ok,no)=>{const q=indexedDB.open('pluginlens',1);q.onupgradeneeded=()=>q.result.createObjectStore('p',{keyPath:'name'});q.onsuccess=()=>ok(q.result);q.onerror=()=>no(q.error)});
async function dbDo(mode,fn){try{const d=await DBP();return await new Promise(ok=>{const q=fn(d.transaction('p',mode).objectStore('p'));if(q){q.onsuccess=()=>ok(q.result);q.onerror=()=>ok(null)}else ok(null)})}catch(e){return null}}
const remember=()=>$('#rem').checked;
function persist(P){if(!remember())return;clearTimeout(P._ps);P._ps=setTimeout(()=>dbDo('readwrite',x=>x.put({name:P.name,t:P.t,dirty:P.dirty,bytes:cat(P.root.map(ser))})),600)}
try{if(localStorage.pl_rem==='0')$('#rem').checked=false}catch(e){}
$('#rem').onchange=()=>{try{localStorage.pl_rem=remember()?1:0}catch(e){}if(remember())plugins.forEach(persist);else dbDo('readwrite',x=>x.clear())};

function pinKey(r){return r._P.name+'|'+hex(r.id)}
function loadPins(){try{return new Set(JSON.parse(localStorage.pl_pins||'[]'))}catch(e){return new Set()}}
function savePins(s){try{localStorage.pl_pins=JSON.stringify([...s])}catch(e){}}
let pinSet=loadPins();
const isPinned=r=>pinSet.has(pinKey(r));
function togglePin(r){const k=pinKey(r);if(!pinSet.delete(k))pinSet.add(k);savePins(pinSet)}
function recentSection(){const w=mk('pinsec recentsec'),ks=recent.slice(0,15);
 if(!ks.length)return w;
 const h=mk('flh');h.style.cssText='display:flex;align-items:center;gap:8px';
 h.append('Recently viewed');
 const clr=document.createElement('button');clr.textContent='Clear';clr.style.cssText='padding:0 6px;font-size:11px;margin-left:auto';
 clr.onclick=()=>{recent=[];renderRecent()};h.append(clr);w.append(h);
 for(const k of ks){const i=k.indexOf('|'),pn=k.slice(0,i),id=k.slice(i+1),P=plugins.find(x=>x.name===pn),r=P&&byId(P,parseInt(id,16)>>>0);
  if(!r)continue;
  const e=rrow(r);if(plugins.length>1)e.append(Object.assign(document.createElement('span'),{className:'mut',textContent:'  '+P.name}));w.append(e)}
 return w}
function renderRecent(){if($('#q').value.trim())return;const old=document.querySelector('.recentsec');if(old)old.replaceWith(recentSection())}
function pinSection(){const w=mk('pinsec'),ks=[...pinSet];
 if(!ks.length)return w;
 w.append(mk('flh','Pinned'));
 for(const k of ks){const[pn,id]=k.split('|'),P=plugins.find(x=>x.name===pn),r=P&&byId(P,parseInt(id,16)>>>0);
  if(!r){continue}
  const e=rrow(r);if(plugins.length>1)e.append(Object.assign(document.createElement('span'),{className:'mut',textContent:'  '+P.name}));w.append(e)}
 return w}
function renderPins(){if($('#q').value.trim())return;const old=document.querySelector('.pinsec');if(old)old.replaceWith(pinSection())}

function pickFormId(onPick,hint){const d=document.createElement('dialog');
 d.style.cssText='width:min(520px,92vw);max-height:80vh;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:0';
 d.innerHTML='<div style="padding:10px 12px;border-bottom:1px solid var(--ln)"><b>Pick a record</b><br><small class="mut"></small><br><input type="search" class="fld" style="width:100%;margin-top:6px" placeholder="EditorID, FormID or type"></div><div style="max-height:50vh;overflow:auto;padding:4px"></div><div style="padding:8px 12px;border-top:1px solid var(--ln);text-align:right"><button value="x">Cancel</button></div>';
 d.querySelector('small').textContent=hint||'Searches every open plugin.';
 const box=d.querySelector('div:nth-child(2)'),inp=d.querySelector('input');
 const run=q=>{box.replaceChildren();if(!q){box.append(mk('mut','Type to search…'));return}
  const l=q.toLowerCase(),u=q.toUpperCase();let n=0;
  outer:for(const P of plugins)for(const r of P.all){if(r.t.toLowerCase()===l||edid(r).toLowerCase().includes(l)||hex(r.id).includes(u)){
   const row=mk('pk-row'),c=document.createElement('code');c.textContent=hex(r.id);
   row.append(c,r.t+'  '+(edid(r)||'')+(plugins.length>1?'  ('+P.name+')':''));
   row.onclick=()=>{d.close();onPick(r)};box.append(row);if(++n>=200)break outer}}
  if(!n)box.append(mk('mut','No matches'))};
 inp.oninput=()=>run(inp.value.trim());
 d.querySelector('button').onclick=()=>d.close();
 d.onclose=()=>d.remove();document.body.append(d);d.showModal();inp.focus()}

function globPanel(r){const w=mk('fl'),fn=r.subs.find(x=>x.t==='FNAM'),fl=r.subs.find(x=>x.t==='FLTV');
 w.append(mk('flh','Global variable'));
 const row=mk('fe');row.style.borderTop='none';
 const tsel=document.createElement('select');tsel.className='fld';
 [['s','Short'],['l','Long'],['f','Float']].forEach(([v,t])=>{const o=document.createElement('option');o.value=v;o.textContent=t;tsel.append(o)});
 tsel.value=fn&&fn.d.length?String.fromCharCode(fn.d[0]):'f';
 const vinp=document.createElement('input');vinp.className='fld';vinp.style.width='140px';
 vinp.value=fl&&fl.d.length===4?new DataView(fl.d.buffer,fl.d.byteOffset,4).getFloat32(0,true):'';
 tsel.onchange=()=>{if(locked(r._P)){tsel.value=fn&&fn.d.length?String.fromCharCode(fn.d[0]):'f';return}const d=new Uint8Array([tsel.value.charCodeAt(0)]);if(fn)fn.d=d;else r.subs.unshift({t:'FNAM',d});setDirty(r._P,'Changed type of '+(edid(r)||hex(r.id)))};
 vinp.oninput=()=>{if(locked(r._P))return;const v=parseFloat(vinp.value);if(isNaN(v))return;const d=new Uint8Array(4);new DataView(d.buffer).setFloat32(0,v,true);
  if(fl)fl.d=d;else r.subs.push({t:'FLTV',d});setDirty(r._P,'Edited value of '+(edid(r)||hex(r.id)))};
 row.append('Type',tsel,'Value',vinp);w.append(row);
 const note=mk('mut','All globals store their value as a float regardless of type.');note.style.cssText='font-size:11px;padding:4px 0 0';w.append(note);
 return w}

function kwdaPanel(r){const P=r._P,w=mk('fl'),get=()=>{const d=r.subs.find(x=>x.t==='KWDA');if(!d)return[];const n=Math.floor(d.d.length/4),v=new DataView(d.d.buffer,d.d.byteOffset,d.d.byteLength),o=[];for(let i=0;i<n;i++)o.push(v.getUint32(i*4,true));return o};
 const setv=(ids,msg)=>{if(locked(P))return;r.subs=r.subs.filter(x=>x.t!=='KWDA'&&x.t!=='KSIZ');
  if(ids.length){const kd=new Uint8Array(4);new DataView(kd.buffer).setUint32(0,ids.length,true);r.subs.push({t:'KSIZ',d:kd});
   const wd=new Uint8Array(ids.length*4),dv=new DataView(wd.buffer);ids.forEach((v,i)=>dv.setUint32(i*4,v,true));r.subs.push({t:'KWDA',d:wd})}
  setDirty(P,msg||('Edited keywords on '+(edid(r)||hex(r.id))));show(r,selRow)};
 w.append(mk('flh','Keywords ('+get().length+')'));
 get().forEach((id,i)=>{const t=resolve(P,id),row=mk('fe'),c=document.createElement('code'),nm=mk('nm');
  c.textContent=hex(id);nm.textContent=t?edid(t)||t.t:(id>>>24<P.masters.length?'from '+P.masters[id>>>24]:'not found');
  if(t)nm.onclick=()=>show(t,t._el);
  const rmv=document.createElement('button');rmv.textContent='Remove';rmv.onclick=()=>{const l=get();l.splice(i,1);setv(l,'Removed a keyword from '+(edid(r)||hex(r.id)))};
  row.append(c,nm,rmv);w.append(row)});
 const add=document.createElement('button');add.textContent='Add keyword…';
 add.onclick=()=>pickFormId(t=>{const x=xref(t,P);if(x.need){if(!confirm('Add '+x.need+' as a master of '+P.name+'?'))return;addMaster(P,x.need)}
  const l=get();const id=xref(t,P).id;if(l.includes(id))return flash('Already has this keyword');l.push(id);setv(l,'Added a keyword to '+(edid(r)||hex(r.id)))},'Pick a KYWD record.');
 w.append(add);dropZone(w,{t:'__KWDA',id:-1,_P:P,subs:[]});
 w.ondrop=e=>{e.preventDefault();e.stopPropagation();w.classList.remove('over');if(locked(P))return;if(!dragRecs.length)return;
  const l=get();let n=0;for(const src of dragRecs){const x=xref(src,P);if(x.need)continue;if(!l.includes(x.id)){l.push(x.id);n++}}
  if(n)setv(l,'Added '+n+' keyword(s) to '+(edid(r)||hex(r.id)))};
 return w}

function addPickButton(sub_h,s,r,repaint){if(s.d.length!==4)return;
 const pk=document.createElement('button');pk.textContent='Pick…';
 pk.onclick=()=>pickFormId(t=>{const x=xref(t,r._P);if(x.need){if(!confirm('Add '+x.need+' as a master of '+r._P.name+'?'))return;addMaster(r._P,x.need)}
  const d=new Uint8Array(4);new DataView(d.buffer).setUint32(0,xref(t,r._P).id,true);s.d=d;setDirty(r._P,'Set '+s.t+' on '+(edid(r)||hex(r.id))+' via picker');repaint()});
 sub_h.append(pk)}

function whereUsed(r){const P=r._P,id=r.id,hits=[];
 for(const Q of plugins){const x=remapId(P,id,Q);if(x.need)continue;
  for(const rec of Q.all){if(rec===r)continue;for(const s of rec.subs)if(s.d.length===4){
   if(new DataView(s.d.buffer,s.d.byteOffset,4).getUint32(0,true)===x.id){hits.push({rec,s,Q});break}}}}
 const d=document.createElement('dialog');d.style.cssText='width:min(560px,92vw);max-height:80vh;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:0';
 const box=document.createElement('div');box.style.cssText='max-height:60vh;overflow:auto;padding:6px';
 if(!hits.length)box.append(mk('mut','No open record has a 4-byte field matching this FormID.'));
 hits.slice(0,300).forEach(({rec,s,Q})=>{const row=mk('pk-row'),c=document.createElement('code');c.textContent=hex(rec.id);
  row.append(c,rec.t+'  '+(edid(rec)||'')+'  ·'+s.t+(plugins.length>1?'  ('+Q.name+')':''));row.onclick=()=>{d.close();show(rec,rec._el)};box.append(row)});
 const hd=document.createElement('div');hd.style.cssText='padding:10px 12px;border-bottom:1px solid var(--ln)';
 hd.innerHTML='<b>Where used: '+(edid(r)||hex(r.id))+'</b><br><small class="mut">Heuristic: matches any 4-byte subrecord whose value equals this FormID (remapped per plugin). May include false positives from unrelated numbers, and can\'t see fields that aren\'t exactly 4 bytes.</small>';
 const ft=document.createElement('div');ft.style.cssText='padding:8px 12px;border-top:1px solid var(--ln);text-align:right';
 const cb=document.createElement('button');cb.textContent='Close';cb.onclick=()=>d.close();ft.append(cb);
 d.append(hd,box,ft);d.onclose=()=>d.remove();document.body.append(d);d.showModal()}

function findDuplicates(){if(!plugins.length)return;
 const byEdid=new Map(),byId=new Map(),dupE=[],dupI=[];
 for(const P of plugins)for(const r of P.all){if(r===P.root[0])continue;
  const e=lc(edid(r));if(e){if(!byEdid.has(e))byEdid.set(e,[]);byEdid.get(e).push({r,P})}
  const k=P.name+'|'+r.id;if(!byId.has(k))byId.set(k,[]);byId.get(k).push({r,P})}
 for(const[e,l] of byEdid)if(l.length>1)dupE.push([e,l]);
 for(const[k,l] of byId)if(l.length>1)dupI.push([k,l]);
 const d=document.createElement('dialog');d.style.cssText='width:min(600px,92vw);max-height:80vh;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:0';
 const box=document.createElement('div');box.style.cssText='max-height:60vh;overflow:auto;padding:6px';
 if(!dupE.length&&!dupI.length)box.append(mk('mut','No duplicate EditorIDs or FormIDs found across open plugins.'));
 if(dupI.length){box.append(mk('flh','Duplicate FormIDs within a plugin'));dupI.forEach(([k,l])=>l.forEach(({r,P})=>{const row=mk('pk-row'),c=document.createElement('code');c.textContent=hex(r.id);row.append(c,r.t+'  '+(edid(r)||'')+'  ('+P.name+')');row.onclick=()=>{d.close();show(r,r._el)};box.append(row)}))}
 if(dupE.length){box.append(mk('flh','Shared EditorIDs (same name, different records — may be intentional overrides)'));dupE.forEach(([e,l])=>l.forEach(({r,P})=>{const row=mk('pk-row'),c=document.createElement('code');c.textContent=hex(r.id);row.append(c,r.t+'  '+edid(r)+'  ('+P.name+')');row.onclick=()=>{d.close();show(r,r._el)};box.append(row)}))}
 const hd=document.createElement('div');hd.style.cssText='padding:10px 12px;border-bottom:1px solid var(--ln)';
 hd.innerHTML='<b>Duplicates</b><br><small class="mut">Duplicate FormIDs in one plugin are invalid and should be fixed. Shared EditorIDs across plugins are often normal (overriding masters), listed for your review.</small>';
 const ft=document.createElement('div');ft.style.cssText='padding:8px 12px;border-top:1px solid var(--ln);text-align:right';
 const cb=document.createElement('button');cb.textContent='Close';cb.onclick=()=>d.close();ft.append(cb);
 d.append(hd,box,ft);d.onclose=()=>d.remove();document.body.append(d);d.showModal()}

function comparePlugins(){if(plugins.length<2)return flash('Open at least two plugins to compare');
 const d=document.createElement('dialog');d.style.cssText='width:min(560px,92vw);max-height:82vh;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:0';
 const hd=document.createElement('div');hd.style.cssText='padding:10px 12px;border-bottom:1px solid var(--ln);display:flex;gap:8px;align-items:center;flex-wrap:wrap';
 const sa=document.createElement('select'),sb=document.createElement('select');[sa,sb].forEach(sel=>{sel.className='fld';plugins.forEach(P=>{const o=document.createElement('option');o.textContent=P.name;sel.append(o)})});
 sb.selectedIndex=Math.min(1,plugins.length-1);
 const go=document.createElement('button');go.textContent='Compare';go.className='pri';
 hd.append('A:',sa,'B:',sb,go);
 const box=document.createElement('div');box.style.cssText='max-height:60vh;overflow:auto;padding:6px';
 go.onclick=()=>{box.replaceChildren();const A=plugins[sa.selectedIndex],B=plugins[sb.selectedIndex];if(A===B)return box.append(mk('mut','Pick two different plugins.'));
  const key=r=>r.t+'|'+lc(edid(r));const am=new Map(A.all.filter(r=>r!==A.root[0]).map(r=>[key(r),r])),bm=new Map(B.all.filter(r=>r!==B.root[0]).map(r=>[key(r),r]));
  const added=[],removed=[],changed=[];
  for(const[k,r] of bm)if(!am.has(k))added.push(r);
  for(const[k,r] of am)if(!bm.has(k))removed.push(r);
  for(const[k,ra] of am){const rb=bm.get(k);if(!rb)continue;
   const sa2=JSON.stringify(ra.subs.filter(s=>s.t!=='EDID').map(s=>[s.t,[...s.d]])),sb2=JSON.stringify(rb.subs.filter(s=>s.t!=='EDID').map(s=>[s.t,[...s.d]]));
   if(sa2!==sb2)changed.push(rb)}
  const sec=(title,list,P)=>{if(!list.length)return;box.append(mk('flh',title+' ('+list.length+')'));
   list.slice(0,200).forEach(r=>{const row=mk('pk-row'),c=document.createElement('code');c.textContent=hex(r.id);row.append(c,r.t+'  '+(edid(r)||''));row.onclick=()=>{d.close();show(r,r._el)};box.append(row)})};
  sec('Only in '+B.name,added,B);sec('Only in '+A.name,removed,A);sec('Changed (same EditorID, different subrecords)',changed,B);
  if(!added.length&&!removed.length&&!changed.length)box.append(mk('mut','No differences found by EditorID.'))};
 const note=mk('mut','Matches records by type + EditorID, so this works best for two builds of the same plugin, not unrelated files.');note.style.cssText='padding:6px 12px;font-size:11px';
 const ft=document.createElement('div');ft.style.cssText='padding:8px 12px;border-top:1px solid var(--ln);text-align:right';
 const cb=document.createElement('button');cb.textContent='Close';cb.onclick=()=>d.close();ft.append(cb);
 d.append(hd,note,box,ft);d.onclose=()=>d.remove();document.body.append(d);d.showModal();go.onclick()}

function decode4(P,d){if(d.length!==4)return null;const v=new DataView(d.buffer,d.byteOffset,4).getUint32(0,true);const t=P?resolve(P,v):null;
 return t?(t.t+' '+(edid(t)||'')).trim():null}
function decodeVal(r,s){if(!s)return'';const nm=decode4(r&&r._P,s.d);
 if(nm)return hex(new DataView(s.d.buffer,s.d.byteOffset,4).getUint32(0,true))+'  — '+nm;
 if(TXT(s.d))return td.decode(s.d.subarray(0,s.d.length-(s.d[s.d.length-1]===0?1:0)));
 return[...s.d].slice(0,20).map(x=>hex(x,2)).join(' ')+(s.d.length>20?' …':'')}
function subRows(r){const groups=new Map();for(const s of r.subs){if(!groups.has(s.t))groups.set(s.t,[]);groups.get(s.t).push(s)}
 const rows=[];for(const[t,arr] of groups)arr.forEach((s,i)=>rows.push({tag:t,key:t+(arr.length>1?' #'+(i+1):''),sub:s}));return rows}
function unionRows(a,b){const ra=subRows(a),rb=subRows(b),bm=new Map(rb.map(x=>[x.key,x])),seen=new Set(),out=[];
 ra.forEach(x=>{out.push({key:x.key,tag:x.tag,aSub:x.sub,bSub:bm.has(x.key)?bm.get(x.key).sub:undefined});seen.add(x.key)});
 rb.forEach(x=>{if(!seen.has(x.key))out.push({key:x.key,tag:x.tag,aSub:undefined,bSub:x.sub})});return out}
function subCell(r,s,opts){const wrap=mk('cellwrap');wrap.style.cssText='display:flex;gap:4px;align-items:flex-start;flex-wrap:wrap;min-height:22px';
 const acceptDrop=()=>{if(locked(r._P))return;
  if(cellDrag&&cellDrag.key===opts.key&&cellDrag.r!==r){const src=cellDrag.s;let nd=src.d.slice(),from=cellDrag.r._P.name;
   if(nd.length===4&&cellDrag.r._P!==r._P){const rv=new DataView(nd.buffer,nd.byteOffset,4).getUint32(0,true),tgt=resolve(cellDrag.r._P,rv);
    if(tgt){const x=xref(tgt,r._P);if(x.need){if(!confirm('Add '+x.need+' as a master of '+r._P.name+'?')){cellDrag=null;return}addMaster(r._P,x.need)}
     nd=new Uint8Array(4);new DataView(nd.buffer).setUint32(0,xref(tgt,r._P).id,true)}}
   if(s){s.d=nd;setDirty(r._P,'Copied '+opts.tag+' from '+from+' (side by side)');opts.refresh()}
   else{r.subs.push({t:opts.tag,d:nd});setDirty(r._P,'Copied '+opts.tag+' from '+from+' (side by side)');opts.rebuild()}
   cellDrag=null;return true}
  if(dragRecs[0]&&(!s||s.d.length===4)){const t=dragRecs[0],x=xref(t,r._P);
   if(x.need){if(!confirm('Add '+x.need+' as a master of '+r._P.name+'?'))return true;addMaster(r._P,x.need)}
   const nd=new Uint8Array(4);new DataView(nd.buffer).setUint32(0,xref(t,r._P).id,true);
   if(s){s.d=nd;setDirty(r._P,'Set '+s.t+' on '+(edid(r)||hex(r.id))+' via drag');opts.refresh()}
   else{r.subs.push({t:opts.tag,d:nd});setDirty(r._P,'Added '+opts.tag+' to '+(edid(r)||hex(r.id))+' via drag');opts.rebuild()}
   return true}
  return false};
 wrap.ondragover=e=>{if(e.dataTransfer.types.includes(MIME)){e.preventDefault();wrap.classList.add('over')}};
 wrap.ondragleave=()=>wrap.classList.remove('over');
 wrap.ondrop=e=>{e.preventDefault();wrap.classList.remove('over');acceptDrop()};
 if(!s){wrap.append(mk('miss','(not present)'));return wrap}
 const ro=r._P.locked;
 const is4=s.d.length===4,txt=TXT(s.d);
 const inp=document.createElement('input');inp.className='fld';inp.disabled=ro;inp.style.cssText='font:12px ui-monospace,monospace;min-width:90px;flex:1';
 const setv=nd=>{s.d=nd;setDirty(r._P,'Edited '+s.t+' on '+(edid(r)||hex(r.id))+' (side by side)');opts.refresh()};
 if(txt&&!is4){inp.type='text';inp.value=td.decode(s.d.subarray(0,s.d.length-(s.d[s.d.length-1]===0?1:0)));
  inp.oninput=()=>setv(cat([te.encode(inp.value),new Uint8Array(1)]))}
 else{inp.type='text';inp.spellcheck=false;inp.value=[...s.d].map(x=>hex(x,2)).join(' ');
  inp.oninput=()=>{const c=inp.value.replace(/[\s,]/g,'');if(!/^([0-9a-f]{2})*$/i.test(c)){inp.classList.add('bad');return}
   inp.classList.remove('bad');const nd=new Uint8Array(c.length/2);for(let i=0;i<nd.length;i++)nd[i]=parseInt(c.substr(i*2,2),16);setv(nd)}}
 const gr=document.createElement('span');gr.className='grip';gr.textContent='⠿';gr.title='Drag onto the other side to copy this field there';
 gr.draggable=true;gr.ondragstart=ev=>{cellDrag={r,s,tag:opts.tag,key:opts.key};ev.dataTransfer.setData(MIME,'1');ev.dataTransfer.effectAllowed='copy'};
 gr.ondragend=()=>cellDrag=null;
 wrap.append(gr,inp);
 if(is4){const nm=decode4(r._P,s.d);const lbl=mk('mut',nm||'');lbl.style.cssText='font-size:11px;flex-basis:100%';wrap.append(lbl);
  if(!ro){const pk=document.createElement('button');pk.textContent='Pick…';pk.onclick=()=>pickFormId(t=>{const x=xref(t,r._P);
    if(x.need){if(!confirm('Add '+x.need+' as a master of '+r._P.name+'?'))return;addMaster(r._P,x.need)}
    const nd=new Uint8Array(4);new DataView(nd.buffer).setUint32(0,xref(t,r._P).id,true);inp.value=[...nd].map(x=>hex(x,2)).join(' ');setv(nd)});
   wrap.append(pk)}}
 return wrap}
function editInp(r,val,fn){const i=document.createElement('input');i.className='fld';i.style.cssText='font:12px ui-monospace,monospace;width:100%';
 i.value=val;i.disabled=r._P.locked;
 i.oninput=()=>{const v=parseInt(i.value,16);if(isNaN(v)){i.classList.add('bad');return}i.classList.remove('bad');fn(v>>>0)};return i}
function dragHexCell(r,val,fn,key){const wrap=mk('cellwrap');wrap.style.cssText='display:flex;gap:4px;align-items:center';
 const inp=editInp(r,val,v=>{fn(v);inp.value=hex(v)});
 const gr=document.createElement('span');gr.className='grip';gr.textContent='⠿';gr.title='Drag onto the other side to copy this value there';
 gr.draggable=true;gr.ondragstart=ev=>{cellDrag={r,raw:val,key};ev.dataTransfer.setData(MIME,'1');ev.dataTransfer.effectAllowed='copy'};
 gr.ondragend=()=>cellDrag=null;
 wrap.ondragover=e=>{if(e.dataTransfer.types.includes(MIME)){e.preventDefault();wrap.classList.add('over')}};
 wrap.ondragleave=()=>wrap.classList.remove('over');
 wrap.ondrop=e=>{e.preventDefault();wrap.classList.remove('over');if(locked(r._P))return;
  if(cellDrag&&cellDrag.key===key&&cellDrag.r!==r){fn(parseInt(cellDrag.raw,16)>>>0);inp.value=cellDrag.raw;cellDrag=null}};
 wrap.append(gr,inp);return wrap}
function sbsTable(a,b,rebuild){const tb=document.createElement('table');tb.className='sbs';
 const head=r=>r?(r.t+'  '+(edid(r)||'')+'  ('+r._P.name+')'+(r._P.locked?'  🔒':'')):'—';
 tb.innerHTML='<tr><th style="width:110px"></th><th>'+head(a)+'</th><th>'+head(b)+'</th></tr>';
 const addRow=(k,acell,bcell,diff)=>{const tr=document.createElement('tr');if(diff)tr.className='diff';
  const td1=document.createElement('td');td1.className='k';td1.textContent=k;
  const td2=document.createElement('td'),td3=document.createElement('td');td2.append(acell);td3.append(bcell);
  tr.append(td1,td2,td3);tb.append(tr);return tr};
 if(!a&&!b)return tb;
 const typeCell=r=>{const s=mk('');s.textContent=r?r.t:'—';return s};
 addRow('Type',typeCell(a),typeCell(b),!!(a&&b&&a.t!==b.t));
 if(a&&b){
  const idTr=addRow('FormID',editInp(a,hex(a.id),v=>{a.id=v;if(a._el)a._el.querySelector('.id').textContent=' '+hex(v);setDirty(a._P,'Set FormID (side by side)');refreshDiff()}),
   editInp(b,hex(b.id),v=>{b.id=v;if(b._el)b._el.querySelector('.id').textContent=' '+hex(v);setDirty(b._P,'Set FormID (side by side)');refreshDiff()}),a.id!==b.id);
  const flTr=addRow('Flags',dragHexCell(a,hex(a.flags),v=>{a.flags=v;setDirty(a._P,'Set flags (side by side)');refreshDiff()},'Flags'),
   dragHexCell(b,hex(b.flags),v=>{b.flags=v;setDirty(b._P,'Set flags (side by side)');refreshDiff()},'Flags'),a.flags!==b.flags);
  const ownA=mk('mut',owner(a.id,a._P)),ownB=mk('mut',owner(b.id,b._P));ownA.style.fontSize='11px';ownB.style.fontSize='11px';
  addRow('Owner',ownA,ownB,false);
  var rowEls=[],unRows=unionRows(a,b);
  unRows.forEach(x=>{const optsA={tag:x.tag,key:x.key,refresh:()=>refreshDiff(),rebuild:()=>rebuild()},optsB={tag:x.tag,key:x.key,refresh:()=>refreshDiff(),rebuild:()=>rebuild()};
   const acell=subCell(a,x.aSub,optsA),bcell=subCell(b,x.bSub,optsB);
   const diff=decodeVal(a,x.aSub)!==decodeVal(b,x.bSub);
   rowEls.push({tr:addRow(x.key,acell,bcell,diff),x})});
  function refreshDiff(){idTr.classList.toggle('diff',a.id!==b.id);flTr.classList.toggle('diff',a.flags!==b.flags);
   rowEls.forEach(({tr,x})=>tr.classList.toggle('diff',decodeVal(a,x.aSub)!==decodeVal(b,x.bSub)))}
 }else{const only=a||b;
  addRow('FormID',a?editInp(a,hex(a.id),v=>{a.id=v;if(a._el)a._el.querySelector('.id').textContent=' '+hex(v);setDirty(a._P,'Set FormID (side by side)')}):mk('','—'),
   b?editInp(b,hex(b.id),v=>{b.id=v;if(b._el)b._el.querySelector('.id').textContent=' '+hex(v);setDirty(b._P,'Set FormID (side by side)')}):mk('','—'),false);
  addRow('Owner',a?mk('mut',owner(a.id,a._P)):mk('','—'),b?mk('mut',owner(b.id,b._P)):mk('','—'),false);
  subRows(only).forEach(x=>{const noop={tag:x.tag,key:x.key,refresh:()=>{},rebuild:()=>rebuild()};
   const cellA=a?subCell(a,x.sub,noop):mk('miss','(not present)'),cellB=b?subCell(b,x.sub,noop):mk('miss','(not present)');
   addRow(x.key,cellA,cellB,false)})}
 return tb}
function compareRecords(){
 let A=cur&&sel.size<1?cur:null,B=null;
 if(sel.size>=2){const arr=[...sel];A=arr[0];B=arr[1]}
 let savedSize={};try{savedSize=JSON.parse(localStorage.pl_sbs_size||'{}')}catch(e){}
 const d=document.createElement('dialog');
 d.style.cssText='width:'+(savedSize.w||760)+'px;height:'+(savedSize.h||520)+'px;min-width:420px;min-height:280px;max-width:96vw;max-height:92vh;'
  +'resize:both;overflow:hidden;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:0;display:flex;flex-direction:column';
 new ResizeObserver(()=>{try{localStorage.pl_sbs_size=JSON.stringify({w:d.offsetWidth,h:d.offsetHeight})}catch(e){}}).observe(d);
 const hd=document.createElement('div');hd.style.cssText='padding:10px 12px;border-bottom:1px solid var(--ln)';
 hd.innerHTML='<b>Compare records side by side</b><br><small class="mut">Pick two records, or drag them here from the tree. Drag the ⠿ grip on any field to copy that value to the other side. Drag the dialog\'s corner to resize.</small>';
 const slots=document.createElement('div');slots.style.cssText='display:flex;gap:10px;padding:10px 12px';
 const box=document.createElement('div');box.style.cssText='flex:1;overflow:auto;padding:0 12px 12px';
 const ft=document.createElement('div');ft.style.cssText='padding:8px 12px;border-top:1px solid var(--ln);text-align:right';
 const cb=document.createElement('button');cb.textContent='Close';cb.onclick=()=>d.close();ft.append(cb);
 const redraw=()=>{box.replaceChildren(sbsTable(A,B,redraw))};
 const mkSlot=(label,get,set)=>{const s=mk('slot');const refresh=()=>{const r=get();s.replaceChildren();
   const b=document.createElement('b');b.textContent=label;s.append(b);
   if(r){const line=mk('',r.t+'  '+(edid(r)||hex(r.id))+'  ('+r._P.name+')');const chg=document.createElement('button');chg.textContent='Change…';chg.style.marginLeft='8px';
    chg.onclick=()=>pickFormId(t=>{set(t);refresh();redraw()});s.append(line,chg)}
   else{const pk=document.createElement('button');pk.textContent='Pick a record…';pk.onclick=()=>pickFormId(t=>{set(t);refresh();redraw()});s.append(pk)}};
  s.ondragover=e=>{if(e.dataTransfer.types.includes(MIME)){e.preventDefault();s.classList.add('over')}};
  s.ondragleave=()=>s.classList.remove('over');
  s.ondrop=e=>{e.preventDefault();s.classList.remove('over');if(dragRecs[0]){set(dragRecs[0]);refresh();redraw()}};
  refresh();return s};
 const slotA=mkSlot('Record A',()=>A,r=>A=r),slotB=mkSlot('Record B',()=>B,r=>B=r);
 slots.append(slotA,slotB);
 d.append(hd,slots,box,ft);d.onclose=()=>d.remove();document.body.append(d);d.showModal();redraw()}
function showStats(){const P=activeP;if(!P)return;
 const counts=new Map();for(const r of P.all){if(r===P.root[0])continue;counts.set(r.t,(counts.get(r.t)||0)+1)}
 const rows=[...counts].sort((a,b)=>b[1]-a[1]);
 const d=document.createElement('dialog');d.style.cssText='width:min(480px,92vw);max-height:82vh;background:var(--pn);border:1px solid var(--ln);border-radius:8px;padding:0';
 const hd=document.createElement('div');hd.style.cssText='padding:10px 12px;border-bottom:1px solid var(--ln)';hd.innerHTML='<b>'+P.name+'</b>';
 const box=document.createElement('div');box.style.cssText='max-height:60vh;overflow:auto;padding:10px 12px';
 const top=mk('stat');top.innerHTML='<span>Total records</span><span class="mono">'+(P.all.length-1).toLocaleString()+'</span>';box.append(top);
 const tp=mk('stat');tp.innerHTML='<span>Masters</span><span class="mono">'+(P.masters.length?P.masters.join(', '):'none')+'</span>';box.append(tp);
 box.append(mk('flh','Records by type'));
 rows.forEach(([t,n])=>{const row=mk('stat');row.innerHTML='<span>'+t+'</span><span class="mono">'+n.toLocaleString()+'</span>';box.append(row)});
 const ft=document.createElement('div');ft.style.cssText='padding:8px 12px;border-top:1px solid var(--ln);text-align:right';
 const cb=document.createElement('button');cb.textContent='Close';cb.onclick=()=>d.close();ft.append(cb);
 d.append(hd,box,ft);d.onclose=()=>d.remove();document.body.append(d);d.showModal()}

function exportLog(){const P=activeP;if(!P)return;
 textBox('Edit log — '+P.name,(P.log&&P.log.length?P.log.join('\n'):'No changes logged yet in this session.'),'Close',null,'This session only; not kept across a reload.')}

function loadWs(){try{return JSON.parse(localStorage.pl_ws||'{}')}catch(e){return{}}}
function saveWsMap(m){try{localStorage.pl_ws=JSON.stringify(m)}catch(e){}}
function refreshWsSelect(){const sel=$('#wssel'),cur=sel.value;sel.replaceChildren();
 const o0=document.createElement('option');o0.value='';o0.textContent='Workspaces…';sel.append(o0);
 Object.keys(loadWs()).forEach(n=>{const o=document.createElement('option');o.value=n;o.textContent=n;sel.append(o)});sel.value=cur}
async function loadWorkspace(name){const ws=loadWs()[name];if(!ws)return;
 const toClose=plugins.filter(P=>!ws.plugins.includes(P.name));
 for(const P of toClose)closePlugin(P);
 const stored=(await dbDo('readonly',x=>x.getAll()))||[];const missing=[];
 for(const nm of ws.plugins){if(plugins.some(P=>P.name===nm))continue;
  const row=stored.find(r=>r.name===nm);if(row)await load({name:nm},row);else missing.push(nm)}
 if(missing.length)alert('These plugins were part of "'+name+'" but are not saved in the browser, so they need to be reopened manually:\n'+missing.join('\n'));
 flash('Loaded workspace "'+name+'"')}
$('#wssave').onclick=()=>{if(!plugins.length)return flash('Open some plugins first');
 const name=(prompt('Name this workspace (the set of plugins currently open)')||'').trim();if(!name)return;
 const m=loadWs();m[name]={plugins:plugins.map(P=>P.name)};saveWsMap(m);refreshWsSelect();$('#wssel').value=name;flash('Saved workspace "'+name+'"')};
$('#wssel').onchange=()=>{const n=$('#wssel').value;if(n)loadWorkspace(n)};
refreshWsSelect();
$('#dup').onclick=findDuplicates;$('#cmp').onclick=comparePlugins;$('#stats').onclick=showStats;$('#cmprec').onclick=compareRecords;
function resortTree(){const q=$('#q').value.trim();if(q){search(q);return}
 const state=plugins.map(P=>{const wasOpen=!!(P._w&&P._w.classList.contains('open')),o=new Set();if(wasOpen)collect(P.root,'',o);return{wasOpen,o}});
 const t=$('#tree');t.replaceChildren();t.append(pinSection());
 plugins.forEach((P,i)=>{pluginRow(P,t);const st=state[i];if(st.wasOpen){P._h.click();reopen(P.root,'',st.o)}})}
$('#sortmode').onchange=()=>{sortMode=$('#sortmode').value;resortTree()};
$('#typefilter').oninput=()=>{typeFilter=$('#typefilter').value.split(',').map(x=>x.trim().toUpperCase()).filter(Boolean);resortTree()};

addEventListener('keydown',e=>{
 const tag=document.activeElement.tagName;
 if(document.querySelector('dialog[open]'))return;
 if(e.key==='/'&&tag!=='INPUT'&&tag!=='TEXTAREA'){e.preventDefault();$('#q').focus();return}
 if(tag==='INPUT'||tag==='TEXTAREA')return;
 if(e.key==='ArrowDown'||e.key==='ArrowUp'){const rows=[...document.querySelectorAll('#tree .row')];if(!rows.length)return;
  let i=selRow?rows.indexOf(selRow):-1;i=e.key==='ArrowDown'?Math.min(rows.length-1,i+1):Math.max(0,i-1);e.preventDefault();
  rows[i].scrollIntoView({block:'nearest'});rows[i].click()}
 else if(e.key==='Delete'&&cur&&cur!==cur._P.root[0]){const btns=[...document.querySelectorAll('#detail button')];const del=btns.find(b=>b.textContent==='Delete record');if(del)del.click()}
});

addEventListener('keydown',e=>{if(!(e.ctrlKey||e.metaKey)||/INPUT|TEXTAREA/.test(document.activeElement.tagName))return;const k=e.key.toLowerCase();
 if(k==='z'){e.preventDefault();undo(activeP,!e.shiftKey)}else if(k==='y'){e.preventDefault();undo(activeP,false)}});
(async()=>{if(!remember())return;const rows=((await dbDo('readonly',x=>x.getAll()))||[]).sort((a,b)=>a.t-b.t);
 for(const r of rows)await load({name:r.name},r);
 if(rows.length)flash('Restored '+rows.length+(rows.length===1?' plugin':' plugins')+' from your last session')})();
