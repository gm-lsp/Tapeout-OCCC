"use strict";
// Sale and verification page for a TapeOut curated collection.
// Trust model: site.json (served with this page) pins the chain, the RPC, the registry and the processor.
// The manifest is untrusted: every work and allowlist entry is rebuilt and checked against the chain before
// anything is shown, and every value from it is inserted as text, never as HTML.
const E = window.ethers;
const $ = (id) => document.getElementById(id);
const REG_ABI = [
  "function collectionOf(address) view returns (tuple(address vault,address curator,address transistors,address treasury,bytes32 root,uint32 count,uint32 reserved,uint32 certified,bytes32 metadata))",
  "function editionOf(address,uint256) view returns (bool official,uint256 index)",
  "function tokenOf(address,uint256) view returns (bool taped,uint256 tokenId)",
  "function isReserved(address,uint256) view returns (bool)",
  "function isCurated(address) view returns (bool)",
  "function royaltyOf(address) view returns (address receiver, uint16 bps)",
];
const VAULT_ABI = [
  "function REGISTRY() view returns (address)", "function CURATOR() view returns (address)",
  "function SALE_START() view returns (uint64)", "function SALE_END() view returns (uint64)",
  "function PRESALE_START() view returns (uint64)", "function ALLOW_ROOT() view returns (bytes32)",
  "function LIMIT_PER_WALLET() view returns (bool)", "function MAX_PER_WALLET() view returns (uint32)",
  "function sold() view returns (uint32)", "function finalized() view returns (bool)", "function paused() view returns (bool)", "function reservedClaimed() view returns (uint32)",
  "function taken(uint256) view returns (bool)", "function remainingFor(address) view returns (bool,uint32)",
  "function presaleBought(address) view returns (uint32)",
  "function buy(uint256,bytes,uint32,uint32,uint256,bytes32[],address) payable returns (uint256)",
  "function buyPresale(uint256,bytes,uint32,uint32,uint256,bytes32[],address,uint32,bytes32[]) payable returns (uint256)",
  "function claimReserved(uint256,bytes,uint32,uint32,bytes32[]) payable returns (uint256)",
  "error SaleNotStarted()", "error SaleEnded()", "error AlreadyTaken()", "error InvalidProof()",
  "error WrongPayment(uint256)", "error WalletLimitReached(address)", "error RecipientMustBeBuyer()",
  "error NoPresale()", "error PresaleNotOpen()", "error NotAllowlisted()", "error PresaleQuotaUsed()",
  "error OnlyCurator()", "error ReservedQuotaUsed()", "error AlreadyFinalized()", "error IndexOutOfRange()", "error ZeroRecipient()",
  "error ReentrancyGuardReentrantCall()",
];
const CIRC_ABI = [
  "function TAPEOUT_FEE() view returns (uint256)", "function ownerOf(uint256) view returns (address)",
  "function netlist(uint256) view returns (bytes)",
];
const ERR_TEXT = {
  SaleNotStarted: "公开发售还没开始。", SaleEnded: "发售已经结束。", AlreadyTaken: "这件作品刚被别人买走了。",
  InvalidProof: "作品数据与链上清单不一致，请刷新页面。", WrongPayment: "支付金额不对，请刷新页面后重试。",
  WalletLimitReached: "已达到单钱包限额，不能再购买。", RecipientMustBeBuyer: "本集合限制了单钱包数量，只能为自己的钱包购买。",
  NoPresale: "本集合没有预售。", PresaleNotOpen: "现在不在预售时间内。", NotAllowlisted: "你的钱包不在白名单中。",
  PresaleQuotaUsed: "你的预售额度已经用完，可以在公开发售时继续购买。", OnlyCurator: "只有策展人可以领取国库预留作品。",
  ReservedQuotaUsed: "国库预留名额已经用完。", AlreadyFinalized: "发售已经收尾，剩余作品再也不能流片。",
};
const ALLOW_TAG = E.keccak256(E.toUtf8Bytes("TAP-curated-allowlist"));
const META_TAG = E.keccak256(E.toUtf8Bytes("TAP-curated-metadata"));
const utf8Hash = (t) => E.keccak256(E.toUtf8Bytes(t));
// same as CuratedVault.metadataOf: commits the name, symbol, story and every work title
function metadataOf(name, symbol, story, titles) {
  const titlesHash = E.keccak256(E.concat(titles.map(utf8Hash)));
  return E.keccak256(coder.encode(["bytes32", "bytes32", "bytes32", "bytes32", "bytes32"],
    [META_TAG, utf8Hash(name), utf8Hash(symbol), utf8Hash(story), titlesHash]));
}
const coder = E.AbiCoder.defaultAbiCoder();

const S = { works: [], wallet: null, signer: null, now: 0, active: null, allow: null, presaleLeft: 0 };

// ------------------------------------------------------------------ small helpers
function toast(msg, err) {
  const t = $("toast"); t.textContent = msg; t.className = "toast" + (err ? " err" : ""); t.hidden = false;
  clearTimeout(toast._t); toast._t = setTimeout(() => (t.hidden = true), err ? 7000 : 4000);
}
const short = (a) => (a ? a.slice(0, 6) + "…" + a.slice(-4) : "");
const bnb = (wei) => { const v = E.formatEther(BigInt(wei)); return v === "0.0" ? "免费" : v.replace(/\.0$/, "") + " BNB"; };
const when = (ts) => new Date(Number(ts) * 1000).toLocaleString("zh-CN", { hour12: false });
const sameAddr = (a, b) => typeof a === "string" && typeof b === "string" && a.toLowerCase() === b.toLowerCase();
const intOrQ = (v) => (Number.isSafeInteger(v) && v >= 0 ? String(v) : "?");
function el(tag, attrs, ...kids) {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (k === "class") e.className = v; else if (k === "text") e.textContent = v; else e.setAttribute(k, v);
  }
  for (const k of kids) if (k != null) e.append(k);
  return e;
}
function fail(msg) { throw new Error(msg); }
function explainError(e) {
  const data = e?.data || e?.info?.error?.data || e?.error?.data;
  try {
    const p = new E.Interface(VAULT_ABI).parseError(typeof data === "string" ? data : data?.data);
    if (p && ERR_TEXT[p.name]) return ERR_TEXT[p.name];
  } catch (_) { /* not a vault error */ }
  if (e?.code === "ACTION_REJECTED" || e?.info?.error?.code === 4001) return "你取消了这笔交易。";
  if (e?.code === "INSUFFICIENT_FUNDS") return "钱包里的 BNB 不够支付价格和流片费。";
  return "交易没有成功：" + (e?.shortMessage || e?.message || "未知原因");
}

// ------------------------------------------------------------------ manifest checks (same rules as curate.py checkroot)
const isHex = (s, bytes) => typeof s === "string" && new RegExp("^0x[0-9a-fA-F]{" + (bytes ? bytes * 2 : "0,") + (bytes ? "" : "}") + (bytes ? "}$" : "$")).test(s);
function workLeaf(chainId, registry, curator, w) {
  const inner = E.keccak256(coder.encode(
    ["uint256", "address", "address", "uint256", "bytes32", "uint32", "uint32", "uint256", "bool"],
    [chainId, registry, curator, w.index, E.keccak256(w.netlist), w.nIn, w.nOut, BigInt(w.priceWei), w.reserved]));
  return E.keccak256(inner);
}
function allowLeaf(chainId, registry, curator, a) {
  const inner = E.keccak256(coder.encode(["uint256", "address", "address", "bytes32", "address", "uint32"],
    [chainId, registry, curator, ALLOW_TAG, a.address, a.quota]));
  return E.keccak256(inner);
}
function merkleRoot(leaves) {
  let layer = leaves.map((x) => x.toLowerCase()).sort();
  if (!layer.length) return E.ZeroHash;
  while (layer.length > 1) {
    const next = [];
    for (let i = 0; i < layer.length; i += 2) {
      if (i + 1 === layer.length) { next.push(layer[i]); continue; }
      const [a, b] = layer[i] < layer[i + 1] ? [layer[i], layer[i + 1]] : [layer[i + 1], layer[i]];
      next.push(E.keccak256(E.concat([a, b])).toLowerCase());
    }
    layer = next;
  }
  return layer[0];
}
function verifyProof(leaf, proof, root) {
  let h = leaf.toLowerCase();
  for (const p of proof) {
    if (!isHex(p, 32)) return false;
    const q = p.toLowerCase();
    h = E.keccak256(E.concat(h < q ? [h, q] : [q, h])).toLowerCase();
  }
  return h === root.toLowerCase();
}
/** NAND and LATCH records of a TAP-02 netlist (REF records burn no transistors). */
function countGates(hex) {
  const b = E.getBytes(hex); let p = 0, nand = 0, latch = 0;
  while (p < b.length) {
    if (b[p] === 0) { nand++; p += 7; } else if (b[p] === 1) { latch++; p += 4; }
    else if (b[p] === 2 && p + 31 <= b.length) p += 31 + 3 * b[p + 29];
    else return null;
  }
  return p === b.length ? { nand, latch } : null;
}
/** Validates the untrusted manifest against the chain. Returns cleaned works and allowlist, or throws. */
function checkManifest(m, cfg, col, allowRootOnChain) {
  const chainId = BigInt(cfg.chainId);
  if (!m || typeof m !== "object" || !Array.isArray(m.works)) fail("清单格式不对。");
  if (!sameAddr(m.registry, cfg.registry)) fail("清单里的登记合约与本站配置不一致。");
  if (BigInt(m.chainId ?? 0) !== chainId) fail("清单是为另一条链生成的。");
  const curator = col.curator;
  if (!sameAddr(m.launch?.curator, curator)) fail("清单里的策展人与链上记录不一致。");
  const works = m.works.map((w, i) => {
    const ok = w && w.index === i && isHex(w.netlist) && Number.isSafeInteger(w.nIn) && Number.isSafeInteger(w.nOut)
      && typeof w.reserved === "boolean" && /^\d+$/.test(String(w.priceWei)) && !(w.reserved && String(w.priceWei) !== "0");
    if (!ok) fail(`清单中第 ${i} 件作品的数据不完整或不合法。`);
    if (typeof w.title !== "string") fail(`清单中第 ${i} 件作品没有标题。`);
    return { index: i, title: w.title, netlist: w.netlist, nIn: w.nIn, nOut: w.nOut,
      priceWei: String(w.priceWei), reserved: w.reserved, proof: Array.isArray(w.proof) ? w.proof.map(String) : [],
      netlistHash: E.keccak256(w.netlist), ...(countGates(w.netlist) || fail(`清单中第 ${i} 件作品的网表格式不对。`)) };
  });
  if (works.length !== Number(col.count)) fail("清单的作品数量与链上不一致。");
  if (works.filter((w) => w.reserved).length !== Number(col.reserved)) fail("清单里的国库预留数量与链上不一致。");
  const root = merkleRoot(works.map((w) => workLeaf(chainId, cfg.registry, curator, w)));
  if (root !== col.root.toLowerCase()) fail("清单里的作品（编号、网表、价格或预留标记）与链上锁定的清单不一致。");
  works.forEach((w) => {
    if (!verifyProof(workLeaf(chainId, cfg.registry, curator, w), w.proof, root)) fail(`清单中第 ${w.index} 件作品的证明无效。`);
  });

  const allow = (Array.isArray(m.allowlist) ? m.allowlist : []).map((a, i) => {
    if (!a || !E.isAddress(a.address) || !Number.isSafeInteger(a.quota) || a.quota < 1) fail(`白名单第 ${i + 1} 项不合法。`);
    return { address: E.getAddress(a.address), quota: a.quota, proof: Array.isArray(a.proof) ? a.proof.map(String) : [] };
  });
  if (new Set(allow.map((a) => a.address)).size !== allow.length) fail("白名单里有重复地址。");
  const aroot = allow.length ? merkleRoot(allow.map((a) => allowLeaf(chainId, cfg.registry, curator, a))) : E.ZeroHash;
  if (aroot !== allowRootOnChain.toLowerCase()) fail("清单里的白名单与链上锁定的白名单不一致。");
  allow.forEach((a) => {
    if (!verifyProof(allowLeaf(chainId, cfg.registry, curator, a), a.proof, aroot)) fail(`白名单中 ${a.address} 的证明无效。`);
  });
  const L = m.launch;
  if (typeof L.name !== "string" || typeof L.symbol !== "string" || typeof L.story !== "string") fail("清单缺少名称或介绍。");
  if (metadataOf(L.name, L.symbol, L.story, works.map((w) => w.title)) !== col.metadata.toLowerCase()) {
    fail("清单里的名称、介绍或作品标题与链上锁定的不一致。");
  }
  return { works, allow, name: L.name, story: L.story };
}

// ------------------------------------------------------------------ load
async function loadConfig() {
  const local = ["localhost", "127.0.0.1"].includes(location.hostname);
  // only a local test may point the page at another config; a public page always uses its own site.json
  const name = local ? (new URLSearchParams(location.search).get("config") || "site.json") : "site.json";
  if (!/^[\w.-]+\.json$/.test(name)) fail("配置文件名不合法。");
  const cfg = await (await fetch(name, { cache: "no-store" })).json();
  for (const k of ["registry", "circuits"]) if (!E.isAddress(cfg[k])) fail(`本站配置缺少合法的 ${k} 地址。`);
  if (!cfg.rpc || !cfg.chainId) fail("本站配置缺少 rpc 或 chainId。");
  if (!/^[\w.-]+\.json$/.test(cfg.manifest || "manifest.json") || (cfg.manifest || "").startsWith(".")) fail("清单必须是与页面同目录的 .json 文件。");
  return cfg;
}

async function load() {
  S.cfg = await loadConfig();
  S.rpc = new E.JsonRpcProvider(S.cfg.rpc, Number(S.cfg.chainId), { staticNetwork: true });
  S.reg = new E.Contract(S.cfg.registry, REG_ABI, S.rpc);
  if (!(await S.reg.isCurated(S.cfg.circuits))) fail("这个处理器不是通过本登记合约发行的策展集合。");
  S.col = await S.reg.collectionOf(S.cfg.circuits);
  S.vault = new E.Contract(S.col.vault, VAULT_ABI, S.rpc);
  S.circ = new E.Contract(S.cfg.circuits, CIRC_ABI, S.rpc);
  const [vreg, ss, se, ps, ar, lim, max, fee, roy] = await Promise.all([
    S.vault.REGISTRY(), S.vault.SALE_START(), S.vault.SALE_END(), S.vault.PRESALE_START(), S.vault.ALLOW_ROOT(),
    S.vault.LIMIT_PER_WALLET(), S.vault.MAX_PER_WALLET(), S.circ.TAPEOUT_FEE(), S.reg.royaltyOf(S.cfg.circuits)]);
  if (!sameAddr(vreg, S.cfg.registry)) fail("发售合约不属于本站配置的登记合约。");
  const raw = await (await fetch(S.cfg.manifest || "manifest.json", { cache: "no-store" })).json();
  S.m = checkManifest(raw, S.cfg, S.col, ar);
  Object.assign(S, { saleStart: ss, saleEnd: se, presaleStart: ps, hasPresale: ar !== E.ZeroHash, limited: lim, max, fee });

  $("c-name").textContent = S.m.name; $("c-title").textContent = S.m.name; $("c-story").textContent = S.m.story;
  $("f-circuits").textContent = short(S.cfg.circuits); $("f-circuits").title = S.cfg.circuits;
  $("f-limit").textContent = lim ? `每个钱包最多 ${max} 件，只能为自己购买` : "不限制";
  $("f-roy").textContent = Number(roy[1]) ? `${Number(roy[1]) / 100}%，由各市场决定是否收取` : "未设置";
  $("f-roy").title = Number(roy[1]) ? "收款地址 " + roy[0] : "";
  $("f-reg").textContent = "登记合约 " + S.cfg.registry;
  document.title = S.m.name + " · 发售与验真";
  await refresh();
}

function phaseOf() {
  const n = BigInt(S.now);
  if (n >= S.saleEnd) return { key: "ended", title: "发售已结束", note: S.finalized
    ? `结束于 ${when(S.saleEnd)}。已经收尾，未售出的作品永远不会再被流片。`
    : `结束于 ${when(S.saleEnd)}。公开发售已关闭；收尾前，策展人仍可把未领取的预留作品领取进国库。` };
  if (S.paused && (n >= S.saleStart || (S.hasPresale && n >= S.presaleStart))) return { key: "paused", title: "销售已暂停",
    note: `策展人暂停了销售，恢复后可以继续购买。销售截止 ${when(S.saleEnd)}。` };
  if (n >= S.saleStart) return { key: "public", title: "公开发售中", note: `任何人都可以购买，截止 ${when(S.saleEnd)}。` };
  if (S.hasPresale && n >= S.presaleStart) return { key: "presale", title: "白名单预售中", note: `只有白名单钱包可以购买，公开发售于 ${when(S.saleStart)} 开始。` };
  if (S.hasPresale) return { key: "soon", title: "即将开始", note: `白名单预售 ${when(S.presaleStart)} 开始，公开发售 ${when(S.saleStart)} 开始。` };
  return { key: "soon", title: "即将开始", note: `公开发售 ${when(S.saleStart)} 开始。` };
}

async function refresh() {
  S.now = (await S.rpc.getBlock("latest")).timestamp;
  const works = S.m.works;
  // ethers batches these reads into a few JSON-RPC requests
  const takenFlags = await Promise.all(works.map((w) => S.vault.taken(w.index)));
  const tokens = await Promise.all(works.map((w, i) => (takenFlags[i] ? S.reg.tokenOf(S.cfg.circuits, w.index) : null)));
  S.works = works.map((w, i) => ({ ...w, taken: takenFlags[i], tokenId: tokens[i] ? tokens[i][1] : null }));
  // the curator may pause buying or move the sale end later, so both are read on every refresh
  const [sold, rc, fin, paused, se] = await Promise.all([S.vault.sold(), S.vault.reservedClaimed(), S.vault.finalized(),
    S.vault.paused(), S.vault.SALE_END()]);
  S.finalized = fin; S.paused = paused; S.saleEnd = se;
  const ph = phaseOf(); S.phase = ph.key;
  $("phase").textContent = ph.title; $("phase-note").textContent = ph.note;
  $("f-sold").textContent = `${sold} / ${works.length} 件`;
  $("f-res").textContent = Number(S.col.reserved) ? `${S.col.reserved} 件，已领取 ${rc} 件` : "无";
  await refreshWallet();
  render();
}

async function refreshWallet() {
  if (!S.wallet) { $("you").hidden = true; return; }
  const [limited, remaining] = await S.vault.remainingFor(S.wallet);
  $("you-limit").textContent = limited ? `你的钱包还能购买 ${remaining} 件。` : "你的钱包不受购买数量限制。";
  S.allow = S.m.allow.find((a) => sameAddr(a.address, S.wallet)) || null;
  if (!S.hasPresale) $("you-presale").textContent = "";
  else if (S.allow) {
    const used = await S.vault.presaleBought(S.wallet);
    S.presaleLeft = S.allow.quota - Number(used);
    $("you-presale").textContent = `你在白名单中，预售额度 ${S.allow.quota} 件，还剩 ${Math.max(S.presaleLeft, 0)} 件。`;
  } else $("you-presale").textContent = "你的钱包不在白名单中，可以在公开发售时购买。";
  $("you").hidden = false;
}

function actionFor(w) {
  if (w.taken) return null;
  const isCurator = S.wallet && sameAddr(S.wallet, S.col.curator);
  if (w.reserved) return isCurator && !S.finalized ? { label: "领取进国库", kind: "claim" } : null;
  if (S.phase === "public") return { label: "购买", kind: "buy" };
  if (S.phase === "presale" && S.allow && S.presaleLeft > 0) return { label: "预售购买", kind: "presale" };
  return null;
}
function statusOf(w) {
  if (w.reserved) return w.taken ? { t: `已进国库，电路 #${w.tokenId}`, c: "res" } : { t: "国库预留，不公开发售", c: "res" };
  if (w.taken) return { t: `已售出，电路 #${w.tokenId}`, c: "sold" };
  return S.phase === "ended" ? { t: "未售出", c: "sold" } : { t: "可购买", c: "ok" };
}

function render() {
  const dies = $("dies"); dies.replaceChildren();
  const n = S.works.length; dies.style.setProperty("--die", n > 400 ? "18px" : n > 120 ? "28px" : "44px");
  const rows = $("rows"); rows.replaceChildren();
  for (const w of S.works) {
    const st = statusOf(w);
    const cls = "die" + (w.reserved ? " reserved" : "") + (w.taken ? (w.reserved ? " claimed" : " sold") : "") + (S.active === w.index ? " active" : "");
    const d = el("button", { class: cls, "aria-label": `第 ${w.index} 号 ${w.title}：${st.t}` }, n <= 120 ? el("span", { text: String(w.index) }) : null);
    d.onclick = () => {
      S.active = w.index; render();
      $("row-" + w.index)?.scrollIntoView({ block: "center", behavior: matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth" });
    };
    dies.append(d);

    const act = actionFor(w);
    const cell = el("td", { class: "act" });
    if (act) {
      const b = el("button", { class: "btn" + (act.kind === "claim" ? " ghost" : " gold"), text: act.label });
      b.onclick = () => (act.kind === "claim" ? claim(w, b) : buy(w, act.kind, b));
      cell.append(b);
    }
    const tr = el("tr", { id: "row-" + w.index, class: S.active === w.index ? "active" : "" },
      el("td", { class: "mono", text: String(w.index) }),
      el("td", { text: w.title }),
      el("td", { class: "mono", text: `${intOrQ(w.nand)} NAND，${intOrQ(w.latch)} LATCH` }),
      el("td", { text: w.reserved ? "不出售" : bnb(w.priceWei) }),
      el("td", { class: "status " + st.c, text: st.t }),
      cell);
    rows.append(tr);
  }
}

// ------------------------------------------------------------------ wallet
async function connect() {
  if (!window.ethereum) { toast("没有检测到浏览器钱包。请安装 MetaMask、OKX 等钱包后刷新页面。", true); return; }
  const bp = new E.BrowserProvider(window.ethereum);
  await bp.send("eth_requestAccounts", []);
  const want = BigInt(S.cfg.chainId);
  if ((await bp.getNetwork()).chainId !== want) {
    const chainId = "0x" + want.toString(16);
    // switching fires chainChanged, which reloads the page; reconnect automatically after the reload
    try { sessionStorage.setItem("p05-reconnect", "1"); } catch (_) { /* storage may be unavailable */ }
    try { await window.ethereum.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] }); }
    catch (e) {
      const add = e?.code === 4902 && (S.cfg.addChain || (want === 56n ? BSC : null));
      try {
        if (!add) throw e;
        await window.ethereum.request({ method: "wallet_addEthereumChain", params: [{ ...add, chainId }] });
      } catch (_) {
        try { sessionStorage.removeItem("p05-reconnect"); } catch (_) { /* ignore */ }
        toast("请在钱包里切换到 BNB Chain 后再连接。", true); return;
      }
    }
    if ((await new E.BrowserProvider(window.ethereum).getNetwork()).chainId !== want) return;
  }
  S.signer = await new E.BrowserProvider(window.ethereum).getSigner();
  S.wallet = await S.signer.getAddress();
  $("acct").textContent = short(S.wallet); $("acct").hidden = false;
  $("connect").textContent = "已连接"; $("connect").disabled = true;
  await refreshWallet(); render();
}
function disconnect() {
  Object.assign(S, { wallet: null, signer: null, allow: null, presaleLeft: 0 });
  $("acct").hidden = true; $("connect").textContent = "连接钱包"; $("connect").disabled = false; $("you").hidden = true;
  render();
}
if (window.ethereum?.on) {
  // a purchase always goes to the connected wallet, so never keep a stale account
  window.ethereum.on("accountsChanged", () => { disconnect(); toast("钱包账户已切换，请重新连接。"); });
  window.ethereum.on("chainChanged", () => location.reload());
}

const BSC = { chainName: "BNB Smart Chain", nativeCurrency: { name: "BNB", symbol: "BNB", decimals: 18 },
  rpcUrls: ["https://bsc-dataseed.bnbchain.org"], blockExplorerUrls: ["https://bscscan.com"] };

async function send(btn, label, fn) {
  if (!S.signer) { await connect(); if (!S.signer) return; }
  // never send money on another chain, even if the wallet changed chain without telling the page
  if ((await new E.BrowserProvider(window.ethereum).getNetwork()).chainId !== BigInt(S.cfg.chainId)) {
    toast("钱包当前不在 BNB Chain 上，请切换网络后重试。", true); disconnect(); return;
  }
  btn.disabled = true; const old = btn.textContent; btn.textContent = "等待钱包确认…";
  try {
    const tx = await fn(S.vault.connect(S.signer));
    btn.textContent = "流片中…";
    await tx.wait();
    toast(label);
    await refresh();
  } catch (e) { toast(explainError(e), true); btn.disabled = false; btn.textContent = old; }
}
function buy(w, kind, btn) {
  const value = BigInt(w.priceWei) + S.fee;
  send(btn, `已购买「${w.title}」，作品已到你的钱包。`, (v) => (kind === "presale"
    ? v.buyPresale(w.index, w.netlist, w.nIn, w.nOut, w.priceWei, w.proof, S.wallet, S.allow.quota, S.allow.proof, { value })
    : v.buy(w.index, w.netlist, w.nIn, w.nOut, w.priceWei, w.proof, S.wallet, { value })));
}
function claim(w, btn) {
  send(btn, `已把「${w.title}」领取进国库。`, (v) => v.claimReserved(w.index, w.netlist, w.nIn, w.nOut, w.proof, { value: S.fee }));
}

// ------------------------------------------------------------------ verify
function isPureRef(hex) {
  const b = E.getBytes(hex); let p = 0, any = false;
  while (p < b.length) { if (b[p] !== 2 || p + 31 > b.length) return false; any = true; p += 31 + 3 * b[p + 29]; }
  return any && p === b.length;
}
function verdict(kind, title, ...lines) {
  $("verdict").replaceChildren(el("div", { class: "verdict " + kind }, el("h3", { text: title }), ...lines.map((t) => el("p", { text: t }))));
}
async function verify(q) {
  verdict("wait", "正在查询链上记录…");
  let circuits = S.cfg.circuits, id = q.trim();
  const m = id.match(/^(0x[0-9a-fA-F]{40})\s*[:：#\s]\s*(\d+)$/);
  if (m) { circuits = m[1]; id = m[2]; }
  if (!/^\d{1,30}$/.test(id)) { verdict("none", "请输入电路编号", "只填数字表示本集合的电路，例如 12；查别的处理器请写成“地址:编号”。"); return; }
  const circ = new E.Contract(circuits, CIRC_ABI, S.rpc);
  let owner;
  try { owner = await circ.ownerOf(id); } catch (_) { verdict("none", "没有这个电路", `处理器 ${short(circuits)} 上还没有编号为 ${id} 的电路。`); return; }
  const [official, index] = await S.reg.editionOf(circuits, id);
  const ours = sameAddr(circuits, S.cfg.circuits);
  if (official && !ours) {
    // official in some other curated collection of this registry: never shown as a work of this collection
    verdict("none", "不属于本集合", `这是另一个策展集合（处理器 ${circuits}）的第 ${index} 号作品，与本集合无关。`,
      "请只认本站公布的处理器地址，警惕名称相同的仿冒集合。", `当前持有人 ${owner}`);
    return;
  }
  if (official) {
    const w = S.m.works[Number(index)];
    const reserved = await S.reg.isReserved(circuits, id);
    const match = w && E.keccak256(await circ.netlist(id)) === w.netlistHash;
    verdict("yes", "官方作品",
      `第 ${index} 号「${w ? w.title : "?"}」，由本集合的发售合约流片并在链上登记。`,
      reserved ? "这件作品发行时被预留给国库，之后可以由国库赠送或空投；它仍然是官方作品。" : null,
      `当前持有人 ${owner}`,
      match ? "链上网表与公开清单一致。" : "注意：链上网表与本页清单不一致，请联系项目方。");
    return;
  }
  const nl = await circ.netlist(id);
  const h = E.keccak256(nl);
  const twin = S.m.works.find((w) => w.netlistHash === h);
  let why;
  if (isPureRef(nl)) why = "它的网表只有“引用”，内容是指向别的电路，没有消耗任何晶体管。这类“包装壳”的门数和运行结果都和被引用的电路一样，所以看起来像正品。";
  else if (twin) why = `它的网表和第 ${twin.index} 号「${twin.title}」一模一样，但不是由本集合的发售合约流片的，属于复制品。`;
  else why = "它不在本集合的作品清单里。";
  verdict("no", "不是官方作品", why, `当前持有人 ${owner}`);
}

// ------------------------------------------------------------------ wiring
function showTab(which) {
  for (const t of ["buy", "verify"]) { $("tab-" + t).setAttribute("aria-selected", String(t === which)); $("view-" + t).hidden = t !== which; }
}
$("tab-buy").onclick = () => showTab("buy");
$("tab-verify").onclick = () => showTab("verify");
$("connect").onclick = () => connect().catch((e) => toast(explainError(e), true));
$("vform").onsubmit = (ev) => { ev.preventDefault(); verify($("vq").value).catch((e) => toast("查询失败：" + (e.shortMessage || e.message), true)); };
if (location.hash === "#verify") showTab("verify");
load().then(() => {
  let again = false;
  try { again = sessionStorage.getItem("p05-reconnect") === "1"; sessionStorage.removeItem("p05-reconnect"); } catch (_) { /* ignore */ }
  if (again) connect().catch((e) => toast(explainError(e), true));
}).catch((e) => {
  $("load-error").textContent = "无法加载集合：" + (e.shortMessage || e.message);
  $("load-error").hidden = false; $("c-title").textContent = "无法加载";
});
