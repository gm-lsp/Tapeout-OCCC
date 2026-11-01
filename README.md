# Official Curated Circuit Collections (OCCC) for TapeOut

Reference implementation of the TAP draft **Official Curated Circuit Collections (OCCC)** (`TAP-draft-occc.md`).

On TapeOut, anyone can add circuits to any processor's NFT collection — with transistors any netlist, and without transistors a pure-REF netlist whose `circuitInfo` copies an official work. This project makes "which circuits are the real works" a public on-chain fact based on **who taped the circuit out**.

## Chains

TapeOut runs on BNB Smart Chain, X Layer and Base, and so does this protocol, unchanged: deploy the three vault implementations and one `CuratedRegistry` per chain with that chain's TapeOut factory (`FACTORY=<factory> forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast --private-key <key>`). A collection, its work list and its officialness belong to one chain (leaves include the chain id).

| Chain | chainId | Native coin | TapeOut factory (registry constructor argument) | Public RPC |
|---|---|---|---|---|
| BNB Smart Chain | 56 | BNB | `0x68224F668083c29e9800Be2a646d42d18cedF7e2` | `https://bsc-dataseed.bnbchain.org` |
| X Layer | 196 | OKB | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | `https://rpc.xlayer.tech` |
| Base | 8453 | ETH | `0x1f09DAeFA827f02CBb40967cc91b259763760761` | `https://mainnet.base.org` |

`curate.py` knows these factories: `build` checks that `--rpc` is on the spec's `chainId` and, unless the spec gives `deployFeeWei` and `protocolFeeWei`, reads the current fees from that chain's factory; `checkroot` checks the registry's `FACTORY()`. For any other chain (a testnet, a devnet) the spec must give `deployFeeWei` and `protocolFeeWei`, and `factory` when REF targets are checked with `--rpc`. The fork tests run on any of the three; `tool/examples/make_examples.py <chainId>` writes the example collection for a chain (`collection.json` for 56, `collection.<chainId>.json` otherwise) and `test/fixtures/manifest[.<chainId>].json` is its manifest.

## How it works

1. **Launch (one transaction, sent by the curator).** `CuratedRegistry.launch` checks the parameters and creates the vault as a clone of the implementation for the collection's sale mode (`"saleMode"`: `"instant-tapeout"` — the default —, `"instant-reveal"` or `"blind-box"`). The vault creates the processor, mints the whole transistor supply to itself, and binds itself to the registry, which re-checks all of that on chain.
2. **Sell (instant tape-out).** A buyer calls `vault.buy(index, netlist, nIn, nOut, price, proof, recipient)` with `price + TAPEOUT_FEE` (in a collection priced in a token, only `TAPEOUT_FEE`; see 12). The vault checks the Merkle proof, tapes out with its own transistors, the registry certifies the new circuit id in the same transaction (and gives it the next official serial, `registry.serialOf`), the circuit goes to the recipient, and the price is paid out at once: the platform's share to `platform`, the rest to `payee` (default: the curator; `vault.setPayee` changes it). A payout that fails is kept in `vault.owed(payee)` and withdrawn with `withdraw` / `withdrawTo`; it never blocks the purchase.
   - **Copies, in order.** A work with `"copies": N` is one design sold N times (the manifest stores it once). With `"sequential": true` works are sold strictly in list order with `vault.buyNext(first, copies, …)`, so the official serial of every work is its list position + 1 and, while nobody injects a wrapper into the processor, its TapeOut id. Reserved runs come first and are claimed with `claimReservedRun` before the sale.
   - **Instant reveal.** `"pools": [{"name": "Common", "priceWei": "…"}, …]`, each work with a `"pool"`, and `"revealFeeWei"`. Buyers call `vault.buySlot(pool, recipient)` with price + tape-out fee + reveal fee; from the next block the platform's server calls `vault.fulfill(slot, secret, proof, work, uri)`, which draws the work at random from the pool and tapes it out to the buyer (TAP §13.3). `build` writes a **private package** (the manifest with the slot secrets: keep it on the server) and `<out>.public.json` (publish this one); publish the package once the sale is over.
   - **Blind box.** As instant reveal, plus `"passURI"`. Each slot is a transferable pass (the vault is its ERC-721); after sell-out or the sale end the curator calls `vault.reveal(secret, directory)`, and anyone calls `vault.redeem(passes, works)` to turn passes into circuits (TAP §13.4). `curate.py assign` replays draws and assignments.
3. **Reserve (optional).** Works marked `"reserved": true` in the spec cannot be bought. The curator claims them with `vault.claimReserved(...)`, or several at once with `vault.claimReservedBatch([...])` (tape-out fee per work; before, during and after the sale, until `finalize`), and they go to the `treasury` fixed at launch. From there the treasury can give them away or airdrop them like any circuit; they stay official. Claim them soon after launch.
4. **Check.** Anyone calls `registry.isOfficial(circuits, id)` / `editionOf(circuits, id)` / `isReserved(circuits, id)`.
5. **Presale (optional).** `"presale": {"start": <unix time>, "allowlist": [{"address": "0x…", "quota": 2, "tier": 0}, …], "tiers": [{"name": "OG", "priceWei": "…", "prices": {"<index>": "…"}}, …]}`. From `start` until `saleStart`, only allowlisted wallets can buy, each up to its quota, with `vault.buyPresale(...)`. `tiers` (optional) gives each allowlist tier its own presale prices: absolute amounts, per tier a default `priceWei` (applied only where it is below a work's public price) and per-work `prices` (keys are work indexes, `"0"`, `"1"`, …); a work without either keeps its public price, and no presale price may exceed the work's public price (the tool and the vault both refuse it). Without `tiers` the presale sells at the public prices and every entry is tier 0. `curate.py allowproof manifest.json 0x… --index N` prints a wallet's allowlist proof and, for work N, its presale price and price proof (`--all` for every work, built in one pass). The allowlist and the price list are Merkle roots fixed at launch and are published in the manifest (`allowlist`, `presaleTiers`).
6. **Royalty declaration (optional).** `"royalty": {"receiver": "0x…", "bps": 300}` (300 bps = 3 %; at most 500 bps = 5 %). Markets read `registry.royaltyInfo(circuits, id, price)` (ERC-2981 shape); only official works report it. It is advisory: platforms collect it on their own trades. The curator can later change the receiver or lower the rate, never raise it.
7. **Per-wallet limit (optional).** `"limitPerWallet": false` = no limit. `"limitPerWallet": true` with `"maxPerWallet": N` lets each wallet buy at most N public works (a limited sale only sells to the buyer's own wallet). Fixed at launch; `vault.remainingFor(wallet)` shows what is left. It does not stop one person using many wallets.
8. **Pause or extend (curator).** `vault.setPaused(true/false)` stops and resumes buying (public sale and presale; reserved claims are unaffected). `vault.extendSale(newEnd)` moves the sale end later, never earlier, while the sale is still open; an ended sale cannot be reopened. `vault.paused()` and `vault.SALE_END()` show the current state.
9. **Finish.** After every work is taped out, or after `saleEnd` once every reserved work is claimed (otherwise 30 days after `saleEnd`), anyone can call `vault.finalize()` to burn the leftover transistors; `vault.finalizable()` tells whether it is time. Hidden sales finalize once every slot is delivered or refunded.
10. **Audit the list.** The curator publishes the manifest; anyone runs `curate.py checkroot` to rebuild the root from every published work, and the metadata commitment from the name, symbol, story and titles, and compare them with the chain. Titles are fixed at launch: the registry stores `collectionOf(circuits).metadata`.

11. **Images and metadata (optional).** Give works `"image"` (and optionally `"animation"`, `"description"`, `"attributes"`) as `ipfs://…` or `ar://…` links, run `curate.py metadata manifest.json out/` to write one ERC-721 `<index>.json` per work, upload that folder as one directory (an IPFS folder, or files plus an Arweave path manifest), set `"metadataURI": "ar://<manifest id>"` (or `"ipfs://<CID>"`) in the spec and build again. The directory is fixed at launch; `registry.tokenURI(circuits, id)` then returns `<metadataURI>/<index>.json` for official works and `""` for everything else. Arweave keeps files permanently; bundlers currently upload files under about 100 KiB for free.
12. **Price in a token (optional).** `"paymentToken": "0x…"` prices every work in that ERC-20 (`priceWei` is then in the token's smallest unit; BEM has 8 decimals). Buyers approve the vault for the amount due (the price, or their presale price) and call `buy` / `buyPresale` with only `TAPEOUT_FEE` in native coin; the vault refuses tokens that do not deliver exactly the price (fee-on-transfer, rebasing); `build --rpc` lists every price in token units so a wrong unit is easy to spot. Payee and platform are paid in the token. Launch fees and reserved claims stay native. `vault.PAYMENT_TOKEN()` shows the token (`address(0)` = native coin).

No contract has an owner, an admin function or an upgrade path.

## Layout

| Path | What |
|---|---|
| `src/CuratedRegistry.sol` | registry + launcher: checks parameters, clones the vault implementation of the sale mode, serials, per-circuit metadata, pass recognition |
| `src/CuratedTypes.sol` | launch parameters, sale-mode numbers |
| `src/CuratedVaultBase.sol` | what every vault shares: launch, presale, limits, direct payouts, payee, finalize |
| `src/CuratedVault.sol` | instant tape-out (any order, or sequential runs of copies) |
| `src/CuratedHiddenBase.sol`, `src/CuratedRevealVault.sol`, `src/CuratedBlindBoxVault.sol` | hidden sales: instant reveal and blind box (the pass is the vault's own ERC-721) |
| `src/interfaces/ICuratedRegistry.sol` | the standard interface |
| `src/interfaces/ICircuitURIProvider.sol` | the `tokenURI` hook proposed to TapeOut (TAP §12); every vault implements it |
| `src/interfaces/ITapeOut.sol` | the TapeOut functions used (selectors checked on mainnet) |
| `tool/curate.py` | encoder, Merkle builder, manifest, verifier (Python 3.11+, no dependencies) |
| `tool/tap02_reference.py`, `tool/tap02_vectors.json` | official TAP-02 reference implementation and vectors (MIT) |
| `tool/examples/` | a throw-away example collection of small test circuits |
| `test/Curated.t.sol`, `test/Modes.t.sol` | 80 fork tests (BNB Smart Chain, X Layer or Base), including token pricing with BEM on BNB Smart Chain, copies, instant reveal and blind box |
| `script/Deploy.s.sol` | deploy the three implementations and the registry |
| `script/Launch.s.sol` | launch a collection from a manifest (run with the curator's key) |
| `script/Demo.s.sol` | end-to-end demo on a local fork |
| `web/index.html`, `web/app.js` | sale and verification page for instant tape-outs sold in any order: two static files, read `site.json` and `manifest.json` (format `/8`) next to them |
| `web/run_e2e.sh` | browser end-to-end test of the page on a local fork (`E2E_TOKEN=1` prices the collection in a test ERC-20; needs Playwright for Python and `ethers.umd.min.js` 6.13.4: `web/run_e2e.sh path/to/ethers.umd.min.js`) |

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
python3 tool/examples/make_examples.py          # 196 or 8453 for X Layer or Base
python3 tool/curate.py build tool/examples/collection.json test/fixtures/manifest.json \
    --rpc https://bsc-dataseed.bnbchain.org
#   X Layer: build tool/examples/collection.196.json test/fixtures/manifest.196.json --rpc https://rpc.xlayer.tech
#   Base:    build tool/examples/collection.8453.json test/fixtures/manifest.8453.json --rpc https://mainnet.base.org

# 4. run the fork tests (Foundry) on BNB Smart Chain, X Layer or Base
forge test --fork-url https://bsc-dataseed.bnbchain.org -vv
forge test --fork-url https://rpc.xlayer.tech
forge test --fork-url https://mainnet.base.org

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
  "paymentToken": "0x… (optional ERC-20 for prices; omit for the native coin)",
  "presale": {"start": 1798000000, "allowlist": [{"address": "0x…", "quota": 2, "tier": 0}],
              "tiers": [{"name": "OG", "priceWei": "5000000000000000"}]},
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
- Five rounds of independent internal review found no critical issue; their findings are fixed (on-chain fixes have regression tests such as `test_H1_*`, `test_M1_*`, `test_L*`) or listed in the TAP's Security Considerations.
- Free public BSC nodes keep recent state only, so long-lived `anvil` forks fail after about a minute; `forge test --fork-url` re-forks the latest block on every run, and `web/run_e2e.sh` forks from a node that keeps older state (`FORK_URL`, default `https://bsc-mainnet.public.blastapi.io`; `FORK_URL=https://rpc.xlayer.tech` or `https://mainnet.base.org` runs it on X Layer or Base).
- `site.json` names the chain (`chainId`); the page knows how to add BNB Smart Chain, X Layer and Base to a wallet and shows prices in the collection's payment token, or the chain's coin (`addChain` in `site.json` covers any other chain).
- Not audited. Do not use with significant value before an independent audit.

Licence: MIT (code), CC0 (TAP text).

