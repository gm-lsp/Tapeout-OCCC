#!/usr/bin/env python3
"""Generate a throw-away example collection of small test circuits (no real artwork).

Writes canvas files and collection.json next to this script. Used by the fork tests.
Usage: make_examples.py [chainId]   (56 BNB Smart Chain, the default; 196 X Layer; 8453 Base)
On another chain than 56 the REF work wraps a circuit of that chain and the files get a ".<chainId>" suffix.
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
P = {"x": 0, "y": 0}


class Canvas:
    def __init__(self, name):
        self.name, self.nodes, self.edges, self.n_in, self.n_out, self.k = name, [], [], 0, 0, 0

    def _id(self, p):
        self.k += 1
        return f"{p}{self.k}"

    def node(self, t, data=None):
        i = self._id(t[0])
        self.nodes.append({"id": i, "type": t, "position": dict(P), "data": data or {}})
        return i

    def wire(self, s, t, h, sh="out"):
        self.edges.append({"id": self._id("e"), "source": s, "sourceHandle": sh, "target": t, "targetHandle": h})

    def inp(self):
        i = self.node("input", {"index": self.n_in, "value": 0, "label": ""}); self.n_in += 1; return i

    def out(self, src, sh="out"):
        o = self.node("output", {"index": self.n_out, "label": ""}); self.n_out += 1; self.wire(src, o, "in", sh)

    def nand(self, a, b):
        g = self.node("nand"); self.wire(a, g, "a"); self.wire(b, g, "b"); return g

    def latch(self):
        return self.node("latch")

    def xor(self, a, b):
        g0 = self.nand(a, b)
        return self.nand(self.nand(a, g0), self.nand(b, g0))

    def doc(self):
        return {"format": "tapeout-canvas", "v": 1, "name": self.name, "nodes": self.nodes, "edges": self.edges}


def toggle():
    c = Canvas("Toggle")
    en, q = c.inp(), c.latch()
    c.wire(c.xor(q, en), q, "d")
    c.out(q)
    return c.doc()


def counter(bits=4):
    c = Canvas(f"{bits}-bit counter")
    one = c.node("const1")
    qs = [c.latch() for _ in range(bits)]
    carry = one
    for q in qs:
        c.wire(c.xor(q, carry), q, "d")
        nc = c.nand(q, carry)
        carry = c.nand(nc, nc)        # AND
    for q in qs:
        c.out(q)
    return c.doc()


def lfsr7():
    # x^7 + x^6 + 1, seeded by forcing bit 0 high while the register is all zero
    c = Canvas("7-bit LFSR")
    qs = [c.latch() for _ in range(7)]
    fb = c.xor(qs[6], qs[5])
    # zero detector: if every bit is 0, inject a 1
    nor_chain = None
    for q in qs:
        inv = c.nand(q, q)
        if nor_chain is None:
            nor_chain = inv
        else:
            t = c.nand(nor_chain, inv)
            nor_chain = c.nand(t, t)
    inv_fb, inv_z = c.nand(fb, fb), c.nand(nor_chain, nor_chain)
    c.wire(c.nand(inv_fb, inv_z), qs[0], "d")      # fb OR zero
    for i in range(1, 7):
        c.wire(qs[i - 1], qs[i], "d")
    for q in qs:
        c.out(q)
    return c.doc()


def xor2():
    c = Canvas("XOR")
    a, b = c.inp(), c.inp()
    c.out(c.xor(a, b))
    return c.doc()


def ref_genesis13():
    """Wraps circuit 13 of the genesis processor (0 in, 6 out, 5 LATCH) and adds a parity output."""
    c = Canvas("Genesis #13 with parity")
    r = c.node("ref", {"cpu": "0x50A994E71615474b55559fF4F500928fbc339DD9", "id": 13, "nIn": 0, "nOut": 6,
                       "nState": 5})
    for j in range(6):
        c.out(r, f"out{j}")
    acc_node, acc_h = r, "out0"
    for j in range(1, 6):
        g0 = c.node("nand"); c.wire(acc_node, g0, "a", acc_h); c.wire(r, g0, "b", f"out{j}")
        g1 = c.node("nand"); c.wire(acc_node, g1, "a", acc_h); c.wire(g0, g1, "b")
        g2 = c.node("nand"); c.wire(r, g2, "a", f"out{j}"); c.wire(g0, g2, "b")
        acc_node, acc_h = c.nand(g1, g2), "out"
    c.out(acc_node, acc_h)
    return c.doc()


# a circuit that already exists on each chain, for the REF work: (circuits contract, id, nIn, nOut, nState)
REF_TARGET = {
    196: ("0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b", 1, 0, 1, 2),    # X Layer, processor 1, circuit #1
    8453: ("0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b", 1, 2, 1, 0),   # Base, processor 1, circuit #1
}


def ref_wrapper(chain):
    """Wraps an existing circuit of the chain and adds the inverse of its first output."""
    cpu, cid, n_in, n_out, n_state = REF_TARGET[chain]
    c = Canvas(f"Circuit #{cid} with inverse")
    ins = [c.inp() for _ in range(n_in)]
    r = c.node("ref", {"cpu": cpu, "id": cid, "nIn": n_in, "nOut": n_out, "nState": n_state})
    for j, i in enumerate(ins):
        c.wire(i, r, f"in{j}")
    for j in range(n_out):
        c.out(r, f"out{j}")
    g = c.node("nand"); c.wire(r, g, "a", "out0"); c.wire(r, g, "b", "out0")
    c.out(g)
    return c.doc()


def and2():
    """AND of two inputs: NAND followed by NAND-as-NOT."""
    c = Canvas("AND")
    a, b = c.inp(), c.inp()
    g = c.nand(a, b)
    c.out(c.nand(g, g))
    return c.doc()


def main(chain=56):
    sfx = "" if chain == 56 else f".{chain}"
    ref_work = (("genesis13_parity.json", ref_genesis13(), "Genesis #13 with parity", "5000000000000000") if chain == 56
                else (f"ref_wrapper{sfx}.json", ref_wrapper(chain), "Circuit #1 with inverse", "5000000000000000"))
    works = [
        ("toggle.json", toggle(), "Toggle", "10000000000000000"),
        ("counter4.json", counter(4), "4-bit counter", "20000000000000000"),
        ("lfsr7.json", lfsr7(), "7-bit LFSR", "30000000000000000"),
        ("xor.json", xor2(), "XOR", "0"),
        ref_work,
    ]
    spec_works = []
    for fn, doc, title, price in works:
        json.dump(doc, open(os.path.join(HERE, fn), "w"), indent=1)
        spec_works.append({"file": fn, "title": title, "priceWei": price})
    # optional per-work metadata: image / animation links must be content-addressed (ipfs:// or ar://)
    spec_works[0].update({"description": "One LATCH that flips every cycle.",
                          "image": "ar://" + "T0gg1eImage-Test_Only_Not_Uploaded_000000000"[:43],
                          "attributes": [{"trait_type": "Gates", "value": 2}, {"trait_type": "Kind", "value": "clock"}]})
    spec_works[1].update({"image": "ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi/counter4.png"})
    # popcount of 8 inputs: on-chain bytes of circuit #3151 (TAP-02 test vector), given as a raw netlist
    v = json.load(open(os.path.join(HERE, "..", "tap02_vectors.json")))
    pc = next(x for x in v["valid"] if x["name"] == "popcount8_3151")
    # reserved for the treasury: can never be bought, only claimed by the curator to the treasury
    spec_works.append({"netlist": pc["netlist"], "nIn": pc["nIn"], "nOut": pc["nOut"],
                       "title": "Popcount 8 (raw netlist, reserved)", "reserved": True})
    # a second reserved work (so a batch claim can be tested), with a non-ASCII title to pin the UTF-8 hashing
    json.dump(and2(), open(os.path.join(HERE, "and2.json"), "w"), indent=1)
    spec_works.append({"file": "and2.json", "title": "与门 AND（国库预留）", "reserved": True})
    spec = {
        "name": "P05 Test Collection",
        "symbol": "P5TEST",
        "story": "Throw-away test circuits for the Curated Collections fork tests.",
        "chainId": chain,
        "registry": "0x00000000000000000000000000000000C0DEC0DE",   # fixed address used by the fork tests
        "curator": "0x00000000000000000000000000000000000C0FFE",
        "platform": "0x0000000000000000000000000000000000001234",
        "platformBps": 500,
        "treasury": "0x0000000000000000000000000000000000007EA5",
        "mintPriceWei": "10000000000000",
        "mintBatch": 2500,
        "saleStart": 2,          # public sale opens after the presale (tests warp time as needed)
        "saleEnd": 4102444800,   # 2100-01-01
        "limitPerWallet": False,  # no per-wallet limit (true + "maxPerWallet": N to limit)
        # optional royalty declaration for resales; markets decide whether to pay it
        "royalty": {"receiver": "0x00000000000000000000000000000000000C0FFE", "bps": 300},
        # optional presale: allowlisted wallets buy first, each up to its quota
        # with per-tier presale prices (absolute amounts, at most the public price; omitted works keep the public price)
        "presale": {"start": 1, "allowlist": [
            {"address": "0x00000000000000000000000000000000000A11CE", "quota": 2, "tier": 0},
            {"address": "0x0000000000000000000000000000000000000B0B", "quota": 1, "tier": 1},
        ], "tiers": [
            {"name": "OG", "prices": {"0": "5000000000000000", "1": "15000000000000000"}},
            {"name": "Friends", "priceWei": "0"},
        ]},
        # the directory of <index>.json metadata files, fixed at launch (test value: nothing is uploaded there)
        "metadataURI": "ar://" + "P05TestMetadataDirectory_NotUploaded_0000000"[:43],
        "spareNand": 5,
        "spareLatch": 3,
        "works": spec_works,
    }
    json.dump(spec, open(os.path.join(HERE, f"collection{sfx}.json"), "w"), indent=1)
    print("wrote", len(spec_works), "works")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 56)
