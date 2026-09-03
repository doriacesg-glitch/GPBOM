// GPBOM minimal SPA — vanilla JS.
// Talks to same-origin /api endpoints; session is a signed HttpOnly cookie.

const $  = (s, r=document) => r.querySelector(s);
const $$ = (s, r=document) => [...r.querySelectorAll(s)];

async function api(path, opts={}) {
  const r = await fetch(path, {
    credentials: "include",
    headers: { "Content-Type": "application/json", ...(opts.headers||{}) },
    ...opts,
  });
  if (r.status === 401) { showLogin(); throw new Error("unauth"); }
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.status === 204 ? null : r.json();
}
const fmtDate = (s) => s ? s.substring(0,10) : "";
const num     = (n, d=3) => n == null ? "" : Number(n).toFixed(d);

// ---------- auth ----------
function showLogin(){ $("#login").classList.remove("hidden"); $("#app").classList.add("hidden"); }
function showApp(me){
  $("#login").classList.add("hidden"); $("#app").classList.remove("hidden");
  $("#who").textContent = `${me.username} (${me.role})`;
  switchTab("parts");
}

$("#loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const f = new FormData(e.target);
  try {
    const me = await api("/api/auth/login", {
      method: "POST",
      body: JSON.stringify({ username: f.get("username"), password: f.get("password") }),
    });
    showApp(me);
  } catch (err) {
    const p = $("#loginErr"); p.classList.remove("hidden"); p.textContent = "登入失敗";
  }
});
$("#logout").addEventListener("click", async () => {
  await api("/api/auth/logout", { method:"POST" });
  showLogin();
});

// ---------- tabs ----------
function switchTab(name){
  $$(".tab-btn").forEach(b => b.classList.toggle("tab-active", b.dataset.tab === name));
  $$(".panel").forEach(p => p.classList.toggle("hidden", p.dataset.panel !== name));
  ({ parts:loadParts, expiring:loadExpiring, claims:loadClaims }[name] || (()=>{}))();
}
$$(".tab-btn").forEach(b => b.addEventListener("click", () => switchTab(b.dataset.tab)));

// ---------- parts ----------
async function loadParts(){
  const q  = $("#partQ").value.trim();
  const st = $("#partStatus").value;
  const qs = new URLSearchParams();
  if (q)  qs.set("q", q);
  if (st) qs.set("status", st);
  const rows = await api("/api/parts?" + qs);
  $("#partRows").innerHTML = rows.map(r => `
    <tr class="border-t hover:bg-slate-50">
      <td class="p-2 font-mono">${r.part_no}</td>
      <td class="p-2">${r.name}</td>
      <td class="p-2 text-slate-500">${r.kind}</td>
      <td class="p-2"><span class="badge badge-${r.status}">${r.status}</span></td>
      <td class="p-2 text-right">${num(r.stock_qty,0)}</td>
      <td class="p-2">${fmtDate(r.last_purchase_at)}</td>
      <td class="p-2 text-right">
        <button class="underline text-sm" onclick="openBom(${r.id})">BOM</button>
        <button class="underline text-sm ml-2" onclick="claimPart(${r.id})">認領</button>
      </td>
    </tr>`).join("");
}
$("#partSearch").addEventListener("click", loadParts);
$("#partQ").addEventListener("keydown", e => { if (e.key === "Enter") loadParts(); });

// ---------- BOM tree ----------
window.openBom = (id) => { $("#bomPartId").value = id; switchTab("bom"); loadBom(); };

async function loadBom(){
  const id = Number($("#bomPartId").value);
  if (!id) return;
  const tree = await api("/api/bom/" + id);
  $("#bomTree").innerHTML = renderTree(tree, true);
}
function renderTree(nodes, expanded){
  if (!nodes.length) return `<div class="text-slate-500">(無子件)</div>`;
  return `<ul>${nodes.map(n => nodeHtml(n, expanded)).join("")}</ul>`;
}
function nodeHtml(n, expanded){
  const pct = n.weight_pct_of_parent != null
    ? ` <span class="text-slate-500">(${n.weight_pct_of_parent.toFixed(1)}%)</span>` : "";
  const wg  = n.weight_g_per_parent != null
    ? ` · ${num(n.weight_g_per_parent,3)}g` : "";
  const status = `<span class="badge badge-${n.status}">${n.status}</span>`;
  const hasKids = n.children.length > 0;
  return `
    <li class="tree-node">
      <span class="tree-toggle" onclick="toggleKids(this)">${hasKids ? (expanded?"▾":"▸") : "·"}</span>
      <span class="font-mono">${n.part_no}</span>
      — ${n.name} ${status}
      <span class="text-slate-500 text-xs">×${num(n.quantity,2)}${wg}${pct}</span>
      ${hasKids ? `<div class="tree-kids" ${expanded?"":'style="display:none"'}>${renderTree(n.children, false)}</div>` : ""}
    </li>`;
}
window.toggleKids = (btn) => {
  const kids = btn.parentElement.querySelector(".tree-kids");
  if (!kids) return;
  const shown = kids.style.display !== "none";
  kids.style.display = shown ? "none" : "";
  btn.textContent = shown ? "▸" : "▾";
};
$("#bomLoad").addEventListener("click", loadBom);

// ---------- substance search ----------
async function loadSub(){
  const qs = new URLSearchParams();
  const cas = $("#subCas").value.trim();
  const nm  = $("#subName").value.trim();
  if (cas) qs.set("cas", cas);
  if (nm)  qs.set("name", nm);
  if (!cas && !nm) return;
  const rows = await api("/api/search/substance?" + qs);
  $("#subRows").innerHTML = rows.map(r => `
    <tr class="border-t hover:bg-slate-50">
      <td class="p-2">${r.substance_name}</td>
      <td class="p-2 font-mono text-slate-600">${r.cas_no || ""}</td>
      <td class="p-2 font-mono">${r.part_no}</td>
      <td class="p-2">${r.part_name}</td>
      <td class="p-2">${r.material_name}</td>
      <td class="p-2 text-right">${num(r.weight_g,4)}</td>
      <td class="p-2 text-right">${num(r.ppm,2)}</td>
    </tr>`).join("");
}
$("#subSearch").addEventListener("click", loadSub);

// ---------- expiring documents ----------
async function loadExpiring(){
  const rows = await api("/api/documents/expiring");
  $("#expRows").innerHTML = rows.map(r => {
    const cls = r.state === "expired" ? "expired" : (r.state === "due_soon" ? "duesoon" : "");
    return `
      <tr class="border-t ${cls}">
        <td class="p-2">${r.doc_kind}</td>
        <td class="p-2 font-mono">${r.doc_no || ""}</td>
        <td class="p-2">${r.title || ""}</td>
        <td class="p-2">${fmtDate(r.issue_date)}</td>
        <td class="p-2">${fmtDate(r.expire_date)}</td>
        <td class="p-2">${r.state}</td>
      </tr>`;
  }).join("");
}

// ---------- claims ----------
async function loadClaims(){
  const rows = await api("/api/claims");
  $("#claimRows").innerHTML = rows.map(r => `
    <tr class="border-t">
      <td class="p-2 font-mono">${r.part_no}</td>
      <td class="p-2">${r.part_name}</td>
      <td class="p-2">${r.username}</td>
      <td class="p-2 text-slate-500">${fmtDate(r.claimed_at)}</td>
      <td class="p-2">${r.reason || ""}</td>
      <td class="p-2"><button class="underline" onclick="releaseClaim(${r.id})">釋出</button></td>
    </tr>`).join("");
}
window.claimPart = async (part_id) => {
  const reason = prompt("認領原因(可空白):") ?? "";
  await api("/api/claims", { method:"POST", body: JSON.stringify({ part_id, reason }) });
  alert("已認領");
};
window.releaseClaim = async (id) => {
  await api(`/api/claims/${id}/release`, { method:"POST" });
  loadClaims();
};

// ---------- boot ----------
(async () => {
  try {
    const me = await api("/api/auth/me");
    showApp(me);
  } catch { showLogin(); }
})();
