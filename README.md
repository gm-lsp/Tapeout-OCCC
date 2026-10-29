# Official Curated Circuit Collections (OCCC) for TapeOut

Reference implementation of the TAP draft **Official Curated Circuit Collections (OCCC)** (`TAP-draft-occc.md`).

On TapeOut, anyone can add circuits to any processor's NFT collection — with transistors any netlist, and without transistors a pure-REF netlist whose `circuitInfo` copies an official work. This project makes "which circuits are the real works" a public on-chain fact based on **who taped the circuit out**.

## How it works

1. **Launch (one transaction, sent by the curator).** `CuratedRegistry.launch` deploys a `CuratedVault`. The vault creates the processor, mints the whole transistor supply to itself, and binds itself to the registry, which re-checks all of that on chain.
2. **Sell.** A buyer calls `vault.buy(index, netlist, nIn, nOut, price, proof, recipient)` with `price + TAPEOUT_FEE`. The vault checks the Merkle proof, tapes out with its own transistors, the registry certifies the new circuit id in the same transaction, and the circuit goes to the recipient.
3. **Reserve (optional).** Works marked `"reserved": true` in the spec cannot be bought. The curator claims them with `vault.claimReserved(...)`, or several at once with `vault.claimReservedBatch([...])` (tape-out fee per work; before, during and after the sale, until `finalize`), and they go to the `treasury` fixed at launch. From there the treasury can give them away or airdrop them like any circuit; they stay official. Claim them soon after launch.
4. **Check.** Anyone calls `registry.isOfficial(circuits, id)` / `editionOf(circuits, id)` / `isReserved(circuits, id)`.
5. **Presale (optional).** `"presale": {"start": <unix time>, "allowlist": [{"address": "0x…", "quota": 2}, …]}`. From `start` until `saleStart`, only allowlisted wallets can buy, each up to its quota, with `vault.buyPresale(...)`; `curate.py allowproof manifest.json 0x…` prints a wallet's proof. The allowlist is a Merkle root fixed at launch and is published in the manifest.
6. **Royalty declaration (optional).** `"royalty": {"receiver": "0x…", "bps": 300}` (300 bps = 3 %, the maximum). Markets read `registry.royaltyInfo(circuits, id, price)` (ERC-2981 shape); only official works report it. It is advisory: platforms collect it on their own trades. The curator can later change the receiver or lower the rate, never raise it.
7. **Per-wallet limit (optional).** `"limitPerWallet": false` = no limit. `"limitPerWallet": true` with `"maxPerWallet": N` lets each wallet buy at most N public works (a limited sale only sells to the buyer's own wallet). Fixed at launch; `vault.remainingFor(wallet)` shows what is left. It does not stop one person using many wallets.
8. **Finish.** After every work is taped out, or after `saleEnd` once every reserved work is claimed (otherwise 30 days after `saleEnd`), anyone can call `vault.finalize()` to burn the leftover transistors; `vault.finalizable()` tells whether it is time. Proceeds are pulled with `vault.withdraw(payee)` or, by the payee, `vault.withdrawTo(address)`.
9. **Audit the list.** The curator publishes the manifest; anyone runs `curate.py checkroot` to rebuild the root from every published work, and the metadata commitment from the name, symbol, story and titles, and compare them with the chain. Titles are fixed at launch: the registry stores `collectionOf(circuits).metadata`.

10. **Images and metadata (optional).** Give works `"image"` (and optionally `"animation"`, `"description"`, `"attributes"`) as `ipfs://…` or `ar://…` links, run `curate.py metadata manifest.json out/` to write one ERC-721 `<index>.json` per work, upload that folder as one directory (an IPFS folder, or files plus an Arweave path manifest), set `"metadataURI": "ar://<manifest id>"` (or `"ipfs://<CID>"`) in the spec and build again. The directory is fixed at launch; `registry.tokenURI(circuits, id)` then returns `<metadataURI>/<index>.json` for official works and `""` for everything else. Arweave keeps files permanently; bundlers currently upload files under about 100 KiB for free.

No contract has an owner, an admin function or an upgrade path.

## Layout

| Path | What |
|---|---|
| `src/CuratedRegistry.sol` | registry + launcher |
| `src/CuratedVault.sol` | per-collection vault and sale |
| `src/interfaces/ICuratedRegistry.sol` | the standard interface |
| `src/interfaces/ICircuitURIProvider.sol` | the `tokenURI` hook proposed to TapeOut (TAP §12); every vault implements it |
| `src/interfaces/ITapeOut.sol` | the TapeOut functions used (selectors checked on mainnet) |
| `tool/curate.py` | encoder, Merkle builder, manifest, verifier (Python 3.11+, no dependencies) |
| `tool/tap02_reference.py`, `tool/tap02_vectors.json` | official TAP-02 reference implementation and vectors (MIT) |
| `tool/examples/` | a throw-away example collection of small test circuits |
| `test/Curated.t.sol` | 46 fork tests |
| `script/Launch.s.sol` | launch a collection from a manifest (run with the curator's key) |
| `script/Demo.s.sol` | end-to-end demo on a local fork |
| `web/index.html`, `web/app.js` | sale and verification page: two static files, read `site.json` and `manifest.json` next to them |
| `web/run_e2e.sh` | browser end-to-end test of the page on a local fork (needs Playwright for Python and `ethers.umd.min.js` 6.13.4: `web/run_e2e.sh path/to/ethers.umd.min.js`) |

## Setup

```bash
# Foundry (https://getfoundry.sh), then the two libraries (tested with forge-std v1.17.0):
forge install foundry-rs/forge-std@v1.17.0 OpenZeppelin/openzeppelin-contracts@v5.1.0
```

## Quick start

```bash
# 1. tool self-test (TAP-02 vectors + random encoder cross-checks)
python3 tool/curate.py selftest

# 2. encode one design (TapeOut canvas export, or {"netlist","nIn","nOut"})
python3 tool/curate.py encode tool/examples/lfsr7.json

# 3. build a launch manifest from a collection spec (--rpc checks REF targets on chain)
python3 tool/examples/make_examples.py
python3 tool/curate.py build tool/examples/collection.json test/fixtures/manifest.json \
    --rpc https://bsc-dataseed.bnbchain.org

# 4. run the fork tests (Foundry)
forge test --fork-url https://bsc-dataseed.bnbchain.org -vv

# 5. after deployment: is circuit 7 of a collection official? (the manifest is optional; it adds the title)
python3 tool/curate.py verify test/fixtures/my_manifest.json --rpc https://bsc-dataseed.bnbchain.org \
    --registry <REGISTRY> --circuits <PROCESSOR> --id 7

# 6. does the published manifest match the chain (works, allowlist, titles and every launch setting)?
python3 tool/curate.py checkroot test/fixtures/my_manifest.json --rpc https://bsc-dataseed.bnbchain.org \
    --registry <REGISTRY> --circuits <PROCESSOR>
```

### Collection spec (`collection.json`)

```json
{
  "name": "My Collection", "symbol": "MYC", "story": "…",
  "chainId": 56, "registry": "0x… (the deployed CuratedRegistry)",
  "curator": "0x… (the address that will send the launch)",
  "platform": "0x…", "platformBps": 500,
  "treasury": "0x… (receives reserved works; a multisig is recommended)",
  "mintPriceWei": "10000000000000", "mintBatch": 2500,
  "saleStart": 1798200000, "saleEnd": 1798761600, "spareNand": 0, "spareLatch": 0,
  "limitPerWallet": true, "maxPerWallet": 3,
  "royalty": {"receiver": "0x…", "bps": 300},
  "presale": {"start": 1798000000, "allowlist": [{"address": "0x…", "quota": 2}]},
  "metadataURI": "ar://<43-character id of the directory>",
  "works": [
    {"file": "design.json", "title": "Work 0", "priceWei": "10000000000000000",
     "image": "ar://<image id>", "description": "…", "attributes": [{"trait_type": "Gates", "value": 12}]},
    {"netlist": "0x…", "nIn": 8, "nOut": 4, "title": "Work 1", "priceWei": "0"},
    {"file": "gift.json", "title": "Kept for the treasury", "reserved": true}
  ]
}
```

`"limitPerWallet": false` (and no `maxPerWallet`) means no limit; `royalty`, `presale`, `metadataURI` and the per-work `image`, `animation`, `description` and `attributes` are optional. `metadataURI` must be `ipfs://<CID>` or `ar://<id>` (an id with at least one upper-case letter, which no ArNS name has) with no path (the registry refuses anything else, so it can never point at changeable content); image links must be `ipfs://` or `ar://` too, and may have a path. Amounts in wei are integers or strings of digits (never decimals). Optional keys: `defaultPriceWei` (price of works without `priceWei`), `maxLaunchFeesWei` (the most you will pay in factory and protocol fees; default: the fees the tool predicts), and `deployFeeWei` / `protocolFeeWei` (the factory's current `deployFee()` and a processor's `protocolFee()`, if you read them from the chain; defaults: 0.001 and 0.0001 BNB). Mixed-case addresses must have a correct EIP-55 checksum.

`build` encodes each design, checks it with the TAP-02 reference implementation, resolves every REF target on chain (refusing targets that do not exist yet or have other pin counts), cross-simulates canvas designs against the encoded netlist, counts NAND / LATCH exactly, pads the supply to the factory minimum of 10,000, computes the launch-fee cap and the value to send, and writes the root, proofs and launch parameters. Leaves are bound to the chain id, the registry and the curator, so the manifest is only valid for that registry and that curator.

### Canvas REF nodes

The TapeOut canvas export does not document a REF node's `data`. This tool expects `{"cpu": "0x…", "id": n, "nIn": i, "nOut": o, "nState": s}`.

## Launch and sale page

```bash
# build the manifest for the deployed registry, then launch with the curator's key
python3 tool/curate.py build my_collection.json test/fixtures/my_manifest.json --rpc https://bsc-dataseed.bnbchain.org
MANIFEST=test/fixtures/my_manifest.json forge script script/Launch.s.sol \
    --rpc-url https://bsc-dataseed.bnbchain.org --broadcast --private-key <curator key>
```

Copy `web/index.html`, `web/app.js`, the manifest (as `manifest.json`) and a `site.json` (see `web/site.example.json`: the registry address and the printed CIRCUITS address) to any static host: GitHub Pages, IPFS, or a TapeOut DeWEB container. Buyers connect a browser wallet and buy (presale or public); anyone can check whether a circuit is official on the Verify tab. The page rebuilds every work and allowlist entry from the manifest and refuses to load if anything differs from the chain; it only trusts the addresses in `site.json`.

## Notes

- Launch must be sent by the curator, with `msg.value` = the manifest's `launchValueWei` (fees + one mint batch of float). The unused part is refunded in the same transaction. If TapeOut raises its fees above `maxLaunchFeesWei`, the launch reverts.
- Publish the whole manifest before the sale opens: buyers need it for proofs, and verifiers need it to rebuild the root.
- Four rounds of independent internal review found no critical issue; their findings are fixed (on-chain fixes have regression tests such as `test_H1_*`, `test_M1_*`, `test_L*`) or listed in the TAP's Security Considerations.
- Free public BSC nodes keep recent state only, so long-lived `anvil` forks fail after about a minute; `forge test --fork-url` re-forks the latest block on every run, and `web/run_e2e.sh` forks from a node that keeps older state (`FORK_URL`, default `https://bsc-mainnet.public.blastapi.io`).
- Not audited. Do not use with significant value before an independent audit.

Licence: MIT (code), CC0 (TAP text).

