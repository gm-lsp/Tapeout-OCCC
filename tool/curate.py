#!/usr/bin/env python3
"""curate — off-chain tool for TapeOut Curated Collections.

Pure Python 3.10+, no third-party dependencies. MIT licence.

Commands
  encode   <design>                 canvas file or raw netlist -> TAP-02 netlist + counts
  build    <collection.json> <out> [--rpc URL]
                                    encode every work, resolve REF targets on chain, build the Merkle
                                    tree, write a launch manifest
  allowproof <manifest> <address> [--index N | --all]   print an allowlisted wallet's presale quota, tier and
                                    proof, and its presale price and price proof for work N (or every work)
  checkroot <manifest> [--rpc URL --registry ADDR --circuits ADDR]
                                    rebuild the root from every published work and compare it with the
                                    manifest and, if given, with the chain
  proof    <manifest> <index>       print the buy() arguments for one work
  verify   <manifest|-> --rpc URL --registry ADDR --circuits ADDR --id N
                                    ask the chain whether a circuit is official (and which work it is)
  selftest                          run TAP-02 vectors and encoder round-trip checks

Design inputs
  * TapeOut canvas export: {"format":"tapeout-canvas","v":1,"nodes":[...],"edges":[...]}
    node types: input, output, const0, const1, nand, latch, ref.
    A ref node's data must carry {"cpu": "0x..", "id": n, "nIn": i, "nOut": o} and, if the target
    has state, "nState". (The canvas format does not document ref data; this is the tool's convention.)
  * Raw netlist: {"netlist": "0x..", "nIn": i, "nOut": o}

Why byte-equality with tapeout.net is NOT required
  A work is official because the collection's vault taped it out and the registry certified that
  circuit id in the same transaction. The Merkle leaf commits to the exact bytes this tool produces
  and the vault tapes out exactly those bytes, so any well-formed encoding is fine.
"""
from __future__ import annotations

import argparse
import json
import os
import random
import sys
import time
import urllib.request
from collections import defaultdict, deque

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import tap02_reference as ref  # noqa: E402  (official TAP-02 reference implementation, MIT)

MIN_SUPPLY = 10_000          # factory minimum transistor supply
# TapeOut on each chain: processor factory, and the fees it charged when last checked (deployFee() and protocolFee()
# per mint call, in the chain's native coin). With --rpc, build reads the current fees from the factory instead.
CHAINS = {
    56: {"name": "BNB Smart Chain", "coin": "BNB", "factory": "0x68224F668083c29e9800Be2a646d42d18cedF7e2",
         "deployFee": 10**15, "protocolFee": 10**14},                       # 2026-10-25
    196: {"name": "X Layer", "coin": "OKB", "factory": "0x1f09DAeFA827f02CBb40967cc91b259763760761",
          "deployFee": 66 * 10**14, "protocolFee": 66 * 10**13},            # 2026-10-30
    8453: {"name": "Base", "coin": "ETH", "factory": "0x1f09DAeFA827f02CBb40967cc91b259763760761",
           "deployFee": 3 * 10**14, "protocolFee": 3 * 10**13},             # 2026-10-30
}
TAPEOUT_FACTORY = CHAINS[56]["factory"]   # kept for callers of earlier versions (BNB Smart Chain)
DEFAULT_DEPLOY_FEE, DEFAULT_PROTOCOL_FEE = CHAINS[56]["deployFee"], CHAINS[56]["protocolFee"]


def _units(amount: int, decimals: int) -> str:
    """An amount in a token's smallest unit, as a decimal string (no rounding)."""
    whole, frac = divmod(amount, 10 ** decimals) if decimals else (amount, 0)
    return str(whole) + ("." + str(frac).rjust(decimals, "0").rstrip("0") if frac else "")


def chain_info(chain_id: int) -> dict:
    if chain_id not in CHAINS:
        known = ", ".join(str(k) + " " + v["name"] for k, v in CHAINS.items())
        raise DesignError(f"chain {chain_id} is not a TapeOut chain this tool knows ({known}); for another chain "
                          "give deployFeeWei and protocolFeeWei in the spec, and factory when checking REFs with --rpc")
    return CHAINS[chain_id]


MAX_TAPEOUT_BYTES = 34_000   # practical single tape-out limit observed on BNB Smart Chain mainnet

# ============================================================================ keccak-256
_RC = [0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
       0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
       0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
       0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
       0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
       0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56],
        [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _f(s):
    for rc in _RC:
        c = [s[x][0] ^ s[x][1] ^ s[x][2] ^ s[x][3] ^ s[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ (((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63)) & _M) for x in range(5)]
        s = [[s[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                r = _ROT[x][y]
                b[y][(2 * x + 3 * y) % 5] = ((s[x][y] << r) | (s[x][y] >> (64 - r))) & _M if r else s[x][y]
        s = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        s[0][0] ^= rc
    return s


def keccak256(data: bytes) -> bytes:
    rate = 136
    msg = bytearray(data) + b"\x01"
    while len(msg) % rate:
        msg.append(0)
    msg[-1] |= 0x80
    s = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        blk = msg[off:off + rate]
        for i in range(rate // 8):
            x, y = i % 5, i // 5
            s[x][y] ^= int.from_bytes(blk[8 * i:8 * i + 8], "little")
        s = _f(s)
    out = b"".join(s[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out


def hx(b: bytes) -> str:
    return "0x" + b.hex()


def unhex(s: str) -> bytes:
    return bytes.fromhex(s[2:] if s.startswith("0x") else s)


# ============================================================================ canvas -> netlist
class DesignError(ValueError):
    pass


def _addr20(s: str) -> bytes:
    b = unhex(s)
    if len(b) != 20:
        raise DesignError(f"bad address {s}")
    return b


def encode_canvas(doc: dict) -> dict:
    """Compile a tapeout-canvas document to a TAP-02 netlist.

    Element order: LATCHes first (their d may point forward), then NAND/REF in a deterministic
    topological order, then the output drivers. TAP-02 takes the last nOut signals as outputs, so
    each output is either its own driver moved to the tail (when nothing else reads it) or a buffer.
    """
    if doc.get("format") != "tapeout-canvas":
        raise DesignError("not a tapeout-canvas document")
    nodes = {n["id"]: n for n in doc["nodes"]}
    order_in_file = {n["id"]: i for i, n in enumerate(doc["nodes"])}
    typ = {k: n["type"] for k, n in nodes.items()}
    for k, t in typ.items():
        if t not in ("input", "output", "const0", "const1", "nand", "latch", "ref"):
            raise DesignError(f"node {k}: unknown type {t}")

    ins: dict[str, dict[str, tuple[str, str]]] = defaultdict(dict)   # target -> handle -> (src, srcHandle)
    readers: dict[tuple[str, str], list[tuple[str, str]]] = defaultdict(list)
    for e in doc["edges"]:
        s, t, th = e["source"], e["target"], e["targetHandle"]
        sh = e.get("sourceHandle") or "out"
        if s not in nodes or t not in nodes:
            raise DesignError(f"edge {e.get('id')}: unknown node")
        if th in ins[t]:
            raise DesignError(f"node {t}: input {th} connected twice")
        ins[t][th] = (s, sh)
        readers[(s, sh)].append((t, th))

    inputs = sorted((k for k in nodes if typ[k] == "input"), key=lambda k: nodes[k]["data"]["index"])
    outputs = sorted((k for k in nodes if typ[k] == "output"), key=lambda k: nodes[k]["data"]["index"])
    if [nodes[k]["data"]["index"] for k in inputs] != list(range(len(inputs))):
        raise DesignError("input indexes must be 0..n-1")
    if [nodes[k]["data"]["index"] for k in outputs] != list(range(len(outputs))):
        raise DesignError("output indexes must be 0..n-1")
    if not outputs:
        raise DesignError("at least one output is required")
    n_in, n_out = len(inputs), len(outputs)

    def ref_meta(k):
        d = nodes[k].get("data") or {}
        try:
            return _addr20(d["cpu"]), int(d["id"]), int(d["nIn"]), int(d["nOut"]), int(d.get("nState", 0))
        except KeyError as exc:
            raise DesignError(f"ref node {k}: data needs cpu, id, nIn, nOut") from exc

    need = {"nand": ["a", "b"], "latch": ["d"], "output": ["in"]}
    for k, t in typ.items():
        hs = need.get(t, [])
        if t == "ref":
            hs = [f"in{i}" for i in range(ref_meta(k)[2])]
        for h in hs:
            if h not in ins[k]:
                raise DesignError(f"node {k} ({t}): input {h} is not connected")

    # ---- which drivers can be moved to the tail (read by nothing but one output; LATCH d may read forward)
    def comb_readers(src):
        return [(t, h) for (t, h) in readers[src] if typ[t] in ("nand", "ref")]

    driver = [ins[o]["in"] for o in outputs]
    uses = defaultdict(int)
    for d in driver:
        uses[d] += 1
    tail: dict[int, str] = {}
    for oi, (src, sh) in enumerate(driver):
        if typ[src] in ("nand", "latch") and sh == "out" and uses[(src, sh)] == 1 and not comb_readers((src, sh)):
            tail[oi] = src
    tail_nodes = set(tail.values())

    # ---- order: latches, then NAND/REF topologically (Kahn, ties by file order)
    latches = sorted((k for k in nodes if typ[k] == "latch" and k not in tail_nodes), key=order_in_file.get)
    comb = [k for k in nodes if typ[k] in ("nand", "ref") and k not in tail_nodes]
    deps = {k: {s for (s, _) in ins[k].values() if typ[s] in ("nand", "ref")} for k in comb}
    for k in comb:
        if deps[k] & tail_nodes:
            raise DesignError("internal: tail node read combinationally")
    indeg = {k: len(deps[k]) for k in comb}
    fwd = defaultdict(list)
    for k in comb:
        for s in deps[k]:
            fwd[s].append(k)
    ready = sorted((k for k in comb if indeg[k] == 0), key=order_in_file.get)
    q = deque(ready)
    topo = []
    while q:
        u = q.popleft()
        topo.append(u)
        nxt = []
        for v in fwd[u]:
            indeg[v] -= 1
            if indeg[v] == 0:
                nxt.append(v)
        for v in sorted(nxt, key=order_in_file.get):
            q.append(v)
    if len(topo) != len(comb):
        raise DesignError("combinational loop (a loop must pass through a LATCH)")

    # ---- assign signals
    sig: dict[tuple[str, str], int] = {}
    for i, k in enumerate(inputs):
        sig[(k, "out")] = 2 + i
    for k in nodes:
        if typ[k] == "const0":
            sig[(k, "out")] = 0
        elif typ[k] == "const1":
            sig[(k, "out")] = 1
    nxt_sig = 2 + n_in
    body: list[tuple[str, str]] = [(k, "latch") for k in latches] + [(k, typ[k]) for k in topo]
    for k, t in body:
        if t == "ref":
            n_o = ref_meta(k)[3]
            for j in range(n_o):
                sig[(k, f"out{j}")] = nxt_sig + j
            nxt_sig += n_o
        else:
            sig[(k, "out")] = nxt_sig
            nxt_sig += 1
    # Tail. The outputs must be exactly the last nOut signals, in output order, so:
    #   phase 1: one inverter NAND(s, s) for every output that needs a 2-gate buffer;
    #   phase 2: exactly one element per output, in output order (the moved driver itself,
    #            a constant NAND, or the second inverter of the buffer).
    tail_plan = []   # (kind, x) for phase 2
    pre_inv = {}     # output index -> signal of its phase-1 inverter
    for oi in range(n_out):
        if oi not in tail and typ[driver[oi][0]] not in ("const0", "const1"):
            pre_inv[oi] = nxt_sig
            nxt_sig += 1
    for oi in range(n_out):
        if oi in tail:
            sig[(tail[oi], "out")] = nxt_sig
            tail_plan.append(("node", tail[oi]))
        elif oi in pre_inv:
            tail_plan.append(("buf", oi))
        else:
            tail_plan.append(("const", driver[oi]))
        nxt_sig += 1

    def s_of(src):
        if src not in sig:
            raise DesignError(f"node {src[0]}: no output {src[1]}")
        return sig[src]

    els: list[ref.Element] = []
    for k, t in body:
        if t == "latch":
            els.append(ref.Element(ref.LATCH, [s_of(ins[k]["d"])]))
        elif t == "nand":
            els.append(ref.Element(ref.NAND, [s_of(ins[k]["a"]), s_of(ins[k]["b"])]))
        else:
            cpu, cid, ni, no, _ = ref_meta(k)
            els.append(ref.Element(ref.REF, [s_of(ins[k][f"in{i}"]) for i in range(ni)], cpu, cid, no))
    for oi in sorted(pre_inv):
        s = s_of(driver[oi])
        assert 2 + n_in + sum(e.n_out for e in els) == pre_inv[oi]
        els.append(ref.Element(ref.NAND, [s, s]))                       # NOT driver
    for kind, x in tail_plan:
        if kind == "node":
            k = x
            if typ[k] == "latch":
                els.append(ref.Element(ref.LATCH, [s_of(ins[k]["d"])]))
            else:
                els.append(ref.Element(ref.NAND, [s_of(ins[k]["a"]), s_of(ins[k]["b"])]))
        elif kind == "const":
            # NAND(1,1) = 0, NAND(0,0) = 1
            els.append(ref.Element(ref.NAND, [1, 1] if typ[x[0]] == "const0" else [0, 0]))
        else:
            inv = pre_inv[x]
            els.append(ref.Element(ref.NAND, [inv, inv]))                # NOT NOT driver
    assert 2 + n_in + sum(e.n_out for e in els) == nxt_sig
    netlist = ref.encode(els)
    return finish(netlist, n_in, n_out, refs_from_canvas(doc))


def refs_from_canvas(doc: dict) -> dict:
    out = {}
    for n in doc["nodes"]:
        if n["type"] == "ref":
            d = n["data"]
            out[(_addr20(d["cpu"]), int(d["id"]))] = (int(d["nIn"]), int(d["nOut"]), int(d.get("nState", 0)))
    return out


def finish(netlist: bytes, n_in: int, n_out: int, refs: dict | None = None) -> dict:
    """Check well-formedness with the TAP-02 reference implementation and count transistors."""
    refs = refs or {}

    def resolve(cpu, cid):
        m = refs.get((cpu, cid))
        if m is None:
            return None
        sub = ref.Circuit(m[0], m[1], [])
        sub.n_state = m[2]
        return sub

    c = ref.load(netlist, n_in, n_out, resolve)   # raises IllFormed
    nand = sum(1 for e in c.elements if e.op == ref.NAND)
    latch = sum(1 for e in c.elements if e.op == ref.LATCH)
    nref = sum(1 for e in c.elements if e.op == ref.REF)
    if len(netlist) > MAX_TAPEOUT_BYTES:
        raise DesignError(f"netlist is {len(netlist)} bytes, above the {MAX_TAPEOUT_BYTES}-byte tape-out limit;"
                          " split it into sub-circuits and combine them with REF")
    return {"netlist": hx(netlist), "nIn": n_in, "nOut": n_out, "nand": nand, "latch": latch, "ref": nref,
            "nState": c.n_state, "bytes": len(netlist), "netlistHash": hx(keccak256(netlist))}


def encode_design(doc: dict) -> dict:
    if doc.get("format") == "tapeout-canvas":
        return encode_canvas(doc)
    if "netlist" in doc:
        refs = {}
        for r in doc.get("refs", []):
            refs[(_addr20(r["cpu"]), int(r["id"]))] = (int(r["nIn"]), int(r["nOut"]), int(r.get("nState", 0)))
        return finish(unhex(doc["netlist"]), int(doc["nIn"]), int(doc["nOut"]), refs)
    raise DesignError("unknown design format (need a tapeout-canvas file or {netlist, nIn, nOut})")


# ============================================================================ canvas simulator (independent check)
def simulate_canvas(doc: dict, beats: list[list[int]]) -> list[list[int]]:
    """Evaluate a canvas document directly from its graph (no REF). Used to cross-check the encoder."""
    nodes = {n["id"]: n for n in doc["nodes"]}
    typ = {k: n["type"] for k, n in nodes.items()}
    ins = defaultdict(dict)
    for e in doc["edges"]:
        ins[e["target"]][e["targetHandle"]] = e["source"]
    inputs = sorted((k for k in nodes if typ[k] == "input"), key=lambda k: nodes[k]["data"]["index"])
    outputs = sorted((k for k in nodes if typ[k] == "output"), key=lambda k: nodes[k]["data"]["index"])
    latch = [k for k in nodes if typ[k] == "latch"]
    state = {k: 0 for k in latch}
    res = []
    for vec in beats:
        val = {}
        for i, k in enumerate(inputs):
            val[k] = vec[i]

        def get(k):
            if k in val:
                return val[k]
            t = typ[k]
            if t == "const0":
                v = 0
            elif t == "const1":
                v = 1
            elif t == "latch":
                v = state[k]
            elif t == "nand":
                v = 1 - (get(ins[k]["a"]) & get(ins[k]["b"]))
            else:
                raise DesignError("simulate_canvas: unsupported node " + t)
            val[k] = v
            return v

        sys.setrecursionlimit(max(10000, 4 * len(nodes)))
        outs = [get(ins[o]["in"]) for o in outputs]
        state = {k: get(ins[k]["d"]) for k in latch}
        res.append(outs)
    return res


def simulate_netlist(enc: dict, beats: list[list[int]]) -> list[list[int]]:
    c = ref.load(unhex(enc["netlist"]), enc["nIn"], enc["nOut"])
    st = [0] * c.n_state
    res = []
    for vec in beats:
        st, outs = ref.beat(c, st, vec)
        res.append(outs)
    return res


def cross_check(doc: dict, enc: dict, n_beats: int = 64, seed: int = 1) -> None:
    rng = random.Random(seed)
    beats = [[rng.randint(0, 1) for _ in range(enc["nIn"])] for _ in range(n_beats)]
    a = simulate_canvas(doc, beats)
    b = simulate_netlist(enc, beats)
    if a != b:
        for i, (x, y) in enumerate(zip(a, b)):
            if x != y:
                raise DesignError(f"encoder mismatch at beat {i}: canvas {x} vs netlist {y}")


# ============================================================================ Merkle tree (OpenZeppelin-compatible)
def abi_word(v: int | bytes) -> bytes:
    if isinstance(v, bytes):
        assert len(v) == 32
        return v
    return v.to_bytes(32, "big")


def leaf_of(chain_id: int, registry: str, curator: str, index: int, netlist_hash: bytes, n_in: int, n_out: int,
            price: int, reserved: bool) -> bytes:
    """keccak256(bytes.concat(keccak256(abi.encode(
           chainid, registry, curator, index, netlistHash, nIn, nOut, price, reserved))))"""
    words = (chain_id, int(registry, 16), int(curator, 16), index, netlist_hash, n_in, n_out, price, int(reserved))
    inner = keccak256(b"".join(abi_word(x) for x in words))
    return keccak256(inner)


def allow_leaf_of(chain_id: int, registry: str, curator: str, wallet: str, quota: int, tier: int = 0) -> bytes:
    """keccak256(bytes.concat(keccak256(abi.encode(chainid, registry, curator, ALLOW_TAG, wallet, quota, tier))))"""
    words = (chain_id, int(registry, 16), int(curator, 16), keccak256(b"TAP-curated-allowlist-v2"), int(wallet, 16),
             quota, tier)
    return keccak256(keccak256(b"".join(abi_word(x) for x in words)))


def presale_price_leaf_of(chain_id: int, registry: str, curator: str, root: bytes, index: int, tier: int,
                          price: int) -> bytes:
    """keccak256(bytes.concat(keccak256(abi.encode(chainid, registry, curator, PRESALE_PRICE_TAG, root, index, tier,
    price)))); `root` is the collection's work-list root, so a price list cannot be reused for another collection"""
    prefix = b"".join(abi_word(x) for x in (chain_id, int(registry, 16), int(curator, 16),
                                            keccak256(b"TAP-curated-presale-price"), root))
    return keccak256(keccak256(prefix + abi_word(index) + abi_word(tier) + abi_word(price)))


def _is_amount(x) -> bool:
    return isinstance(x, str) and x.isascii() and x.isdecimal() and str(int(x)) == x


def presale_price_leaves(chain_id: int, registry: str, curator: str, root: bytes, tiers: list, works: list) -> list:
    """Every (tier, index, price) of the presale price list, tier by tier, in index order; reserved works have none."""
    prefix = b"".join(abi_word(x) for x in (chain_id, int(registry, 16), int(curator, 16),
                                            keccak256(b"TAP-curated-presale-price"), root))
    out = []
    for t, tier in enumerate(tiers):
        for w, price in zip(works, tier["prices"]):
            if price is not None:
                leaf = keccak256(keccak256(prefix + abi_word(w["index"]) + abi_word(t) + abi_word(int(price))))
                out.append((t, w["index"], int(price), leaf))
    return out


def presale_price_proofs(m: dict, tier: int, indexes: list) -> list:
    """The presale price of each work in `indexes` for allowlist tier `tier`, with its proof against presalePriceRoot
    (the tree is built once). Without presale prices the presale price is the work-list price and needs no proof."""
    works = m["works"]
    for i in indexes:
        if not 0 <= i < len(works):
            raise DesignError(f"there is no work {i} (the collection has {len(works)})")
        if works[i]["reserved"]:
            raise DesignError(f"work {i} is reserved: it is not sold in the presale")
    tiers = m.get("presaleTiers")
    if not tiers:
        return [{"index": i, "presalePriceWei": works[i]["priceWei"], "presaleProof": []} for i in indexes]
    if not 0 <= tier < len(tiers):
        raise DesignError(f"tier {tier} has no presale prices (there are {len(tiers)} tiers)")
    pl = presale_price_leaves(int(m["chainId"]), m["registry"], m["launch"]["curator"], unhex(m["launch"]["root"]),
                              tiers, works)
    _, proofs = merkle([x[3] for x in pl])
    found = {i: (price, proof) for (t, i, price, _), proof in zip(pl, proofs) if t == tier}
    return [{"index": i, "presalePriceWei": str(found[i][0]), "presaleProof": [hx(x) for x in found[i][1]]}
            for i in indexes]


def titles_hash(titles: list[str]) -> bytes:
    """keccak256(abi.encodePacked(keccak256(bytes(title_0)), ..., keccak256(bytes(title_n-1)))), UTF-8, index order"""
    return keccak256(b"".join(keccak256(t.encode("utf-8")) for t in titles))


def metadata_of(name: str, symbol: str, story: str, t_hash: bytes) -> bytes:
    """CuratedVault.metadataOf: keccak256(abi.encode(METADATA_TAG, keccak(name), keccak(symbol), keccak(story), titlesHash))"""
    words = (keccak256(b"TAP-curated-metadata"), keccak256(name.encode("utf-8")), keccak256(symbol.encode("utf-8")),
             keccak256(story.encode("utf-8")), t_hash)
    return keccak256(b"".join(words))


_B64URL = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
_B58 = set("123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz")
_B32 = set("abcdefghijklmnopqrstuvwxyz234567")
_SEGMENT = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._~-")


def is_content_addressed(u: str) -> bool:
    """CuratedRegistry.isContentAddressed: "", "ipfs://" + a CIDv0 ("Qm…", 46) or a base32 CIDv1 of dag-pb or raw
    data ("bafy…" / "bafk…", 50..100), or "ar://" + 43 base64url characters with an upper-case letter."""
    if u == "":
        return True
    if not isinstance(u, str) or not u.isascii():
        return False
    if u.startswith("ipfs://"):
        c = u[7:]
        if len(c) == 46 and c.startswith("Qm"):
            return set(c) <= _B58
        if 50 <= len(c) <= 100 and c[:4] in ("bafy", "bafk"):
            return set(c) <= _B32
        return False
    if u.startswith("ar://") and len(u) - 5 == 43:
        # ArNS names are lower case: an upper-case letter means a transaction id, never a repointable name
        return set(u[5:]) <= _B64URL and any("A" <= c <= "Z" for c in u[5:])
    return False


def is_content_uri(u: str) -> bool:
    """An image or animation link inside a metadata file: a content-addressed root, optionally followed by a path of
    plain segments (letters, digits, . _ ~ -; no "." or ".." and no percent-encoding, so it cannot leave the root)."""
    if not isinstance(u, str) or not u.isascii():
        return False
    for pre in ("ipfs://", "ar://"):
        if u.startswith(pre):
            head, sep, rest = u[len(pre):].partition("/")
            if not is_content_addressed(pre + head) or head == "":
                return False
            if not sep:
                return True
            segs = rest.split("/")
            return all(x and x not in (".", "..") and set(x) <= _SEGMENT for x in segs)
    return False


def metadata_json(m: dict, index: int) -> dict:
    """The ERC-721 metadata file <metadataURI>/<index>.json for work `index` of a manifest."""
    w = m["works"][index]
    meta = w.get("meta", {})
    out = {"name": w["title"]}
    if meta.get("description"):
        out["description"] = meta["description"]
    if meta.get("image"):
        out["image"] = meta["image"]
    if meta.get("animation"):
        out["animation_url"] = meta["animation"]
    attrs = list(meta.get("attributes", []))
    attrs.append({"trait_type": "Edition", "value": index})
    out["attributes"] = attrs
    out["properties"] = {"collection": m["launch"]["name"], "index": index, "netlistHash": w["netlistHash"],
                         "nIn": w["nIn"], "nOut": w["nOut"]}
    return out


def write_metadata(manifest_path: str, out_dir: str) -> list[str]:
    """Write <index>.json for every work. Upload the folder as one directory (IPFS or an Arweave path manifest),
    then set "metadataURI" in the collection spec to ipfs://<CID> or ar://<manifest id> and build again."""
    m = json.load(open(manifest_path, encoding="utf-8"))
    os.makedirs(out_dir, exist_ok=True)
    names = []
    for i in range(len(m["works"])):
        name = f"{i}.json"
        with open(os.path.join(out_dir, name), "w", encoding="utf-8") as f:
            json.dump(metadata_json(m, i), f, ensure_ascii=False, separators=(",", ":"))
        names.append(name)
    return names


def _work_meta(i: int, w: dict) -> dict:
    meta = {}
    for k in ("description", "image", "animation"):
        if k in w:
            v = w[k]
            if not isinstance(v, str):
                raise DesignError(f"work {i}: {k} must be text")
            if k != "description" and not is_content_uri(v):
                raise DesignError(f"work {i}: {k} must be an ipfs://<CID>[/path] or ar://<id>[/path] link "
                                  "(content-addressed, so it can never change)")
            if v:
                meta[k] = v
    if "attributes" in w:
        a = w["attributes"]
        if not isinstance(a, list) or not all(isinstance(x, dict) and isinstance(x.get("trait_type"), str)
                                              and isinstance(x.get("value"), (str, int)) and not isinstance(x.get("value"), bool)
                                              and set(x) <= {"trait_type", "value"} for x in a):
            raise DesignError(f"work {i}: attributes must be a list of {{\"trait_type\": text, \"value\": text or number}}")
        if a:
            meta["attributes"] = a
    return meta


def _hash_pair(a: bytes, b: bytes) -> bytes:
    return keccak256(a + b) if a < b else keccak256(b + a)


def merkle_root(leaves: list[bytes]) -> bytes:
    """The root of merkle(leaves), without building every proof."""
    layer = sorted(leaves)
    while len(layer) > 1:
        layer = [_hash_pair(layer[i], layer[i + 1]) if i + 1 < len(layer) else layer[i] for i in range(0, len(layer), 2)]
    return layer[0]


def merkle(leaves: list[bytes]) -> tuple[bytes, list[list[bytes]]]:
    """Sorted-pair tree as verified by OpenZeppelin MerkleProof. Returns (root, proof per leaf)."""
    if not leaves:
        raise ValueError("no leaves")
    layers = [sorted(leaves)]
    position = {leaf: i for i, leaf in enumerate(layers[0])}
    while len(layers[-1]) > 1:
        cur = layers[-1]
        nxt = [_hash_pair(cur[i], cur[i + 1]) if i + 1 < len(cur) else cur[i] for i in range(0, len(cur), 2)]
        layers.append(nxt)
    root = layers[-1][0]
    proofs = []
    for leaf in leaves:
        pos = position[leaf]
        proof = []
        for layer in layers[:-1]:
            sib = pos ^ 1
            if sib < len(layer):
                proof.append(layer[sib])
            pos //= 2
        proofs.append(proof)
    return root, proofs


def verify_proof(leaf: bytes, proof: list[bytes], root: bytes) -> bool:
    h = leaf
    for p in proof:
        h = _hash_pair(h, p)
    return h == root


# ============================================================================ build
def _addr(s: str) -> str:
    if not isinstance(s, str):
        raise DesignError(f"bad address {s!r}")
    b = unhex(s)
    if len(b) != 20:
        raise DesignError(f"bad address {s}")
    body = s[2:] if s[:2].lower() == "0x" else s
    if body != body.lower() and body != body.upper():
        # mixed case: must be a correct EIP-55 checksum, so a typo is caught
        h = keccak256(body.lower().encode()).hex()
        good = "".join(c.upper() if c.isalpha() and int(h[k], 16) >= 8 else c.lower() for k, c in enumerate(body.lower()))
        if body != good:
            raise DesignError(f"address {s} has a wrong checksum (did you mistype it?)")
    return "0x" + b.hex()


def _uint(v, what: str, hi: int = 2**256 - 1) -> int:
    """A whole number given as a JSON integer or a string of decimal digits (wei amounts are often too big
    for JSON numbers). Floats, booleans, negatives and values above `hi` are refused, so "0.05" (coins) or
    true can never silently become a price."""
    if isinstance(v, bool) or not (isinstance(v, int) or (isinstance(v, str) and v.isdigit() and v.isascii())):
        raise DesignError(f"{what} must be a whole number (an integer, or a string of digits), not {v!r}")
    n = int(v)
    if not 0 <= n <= hi:
        raise DesignError(f"{what} must be between 0 and {hi}, not {n}")
    return n


def resolve_refs_onchain(netlist: bytes, n_in: int, url: str, factory: str = TAPEOUT_FACTORY) -> dict:
    """Read every REF target's circuitInfo from the chain. Rejects targets that do not exist yet:
    a work must never point at a circuit id someone else could still claim."""
    refs = {}
    for e in ref.decode(netlist, n_in):
        if e.op != ref.REF or (e.cpu, e.cid) in refs:
            continue
        cpu = "0x" + e.cpu.hex()
        ok = rpc_call(url, factory, "0x" + sel("isCPU(address)") + cpu[2:].rjust(64, "0"))
        if int(ok, 16) != 1:
            raise DesignError(f"REF target {cpu} is not a TapeOut processor")
        try:
            info = rpc_call(url, cpu, "0x" + sel("circuitInfo(uint256)") + hex(e.cid)[2:].rjust(64, "0"))
        except RuntimeError as exc:
            raise DesignError(f"REF target {cpu} #{e.cid} does not exist (yet)") from exc
        f = [int(info[2 + 64 * j: 66 + 64 * j], 16) for j in range(4)]
        if (f[0], f[1]) != (len(e.ins), e.n_out):
            raise DesignError(f"REF target {cpu} #{e.cid} has {f[0]} in / {f[1]} out, netlist says "
                              f"{len(e.ins)} / {e.n_out}")
        refs[(e.cpu, e.cid)] = (f[0], f[1], f[2])
    return refs


def _mint_calls(amount: int, price: int, batch: int) -> int:
    if amount == 0:
        return 0
    return 1 if price == 0 else -(-amount // batch)


def build(spec_path: str, out_path: str, url: str | None = None) -> dict:
    spec = json.load(open(spec_path, encoding="utf-8"))
    base = os.path.dirname(os.path.abspath(spec_path))
    chain_id = _uint(spec.get("chainId", 56), "chainId")
    if chain_id in CHAINS:
        chain = CHAINS[chain_id]
    elif "deployFeeWei" in spec and "protocolFeeWei" in spec and (not url or "factory" in spec):
        # another chain (a testnet, a devnet): the spec names the fees, and the factory if REFs are checked on chain
        chain = {"name": f"chain {chain_id}", "factory": _addr(spec.get("factory", "0x" + "00" * 20)),
                 "deployFee": 0, "protocolFee": 0}
    else:
        chain = chain_info(chain_id)   # raises: unknown chain without fees (and factory)
    if url:
        rpc_chain = int(rpc_raw(url, "eth_chainId", []), 16)
        if rpc_chain != chain_id:
            raise DesignError(f"the spec is for chain {chain_id}, but the RPC is chain {rpc_chain}")
    registry = _addr(spec["registry"])
    curator = _addr(spec["curator"])
    works, warnings = [], []
    seen_hashes = {}
    for i, w in enumerate(spec["works"]):
        doc = json.load(open(os.path.join(base, w["file"]), encoding="utf-8")) if "file" in w else w
        enc = encode_design(doc)
        if enc["ref"]:
            if url is None:
                raise DesignError(f"work {i} uses REF: run build with --rpc so every REF target is checked on chain")
            onchain = resolve_refs_onchain(unhex(enc["netlist"]), enc["nIn"], url, chain["factory"])
            enc = finish(unhex(enc["netlist"]), enc["nIn"], enc["nOut"], onchain)
            if enc["nand"] == 0 and enc["latch"] == 0:
                warnings.append(f"work {i} is pure REF: anyone can tape out byte-identical copies of it "
                                "(they will not be official, but they look the same)")
        elif doc.get("format") == "tapeout-canvas":
            cross_check(doc, enc)
        if enc["netlistHash"] in seen_hashes:
            raise DesignError(f"work {i} has the same netlist as work {seen_hashes[enc['netlistHash']]}")
        seen_hashes[enc["netlistHash"]] = i
        reserved = w.get("reserved", False)
        if not isinstance(reserved, bool):
            raise DesignError(f"work {i}: reserved must be true or false (not a string)")
        if reserved:
            if _uint(w.get("priceWei", 0), f"work {i} priceWei") != 0:
                raise DesignError(f"work {i} is reserved for the treasury, so it has no price: remove priceWei")
            price = 0
        else:
            price = _uint(w.get("priceWei", spec.get("defaultPriceWei", 0)), f"work {i} priceWei")
        leaf = leaf_of(chain_id, registry, curator, i, unhex(enc["netlistHash"]), enc["nIn"], enc["nOut"], price,
                       reserved)
        title = w.get("title", f"#{i}")
        if not isinstance(title, str) or not title:
            raise DesignError(f"work {i}: title must be text")
        entry = {"index": i, "title": title, "priceWei": str(price), "reserved": reserved, **enc, "leaf": hx(leaf)}
        meta = _work_meta(i, w)
        if meta:
            entry["meta"] = meta
        works.append(entry)

    root, proofs = merkle([unhex(w["leaf"]) for w in works])
    for w, p in zip(works, proofs):
        w["proof"] = [hx(x) for x in p]
        assert verify_proof(unhex(w["leaf"]), p, root)

    nand = sum(w["nand"] for w in works)
    latch = sum(w["latch"] for w in works)
    nand_supply = nand + _uint(spec.get("spareNand", 0), "spareNand")
    latch_supply = latch + _uint(spec.get("spareLatch", 0), "spareLatch")
    if nand_supply + latch_supply < MIN_SUPPLY:
        # the factory requires at least 10,000 transistors; pad with NAND (burned at finalize)
        nand_supply = MIN_SUPPLY - latch_supply
    mint_price = _uint(spec.get("mintPriceWei", 0), "mintPriceWei")
    mint_batch = _uint(spec.get("mintBatch", 0 if mint_price == 0 else 2500), "mintBatch")
    if mint_price > 0 and mint_batch == 0:
        raise DesignError("mintBatch must be at least 1 when mintPriceWei is not 0")
    calls = _mint_calls(latch_supply, mint_price, mint_batch) + _mint_calls(nand_supply, mint_price, mint_batch)
    # the factory's fees, which a new processor inherits (the vault pays the transistor contract's protocolFee(), which
    # equals the factory's for a fresh processor); a launcher that read them from the chain can pass them in
    default_deploy, default_protocol = chain["deployFee"], chain["protocolFee"]
    if url and ("deployFeeWei" not in spec or "protocolFeeWei" not in spec):
        default_deploy = int(rpc_call(url, chain["factory"], "0x" + sel("deployFee()")), 16)
        default_protocol = int(rpc_call(url, chain["factory"], "0x" + sel("protocolFee()")), 16)
    deploy_fee = _uint(spec.get("deployFeeWei", default_deploy), "deployFeeWei")
    protocol_fee = _uint(spec.get("protocolFeeWei", default_protocol), "protocolFeeWei")
    fees = deploy_fee + calls * protocol_fee
    max_fees = _uint(spec.get("maxLaunchFeesWei", fees), "maxLaunchFeesWei")
    reserved_count = sum(1 for w in works if w["reserved"])
    treasury = _addr(spec.get("treasury", "0x" + "00" * 20))
    if reserved_count and int(treasury, 16) == 0:
        raise DesignError("some works are reserved: set \"treasury\" to the address that will receive them")
    if int(treasury, 16) == int(registry, 16):
        raise DesignError("treasury cannot be the registry")
    platform = _addr(spec.get("platform", "0x" + "00" * 20))
    platform_bps = _uint(spec.get("platformBps", 0), "platformBps", 1000)
    if platform_bps and int(platform, 16) == 0:
        raise DesignError("platformBps is set: set \"platform\" to the address that receives the share")
    # per-wallet limit: two separate settings, checked against each other
    limit_per_wallet = spec.get("limitPerWallet", False)
    if not isinstance(limit_per_wallet, bool):
        raise DesignError("limitPerWallet must be true (limit each wallet) or false (no limit)")
    if limit_per_wallet:
        if "maxPerWallet" not in spec:
            raise DesignError("limitPerWallet is true: set maxPerWallet to the number of works one wallet may mint")
        max_per_wallet = spec["maxPerWallet"]
        if not isinstance(max_per_wallet, int) or isinstance(max_per_wallet, bool) or not 1 <= max_per_wallet < 2**32:
            raise DesignError("maxPerWallet must be a whole number of at least 1")
    else:
        if spec.get("maxPerWallet") not in (None, 0):
            raise DesignError("maxPerWallet is set but limitPerWallet is false: set limitPerWallet to true, "
                              "or remove maxPerWallet for no limit")
        max_per_wallet = 0
    sale_start = _uint(spec.get("saleStart", 0), "saleStart", 2**64 - 1)
    sale_end = _uint(spec["saleEnd"], "saleEnd", 2**64 - 1)
    if sale_end <= sale_start:
        raise DesignError("saleEnd must be after saleStart")
    if sale_end <= time.time():
        raise DesignError("saleEnd is in the past: the launch would revert")

    # payment token (optional): an ERC-20 address; work prices ("priceWei") are then in its smallest unit.
    # Omitted or the zero address = the chain's native coin. Tape-out and launch fees are always native.
    payment_token = _addr(spec.get("paymentToken", "0x" + "00" * 20))
    token_info = {"symbol": chain.get("coin", "native coin"), "decimals": 18}
    if int(payment_token, 16) != 0:
        if int(payment_token, 16) in (int(registry, 16), int(curator, 16)):
            raise DesignError("paymentToken must be an ERC-20 contract")
        if url:
            if len(rpc_raw(url, "eth_getCode", [payment_token, "latest"])) <= 2:
                raise DesignError(f"paymentToken {payment_token} has no code on chain {chain_id}")
            try:
                dec = int(rpc_call(url, payment_token, "0x" + sel("decimals()")), 16)
                token_info = {"symbol": _token_symbol(rpc_call(url, payment_token, "0x" + sel("symbol()"))),
                              "decimals": dec}
            except (RuntimeError, ValueError) as exc:
                raise DesignError(f"paymentToken {payment_token} does not answer decimals() and symbol()") from exc
        else:
            token_info = {"symbol": "?", "decimals": None}
            warnings.append("paymentToken was not checked on chain: run build with --rpc")
        warnings.append("prices are in the payment token; buyers also pay the tape-out fee in the native coin. "
                        "The vault refuses tokens that do not deliver the exact amount (fee-on-transfer, rebasing)")

    # royalty declaration (optional): {"royalty": {"receiver": "0x..", "bps": 500}}  (300 = 3 %, at most 300)
    roy = spec.get("royalty") or {}
    royalty_receiver = _addr(roy.get("receiver", "0x" + "00" * 20))
    royalty_bps = roy.get("bps", 0)
    if not isinstance(royalty_bps, int) or isinstance(royalty_bps, bool) or not 0 <= royalty_bps <= 500:
        raise DesignError("royalty.bps must be a whole number from 0 to 500 (500 = 5 %)")
    if (int(royalty_receiver, 16) == 0) != (royalty_bps == 0):
        raise DesignError("royalty needs both a receiver and a rate, or neither")

    # presale allowlist (optional): {"presale": {"start": ts, "allowlist": [{"address": "0x..", "quota": 2, "tier": 0}, ...],
    #   "tiers": [{"name": "OG", "priceWei": "…", "prices": {"<index>": "…"}}, …]}}   ("tiers" optional)
    allowlist, allow_root, presale_start = [], "0x" + "00" * 32, 0
    presale_tiers, presale_price_root = None, "0x" + "00" * 32
    pre = spec.get("presale")
    if pre is not None:
        if not isinstance(pre, dict) or "start" not in pre or not isinstance(pre.get("allowlist"), list):
            raise DesignError('presale must be {"start": <unix time>, "allowlist": [...]} (or leave it out)')
        presale_start = _uint(pre["start"], "presale.start", 2**64 - 1)
        if presale_start <= 0:
            raise DesignError("presale.start must be a real time (unix seconds), not 0")
        if presale_start >= sale_start:
            raise DesignError("presale.start must be before saleStart (the presale ends when the public sale opens)")
        tiers_spec = pre.get("tiers")
        if tiers_spec is not None:
            # presale prices per allowlist tier: absolute amounts, at most the work's public price, fixed at launch
            if not isinstance(tiers_spec, list) or not 1 <= len(tiers_spec) <= 64:
                raise DesignError("presale.tiers must be a list of 1 to 64 tiers")
            presale_tiers = []
            for t, ts in enumerate(tiers_spec):
                if not isinstance(ts, dict):
                    raise DesignError(f"presale.tiers[{t}] must be {{\"name\", \"priceWei\", \"prices\"}}")
                unknown = set(ts) - {"name", "priceWei", "prices"}
                if unknown:
                    raise DesignError(f"presale.tiers[{t}] has unknown keys {sorted(unknown)}: use name, priceWei, prices")
                name = ts.get("name", f"tier {t}")
                if not isinstance(name, str):
                    raise DesignError(f"presale.tiers[{t}].name must be text")
                each = ts.get("prices", {})
                if not isinstance(each, dict) or any(not (isinstance(k, str) and k.isascii() and k.isdecimal()
                                                          and str(int(k)) == k and int(k) < len(works)) for k in each):
                    raise DesignError(f"presale.tiers[{t}].prices must map work indexes (\"0\", \"1\", …) to prices")
                default = None if "priceWei" not in ts else _uint(ts["priceWei"], f"presale.tiers[{t}].priceWei")
                prices = []
                for w in works:
                    if w["reserved"]:
                        if str(w["index"]) in each:
                            raise DesignError(f"presale.tiers[{t}]: work {w['index']} is reserved and is not sold")
                        prices.append(None)
                        continue
                    if str(w["index"]) in each:
                        pp = _uint(each[str(w["index"])], f"presale.tiers[{t}] price of work {w['index']}")
                    elif default is not None:
                        # a tier-wide price never raises a work above its public price: cheaper works keep theirs
                        pp = min(default, int(w["priceWei"]))
                    else:
                        pp = int(w["priceWei"])
                    if pp > int(w["priceWei"]):
                        raise DesignError(f"presale.tiers[{t}]: work {w['index']} costs {pp} in the presale, more than its "
                                          f"public price {w['priceWei']}")
                    prices.append(str(pp))
                presale_tiers.append({"name": name, "prices": prices})
        n_tiers = len(presale_tiers) if presale_tiers else 1
        seen = set()
        for e in pre["allowlist"]:
            if not isinstance(e, dict) or "address" not in e:
                raise DesignError("each allowlist entry must be {\"address\": \"0x..\", \"quota\": N}")
            a = _addr(e["address"])
            q = e.get("quota")
            if not isinstance(q, int) or isinstance(q, bool) or not 1 <= q < 2**32:
                raise DesignError(f"allowlist {a}: quota must be a whole number of at least 1")
            tier = e.get("tier", 0)
            if not isinstance(tier, int) or isinstance(tier, bool) or not 0 <= tier < n_tiers:
                raise DesignError(f"allowlist {a}: tier must be 0" + (f" to {n_tiers - 1}" if n_tiers > 1 else "")
                                  + (" (presale.tiers sets the tiers)" if presale_tiers is None and tier else ""))
            if a in seen:
                raise DesignError(f"allowlist {a} appears twice")
            seen.add(a)
            allowlist.append({"address": a, "quota": q, "tier": tier,
                              "leaf": hx(allow_leaf_of(chain_id, registry, curator, a, q, tier))})
        if not allowlist:
            raise DesignError("presale is set but the allowlist is empty")
        r, ps = merkle([unhex(e["leaf"]) for e in allowlist])
        for e, p in zip(allowlist, ps):
            e["proof"] = [hx(x) for x in p]
        allow_root = hx(r)
        if presale_tiers is not None:
            pl = presale_price_leaves(chain_id, registry, curator, root, presale_tiers, works)
            if not pl:
                raise DesignError("presale.tiers is set but every work is reserved: nothing is sold in the presale")
            presale_price_root = hx(merkle_root([x[3] for x in pl]))
    for k in ("name", "symbol", "story"):
        if not isinstance(spec.get(k, ""), str):
            raise DesignError(f"{k} must be text")
    t_hash = titles_hash([w["title"] for w in works])
    metadata_uri = spec.get("metadataURI", "")
    if not isinstance(metadata_uri, str) or not is_content_addressed(metadata_uri):
        raise DesignError("metadataURI must be \"\" (none), ipfs://<CID> or ar://<transaction id>, with no path "
                          "or trailing slash: the directory that holds <index>.json for every work")
    if metadata_uri == "" and any("meta" in w for w in works):
        warnings.append("works have images or descriptions but metadataURI is empty: run `curate.py metadata`, "
                        "upload the folder, set metadataURI and build again, or no wallet or market will see them")
    if int(payment_token, 16) != 0 and token_info["decimals"] is not None:
        dec, sym = token_info["decimals"], token_info["symbol"]
        priced = [(w["index"], int(w["priceWei"])) for w in works if not w["reserved"]]
        warnings.append("prices in " + sym + ": " + ", ".join(
            f"#{i} {_units(p, dec)}" for i, p in priced[:20]) + (" …" if len(priced) > 20 else ""))
        if any(p >= 10 ** (dec + 6) for _, p in priced):
            warnings.append(f"some prices are a million {sym} or more: priceWei is in the token's smallest unit "
                            f"({dec} decimals), check the spec")
    launch = {
        "name": spec["name"], "symbol": spec["symbol"], "story": spec.get("story", ""),
        "nandSupply": str(nand_supply), "latchSupply": str(latch_supply),
        "mintPrice": str(mint_price), "mintBatch": str(mint_batch),
        "root": hx(root), "count": len(works),
        "curator": curator, "platform": platform,
        "platformBps": platform_bps, "saleStart": sale_start, "saleEnd": sale_end,
        "maxLaunchFees": str(max_fees),
        "treasury": treasury, "reservedCount": reserved_count,
        "limitPerWallet": limit_per_wallet, "maxPerWallet": max_per_wallet,
        "allowRoot": allow_root, "presaleStart": presale_start, "presalePriceRoot": presale_price_root,
        "royaltyReceiver": royalty_receiver, "royaltyBps": royalty_bps,
        "titlesHash": hx(t_hash), "metadataURI": metadata_uri,
        "paymentToken": payment_token, "paymentSymbol": token_info["symbol"], "paymentDecimals": token_info["decimals"],
        "metadataHash": hx(metadata_of(spec["name"], spec["symbol"], spec.get("story", ""), t_hash)),
        "launchValueWei": str(max_fees + mint_price * mint_batch),
    }
    manifest = {
        "format": "curated-collection-manifest/7",
        "chainId": chain_id, "registry": registry,
        "launch": launch,
        "totals": {"works": len(works), "publicWorks": len(works) - reserved_count, "reservedWorks": reserved_count,
                   "nandNeeded": nand, "latchNeeded": latch,
                   "netlistBytes": sum(w["bytes"] for w in works)},
        "warnings": warnings,
        "works": works,
        "allowlist": allowlist,
        "presaleTiers": presale_tiers,
    }
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1, ensure_ascii=False)
    return manifest


def checkroot(manifest_path: str, url: str | None = None, registry: str | None = None,
              circuits: str | None = None) -> dict:
    """Rebuild every work leaf and allowlist leaf from the published manifest and check that they, and only they,
    make the roots. With --rpc and --circuits, also compare every launch setting with the chain."""
    if (url is None) != (circuits is None):
        raise DesignError("give both --rpc and --circuits to compare with the chain, or neither")
    m = json.load(open(manifest_path, encoding="utf-8"))
    L = m["launch"]
    works = m["works"]
    problems = []
    for w in works:
        # the same strict types the sale page requires
        ok = (isinstance(w.get("index"), int) and not isinstance(w.get("index"), bool)
              and isinstance(w.get("title"), str) and isinstance(w.get("netlist"), str)
              and all(isinstance(w.get(k), int) and not isinstance(w.get(k), bool) for k in ("nIn", "nOut"))
              and isinstance(w.get("reserved"), bool)
              and isinstance(w.get("priceWei"), str) and w["priceWei"].isdigit() and w["priceWei"].isascii())
        if not ok:
            raise DesignError(f"work {w.get('index')}: a field is missing or has the wrong type")
    for k in ("name", "symbol", "story"):
        if not isinstance(L.get(k), str):
            raise DesignError(f"launch.{k} must be text")
    if [w["index"] for w in works] != list(range(len(works))) or len(works) != int(L["count"]):
        raise DesignError("indexes are not exactly 0..count-1")
    leaves = []
    for w in works:
        nl = unhex(w["netlist"])
        if hx(keccak256(nl)) != w["netlistHash"]:
            raise DesignError(f"work {w['index']}: netlistHash does not match netlist")
        reserved = w.get("reserved", False)
        if not isinstance(reserved, bool):
            raise DesignError(f"work {w['index']}: reserved must be true or false")
        if reserved and int(w["priceWei"]) != 0:
            raise DesignError(f"work {w['index']}: a reserved work must have price 0")
        leaves.append(leaf_of(int(m["chainId"]), m["registry"], L["curator"], w["index"], keccak256(nl),
                              int(w["nIn"]), int(w["nOut"]), int(w["priceWei"]), reserved))
    root, _ = merkle(leaves)
    if hx(root) != L["root"].lower():
        problems.append("the published works do not rebuild the manifest root")
    for w, leaf in zip(works, leaves):
        if not verify_proof(leaf, [unhex(x) for x in w.get("proof", [])], root):
            problems.append(f"work {w['index']}: its published proof does not verify (buyers could not buy it)")
    reserved_idx = [w["index"] for w in works if w.get("reserved")]
    if len(reserved_idx) != int(L.get("reservedCount", 0)):
        problems.append("the number of reserved works differs from reservedCount")

    # names, story and titles: the registry records a commitment to them at launch
    t_hash = titles_hash([str(w.get("title", "")) for w in works])
    meta = metadata_of(L["name"], L["symbol"], L.get("story", ""), t_hash)
    if hx(t_hash) != L.get("titlesHash", "").lower() or hx(meta) != L.get("metadataHash", "").lower():
        problems.append("the published name, symbol, story or titles do not rebuild the manifest's metadataHash")

    if not isinstance(L.get("metadataURI", ""), str) or not is_content_addressed(L.get("metadataURI", "")):
        problems.append("launch.metadataURI is not a content-addressed directory (ipfs://<CID> or ar://<id>)")

    al = m.get("allowlist") or []
    addrs = [e["address"].lower() for e in al]
    if len(set(addrs)) != len(addrs):
        problems.append("an address appears twice in the allowlist")
    if al:
        for e in al:
            if not (isinstance(e.get("address"), str) and isinstance(e.get("quota"), int)
                    and not isinstance(e.get("quota"), bool) and e["quota"] >= 1
                    and isinstance(e.get("tier", 0), int) and not isinstance(e.get("tier", 0), bool) and e.get("tier", 0) >= 0):
                raise DesignError(f"allowlist entry {e.get('address')}: a field is missing or has the wrong type")
        aleaves = [allow_leaf_of(int(m["chainId"]), m["registry"], L["curator"], e["address"], int(e["quota"]),
                                 int(e.get("tier", 0))) for e in al]
        aroot = merkle(aleaves)[0]
        if hx(aroot) != L["allowRoot"].lower():
            problems.append("the published allowlist does not rebuild allowRoot")
        for e, leaf in zip(al, aleaves):
            if not verify_proof(leaf, [unhex(x) for x in e.get("proof", [])], aroot):
                problems.append(f"allowlist {e['address']}: its published proof does not verify")
    elif int(L.get("allowRoot", "0x0"), 16) != 0:
        problems.append("allowRoot is set but no allowlist is published")

    # presale prices: rebuild the price list root, and check every price against the work's public price
    tiers = m.get("presaleTiers")
    want_proot = L.get("presalePriceRoot", "0x" + "00" * 32).lower()
    if tiers:
        ok_shape = isinstance(tiers, list) and all(isinstance(t, dict) and isinstance(t.get("prices"), list)
                                                   and len(t["prices"]) == len(works) for t in tiers)
        if not ok_shape:
            problems.append("presaleTiers must list one price (or null for a reserved work) per work for every tier")
        else:
            for t, tier in enumerate(tiers):
                for w, pp in zip(works, tier["prices"]):
                    if (pp is None) != bool(w["reserved"]):
                        problems.append(f"presale tier {t}: work {w['index']} must have a price exactly when it is not reserved")
                    elif pp is not None and not _is_amount(pp):
                        problems.append(f"presale tier {t}: work {w['index']} has a presale price that is not a whole number")
                    elif pp is not None and int(pp) > int(w["priceWei"]):
                        problems.append(f"presale tier {t}: work {w['index']} has a presale price above its public price")
            if not any("presale tier" in x for x in problems):
                pl = presale_price_leaves(int(m["chainId"]), m["registry"], L["curator"], root, tiers, works)
                if not pl or hx(merkle_root([x[3] for x in pl])) != want_proot:
                    problems.append("the published presale prices do not rebuild presalePriceRoot")
            bad = [e["address"] for e in al if int(e.get("tier", 0)) >= len(tiers)]
            if bad:
                problems.append(f"allowlist entries with a tier that has no prices: {', '.join(bad[:5])}")
    elif int(want_proot, 16) != 0:
        problems.append("presalePriceRoot is set but no presale prices are published")
    elif any(int(e.get("tier", 0)) != 0 for e in al):
        problems.append("allowlist entries have tiers but no presale prices are published")
    if int(want_proot, 16) != 0 and int(L.get("allowRoot", "0x0"), 16) == 0:
        problems.append("presalePriceRoot is set without an allowlist: the launch would revert")

    out = {"rebuiltRoot": hx(root), "manifestRoot": L["root"], "count": len(works),
           "reservedIndexes": reserved_idx, "allowlistEntries": len(al)}
    if url and circuits:
        reg = registry or m["registry"]
        if int(reg, 16) != int(m["registry"], 16):
            problems.append("the manifest was built for another registry than the one checked")
        chain_id = int(rpc_raw(url, "eth_chainId", []), 16)
        if chain_id != int(m["chainId"]):
            problems.append(f"the manifest was built for chain {m['chainId']}, but the RPC is chain {chain_id}")
        elif chain_id in CHAINS:
            try:
                fac = rpc_call(url, reg, "0x" + sel("FACTORY()"))
            except RuntimeError:
                fac = "0x"
            if len(fac) < 66:
                problems.append(f"registry {reg} has no FACTORY(): it is not a CuratedRegistry")
            elif int(fac, 16) != int(CHAINS[chain_id]["factory"], 16):
                problems.append(f"registry {reg} is bound to factory 0x{fac[-40:]}, not TapeOut's factory on "
                                f"{CHAINS[chain_id]['name']}")
        cpad = circuits.lower()[2:].rjust(64, "0")
        r = rpc_call(url, reg, "0x" + sel("collectionOf(address)") + cpad)
        word = lambda k: r[2 + 64 * k: 2 + 64 * (k + 1)]  # noqa: E731
        # Collection = (vault, curator, transistors, treasury, root, count, reserved, certified, metadata)
        vault = "0x" + word(0)[24:]
        if int(vault, 16) == 0:
            raise DesignError(f"{circuits} is not a curated collection of registry {reg}")

        def vget(sig):
            return int(rpc_call(url, vault, "0x" + sel(sig)), 16)

        def same_addr(a, b):
            return int(a, 16) == int(b, 16)

        chain = {
            "root": "0x" + word(4), "metadata": "0x" + word(8), "count": int(word(5), 16), "reserved": int(word(6), 16),
            "curator": "0x" + word(1)[24:], "treasury": "0x" + word(3)[24:],
            "registryOfVault": hex(vget("REGISTRY()")),
            "saleStart": vget("SALE_START()"), "saleEnd": vget("SALE_END()"),
            "presaleStart": vget("PRESALE_START()"), "allowRoot": "0x" + hex(vget("ALLOW_ROOT()"))[2:].rjust(64, "0"),
            "limitPerWallet": bool(vget("LIMIT_PER_WALLET()")), "maxPerWallet": vget("MAX_PER_WALLET()"),
            "platform": hex(vget("PLATFORM()")), "platformBps": vget("PLATFORM_BPS()"),
        }
        try:
            chain["presalePriceRoot"] = "0x" + hex(vget("PRESALE_PRICE_ROOT()"))[2:].rjust(64, "0")
            chain["paymentToken"] = hex(vget("PAYMENT_TOKEN()"))
        except RuntimeError as exc:
            if "revert" not in str(exc).lower():
                raise   # a node error, not an answer
            raise DesignError(f"vault {vault} is from an earlier protocol version; this tool checks the current one only") from exc
        mu = rpc_call(url, reg, "0x" + sel("metadataURIOf(address)") + cpad)
        if len(mu) < 130:
            raise DesignError(f"registry {reg} has no metadataURIOf: it is not a registry of this protocol version")
        n = int(mu[66:130], 16)
        chain["metadataURI"] = bytes.fromhex(mu[130:130 + 2 * n]).decode()
        rr = rpc_call(url, reg, "0x" + sel("royaltyOf(address)") + cpad)
        chain["royaltyReceiver"], chain["royaltyBps"] = "0x" + rr[26:66], int(rr[66:130], 16)
        checks = [
            ("root", chain["root"] == hx(root)), ("metadata (name, symbol, story, titles)", chain["metadata"] == hx(meta)),
            ("count", chain["count"] == len(works)),
            ("metadata directory", chain["metadataURI"] == L.get("metadataURI", "")),
            ("reserved count", chain["reserved"] == len(reserved_idx)),
            ("vault belongs to this registry", same_addr(chain["registryOfVault"], reg)),
            ("curator", same_addr(chain["curator"], L["curator"])),
            ("treasury", same_addr(chain["treasury"], L.get("treasury", "0x0"))),
            ("sale start", chain["saleStart"] == int(L["saleStart"])),
            ("presale start", chain["presaleStart"] == int(L.get("presaleStart", 0))),
            ("allowlist root", chain["allowRoot"] == L.get("allowRoot", "0x" + "00" * 32).lower()),
            ("presale price root", chain["presalePriceRoot"] == want_proot),
            ("per-wallet limit", chain["limitPerWallet"] == bool(L.get("limitPerWallet", False))
             and chain["maxPerWallet"] == int(L.get("maxPerWallet", 0))),
            ("platform share", same_addr(chain["platform"], L.get("platform", "0x0"))
             and chain["platformBps"] == int(L.get("platformBps", 0))),
            ("payment token", same_addr(chain["paymentToken"], L.get("paymentToken", "0x0"))),
        ]
        for name, ok in checks:
            if not ok:
                problems.append(f"on chain, {name} differs from the manifest")
        # the curator may move the sale end later (never earlier) and may pause buying
        chain["paused"] = bool(vget("paused()"))
        if chain["saleEnd"] < int(L["saleEnd"]):
            problems.append("on chain, the sale ends earlier than the manifest says")
        out["saleEndExtendedSinceLaunch"] = chain["saleEnd"] != int(L["saleEnd"])
        # the curator may lower the royalty or change its receiver after launch; it can never rise
        if chain["royaltyBps"] > int(L.get("royaltyBps", 0)):
            problems.append("on chain, the royalty is higher than the manifest declares")
        out["chain"] = chain
        out["royaltyChangedSinceLaunch"] = (chain["royaltyBps"] != int(L.get("royaltyBps", 0))
                                            or not same_addr(chain["royaltyReceiver"],
                                                             L.get("royaltyReceiver", "0x0")))
    out["problems"] = problems
    out["ok"] = not problems
    return out


# ============================================================================ chain reads
def rpc_raw(url: str, method: str, params: list):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    # some public nodes refuse requests without a User-Agent
    req = urllib.request.Request(url, body, {"content-type": "application/json", "user-agent": "curate.py"})
    r = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


def _token_symbol(ret: str) -> str:
    """Decode symbol(): an ABI string, or bytes32 (older tokens); "?" if neither."""
    try:
        if len(ret) >= 130 and int(ret[2:66], 16) == 32:
            n = int(ret[66:130], 16)
            if 0 < n <= 64 and len(ret) >= 130 + 2 * n:
                return bytes.fromhex(ret[130:130 + 2 * n]).decode("utf-8", "replace")
        if len(ret) == 66:
            return bytes.fromhex(ret[2:]).rstrip(b"\0").decode("utf-8", "replace") or "?"
    except ValueError:
        pass
    return "?"


def rpc_call(url: str, to: str, data: str) -> str:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                       "params": [{"to": to, "data": data}, "latest"]}).encode()
    # some public nodes refuse requests without a User-Agent
    req = urllib.request.Request(url, body, {"content-type": "application/json", "user-agent": "curate.py"})
    r = json.load(urllib.request.urlopen(req, timeout=30))
    if "error" in r:
        raise RuntimeError(r["error"])
    return r["result"]


def sel(sig: str) -> str:
    return keccak256(sig.encode())[:4].hex()


def verify(manifest_path: str | None, url: str, registry: str, circuits: str, token_id: int) -> dict:
    a = circuits.lower().replace("0x", "").rjust(64, "0")
    i = hex(token_id)[2:].rjust(64, "0")
    r = rpc_call(url, registry, "0x" + sel("editionOf(address,uint256)") + a + i)
    official = int(r[2:66], 16) == 1
    index = int(r[66:130], 16)
    out = {"circuits": circuits, "tokenId": token_id, "official": official}
    if official:
        out["index"] = index
        rr = rpc_call(url, registry, "0x" + sel("isReserved(address,uint256)") + a + i)
        out["reservedForTreasury"] = int(rr, 16) == 1
        if manifest_path:
            m = json.load(open(manifest_path, encoding="utf-8"))
            # only use the manifest's title if it is this collection's manifest
            col = rpc_call(url, registry, "0x" + sel("collectionOf(address)") + a)
            if int(m["registry"], 16) != int(registry, 16) or "0x" + col[2 + 64 * 4: 2 + 64 * 5] != m["launch"]["root"].lower():
                raise DesignError("this manifest does not belong to this registry and processor")
            w = m["works"][index]
            out["title"] = w["title"]
            raw = rpc_call(url, circuits, "0x" + sel("netlist(uint256)") + i)
            b = unhex(raw)
            off = int.from_bytes(b[:32], "big")
            ln = int.from_bytes(b[off:off + 32], "big")
            nl = b[off + 32: off + 32 + ln]
            out["netlistMatchesManifest"] = hx(keccak256(nl)) == w["netlistHash"]
    return out


# ============================================================================ selftest
def _toggle_canvas():
    # q' = q XOR en, output = q  (a LATCH read by an output, plus XOR from 4 NANDs)
    N = lambda i, t, d=None: {"id": i, "type": t, "position": {"x": 0, "y": 0}, "data": d or {}}  # noqa: E731
    E = lambda s, t, h: {"id": f"{s}-{t}-{h}", "source": s, "sourceHandle": "out", "target": t, "targetHandle": h}  # noqa: E731
    nodes = [N("en", "input", {"index": 0}), N("q", "latch"), N("x0", "nand"), N("x1", "nand"), N("x2", "nand"),
             N("x3", "nand"), N("o", "output", {"index": 0})]
    edges = [E("q", "x0", "a"), E("en", "x0", "b"), E("q", "x1", "a"), E("x0", "x1", "b"), E("en", "x2", "a"),
             E("x0", "x2", "b"), E("x1", "x3", "a"), E("x2", "x3", "b"), E("x3", "q", "d"), E("q", "o", "in")]
    return {"format": "tapeout-canvas", "v": 1, "nodes": nodes, "edges": edges}


def selftest() -> None:
    # keccak
    assert keccak256(b"").hex() == "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"
    assert sel("isOfficial(address,uint256)") and sel("transfer(address,uint256)") == "a9059cbb"
    # TAP-02 vectors through decode / encode / load
    v = json.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tap02_vectors.json")))
    ok = 0
    for case in v["valid"]:
        refs = {}
        for r in case["refs"]:
            sub = ref.load(unhex(r["netlist"]), r["nIn"], r["nOut"])
            refs[(_addr20(r["cpu"]), int(r["id"]))] = (r["nIn"], r["nOut"], sub.n_state)
        enc = finish(unhex(case["netlist"]), case["nIn"], case["nOut"], refs)
        assert enc["nState"] == case["nState"], case["name"]
        assert ref.encode(ref.decode(unhex(case["netlist"]), case["nIn"])) == unhex(case["netlist"])
        ok += 1
    bad = 0
    for case in v["illFormed"]:
        refs = {}
        for r in case.get("refs", []):
            refs[(_addr20(r["cpu"]), int(r["id"]))] = (r["nIn"], r["nOut"], 0)
        try:
            finish(unhex(case["netlist"]), case["nIn"], case["nOut"], refs)
        except (ref.IllFormed, DesignError):
            bad += 1
        else:
            raise AssertionError("accepted ill-formed vector " + case["name"])
    # encoder: canvas toggle vs its own graph simulation, many random beats
    doc = _toggle_canvas()
    enc = encode_canvas(doc)
    cross_check(doc, enc, 200)
    # random canvases: combinational + latches, random wiring, cross-checked
    rnd = random.Random(7)
    for trial in range(200):
        n_in, n_nand, n_latch, n_out = rnd.randint(0, 4), rnd.randint(1, 30), rnd.randint(0, 8), rnd.randint(1, 5)
        nodes, edges = [], []
        P = {"x": 0, "y": 0}
        for i in range(n_in):
            nodes.append({"id": f"i{i}", "type": "input", "position": P, "data": {"index": i}})
        nodes += [{"id": "c0", "type": "const0", "position": P, "data": {}},
                  {"id": "c1", "type": "const1", "position": P, "data": {}}]
        latches = [f"l{i}" for i in range(n_latch)]
        for l in latches:
            nodes.append({"id": l, "type": "latch", "position": P, "data": {}})
        avail = [f"i{i}" for i in range(n_in)] + ["c0", "c1"] + latches
        gates = []
        for g in range(n_nand):
            gid = f"n{g}"
            a, b = rnd.choice(avail), rnd.choice(avail)
            nodes.append({"id": gid, "type": "nand", "position": P, "data": {}})
            edges += [{"id": f"{gid}a", "source": a, "sourceHandle": "out", "target": gid, "targetHandle": "a"},
                      {"id": f"{gid}b", "source": b, "sourceHandle": "out", "target": gid, "targetHandle": "b"}]
            avail.append(gid)
            gates.append(gid)
        for l in latches:
            edges.append({"id": f"{l}d", "source": rnd.choice(avail), "sourceHandle": "out", "target": l,
                          "targetHandle": "d"})
        for o in range(n_out):
            nodes.append({"id": f"o{o}", "type": "output", "position": P, "data": {"index": o}})
            edges.append({"id": f"o{o}e", "source": rnd.choice(avail), "sourceHandle": "out", "target": f"o{o}",
                          "targetHandle": "in"})
        rnd.shuffle(nodes)   # file order must not matter for correctness
        d = {"format": "tapeout-canvas", "v": 1, "nodes": nodes, "edges": edges}
        e = encode_canvas(d)
        cross_check(d, e, 40, seed=trial)
    # Merkle
    leaves = [keccak256(bytes([i])) for i in range(13)]
    root, proofs = merkle(leaves)
    assert all(verify_proof(lf, p, root) for lf, p in zip(leaves, proofs))
    assert not verify_proof(keccak256(b"x"), proofs[0], root)
    print(f"selftest ok: {ok} valid + {bad} ill-formed TAP-02 vectors, 201 encoder cross-checks, Merkle ok")


# ============================================================================ CLI
def main(argv=None):
    ap = argparse.ArgumentParser(prog="curate", description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    p = sp.add_parser("encode"); p.add_argument("design")
    p = sp.add_parser("build"); p.add_argument("spec"); p.add_argument("out"); p.add_argument("--rpc")
    p = sp.add_parser("allowproof"); p.add_argument("manifest"); p.add_argument("address")
    p.add_argument("--index", type=int)
    p.add_argument("--all", action="store_true", help="presale price and proof for every work the wallet can buy")
    p = sp.add_parser("checkroot"); p.add_argument("manifest"); p.add_argument("--rpc")
    p.add_argument("--registry"); p.add_argument("--circuits")
    p = sp.add_parser("proof"); p.add_argument("manifest"); p.add_argument("index", type=int)
    p = sp.add_parser("metadata"); p.add_argument("manifest"); p.add_argument("outdir")
    p = sp.add_parser("verify")
    p.add_argument("manifest", nargs="?")
    p.add_argument("--rpc", required=True); p.add_argument("--registry", required=True)
    p.add_argument("--circuits", required=True); p.add_argument("--id", type=int, required=True)
    sp.add_parser("selftest")
    a = ap.parse_args(argv)
    if a.cmd == "encode":
        print(json.dumps(encode_design(json.load(open(a.design, encoding="utf-8"))), indent=1))
    elif a.cmd == "build":
        m = build(a.spec, a.out, a.rpc)
        print(json.dumps({"root": m["launch"]["root"], **m["totals"],
                          "nandSupply": m["launch"]["nandSupply"], "latchSupply": m["launch"]["latchSupply"],
                          "launchValueWei": m["launch"]["launchValueWei"], "warnings": m["warnings"]},
                         indent=1, ensure_ascii=False))
    elif a.cmd == "allowproof":
        m = json.load(open(a.manifest, encoding="utf-8"))
        want = _addr(a.address)
        hit = [e for e in m.get("allowlist", []) if e["address"] == want]
        out = dict(hit[0]) if hit else {"address": want, "allowlisted": False}
        if hit and (a.index is not None or a.all):
            want = [w["index"] for w in m["works"] if not w["reserved"]] if a.all else [a.index]
            pp = presale_price_proofs(m, int(hit[0].get("tier", 0)), want)
            out["presale"] = pp if a.all else pp[0]
        print(json.dumps(out, indent=1))
    elif a.cmd == "checkroot":
        print(json.dumps(checkroot(a.manifest, a.rpc, a.registry, a.circuits), indent=1))
    elif a.cmd == "proof":
        m = json.load(open(a.manifest, encoding="utf-8"))
        w = m["works"][a.index]
        print(json.dumps({k: w[k] for k in ("index", "netlist", "nIn", "nOut", "priceWei", "proof")}, indent=1))
    elif a.cmd == "metadata":
        names = write_metadata(a.manifest, a.outdir)
        print(json.dumps({"files": len(names), "dir": a.outdir,
                          "next": "upload the folder as one directory, set metadataURI to ipfs://<CID> or "
                                  "ar://<manifest id>, and build again"}, indent=1))
    elif a.cmd == "verify":
        print(json.dumps(verify(None if a.manifest in (None, "-") else a.manifest, a.rpc, a.registry,
                                a.circuits, a.id), indent=1))
    elif a.cmd == "selftest":
        selftest()


if __name__ == "__main__":
    main()
