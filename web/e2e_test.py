#!/usr/bin/env python3
"""End-to-end test of web/index.html against a local anvil fork of BSC.

Run from the repository root with anvil on 127.0.0.1:8546 and a launched collection; see web/run_e2e.sh.
The browser gets a stand-in wallet that forwards every request to anvil, where the buyer is impersonated.
"""
import json
import os
import sys
import urllib.request

from playwright.sync_api import sync_playwright

RPC = "http://127.0.0.1:8546"
SITE = sys.argv[1]          # http://127.0.0.1:8780/
BUYER = sys.argv[2]
OUT = sys.argv[3]           # screenshot folder
ETHERS = sys.argv[4]        # local ethers.umd.min.js
CIRCUITS = sys.argv[5]
STRANGER = sys.argv[6]      # impersonated on anvil, holds no transistors
MANIFEST = json.load(open(sys.argv[7]))
CURATOR = sys.argv[8]       # impersonated on anvil; claims the reserved works


def rpc(method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    r = json.load(urllib.request.urlopen(urllib.request.Request(RPC, body, {"content-type": "application/json"})))
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


WALLET_JS = """
(() => {
  const buyer = "%s";
  window.ethereum = {
    isMetaMask: true,
    async request({ method, params }) {
      if (method === "eth_requestAccounts" || method === "eth_accounts") return [buyer];
      if (method === "wallet_switchEthereumChain") return null;
      const r = await fetch("%s", { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: params || [] }) }).then((x) => x.json());
      if (r.error) { const e = new Error(r.error.message); e.code = r.error.code; e.data = r.error.data; throw e; }
      return r.result;
    },
    _l: {},
    on(ev, f) { (this._l[ev] = this._l[ev] || []).push(f); }, removeListener() {},
  };
  window.__emit = (ev, arg) => (window.ethereum._l[ev] || []).forEach((f) => f(arg));
})();
"""
WALLET = WALLET_JS % (BUYER, RPC)


def owner_of(token_id):
    r = rpc("eth_call", [{"to": CIRCUITS, "data": "0x6352211e" + token_id.to_bytes(32, "big").hex()}, "latest"])
    return "0x" + r[-40:]

checks = []


def CDN(route):
    # the page loads ethers with crossorigin + SRI, so the stand-in response must allow CORS
    route.fulfill(path=ETHERS, content_type="application/javascript", headers={"access-control-allow-origin": "*"})


def check(name, ok):
    checks.append((name, bool(ok)))
    print(("PASS " if ok else "FAIL ") + name)


with sync_playwright() as p:
    b = p.chromium.launch()
    # the test polls with string predicates, which the page's CSP forbids; the phone pass below keeps the CSP on
    ctx = b.new_context(viewport={"width": 1280, "height": 900}, locale="zh-CN", bypass_csp=True)
    ctx.add_init_script(WALLET)
    ctx.route("https://cdnjs.cloudflare.com/**", CDN)
    ctx.route("https://fonts.googleapis.com/**", lambda r: r.abort())
    page = ctx.new_page()
    errors = []
    page.on("pageerror", lambda e: errors.append(str(e)))
    page.on("console", lambda msg: print("console:", msg.text[:600]) if msg.type in ("error", "warning") else None)

    page.goto(SITE)
    page.wait_for_function("document.getElementById('phase').textContent !== '—' || "
                           "!document.getElementById('load-error').hidden", timeout=60000)
    if page.is_visible("#load-error"):
        print("page could not load:", page.inner_text("#load-error"))
        sys.exit(2)
    check("loads the collection", page.inner_text("#c-title") == MANIFEST["launch"]["name"])
    check("presale phase shown", "白名单预售中" in page.inner_text("#phase"))
    check("committed HTML title shown as text", page.evaluate("window.__xss === undefined")
          and "<img" in page.inner_text("#row-2") and page.locator("#rows img").count() == 0
          and "<script>" in page.inner_text("#c-story"))
    check("no buy buttons before connecting", page.locator("td.act button").count() == 0)
    page.screenshot(path=f"{OUT}/1-presale.png", full_page=True)

    page.click("#connect")
    page.wait_for_function("!document.getElementById('you').hidden")
    check("allowlisted wallet recognised", "你在白名单中" in page.inner_text("#you-presale"))
    page.locator("#row-0 button").click()
    page.wait_for_function("document.querySelector('#row-0 .status').textContent.includes('已售出')", timeout=60000)
    check("presale purchase of work 0", True)
    check("presale quota used up", "还剩 0 件" in page.inner_text("#you-presale"))
    check("no more presale buttons", page.locator("td.act button").count() == 0)
    page.screenshot(path=f"{OUT}/2-after-presale.png", full_page=True)

    # move the chain past the public sale start
    rpc("evm_increaseTime", [4000])
    rpc("evm_mine", [])
    page.reload()
    page.wait_for_function("document.getElementById('phase').textContent.includes('公开发售中')", timeout=30000)
    page.click("#connect")
    page.wait_for_function("!document.getElementById('you').hidden")
    page.locator("#row-1 button").click()
    page.wait_for_function("document.querySelector('#row-1 .status').textContent.includes('已售出')", timeout=60000)
    check("public purchase of work 1", True)
    check("bought works are owned by the buyer", owner_of(1) == BUYER.lower() and owner_of(2) == BUYER.lower())
    check("reserved work has no buy button", page.locator("#row-5 button").count() == 0 and
          "国库预留" in page.inner_text("#row-5 .status"))
    page.screenshot(path=f"{OUT}/3-public.png", full_page=True)

    # a stranger with no transistors tapes out a zero-cost REF wrapper of circuit 1 (work 0: 1 input, 1 output)
    ref = "02" + CIRCUITS[2:].lower() + (1).to_bytes(8, "big").hex() + "01" + "01" + "000002"
    nl = bytes.fromhex(ref)
    data = ("0x7bd3ac1d" + (0x60).to_bytes(32, "big").hex() + (1).to_bytes(32, "big").hex() + (1).to_bytes(32, "big").hex()
            + len(nl).to_bytes(32, "big").hex() + nl.hex().ljust(64 * ((len(nl) + 31) // 32), "0"))
    txh = rpc("eth_sendTransaction", [{"from": STRANGER, "to": CIRCUITS, "data": data, "value": hex(2 * 10**14)}])
    rcpt = rpc("eth_getTransactionReceipt", [txh])
    check("stranger taped out a REF wrapper", rcpt and int(rcpt["status"], 16) == 1)
    wrapper_id = 3

    # verification
    page.click("#tab-verify")
    page.fill("#vq", "1")
    page.click("#vform button")
    page.wait_for_selector(".verdict.yes, .verdict.no", timeout=30000)
    check("official circuit verified", "官方作品" in page.inner_text("#verdict") and "第 0 号" in page.inner_text("#verdict"))
    page.screenshot(path=f"{OUT}/4-verify-official.png", full_page=True)
    page.fill("#vq", str(wrapper_id))
    page.click("#vform button")
    page.wait_for_selector(".verdict.no", timeout=30000)
    check("REF wrapper flagged", "不是官方作品" in page.inner_text("#verdict") and "引用" in page.inner_text("#verdict"))
    page.screenshot(path=f"{OUT}/5-verify-wrapper.png", full_page=True)
    page.fill("#vq", "999")
    page.click("#vform button")
    page.wait_for_selector(".verdict.none h3", timeout=30000)
    check("missing circuit reported", "没有这个电路" in page.inner_text("#verdict"))

    # the curator claims a reserved work during the sale, and the other one after the sale has ended
    cur = b.new_context(viewport={"width": 1280, "height": 900}, locale="zh-CN", bypass_csp=True)
    cur.add_init_script(WALLET_JS % (CURATOR, RPC))
    cur.route("https://cdnjs.cloudflare.com/**", CDN)
    cur.route("https://fonts.googleapis.com/**", lambda r: r.abort())
    cp = cur.new_page()
    cp.on("pageerror", lambda e: errors.append(str(e)))
    cp.goto(SITE)
    cp.wait_for_function("document.getElementById('phase').textContent !== '—'", timeout=60000)
    check("buyer sees no claim button", page.locator("#row-5 button").count() == 0)
    cp.click("#connect")
    cp.wait_for_function("!document.getElementById('you').hidden")
    cp.locator("#row-5 button").click()
    cp.wait_for_function("document.querySelector('#row-5 .status').textContent.includes('已进国库')", timeout=60000)
    treasury = MANIFEST["launch"]["treasury"].lower()
    check("curator claims a reserved work to the treasury", owner_of(4) == treasury)
    rpc("evm_increaseTime", [31 * 86400])
    rpc("evm_mine", [])
    cp.reload()
    cp.wait_for_function("document.getElementById('phase').textContent.includes('发售已结束')", timeout=30000)
    cp.click("#connect")
    cp.wait_for_function("!document.getElementById('you').hidden")
    check("after the sale: no buy buttons, one claim button", cp.locator("td.act button").count() == 1
          and cp.locator("#row-6 button").count() == 1)
    cp.locator("#row-6 button").click()
    cp.wait_for_function("document.querySelector('#row-6 .status').textContent.includes('已进国库')", timeout=60000)
    check("reserved work claimed after the sale ended", owner_of(5) == treasury)
    cp.screenshot(path=f"{OUT}/7-after-sale-claimed.png", full_page=True)
    cur.close()

    # switching account in the wallet must drop the connection
    page.click("#tab-buy")
    page.evaluate("window.__emit('accountsChanged', [])")
    check("account switch disconnects", page.is_hidden("#acct") and page.is_hidden("#you"))

    # hostile manifests
    page.goto(SITE + "?config=site-tampered.json")
    page.wait_for_function("!document.getElementById('load-error').hidden || "
                           "document.getElementById('phase').textContent !== '—'", timeout=60000)
    check("tampered price refused", page.is_visible("#load-error") and page.locator("td.act button").count() == 0
          and "不一致" in page.inner_text("#load-error"))
    page.goto(SITE + "?config=site-othercurator.json")
    page.wait_for_function("!document.getElementById('load-error').hidden || "
                           "document.getElementById('phase').textContent !== '—'", timeout=60000)
    check("manifest naming another curator refused", page.is_visible("#load-error") and "策展人" in page.inner_text("#load-error"))
    page.goto(SITE + "?config=site-retitled.json")
    page.wait_for_function("!document.getElementById('load-error').hidden || "
                           "document.getElementById('phase').textContent !== '—'", timeout=60000)
    check("changed title refused", page.is_visible("#load-error") and "标题" in page.inner_text("#load-error"))

    m = b.new_context(viewport={"width": 390, "height": 844}, locale="zh-CN")
    m.add_init_script(WALLET)
    m.route("https://cdnjs.cloudflare.com/**", CDN)
    m.route("https://fonts.googleapis.com/**", lambda r: r.abort())
    mp = m.new_page()
    mp.goto(SITE)
    mp.wait_for_selector("#rows tr", timeout=60000)
    check("works under its own CSP", mp.locator("#rows tr").count() == len(MANIFEST["works"]))
    check("no horizontal scroll on a phone", mp.evaluate("document.documentElement.scrollWidth <= innerWidth + 1"))
    mp.screenshot(path=f"{OUT}/6-mobile.png", full_page=True)

    check("no page errors", not errors)
    if errors:
        print(errors)
    b.close()

failed = [n for n, ok in checks if not ok]
print(f"{len(checks) - len(failed)}/{len(checks)} checks passed")
sys.exit(1 if failed else 0)
