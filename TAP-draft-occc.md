---
tap: TBD
title: Official Curated Circuit Collections
description: A registry and launch pattern that make "this circuit is an official work of this collection" a public, provenance-based fact on chain.
author: gm-lsp (@gm-lsp)
discussions-to: <URL of the discussion thread>
status: Draft
type: Standards
created: 2026-10-25
requires: TAP-02, ERC-165, ERC-721, ERC-1155, ERC-2981
license: CC0-1.0
---

# TAP-TBD: Official Curated Circuit Collections (OCCC)

## Summary

A way for an artist or project to sell a fixed list of circuits on TapeOut so that anyone — a buyer, a market, another contract — can check on chain which circuits in the collection are the real works and which were added by someone else. A collection can sell each work openly, one design in many numbered copies, or works drawn at random (at once, or in a blind box opened after the sale) so that nobody can learn or pick the rare ones in advance.

## Abstract

On TapeOut a processor contract is an NFT collection, but anyone can add circuits to it: with transistors any netlist can be taped out, and without any transistors a netlist made only of REF records can be taped out at zero transistor cost. This TAP defines **curated collections** (the Official Curated Circuit Collections, OCCC, of the title): collections whose official works anyone can check. A curated collection is launched in a single transaction in which a vault contract creates the processor and mints its entire transistor supply to itself. Afterwards, the collection's transistors can be spent only through that vault, and the vault tapes out only netlists from a work list fixed at launch as a Merkle root. A circuit is **official** if and only if the vault taped it out and a registry certified its id in the same transaction. A curator can also mark works in the list as **reserved** for a treasury fixed at launch: the public can never buy them, and they are claimed to the treasury, from which they can be given away or airdropped like any circuit. Optionally, a curator can declare a royalty that markets may read and honour, and can price works in an ERC-20 token such as BEM instead of the chain's coin. Every sale is paid to the curator's payee at once. A collection is sold in one of three **sale modes** fixed at launch: **instant tape-out** (the buyer picks a listed work, or the next one in list order, and receives the circuit in the same transaction; a design may be listed as a run of identical copies), **instant reveal** (the buyer buys a slot in a price pool, and from the next block the work is drawn at random from the pool's remaining works and taped out to the buyer), and **blind box** (the buyer receives a transferable pass; after the sale the curator reveals, every pass is assigned a work by a random permutation, and anyone redeems passes into circuits). In the two hidden modes the works stay unpublished until they are taped out, and the randomness is committed at launch so that neither the buyer nor the curator nor the platform can choose an outcome. Every official circuit gets an official serial number, its order among the collection's official tape-outs. The TAP specifies the registry interface (`isOfficial`, `editionOf`, `tokenOf`, `serialOf`, `tokenOfSerial`, `isReserved`, `isCurated`, `collectionOf`, `isBlindBoxPass`, the royalty functions and their events), the conditions the registry checks at launch (including that the curator launches personally), the vault's behaviour, a work-list leaf encoding bound to the chain, the registry and the curator, the requirement to publish every leaf, a commitment to the collection's name, symbol, story and titles, an optional metadata directory fixed at launch from which the registry's `tokenURI` gives every official circuit ERC-721 metadata (name, image, attributes), and how front-ends, markets and contracts are to use the record. It also makes three recommendations to TapeOut: a small change to its processor contracts so that wallets and markets that read only the NFT contract show the same metadata, an option for a processor's creator to restrict tape-outs to itself, and an assessment of deferred tape-out.

## Motivation

A collection of circuit NFTs is, on TapeOut, the set of circuits of one processor contract. The protocol does not let the processor's creator decide what enters that set:

1. **Anyone holding transistors can tape out any netlist** into the processor. If the processor's transistors are sold publicly, buyers can tape out small "toy" circuits, or tape out a netlist **byte-for-byte identical** to an official work.
2. **Anyone can tape out a pure-REF netlist with no transistors at all.** `tapeout` burns only the netlist's own NAND and LATCH records (TAP-02 §6); REF records burn nothing. A 31-byte netlist that is a single REF to an official circuit costs only the tape-out fee, and its `circuitInfo`, `eval` and `step` are identical to the official circuit's (TAP-02 §4, §6).

Mainnet collections already contain toy circuits and pure-REF wrappers. In two collections examined on 2026-10-25, between a few dozen and about 1,400 circuits were small toy circuits, and tens to hundreds were pure-REF wrappers whose `circuitInfo` matched the official design exactly. Their projects did not recognise them, but markets listed them in the collection, and some marked them as matching the standard. Users also reported official-identical netlists taped out by holders of the processor's transistors, which no content check can distinguish.

What the projects actually used to decide "official" was off-chain knowledge of **who taped the circuit out**. Buyers could not check it, markets could not display it, and contracts that grant rights to circuit holders could not enforce it. This TAP turns that knowledge into a public, immutable record with a fixed meaning.

Content checks cannot replace it:

| Kind | Netlist vs. official | Detectable by content? |
|---|---|---|
| Toy circuit | different | yes, by netlist hash |
| Pure-REF wrapper | different bytes, identical `circuitInfo` / evaluation | only by netlist bytes |
| Same netlist taped out by someone else | identical | **no** |

## Specification

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in RFC 2119 and RFC 8174 when, and only when, they appear in all capitals.

### 1. Terms

| Term | Meaning |
|---|---|
| Processor contract | As in TAP-02: an ERC-721 contract created by the TapeOut processor factory. Called `circuits` below |
| Transistor contract | The processor's ERC-1155 contract; id 0 = NAND, id 1 = LATCH; one supply cap shared by both ids |
| Chain | A chain on which TapeOut is deployed: BNB Smart Chain (chain id 56), X Layer (196) and Base (8453) at the time of writing. "Native coin" is the chain's own coin (BNB, OKB, ETH) |
| Registry | A contract implementing §3, deployed on one chain and bound at deployment to that chain's TapeOut processor factory. It has no owner and cannot be upgraded |
| Vault | The contract that launched a curated collection and is bound to it in the registry |
| Curated collection | A processor contract bound to a vault in a registry |
| Work list | An ordered list of `count` works, indexed from 0, committed to by a Merkle root |
| Official circuit | A circuit `(circuits, tokenId)` certified by the registry under §2 |
| Curator | The address that launches the collection, is the only one that may claim reserved works, chooses the payee, and may change the royalty receiver or lower its rate |
| Payee | The address that receives the curator's share of every sale directly, fixed at launch and changeable by the curator |
| Sale mode | How a collection sells, fixed at launch: 0 **instant tape-out**, 1 **instant reveal**, 2 **blind box** (§6, §13) |
| Run | In a work list, a design listed once with a number of identical copies, which occupy consecutive indexes |
| Serial | An official circuit's position, from 1, among the official circuits of its collection in tape-out order (§3) |
| Hidden sale | A sale in mode 1 or 2: buyers buy a **slot** in a **price pool**, not a work, and works stay unpublished until they are taped out |
| Pass | In a blind box, the transferable ERC-721 token a buyer receives for a slot; it is burned when it is redeemed into a circuit |
| Reserved work | A work the work list marks as kept for the treasury: it cannot be bought, only claimed to the treasury |
| Treasury | The address, fixed at launch, that receives every reserved work |

### 2. Definition of an official circuit

A circuit `(circuits, tokenId)` is **official** in a registry if and only if:

1. `circuits` is a curated collection in that registry (§4), and
2. the collection's vault taped out circuit `tokenId` by calling `circuits.tapeout`, and
3. in the same transaction, the vault called the registry's `certify(circuits, tokenId, index, netlistHash, reserved)` for a work `index` with `index < count` that had not been certified before.

Officialness belongs to the circuit, not to its holder: it does not change when the circuit is transferred, sold, given away or airdropped.

When a work list sells one design in many copies (§5), each copy is official by the same rule, because the vault taped it out. A circuit with the same netlist taped out by anyone else, on this processor (only possible as a pure-REF wrapper, §4) or on another, is not official.

Officialness MUST NOT be inferred from a circuit's netlist bytes, netlist hash, `circuitInfo`, evaluation results, owner, or token URI.

Officialness is relative to one processor contract. A curator may launch more than one collection, so consumers MUST identify a collection by the chain id and processor address the curator announced, not by its name or symbol, which are not unique.

### 3. Registry interface

A registry MUST implement the following functions and events. All functions in the table except `certify` are `view`.

| Function | Selector | Returns |
|---|---|---|
| `isOfficial(address circuits, uint256 tokenId)` | `0x9a516edc` | `bool`: whether the circuit is official (§2) |
| `editionOf(address circuits, uint256 tokenId)` | `0xe80e01aa` | `(bool official, uint256 index)`: `index` is the work-list position; `(false, 0)` if not official |
| `tokenOf(address circuits, uint256 index)` | `0xa3dabb02` | `(bool taped, uint256 tokenId)`: whether work `index` has been taped out, and its circuit id |
| `isReserved(address circuits, uint256 tokenId)` | `0x9e9cf5c3` | `bool`: whether the circuit is an official work that the list reserved for the treasury; unchanged by later transfers |
| `isCurated(address circuits)` | `0x774d70e4` | `bool`: whether `circuits` is a curated collection in this registry |
| `collectionOf(address circuits)` | `0x3e94c904` | `(address vault, address curator, address transistors, address treasury, bytes32 root, uint32 count, uint32 reserved, uint32 certified, bytes32 metadata, uint8 saleMode)`; all zero if not curated |
| `serialOf(address circuits, uint256 tokenId)` | `0x7be75877` | `uint256`: the circuit's official serial (1 for the collection's first official circuit, 2 for the next, …); 0 if not official |
| `tokenOfSerial(address circuits, uint256 serial)` | `0x065b9385` | `(bool taped, uint256 tokenId)`: the circuit with that serial |
| `isBlindBoxPass(address token)` | `0xa7dc0bbe` | `bool`: whether `token` is the pass contract of a blind-box collection launched through this registry (§13) |
| `certify(address circuits, uint256 tokenId, uint256 index, bytes32 netlistHash, bool reserved)` | `0xaa92a7c0` | not `view`: records an official circuit; callable only by the collection's vault (§3 rule 4) |

| Event | Topic 0 |
|---|---|
| `CollectionLaunched(address indexed circuits, address indexed vault, address indexed curator, address transistors, bytes32 root, uint32 count, address treasury, uint32 reserved, bytes32 metadata)` | `0xfafcf03610954fd778b52f9044d3c3fcbade024c53f03257b287645a997bb10d` |
| `Certified(address indexed circuits, uint256 indexed tokenId, uint256 indexed index, bytes32 netlistHash, bool reserved)` | `0x8d7d8f5d2406ca80fb5e26889f1d3c94eaa0bc9e610a469ca59e18cab4ff1340` |
| `Serial(address indexed circuits, uint256 indexed tokenId, uint256 serial)` | `0x8299a793f3c0fd9c6e44cf13aa3d647c724f27561931bed2f30f320848a31a19` |
| `SaleModeSet(address indexed circuits, uint8 saleMode)` | `0x96a08b66a34b0db3ec807bf462081fb299e174e057a1571aa73b1eb870a1fa7e` |

Rules:

1. For each `circuits`, `CollectionLaunched` MUST be emitted exactly once, and before any `Certified` for it.
2. `Certified` MUST be emitted in the same transaction as the tape-out of `tokenId`, exactly once per `tokenId` and exactly once per `index`.
3. Once `isOfficial(circuits, tokenId)` is true it MUST stay true; `editionOf` and `tokenOf` MUST NOT change once set. `collectionOf(circuits).root`, `.count`, `.vault`, `.curator`, `.transistors`, `.treasury`, `.reserved` and `.metadata` MUST NOT change once set.
4. The registry MUST NOT have an owner, administrator, pause switch or upgrade mechanism, and MUST NOT accept certifications from any address other than the collection's vault.
5. The registry MUST NOT certify more reserved works for a collection than the `reserved` count fixed at launch.
6. Each certification MUST assign the next serial: the first circuit certified for a collection gets serial 1, and each later one the previous serial plus 1. `Serial` MUST be emitted right after `Certified`, and `serialOf` and `tokenOfSerial` MUST NOT change once set. `CollectionLaunched` and `SaleModeSet` are emitted together, once; `saleMode` MUST NOT change.

The index (`editionOf`) is a work's position in the work list; the serial (`serialOf`) is its place in the order of official tape-outs, which is the number a collection's holders usually mean by "#N". The registry requires a fresh processor (§4.6) and TapeOut numbers circuits from 1 in tape-out order, so as long as nobody else tapes out a circuit on the processor, the serial equals the TapeOut circuit id. Anyone can still tape out a pure-REF wrapper into any processor (§4); each one takes a TapeOut id, and from then on the two numbers differ. A protocol cannot prevent that today; §12.2 recommends the TapeOut change that would. Front-ends SHOULD show the serial as the work's number and the TapeOut id beside it when they differ. In a sequential collection (§6.10) the serial is the index plus one; in a hidden sale (§13) the serial is the order in which slots were delivered and is unrelated to the work's index or title.

### 4. Launch

A registry MUST bind a collection to a vault only if all of the following hold **at the moment of binding**, checked on chain by the registry itself rather than taken from the vault:

1. The vault was created for this launch by this registry, in a call whose sender is the curator, from vault code the registry fixed at its own deployment (the reference registry creates an EIP-1167 clone of one of three implementations, one per sale mode, whose addresses are immutable in the registry). A registry MUST NOT launch a collection whose curator is not the caller, so nobody can launch in an artist's name.
2. `factory.isCPU(circuits)` (selector `0x5f5a364f`) is true for the TapeOut processor factory of the registry's chain, which the registry MUST fix at deployment.
3. `circuits.transistors() == transistors` and `transistors.circuits() == circuits`.
4. `transistors.creator() == vault`.
5. `transistors.minted() == transistors.supplyCap()`, and `transistors.balanceOf(vault, 0) + transistors.balanceOf(vault, 1) == transistors.supplyCap()`.
6. No circuit has been taped out on `circuits` yet. (On the deployed contracts `circuits.nextId()` returns 0 for a fresh processor; see Backwards Compatibility.)
7. `circuits` is not already bound.

Creating the processor, minting its whole supply to the vault and binding MUST happen in one transaction. Because the processor does not exist before that transaction, nobody else can hold any of its transistors.

Right after creating the processor, the reference vault calls `restrictTapeoutToCreator()` (`0x9051fb27`) on it with a gas limit of 100,000 and ignores the result. Today's processors have no such function and the call changes nothing; if TapeOut adopts the recommendation of §12.2, collections launched afterwards are restricted to their vault from their first block, and no wrapper can ever be taped out into them.

The launch MUST fix a sale end time, which MUST be later than the launch. The launcher SHOULD state the most it will pay in factory and protocol fees, and the launch MUST revert if the fees read at launch time exceed it, so a fee change between preparing and sending the launch cannot drain the launcher's float.

A launch MAY use a non-zero processor mint price (for example to meet a front-end display threshold). In that case the vault pays itself and recovers the payment with `withdraw()` between mint batches; the vault is the creator, so the net cost is the factory deploy fee and the protocol fees. This "mint revenue" is not real demand, and tools SHOULD say so.

### 5. Work list

This section describes the work list of an instant tape-out (sale mode 0); hidden sales use the leaves of §13.2. Each work is `(index, netlist, nIn, nOut, price, reserved)`, where `netlist` is a well-formed TAP-02 netlist, `price` is the sale price in the smallest unit of the collection's payment asset (wei for the native coin; §6.8), and `reserved` says whether the work is kept for the treasury. A reserved work MUST have `price = 0`. The leaf of a work is (pseudo-code; `abi.encode` and `keccak256` as in Solidity)

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(
    uint256 chainId, address registry, address curator,
    uint256 index, bytes32 keccak256(netlist), uint32 nIn, uint32 nOut, uint256 price, bool reserved))))
```

and the root is computed with sorted-pair hashing, as verified by OpenZeppelin `MerkleProof` (`hash(a, b) = keccak256(a < b ? a ‖ b : b ‖ a)`). Binding the leaf to the chain, the registry and the curator means a work list cannot be reused by anyone else, on another chain, or in another registry.

Which works are public and which are reserved is therefore fixed at launch, together with the number of reserved works and the treasury address. A curator cannot later move a popular public work into the treasury, and buyers can see every reserved work before the sale opens. Indexes MUST be `0 … count − 1`, each used once.

**Copies.** Many collections sell one design many times: thousands of circuits with the same netlist, each an official work (§2). A work list MAY therefore contain the same netlist at several indexes. Tools SHOULD reject a work list that contains the same netlist twice unless the curator declares it as one design sold in `copies` identical copies, which the tool expands to `copies` consecutive indexes; an undeclared repetition is refused as a likely mistake. Tools and publication formats SHOULD store such a design once, with its copy count, not once per copy. The transistors a design needs are counted once per copy.

**Sequential collections.** A collection MAY be launched as **sequential**: works are then sold strictly in list order, the vault tapes out index `sold` (the number of works taped out so far) on each purchase, and the work list is a list of **runs**, each a design with `copies` identical copies at indexes `first … first + copies − 1` (a single work is a run of one), with one leaf per run:

```
runLeaf = keccak256(bytes.concat(keccak256(abi.encode(
    uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-run"),
    uint256 first, uint32 copies, bytes32 keccak256(netlist), uint32 nIn, uint32 nOut, uint256 price, bool reserved))))
```

The tag and the length (eleven words) keep run leaves apart from work leaves. Because nobody can skip ahead, a work's index fixed in the list is also its tape-out order, so its serial (§3) is `index + 1`, and while nobody else tapes out on the processor it is also its TapeOut id: a curator can number works in advance (#1 is this design, #2 that one). Reserved runs MUST come first in a sequential list and are claimed in order before the public sale (tools enforce this); a reserved run placed later would stop the sale until it is claimed, and one placed last could not be claimed once the sale ended unsold. Works not sold by the end are the last ones in the list, so no serial is ever skipped.

A Merkle root commits to a set of leaves, not to "exactly `count` works": a dishonest curator could add a hidden second leaf for an index (for example, at price 0) and buy it first. The curator of an instant tape-out MUST therefore publish every leaf — every work's index, netlist, pins, price and reserved flag — before the sale opens, and verifiers SHOULD rebuild the root from the published list and compare it with `collectionOf(circuits).root`. A collection whose published list does not rebuild the on-chain root MUST NOT be presented as verified.

A REF record in a listed netlist MUST point to a circuit that already exists when the list is built, with matching pin counts. A REF to an id that does not exist yet would let anyone tape out a circuit at that id first and so decide part of the official work's behaviour; a REF with wrong pins can never be taped out.

The netlist does not need to equal what any particular editor would produce for the same design; it needs to be well-formed and to be exactly the bytes the vault will tape out.

### 6. Vault

A vault bound to a collection (rules 1–9 apply to every sale mode; §13 adds the rules of the hidden modes):

1. MUST tape out only netlists whose leaf is proven against the root, at most once per `index`.
2. MUST call `certify` in the same transaction as each tape-out, with the id returned by `tapeout`.
3. MUST NOT sell a reserved work. It MUST tape out a reserved work only to the treasury fixed at launch (which MUST NOT be the vault or the registry), at most `reserved` times in total, and only until the leftover transistors are burned (item 4). Once in the treasury, a reserved work is an ordinary circuit that the treasury MAY transfer, give away or airdrop; the vault and registry place no restriction on it.
4. MUST NOT transfer, approve or burn transistors except by tape-out, or by sending the remainder to a burn address once all `count` works are taped out, or once the sale has ended and either every reserved work has been claimed or a grace period fixed in the vault has passed. Public works not sold by the sale end can never be taped out, and the grace period is bounded, so one unsellable work cannot keep the supply unburned forever; a reserved work that the curator forgot to claim is not lost when the sale ends.
5. MUST NOT have an owner or functions that change the root, the count, the curator, the platform share, the treasury, the reserved count, the payment asset, the presale prices, the sale mode or the sale start after launch. It MAY let the curator change the payee. It MAY let the curator pause and resume buying, and move the sale end later (never earlier) while the sale has not ended and the vault is not finalized; it MUST NOT let anyone move the sale end earlier or reopen an ended sale.
6. MUST NOT let the launcher, or anyone else, buy works during the launch transaction (for example from a refund callback).
7. SHOULD transfer each new circuit to the buyer's chosen recipient in the same transaction. SHOULD pay each sale out at once, the platform's share to the platform and the rest to the payee, and MUST NOT let a payout that fails (a payee contract that refuses the native coin, a token that blocks the payee) make the purchase fail: such an amount is kept for that payee, who withdraws it later, to itself or to another address. The tape-out fee, and in a hidden sale the reveal fee (§13), are not proceeds and stay in the vault until they are spent or returned.
8. MAY price works in one ERC-20 token fixed at launch instead of the native coin (the payment asset); TapeOut's tape-out and launch fees are still paid in the native coin. A vault that does MUST make the token readable on chain, and MUST complete a purchase only if it received exactly the price in that token, so that payees are never credited with tokens that did not arrive.
9. MAY sell works to allowlisted wallets before the public sale at presale prices of its own, which may differ from the work list's prices. Such prices MUST be fixed at launch, and the vault MUST NOT sell a work in the presale for more than its price in the work list.
10. In a sequential collection (§5), MUST tape out exactly index `sold` on every purchase and every reserved claim, so that no work can be bought, or claimed, out of order.

The reference vault sells with `buy(index, netlist, nIn, nOut, price, proof, recipient)` (`0x2a21357f`). The curator can stop and resume buying (public sale and presale) with `setPaused(bool)` (`0x16c38b3c`, event `SalePaused(bool)`), and can move the sale end later with `extendSale(uint64 newEnd)` (`0xb69ee020`, event `SaleEndExtended(uint64 previousEnd, uint64 newEnd)`) as long as the current end has not passed; `SALE_END()` (`0x9aa0ff7b`) and `paused()` (`0x5c975abb`) return the current state. Neither control affects reserved claims, the work list or prices, and the reserve grace period counts from the current end. When prices are in the native coin, the vault charges exactly the amount due (`price`, or `presalePrice` in the presale) plus `circuits.TAPEOUT_FEE()`; it pays that amount out in the same transaction to an optional platform (at most 10 %) and to the payee, sells between a fixed `saleStart` and `saleEnd`, and accepts only circuits freshly minted to it by its own tape-out. The payee is a launch parameter (`payee`, which may not be zero, the vault or the registry; tools default it to the curator and recommend a multisig) that the curator may change with `setPayee(address)` (`0x410459ad`, event `PayeeChanged(address)`); `payee()` (`0xae90b213`) reads it. Each payout is a call with at most 50,000 gas (native coin) or a `transfer` (token) whose failure does not revert: the amount is then credited to `owed(payee)` (`0xdf18e047`) and the event `Paid(address indexed to, uint256 amount, bool deferred)` (`0x162f9eb7304cbf07de399b2c5000f621c8a1d7cf02c1d5dabe674206cf779009`) says so; `withdraw(who)` sends `who` what it is owed and `withdrawTo(to)` sends the caller's to another address. Native coin owed back to a buyer in a hidden sale (unused reveal fee) is kept the same way in `owedNative`. Reserved works are claimed with `claimReserved(index, netlist, nIn, nOut, proof)` (`0xfc451b6a`), or several at once with `claimReservedBatch((uint256 index, bytes netlist, uint32 nIn, uint32 nOut, bytes32[] proof)[])` (`0x8549fef1`, all or nothing): only the curator may call them, each work costs exactly the tape-out fee, they work before the public sale opens, during it and after it ends, and they send the circuit to the treasury. `finalize()` burns the leftover transistors once every work is taped out, or once the sale has ended and either every reserved work is claimed or `RESERVE_GRACE` (30 days) has passed; anyone may call it, and `finalizable()` (`0x107e8456`) tells whether it may be called now. After that no work can be taped out, so curators SHOULD still claim reserved works soon after launch.

The reference vault can price works in an ERC-20 token, fixed at launch by the launch parameter `paymentToken` (`address(0)` = the native coin; any other value must be a contract) and read with `PAYMENT_TOKEN()` (`0x877c86fb`). Then `buy` and `buyPresale` take exactly `circuits.TAPEOUT_FEE()` in `msg.value` and pull the amount due (`price`, or `presalePrice` in the presale) from the buyer with `transferFrom`, so the buyer approves the vault for it first; the vault compares its token balance before and after and reverts with `TokenAmountMismatch(expected, received)` unless it received exactly that amount, which refuses fee-on-transfer and similar tokens. A free work needs no approval. The curator's and platform's shares are paid out in the token at once (failed transfers are kept in `owed`, as above); the `price` in `Purchased` is in the token's smallest unit. Reserved claims, launch fees and the launch refund stay in the native coin. Work-list leaves (§5) do not name the token: prices in a work list mean the smallest unit of the collection's payment asset, so a work list is built for one payment asset. The reference registry creates each vault as an EIP-1167 minimal proxy (clone) of one of three implementations fixed in its constructor, `INSTANT_IMPL()` (`0x752488ea`, sale mode 0), `REVEAL_IMPL()` (`0x28367e9e`, mode 1) and `BOX_IMPL()` (`0xad9b3776`, mode 2); an implementation can never be initialised itself, and a clone only once, by the registry that created it. The registry also checks the launch parameters every mode shares, and the hidden parameters (§13), before it initialises the clone.

A sequential collection (launch parameter `sequential`; `SEQUENTIAL()`, `0xac60a828`) is sold with `buyNext(first, copies, netlist, nIn, nOut, price, proof, recipient)` (`0xbe7c25dd`), which tapes out the next index, `sold`, if it lies in the proven run (else `NotNext(uint256 next)`), and in the presale with `buyNextPresale(first, copies, netlist, nIn, nOut, price, proof, recipient, quota, tier, allowProof, presalePrice, presaleProof)` (`0x3fcb007f`), whose presale price leaves are keyed by the run's `first`. Its reserved runs are claimed with `claimReservedRun(first, copies, netlist, nIn, nOut, proof, n)` (`0x09420559`), which tapes out the next `n` copies to the treasury; `buy`, `buyPresale` and `claimReserved` refuse a sequential collection, and `buyNext` refuses one that is not. `runLeafOf(first, copies, netlistHash, nIn, nOut, price, reserved)` (`0x206cd52c`) computes a run leaf.

The reference vault also offers an optional per-wallet limit, fixed at launch as two separate settings: `limitPerWallet` (`false` = no limit) and `maxPerWallet` (the limit, at least 1, only when `limitPerWallet` is `true`; a launch whose two settings disagree reverts). With a limit, the reference vault sells only to the buyer's own wallet (`recipient == msg.sender`, else `RecipientMustBeBuyer`), each purchase counts once against that wallet, and a wallet that has reached the limit cannot buy further works. (Counting only the buyer would let one wallet buy for many; counting the recipient as well would let anyone use up a stranger's quota by buying for it.) `remainingFor(wallet)` returns whether a limit applies and how many purchases remain. The limit applies to minting only, not to later transfers, and not to reserved works. It is a sale policy of the vault, not part of the registry standard, and like any address-based limit it does not stop one person who uses many wallets.

The reference vault can also run a presale before the public sale. At launch the curator fixes `allowRoot`, the Merkle root of an allowlist of `(wallet, quota, tier)` entries, `presaleStart`, which the reference vault requires to be non-zero and before `saleStart` (with no presale both are zero), and optionally `presalePriceRoot`, the Merkle root of a presale price list of `(index, tier, presalePrice)` entries, read with `PRESALE_PRICE_ROOT()` (`0xf6b2ed47`). From `presaleStart` until `saleStart`, `buyPresale(index, netlist, nIn, nOut, price, proof, recipient, quota, tier, allowProof, presalePrice, presaleProof)` (`0xabb42724`) sells only to allowlisted wallets, each at most `quota` times; the per-wallet limit, if any, also applies. `price` and `proof` prove the work against the work list as in `buy`; `(msg.sender, quota, tier)` must be in the allowlist. With a presale price list, the buyer pays `presalePrice`, which must be proven for `(index, tier)` (else `InvalidPresalePrice`) and may not exceed `price` (else `PresaleAbovePrice(presalePrice, price)`); without one, `presalePrice` must equal `price`. The payment, the payees' shares and the `price` in `Purchased` are what the buyer paid, in the payment asset. Tiers let one presale give different allowlists different prices (for example an early-supporter list and a general list); a presale with one price list uses tier 0 throughout. An allowlist leaf is `keccak256(bytes.concat(keccak256(abi.encode(uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-allowlist-v2"), address wallet, uint32 quota, uint32 tier))))` and a presale price leaf is `keccak256(bytes.concat(keccak256(abi.encode(uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-presale-price"), bytes32 root, uint256 index, uint32 tier, uint256 presalePrice))))`, where `root` is the collection's work-list root, so a price list can only ever apply to the collection it was built for; the tags keep allowlist and price leaves apart, and their lengths (seven and eight words) keep both apart from nine-word work leaves. The vault refuses a `presalePriceRoot` without an allowlist. Curators SHOULD publish the allowlist and the presale price list with the work list so anyone can rebuild `allowRoot` and `presalePriceRoot`, and check that no presale price exceeds the work's price.

### 7. Front-ends and markets

1. A front-end that labels a circuit as an official or verified work of a curated collection MUST base that label on `isOfficial` (or `editionOf`) of a registry, named by the front-end, that is deployed on the same chain as the circuit. It MUST identify a collection by chain id and address together: officialness on one chain says nothing about another, and the same address can be a different processor on another chain (X Layer and Base share TapeOut's contract addresses).
2. It MUST NOT label a circuit as official, verified or "matching" a curated collection based on `circuitInfo`, evaluation results, netlist hash, owner or token URI.
3. For a curated collection, it SHOULD visibly mark circuits that are not official, and SHOULD let users filter them out.
4. It SHOULD show the official serial (`serialOf`) as the work's number, the work index (`editionOf`), and the TapeOut circuit id where it differs from the serial, and link to the certifying transaction (`Certified` log).
5. It SHOULD show which works of a collection are reserved for the treasury, before and after they are claimed (`isReserved`), and MUST still show a reserved work as official after the treasury transfers it.
6. It SHOULD show a collection as verified only if the curator's published work list rebuilds the on-chain root (§5).
7. It SHOULD show prices in the collection's payment asset (§6.8) read from the vault, using the token's own `decimals()`, and SHOULD show the native tape-out fee separately when prices are in a token.
8. It MUST NOT present a blind-box pass (§13) as a circuit or as an official work. It MAY list passes of contracts for which `isBlindBoxPass` is true as "unopened" passes of that collection, and SHOULD follow a redeemed pass to its circuit with the vault's `circuitOfSlot`.

### 8. Contracts that grant rights to holders

A contract that grants rights, rewards, access or voting power to holders of circuits from a curated collection MUST check `isOfficial(circuits, tokenId)` of the collection's registry, and MUST NOT rely on netlist content or `circuitInfo`.

### 9. Royalty declaration (optional)

TapeOut's processor contracts do not implement ERC-2981, and a curator cannot add it to them. A registry MUST therefore offer an advisory royalty declaration in the shape of ERC-2981, with the processor as an extra argument; declaring a royalty is optional for the curator:

| Function / event | Selector / topic 0 | Meaning |
|---|---|---|
| `royaltyInfo(address circuits, uint256 tokenId, uint256 salePrice)` | `0x538bd5ea` | `(address receiver, uint256 royaltyAmount)`; `(address(0), 0)` for a circuit that is not official, or when the collection declared no royalty |
| `royaltyOf(address circuits)` | `0xbb30d4ce` | `(address receiver, uint16 bps)` of the collection |
| `setRoyalty(address circuits, address receiver, uint16 bps)` | `0x4adc6e44` | curator only: change the receiver or lower the rate |
| `RoyaltySet(address indexed circuits, address receiver, uint16 bps)` | `0x42467d290c72e182ef85378ad110bba52b9442ac5509a2fd4c2754a38dac93c9` | emitted at launch and on every change |

1. A curator MAY declare a royalty at launch, as a receiver and a rate in basis points, or none. A receiver MUST be given if and only if the rate is not zero, and the rate MUST be at most 500 (5 %).
2. `royaltyInfo` MUST return `(address(0), 0)` for circuits that are not official, so REF wrappers and copies never carry the collection's royalty.
3. After launch, the curator MAY change the receiver and MAY lower the rate. The rate MUST NOT rise, so a collection that declared none can never add one. Nobody else can change it.
4. The declaration is advisory. This TAP does not require anyone to pay it and does not restrict transfers. Markets SHOULD read it for official circuits and MAY honour it; a platform MAY enforce it on trades made through that platform.

### 10. Metadata commitment

The netlists, prices and reserved flags are committed by the root (§5), but the collection's name, symbol, story and work titles are not part of any leaf. Without a commitment, any site could show official circuits under other titles or another story. A registry therefore records one `metadata` value per collection at launch, returned by `collectionOf` (pseudo-code):

```
titlesHash = keccak256(abi.encodePacked(keccak256(bytes(title_0)), …, keccak256(bytes(title_{count−1}))))
metadata   = keccak256(abi.encode(keccak256("TAP-curated-metadata"),
                                  keccak256(bytes(name)), keccak256(bytes(symbol)), keccak256(bytes(story)),
                                  titlesHash))
```

with every string UTF-8 encoded and titles in index order (one title per index: every copy of a run repeats the run's title; in a hidden sale the index order is the pool order of §13.2). `name`, `symbol` and `story` are the strings the processor was created with; the reference registry computes their hashes on chain from the launch parameters (`metadataOf(name, symbol, story, titlesHash)`, `0xe2e2bef0`), so the commitment cannot disagree with the processor, and the launcher supplies only `titlesHash`, which MUST NOT be zero.

1. `metadata` MUST be fixed at launch and MUST NOT change.
2. A curator MUST publish the name, symbol, story and every title together with the work list.
3. A front-end SHOULD show a collection's name, symbol, story and titles only after rebuilding `metadata` from them and comparing it with `collectionOf(circuits).metadata`, and MUST NOT present them as the curator's if they do not match.

### 11. Token metadata and images (optional)

TapeOut's processor contracts return an empty `tokenURI` for every circuit and give a processor's creator no way to set one, so a circuit NFT has no name, image or attributes in any wallet or market. A registry MUST therefore implement the functions below; a curator MAY record one **content-addressed** metadata directory per collection at launch, and the registry answers `tokenURI` for official circuits:

| Function / event | Selector / topic 0 | Meaning |
|---|---|---|
| `tokenURI(address circuits, uint256 tokenId)` | `0xe9dc6375` | for an official circuit, its own file if one was declared (instant reveal, §13.6), else `"<metadataURI>/<index>.json"`, where `index` is its work-list position (`editionOf`); `""` for a circuit that is not official, or when there is neither |
| `metadataURIOf(address circuits)` | `0x9eac0ca2` | the collection's directory: `"ipfs://<CID>"`, `"ar://<transaction id>"` or `""` |
| `MetadataURISet(address indexed circuits, string uri)` | `0xf4ea916416710952791c00e6c397903c99c416633fd82eeb8f5786572a9d899c` | emitted once: in the launch transaction (instant tape-out) or in the reveal (blind box) |
| `TokenURISet(address indexed circuits, uint256 indexed tokenId, string uri)` | `0x7e2a04aa388921ad0859b09b5255b044773bb1782dd70ac3b1db0031e7fd054d` | emitted with the tape-out of an instant-reveal circuit that has its own metadata file |

1. The directory MUST be declared at most once and MUST NOT change: at launch in an instant tape-out (a collection launched without one never gets one), in the reveal of a blind box (§13.5), never in an instant reveal, whose circuits each get one content-addressed file, declared once in the transaction that tapes the circuit out (`declareTokenURI`, callable only by the vault). Nobody, including the curator, can change either later.
2. The directory MUST be content-addressed, so that its content cannot change either: `"ipfs://"` followed by a CID of immutable content (CIDv0, `Qm` + 44 base58 characters, or CIDv1 in lower-case base32 beginning `bafy` or `bafk`, which covers dag-pb, dag-cbor and raw data with any hash, 50 to 100 characters; no path, no other encoding, never a libp2p-key CID, which names an IPNS record), or `"ar://"` followed by a 43-character Arweave transaction id (base64url) that contains at least one upper-case letter (typically the id of an Arweave path manifest). ArNS names and undernames are lower case, so the upper-case rule keeps a 43-character name from ever passing as an id; a random id lacks an upper-case letter with probability about 2 × 10⁻¹⁰, and an uploader that draws one can re-sign the file. Mutable names (IPNS, DNSLink, ENS, ArNS) and `http(s)` URLs MUST be refused. The reference registry checks this on chain (`isContentAddressed(bytes)`, `0x9bdfd89c`) and reverts the launch otherwise.
3. `tokenURI` MUST return `""` for circuits that are not official, so REF wrappers and copies never show a work's image.
4. The file `<index>.json` SHOULD follow the ERC-721 metadata JSON schema (`name`, `description`, `image`, optionally `animation_url` and `attributes`). Its `name` SHOULD equal the committed title of work `index` (§10), and its `image` and `animation_url` SHOULD themselves be content-addressed (`ipfs://…` or `ar://…`, optionally with a path of plain segments: letters, digits and `. _ ~ -`, no `.` or `..` segment and no percent-encoding, so a link cannot climb out of its content-addressed root). The reference tool also writes `properties` with the work's `index` and `netlistHash`, which ties the image to the circuit design.
5. A front-end SHOULD read a circuit's metadata only through the registry's `tokenURI`, SHOULD show only content-addressed images, and MUST NOT treat the presence of metadata as evidence that a circuit is official (§7.2); `isOfficial` decides that.

Because the directory is fixed before the first sale, the curator uploads it before launch: first the images (each gets its own content address), then one `<index>.json` per work that links to them, then the directory. A launch that stores the directory costs about 90,000 gas (an `ar://` id) to 105,000 gas (a CIDv1) more than one without, measured on a mainnet fork. Storage of the files themselves is outside the chain: Arweave stores them permanently for a one-off fee; IPFS needs at least one party, the curator, a platform or a holder, to keep the files pinned, and anyone holding a copy of the files can re-publish them under the same CID. Collections whose images are computed from the netlist itself MAY instead point `animation_url` at a renderer stored on chain or on Arweave.

### 12. Recommendations to TapeOut (informative)

This section makes recommendations to TapeOut, not requirements of this standard; nothing else in this TAP depends on them.

#### 12.1 Token metadata from the processor's creator

Wallets and markets that read only an NFT contract's own `tokenURI` cannot see a registry. TapeOut can make every curated collection's metadata visible everywhere, without trusting any particular registry, with one change to the shared processor implementation behind its beacon. Example (informative):

```solidity
interface ICircuitURIProvider {
    function circuitURI(address circuits, uint256 tokenId) external view returns (string memory); // 0xcd51078c
}

function tokenURI(uint256 id) public view returns (string memory) {
    _requireOwned(id);
    address creator = transistors.creator();
    if (creator.code.length == 0) return "";
    // low-level calls: try/catch would not catch return data that fails to decode
    (bool ok, bytes memory r) = creator.staticcall{gas: 30_000}(
        abi.encodeCall(IERC165.supportsInterface, (type(ICircuitURIProvider).interfaceId)));
    if (!ok || r.length < 32 || abi.decode(r, (uint256)) != 1) return "";
    (ok, r) = creator.staticcall{gas: 200_000}(abi.encodeCall(ICircuitURIProvider.circuitURI, (address(this), id)));
    if (!ok || r.length < 64) return "";
    (uint256 offset, uint256 length) = abi.decode(r, (uint256, uint256));
    if (offset != 32 || length > r.length - 64) return "";
    return abi.decode(r, (string));
}
```

The processor asks its own creator, which is fixed when the processor is created: for a processor whose creator does not declare `ICircuitURIProvider` (any ordinary wallet) nothing changes, and a curated collection's creator is its vault, which has no owner and answers with the registry's `tokenURI` (official works only, fixed at launch). TapeOut need not whitelist registries or judge collections. The gas limits keep a faulty creator from making `tokenURI` expensive, and every failure (a call that reverts, runs out of gas, or returns data that is too short or malformed) returns `""`, which is today's behaviour. A production implementation would also copy at most a few kilobytes of return data (in assembly, since a plain `staticcall` copies all of it), so a creator cannot return an oversized string. The reference vault already implements `ICircuitURIProvider` and ERC-165, so existing curated collections would show their metadata as soon as TapeOut adopted the change.

#### 12.2 Letting a processor's creator restrict tape-outs to itself

Anyone can tape out a pure-REF wrapper into any processor without transistors (§4, Motivation). Such wrappers are never official, but they appear in the collection's contract, look like its works, and take TapeOut circuit ids, so after the first one the official serial (§3) and the TapeOut id of later works differ. No protocol built on today's processors can prevent this. TapeOut could let a creator opt in to a processor that only its creator can tape out on:

```solidity
bool public tapeoutRestricted;                          // 0x… view, false by default
event TapeoutRestricted();

/// One-way: once set, it can never be cleared.
function restrictTapeoutToCreator() external {           // 0x9051fb27
    require(msg.sender == transistors.creator());
    tapeoutRestricted = true;
    emit TapeoutRestricted();
}

// at the start of tapeout(...):
//     if (tapeoutRestricted && msg.sender != transistors.creator()) revert NotCreator();
```

For a curated collection the creator is its vault, so after the change nothing but official works could ever enter the processor, and the serial would always equal the TapeOut id. Assessment: the change touches only who may create circuits in one processor. It changes nothing for processors that do not opt in (the default), nothing about existing circuits, and nothing about REF: circuits of a restricted processor can still be used as REF targets from other processors, and nothing that reads circuits (evaluation, mining, REF resolution, ERC-6551 accounts) needs to know about it. It must be one-way, or a creator could lift the restriction once buyers rely on it. A creator that is an ordinary wallet could restrict its own processor too; that is its choice and affects only its own collection. The reference vault already calls `restrictTapeoutToCreator()` right after creating its processor (§4), with a gas limit and ignoring failure, so every collection launched after TapeOut adopted the change, with this exact selector and meaning, would be restricted from its first block, without a new registry.

#### 12.3 Deferred tape-out (assessment)

A blind-box pass (§13.4) is a second NFT because a TapeOut circuit exists only once it is taped out, and taping out publishes the netlist. TapeOut could instead let a processor's creator mint a circuit first and write its netlist later: `reserve(to)` would mint a circuit id to `to` with no netlist and burn no transistors, and `fill(id, netlist, nIn, nOut)` could be called once, only by the creator, and would then burn the netlist's transistors and fix it forever. A blind box would then be the circuit itself: same contract, same id before and after opening, so every listing and offer would carry over, and a project would have one collection instead of a pass contract and a processor.

This is feasible only as an upgrade of TapeOut's processor implementation, which is TapeOut's decision. It would have to guarantee, for a circuit that is reserved but not filled: `eval`, `step` and `circuitInfo` revert or say so explicitly, `netlist` is empty; it is not a valid REF target at tape-out (REF checks read the target's pins, which do not exist yet; otherwise a circuit could depend on behaviour fixed later); mining and any other feature that reads a circuit's netlist or behaviour ignore it; and `fill` checks the netlist exactly as `tapeout` does, so a netlist that cannot be taped out (for example above the size limit) is refused before anything is reserved for it by the tools. Indexers and markets would have to show unfilled circuits as unopened, and TAP-02 would need to describe the new state. For this protocol, a deferred-tape-out blind box would be a new vault implementation, used by a new registry deployment next to the current one (a registry's implementations are fixed, §4.1); certification would move to `fill`, which is when the work exists. Collections already launched would keep their passes. We recommend TapeOut evaluate it together with §12.2, but nothing in this TAP depends on it; the pass of §13.4 works on today's contracts.

### 13. Hidden sales (sale modes 1 and 2)

In an instant tape-out the work list is public before the sale, so anyone can see which work is rare, and a buyer who names the work it buys can take only the rare ones. In the two hidden modes a buyer buys a **slot** in a **price pool** and cannot choose the work; which work a slot gets is decided by randomness committed at launch, so that the buyer cannot predict it and neither the curator nor the platform that delivers the works can choose it. Works not yet taped out stay unpublished. Taping out a work publishes its netlist, so the work is taped out only after its slot's randomness is fixed, in a second transaction sent by whoever holds the unpublished works (in practice the platform's server) or, in a blind box, by anyone after the reveal. A vault that implements a hidden mode MUST follow §6 rules 1–9 and this section.

#### 13.1 Pools and slots

At launch the curator fixes the pools, `poolPrices` and `poolCounts` (at most 64 pools, each with at least one work), and `count = Σ poolCounts + reserved`. Pool `p` holds the work indexes `[start_p, start_p + count_p)` with `start_0 = 0` and `start_{p+1} = start_p + count_p`; reserved works come after all pools. The pools, their prices and counts are public (`poolPrice(p)`, `poolCount(p)`, `poolStart(p)`, `poolSold(p)`; `POOLED()`, the number of works in all pools).

`buySlot(uint32 pool, address recipient)` (`0x10431d45`) sells the pool's next slot: the buyer pays `poolPrice(pool) + circuits.TAPEOUT_FEE() + REVEAL_FEE()` in the native coin (with a payment token, the price in the token and the two fees in the native coin). The price is paid out at once (§6.7); the two fees stay in the vault for this slot. Slots are numbered from 1 across all pools in purchase order; `slots(slot)` (`0x387dd9e9`) returns `(holder, boughtBlock, pool, pos, state, paid, feeHeld)`, where `pos` is the slot's position among its pool's slots and `state` is 1 pending, 2 delivered, 3 refunded. The presale works as in §6, with `buySlotPresale(pool, recipient, quota, tier, allowProof, presalePrice, presaleProof)` (`0xb49665be`) and presale prices per pool: `keccak256(bytes.concat(keccak256(abi.encode(uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-presale-pool-price"), bytes32 root, uint256 pool, uint32 tier, uint256 presalePrice))))`, never above the pool's price. Per-wallet limits, pausing and extending apply as in §6. Event: `SlotBought(uint256 indexed slot, uint32 indexed pool, address indexed recipient, uint256 price)`.

#### 13.2 The hidden work list

The leaf of work `index` is

```
hiddenLeaf = keccak256(bytes.concat(keccak256(abi.encode(
    uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-hidden-work"),
    uint256 index, bytes32 keccak256(netlist), uint32 nIn, uint32 nOut, uint32 pool, bool reserved))))
```

with `pool = 2³² − 1` for a reserved work. The root is a **positional** tree, not a sorted-pair tree: with `d` the smallest integer such that `2^d ≥ count`, leaf `i` sits at position `i` of `2^d` positions, unused positions are `bytes32(0)`, each parent is `keccak256(left ‖ right)`, and a proof is exactly `d` siblings, combined in the order given by the bits of the position. The vault verifies every work at the position equal to its index (`WORK_DEPTH()` is `d`). A positional tree holds exactly one leaf per index; a sorted-pair tree could hold a second leaf for the same index, which nobody could see before the reveal and which would let whoever delivers choose between two works. The same construction is used for the slot secrets (§13.3) and for `metadataRoot` (§13.5).

The curator MUST NOT publish the netlists or titles of works before they are taped out, and MUST publish every leaf (designs, titles, pools, reserved flags), the metadata contents of §13.5 and, in an instant reveal, every slot secret, once the sale is over (sold out, or the sale end has passed). Verifiers then rebuild the root, `metadataRoot` and `secretsRoot`, recompute every draw or assignment from the chain's records, and compare each delivered circuit with the work it should have been. Until then, buyers rely on the commitments: nobody can deliver a work that is not in the list, or a work other than the one the randomness selects.

#### 13.3 Instant reveal (sale mode 1)

At launch the curator fixes `secretsRoot` (`SECRETS_ROOT()`, `0x105a4a9d`), the positional root (§13.2, depth `SECRET_DEPTH()`) of one secret per slot, slot `k` at position `k − 1`, with leaf `keccak256(bytes.concat(keccak256(abi.encode(uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-slot-secret"), bytes32 root, uint256 slot, bytes32 secret))))`. The tools generate the secrets at random; only the party that delivers the works (the platform's server) holds them.

From the block after the purchase block on, `fulfill(slot, secret, secretProof, work, uri)` (`0x0641cb89`, `work` = `(index, netlist, nIn, nOut, proof)`) draws the slot's work and tapes it out to the slot's holder:

1. Slots of one pool are served strictly in purchase order (`NotItsTurn` otherwise); pools are independent.
2. `h` is the hash of the block after the slot's anchor block (the purchase block, unless the slot was re-anchored, below): the value locked for it if any, else `blockhash(anchor + 1)`. If that hash was never locked and is no longer available (more than 256 blocks later), the slot cannot be drawn (`HashExpired`) until it is re-anchored.
3. `seed = keccak256(abi.encode(secret, h))`; with `r` the number of works the pool has left, `j = uint256(seed) mod r`. The pool's remaining positions form an array, initially `0 … count_p − 1`; the drawn position is element `j`, which is replaced by the last element, and the array shrinks by one ("swap and pop"). The drawn index is `start_p` plus the drawn position. `Drawn(uint256 indexed slot, uint256 indexed index)` records it.
4. The caller passes the drawn work and its proof; the vault checks both (`WrongWork(expected)`, `InvalidProof`), tapes it out, certifies it, and sends it to the holder with a plain `transferFrom`, so a holder contract cannot block its pool's queue. `uri` (optional) is the work's own content-addressed metadata file (§11); a circuit delivered without one can get it later, once, from the curator (`declareURI(slot, uri)`, `0x0d061062`). `circuitOfSlot(slot)` (`0xc64c35e2`) returns the circuit.

The buyer cannot predict `h` when buying, and the server, whose secrets are fixed at launch and served in a fixed order, cannot choose the outcome once `h` is known: it can only deliver or not. Because `blockhash` is available for 256 blocks only, the vault keeps a hash once anyone locks it, so that waiting changes nothing: every purchase, every `fulfill` and every `lockHash(slot)` (`0x0448662b`, anyone may call) locks the next hash of every earlier anchor block that exists (`lockedHash(blockNumber)`). If nobody acts for 256 blocks, the hash is gone; anyone may then call `rearm(slot)` (`0x57e12865`, event `Rearmed(uint256 indexed slot, uint256 anchorBlock)`), which makes the current block the slot's anchor. No fixed fallback value is used, because the holder of the secret would know the outcome under it in advance and could choose it by waiting; a re-anchor gives the server a second outcome only if nobody locked the hash for 256 blocks while the whole pool's queue stood still, which is visible on chain.

Refunds are possible only once the sale is over (every pool sold out, or the sale end passed), never during it. The curator may then refund the next slot of a pool with `refundPending(slot, secret, secretProof)` (`0x7660c334`) only when it can no longer be delivered because `TAPEOUT_FEE()` has risen above what it holds (§13.6; anyone may instead top it up, `topUp(slot)`, `0x50017f3e`), sending exactly the slot's price with the call (native coin) or approving it to the vault (token). Refunds are limited to that case because the curator, through the platform, can compute a slot's draw before delivering it, and could otherwise refund exactly the buyers who drew rare works. The draw is made exactly as in a delivery and the drawn work is withdrawn from sale, so a refund changes no other slot's outcome and cannot be used to keep a particular work back; the holder receives the price, the tape-out fee and the reveal fee. There is no refund a buyer can request, and no automatic refund.

#### 13.4 Blind box (sale mode 2)

The vault is itself the ERC-721 contract of the collection's passes: name "<collection name> · blind box", symbol "<symbol>BOX", pass id = slot id. Each slot mints a pass to the recipient; passes are transferable (`transferFrom`, `safeTransferFrom`, approvals) until they are redeemed, and are never frozen. `isBlindBoxPass(vault)` of the registry is true. `tokenURI(pass)` is `PASS_URI` (a content-addressed file fixed at launch, or `""`) until the seed is fixed, then `"<metadataURI>/<index>.json"` of the work the pass will become, so every market shows the real result before redemption.

At launch the curator fixes `SECRET_HASH()` (`0x7975d3cf`) `= keccak256(abi.encode(secret))`. Once every pool is sold out or the sale end has passed, and at any time after that (there is no deadline), the curator calls `reveal(secret, metadataURI)` (`0x66d8c463`), which checks the secret, records it and the reveal block, and declares the collection's metadata directory (§11). The seed is fixed from the block after the reveal: `seed = keccak256(abi.encode(secret, blockhash(revealBlock + 1)))`, by `fixSeed()` (`0x0326fe7e`, event `SeedFixed(bytes32 seed)`), which anyone may call and which the first redemption calls. If nobody did within 256 blocks, the hash is gone and `fixSeed` instead makes the current block the anchor (`Rearmed(uint256 anchorBlock)`), for the same reason as in §13.3. Whoever reveals has published the secret before the hash exists, so cannot know or retry the outcome, unless nobody at all fixes the seed for 256 blocks; the platform does it in the block after next. The pass of slot `s` (pool `p`, position `pos`) is assigned

```
index = start_p + permute(pos, count_p, keccak256(abi.encode(seed, p)))
```

where `permute(x, n, key)` (`0x65fef13f`) is a 4-round Feistel network on `2k` bits, `k ≥ 1` the smallest with `4^k ≥ n`: split `x` into `l = x >> k` and `r = x & (2^k − 1)`, repeat four times `(l, r) = (r, l XOR (uint256(keccak256(abi.encode(key, round, r))) & (2^k − 1)))` for `round = 0 … 3`, set `x = (l << k) | r`, and repeat the whole network ("cycle walking") until `x < n`. It is a bijection of `[0, n)`, so the passes of a pool get distinct works; when a pool did not sell out, the unsold positions' works are never taped out. `assignedIndex(pass)` (`0xa36742d6`) returns the result.

`redeem(ids, works)` (`0x49851038`) may be called by anyone, in batches: for each pending pass it checks that the work is the assigned one, burns the pass, tapes the work out and sends it to the pass's holder at that moment, all in one transaction, so at any time a slot is either a pass or a circuit, never both. Delivered or refunded passes in a batch are skipped. `circuitOfSlot(pass)` returns the circuit, which markets use to carry a listing of a pass over to its circuit.

Once the sale is over (every pool sold out, or the sale end passed), never during it, the curator may refund passes with `refund(ids)` (`0xaa613df5`), sending exactly their prices with the call (native coin) or approving them (token): any unredeemed pass before the reveal, and after it only a pass that can no longer be redeemed because `TAPEOUT_FEE()` has risen above what it holds, so that a curator who knows the assignment cannot pick which buyers lose their works (a holder can protect its pass by topping it up, `topUp`, and redeeming it). The holder receives the price, the tape-out fee and the reveal fee; the pass is burned and its work is never sold.

#### 13.5 Metadata of hidden sales

At launch the curator fixes `METADATA_ROOT()` (`0xb11bc14f`), the positional root (§13.2) of one leaf per work committing to the content of its metadata, not to a file (the image's address is known only after the upload):

```
metadataLeaf = keccak256(bytes.concat(keccak256(abi.encode(bytes32 keccak256("TAP-curated-metadata-leaf"),
    uint256 index, bytes32 keccak256(bytes(title)), bytes32 keccak256(bytes(description)),
    bytes32 keccak256(attributes), bytes32 imageSha256))))
```

where `attributes` is the UTF-8 JSON array `[{"trait_type":…,"value":…},…]` in list order, keys in that order, without spaces and without escaping non-ASCII characters (what `JSON.stringify` produces), and `imageSha256` is the SHA-256 of the image file (zero if none). The vault stores the root; checking files against it happens off chain. In an instant reveal, the server uploads each work's image and metadata file when it delivers the work and passes the file to `fulfill`, and the registry's `tokenURI` returns that file for that circuit (`declareTokenURI(circuits, tokenId, uri)`, `0x98cb20bd`, vault only, once, content-addressed); the remaining works are uploaded once the sale is over. In a blind box, the curator uploads every file before the reveal and passes the directory to `reveal`.

#### 13.6 Reveal fee

The transactions that tape out hidden works are sent by someone other than the buyer, so the buyer prepays their gas: every slot carries `REVEAL_FEE()` (`0xc9cd5d7a`), a native-coin amount fixed at launch (tools estimate it from the largest netlist of the pool, a reference gas price and a margin). At delivery the slot's budget is the tape-out fee it paid plus the reveal fee, minus `TAPEOUT_FEE()` at that moment (`FeeShortfall` if negative). The caller is repaid `min(gasUsed × min(tx.gasprice, REVEAL_GAS_PRICE), budget)` and the rest goes to the holder in the same transaction (kept in `owedNative` if it cannot be received). `REVEAL_GAS_PRICE()` (`0xb5edbfbb`) is a launch parameter (`revealGasPrice`, not zero; tools default it to the price at which the reveal fee just covers the largest work), so a caller cannot take a slot's budget by bidding a high gas price, which a block producer including its own transaction could do at no cost. `gasUsed` is, for `fulfill`, the gas the call used plus 21,000 plus 16 gas per byte of the call data the delivery needs (the netlist, 32 bytes per proof element, and 640 bytes for the rest); for `redeem`, each pass's own gas and needed call data plus an equal share of the rest of the transaction. Call data padded with extra bytes is therefore not repaid. Anyone may add to a pending slot's fees with `topUp(slot)` (`0x50017f3e`). A slot's reveal fee never pays for another slot. If gas is more expensive than the budget covers, the server can wait for cheaper gas or top the slot up. A refunded slot returns its reveal fee and any top-up in full.

#### 13.7 Reserved works and finalize

Reserved works of a hidden sale are claimed with `claimReservedBatch(works)` (`0x8549fef1`, curator only) only once every pool is sold out or the sale end has passed (a claim publishes the netlist), and only at indexes after the pools. `finalize` additionally requires every slot to be delivered or refunded; in a blind box with passes left that means after the reveal.

#### 13.8 Who must be trusted for what

Nobody can deliver a work that is not in the committed list, or the same index twice, and the buyer cannot choose or predict its work. What remains is stated here so that front-ends can say it plainly:

1. **Availability.** In an instant reveal, the party holding the secrets and the unpublished works can delay or stop deliveries; in a blind box, the curator decides when to reveal and may never reveal. The buyers' payments have already been paid out (§6.7), so only the curator can refund, and only in the cases of §13.3 and §13.4.
2. **Waiting past 256 blocks.** The secret's holder cannot choose an outcome once the hash exists, except by preventing anyone from locking it (instant reveal) or fixing the seed (blind box) for 256 blocks and then re-anchoring. Every purchase and delivery locks hashes, anyone can, and the platform should within a few blocks; a stall shows on chain (a pool's queue stands still, `Rearmed` is emitted).
3. **Source of randomness.** The draws use block hashes, the randomness the chains offer today; a chain with a reliable verifiable random function could replace the block hash without changing the rest of this section.
4. **Fees.** A reveal fee set too low, or a tape-out fee raised by TapeOut, delays deliveries until someone tops the slot up.

The published list, once the sale is over, lets anyone check every delivery after the fact (§13.2).

## Rationale

**Provenance, not content.** Two of the three kinds of foreign circuit cannot be told apart from official ones by anything the processor contract exposes except raw netlist bytes, and one of them has identical bytes. The only property that separates official from foreign circuits in every case is who taped the circuit out. Recording it at tape-out time makes it a fact anyone can read without trusting the curator's later word or an indexer.

**Why the curator must launch personally.** An internal review of the reference implementation found that, without this rule, anyone could launch a collection naming a real artist as curator, reuse the artist's root, and have its circuits certified as official; or reuse the artist's root under its own name. Requiring `curator == msg.sender` closes the first path, and binding leaves to the curator closes the second. A platform that runs launches for artists can still do so by having the artist sign the launch transaction.

**Why reserved works are fixed at launch.** Projects often keep part of a collection for a treasury, to give away, airdrop or reward contributors later. If the curator could decide afterwards which works to keep, it could take the most sought-after pieces once demand is visible. Marking reserved works in the leaves, and fixing the treasury and the reserved count at launch, makes the split public and binding before anyone buys. Sending every reserved work to one fixed treasury, rather than straight to arbitrary recipients, keeps the reserve easy to audit: every later gift or airdrop is an ordinary, visible transfer out of that address.

**Why the royalty is only a declaration.** Royalties cannot be enforced on circuits: the NFT contract belongs to TapeOut, so a curator can neither add ERC-2981 to it nor restrict transfers in the way ERC-721C does, and anyone can trade around a market. Across NFTs, ERC-2981 itself is advisory for the same reason. What a shared protocol can usefully add is one public place, next to the officialness record that markets already read, where the curator's terms are stated and cannot be raised after people have bought. Collecting the royalty is left to platforms. Fees a platform charges for its own services are not part of this TAP; only the optional primary-sale share (`platform`, `platformBps`) is, because it is paid by the vault.

**Why reserved works survive the sale end.** A first version closed reserved claims with the sale, which made a forgotten claim a permanent loss. Keeping claims open until the leftover supply is burned, and delaying the burn only while reserved works are unclaimed and only for a fixed period, removes that loss without letting anyone keep the supply unburned forever. The grace period gives the curator no new power: it can only tape out the works the list already marks as reserved, to the treasury fixed at launch.

**Why titles are committed as a hash.** Storing every title on chain would cost gas per byte for text that only front-ends read. A single hash, fixed at launch, makes any change detectable at the cost of one storage slot. Name, symbol and story are hashed by the vault from the launch parameters, so the commitment always describes the processor that was actually created.

**Why metadata is a directory fixed at launch, not images on chain.** An NFT without an image is of little use to most collections, but storing images on chain costs about 216 gas per byte (measured on BNB Smart Chain): a 700 KB animation costs about 150 M gas, and a collection of thousands of works would need hundreds of blocks' worth of gas. A content-addressed directory costs one short string on chain, and its address is itself the hash of every file in it, so committing the address commits every file in it, and every image the files link to by content address (§11.4), as firmly as the root commits the netlists. Fixing it at launch keeps the guarantee buyers get from the rest of this TAP: what they see before buying cannot be swapped afterwards, not even by the curator. Mutable names are refused because a name is a pointer whose owner can repoint it. Returning `""` for circuits that are not official keeps images, like royalties, attached to provenance rather than to netlist content.

**Why the vault answers for its processor.** The processor's creator is the only party TapeOut already associates with each processor, and a curated vault is that creator by construction (§4.4). Asking the creator lets TapeOut support every curated collection, and any future scheme, without choosing which registries to trust.

**Why the curator can pause and extend a sale, but not shorten or reopen it.** Projects sometimes find a problem during a sale, a broken page, a wrong announcement or a market event, and need to stop buying for a while or give buyers more time. Pausing and extending change only when the listed works can be bought: they add no work, change no price and touch no circuit already sold, so buyers keep exactly what they were promised. Shortening a sale or reopening an ended one would break what buyers could rely on, namely that the works stay buyable until the announced end and never again after it, so neither is possible.

**Why one registry per chain, and no cross-chain officialness.** TapeOut runs a separate factory on each chain, and a processor, its transistors and its circuits exist on one chain only (BEM and miners can be bridged; processors and circuits cannot). A registry is therefore deployed per chain and bound to that chain's factory, so the launch checks of §4 are made against the chain the collection lives on. Work-list and allowlist leaves include the chain id (§5, §6), so a work list or allowlist built for one chain cannot be used on another, even by the same curator with a registry at the same address. A curator who wants the same works on several chains launches one collection per chain; each is official only on its own chain. A single registry that accepted certifications from other chains would need a bridge or an oracle and would no longer be checkable with a read-only call.

**Why the curator cannot be changed.** No one, including the curator, can change the curator address after launch, and there is no recovery path for a lost key. Any such path would be a privilege that could be stolen or abused, and buyers would have to trust whoever holds it. A curator that wants protection against losing a single key can launch from a multi-signature wallet.

**Why the vault tapes out, not the buyer.** If buyers taped out with transistors they were given, the registry could not tell their circuits from copies taped out with the same transistors. Keeping every transistor in the vault means that nobody else can tape out anything into the processor except pure-REF netlists, which cost no transistors. These include byte-identical copies of any listed work that is itself pure-REF (see Security Considerations), and none of them is ever certified.

**Why the registry re-checks everything at bind.** A registry that trusted the vault's word would make the guarantee only as strong as the least careful vault. The checks in §4 are cheap view calls and make the launch guarantee hold regardless of vault code, given that the vault came from this registry.

**Why not a wrapper collection.** A second ERC-721 that wraps official circuits would give markets a collection that looks clean without integration, but it must hold every work indefinitely, which concentrates risk; and a wrapped circuit is owned by the wrapper, so the buyer loses control of the circuit's container account (ERC-6551) and is not shown as the owner on TapeOut. A registry holds nothing. A wrapper can be built on top of this registry later, as an option for holders.

**Why a Merkle root fixed at launch.** It makes the full work list, and every price, binding before the first sale. A curator cannot add works later or quietly replace a design with another version.

**Why byte-equality with the tapeout.net editor is not required.** Officialness comes from the certified tape-out, not from re-deriving the netlist. The leaf commits to exactly the bytes the vault tapes out.

**Why presale prices are a separate list.** Projects often reward their allowlist with a lower price, sometimes with different prices for different lists. Putting a second price into each work leaf would allow only one presale price per work and would change the work-list format; a separate list of `(index, tier, price)` keeps the work list as it is, allows any number of tiers and any absolute price per work and tier, and is fixed at launch like the work list. The vault re-checks on chain that no presale price exceeds the work's own price, so a mistaken or hostile list can never make the presale cost more than the public sale.

**Why prices may be in a token, while tape-out fees stay native.** Communities on TapeOut often want to sell in their own token (for example BEM) rather than in the chain's coin. TapeOut's `tapeout` and `createCPU` charge their fees in the native coin and cannot be changed by this TAP, so a token sale still needs a small native payment; the vault keeps the two apart (`msg.value` is exactly the tape-out fee) so neither can be mistaken for the other. The token is a launch parameter rather than a list in the registry, so no one has to approve tokens and a token that appears on a chain later can be used without deploying anything; the price of this freedom is that a curator can pick a token that misbehaves, which affects only that collection (see Security Considerations). Exact-amount receipt is required because a fee-on-transfer token would otherwise let the vault credit payees with tokens it never received, and the last withdrawal would fail.

**Why proceeds are paid out at once, with a fallback.** Artists asked for sale income to reach them as each work sells, not to wait in a contract until someone withdraws it. Pull payments were used before because a direct transfer that fails (a payee contract that rejects the coin, a token that blocks an address) would make every purchase fail and stop the sale. Paying out directly with a gas-limited call, and keeping only a failed amount for its payee, gives both: income arrives at once, and no payee can stop the sale. The payee is separate from the curator so that a project can receive income in a multisig while the curator key launches and runs the sale, and it can be changed because receiving addresses change; the curator, who cannot be changed, decides.

**Why serials, and why sequential sales.** Holders call a work "#N", and in most collections they expect #N on the project's site, in markets and on TapeOut to be the same circuit. A work-list index cannot be that number when buyers pick works in any order, because TapeOut numbers circuits in tape-out order. The registry therefore records the order of official tape-outs as the serial, which equals the TapeOut id until someone injects a wrapper, and a sequential sale makes the index, fixed in advance, equal to that order. Runs of copies keep the most common kind of project, one design sold thousands of times, to one leaf per design, and let the tools store the design once. Reserved runs come first because a later reserved run would either stop the sale or, once the sale ended unsold, be unreachable.

**Why hidden sales are two modes.** Some projects want buyers to see their work at once, others want the suspense of a blind box that opens when the sale is over; both need the same guarantee that no one can see or pick the rare works. Taping out publishes the netlist, so in both the work can only be taped out after the buyer paid and the randomness was fixed, by a second transaction. An instant reveal does that per slot, one block later, with a secret per slot so that the outcome cannot be computed from public data; a blind box does it once for all slots after the sale, and needs a transferable pass in the meantime, because the circuit does not exist yet (§12.3 describes how TapeOut could remove that need).

**Why the secret is published before the block hash in a blind box.** A design in which the curator requests a reveal at block B and then publishes the secret within 256 blocks would let the curator compute the outcome as soon as B + 1 exists and, if it dislikes it, not publish and request again. Publishing the secret first and taking the hash of the following block leaves the curator nothing to retry. The instant reveal achieves the same with secrets fixed at launch and a fixed serving order: the server knows its secrets but not the future hash, and once the hash exists it can only deliver what the draw selects.

**Why hashes are locked, and why an expired one re-anchors instead of falling back.** After 256 blocks a block hash is gone. A fixed fallback (for example zero) would be known in advance to whoever holds the secret, who could then plan for it, sell or buy the slots it favours, and choose it by waiting. Re-anchoring to a new block keeps every outcome unknown until its block exists. Locking every pending hash at every purchase, delivery or call of `lockHash` means that in practice nothing ever expires: an expiry needs 256 blocks in which nobody, not a buyer, not the platform, not a later purchase, touched the vault, while the pool's queue stood still for everyone to see.

**Why refunds void the drawn work, and why they are limited.** If a refunded slot's work went back into its pool, a curator who knows the secrets could refund slots that drew the rarest works and so steer them to later slots or keep them unsold for itself. Drawing first and withdrawing the drawn work means a refund changes nothing for anyone else. Even so, a curator who can compute a draw before it is delivered could refund exactly the buyers who drew rare works and so keep those works from ever existing; refunds are therefore allowed only when a slot cannot be delivered (TapeOut's fee rose above what it holds), and in a blind box also before the reveal, when the assignment is not known to anyone. In both modes refunds wait until the sale is over, so that the sale itself runs to its end on the terms buyers saw.

**Why the hidden lists use a positional tree.** In an instant tape-out every leaf is published before the sale, and anyone can see a second leaf for an index. In a hidden sale nothing is published until the sale is over, so a second leaf for an index, or a second secret for a slot, would let whoever delivers choose between them after seeing the block hash, and the choice would be discovered only afterwards. A tree in which every position holds exactly one leaf, and the vault checks the position, rules that out on chain at no extra cost.

**Why the reveal gas is prepaid by the buyer.** The transaction that tapes out a hidden work is not the buyer's, so someone else pays its gas. Asking the curator to keep a gas deposit in the vault would add a balance to manage and a way to stall all reveals; a fixed per-slot fee that the buyer pays with the slot, which repays the caller's actual gas and returns the rest to the holder, keeps every slot self-funded, never lets one slot pay for another, and costs the buyer about what a one-transaction tape-out would, because the expensive part, storing the netlist, only moves to the second transaction.

**Why vaults are clones.** Three sale modes need more code than one contract may hold (EIP-170). Fixing one implementation per mode in the registry, and creating each vault as an EIP-1167 clone of it, keeps each piece under the limit, makes a launch much cheaper, and keeps verification simple: a verifier checks the registry's code and the three implementations' code once, and a vault's code is the 45-byte proxy naming one of them.

**Why at most 10 % platform share and no admin.** A launch tool will often be run by a platform for an artist. Bounding the share and removing every admin path means the artist does not have to trust the platform after launch.

## Backwards Compatibility

This TAP changes no TapeOut contract. Existing processors cannot become curated collections under §4, because their transistors already circulate; their projects may publish signed lists of official ids in another TAP, but such lists are attestations by the project, not provenance guarantees, and are out of scope here.

During this work it was observed on mainnet that `circuits.nextId()` returns the number of circuits taped out so far (0 for a fresh processor, 1 after the first tape-out, whose id is 1), not "the id the next taped-out circuit will get" as TAP-02 §6 states. The reference registry uses `nextId() == 0` for condition §4.6. TAP-02 may want to correct its description.

## Test Cases

The reference implementation ships 82 Foundry tests (65 in `test/Curated.t.sol`, 17 in `test/Modes.t.sol`) that run against a fork of BNB Smart Chain, X Layer or Base mainnet (`forge test --fork-url https://bsc-dataseed.bnbchain.org`, `https://rpc.xlayer.tech` or `https://mainnet.base.org`); the tests pick that chain's factory and a work list built for it. The work list has seven throw-away test circuits produced by the reference tool: a toggle, a 4-bit counter, a 7-bit LFSR, an XOR, a REF work (on BNB Smart Chain, genesis circuit #13 with a parity output; on X Layer and Base, circuit #1 of processor `0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b` with an inverse output), and two works the list reserves for the treasury (the TAP-02 vector `popcount8_3151` and an AND gate with a non-ASCII title). `test/Modes.t.sol` uses three more fixtures built from the same circuits: a sequential collection of two reserved AND gates, five toggles and three XORs (`copies`), and an instant reveal and a blind box (`reveal`, `blindbox`) with a common pool of four works (three copies of the toggle and an XOR), a rare pool of two (the counter and the LFSR) and a reserved AND gate. All pass on all three chains (2026-11-01; the BEM test runs on BNB Smart Chain only and is skipped elsewhere); the contracts are the same on every chain. Gas figures and fees below are from BNB Smart Chain. Because free public nodes keep only recent state, the tests fork the latest block rather than a pinned one. The tests are:

| Test | What it shows |
|---|---|
| `test_Launch_AtomicAndVerified` | one transaction creates the processor, mints the full supply to the vault (non-zero mint price, 5 mint batches), binds, fixes the metadata directory, refunds the float; 1.83 M gas (the vault is a clone); the launcher pays exactly the 0.0015 BNB (on BNB Smart Chain) of factory and protocol fees (0.001 deploy fee + 5 × 0.0001) the tool predicted |
| `test_Launch_ZeroMintPrice` | the same with mint price 0 |
| `test_Launch_RejectsBadParams` | platform share above 10 %, sale end not after sale start, insufficient launch funds |
| `test_L2_LaunchFeeCap` | launch reverts when fees exceed the launcher's cap |
| `test_H1_CopycatLaunchRejected` | nobody can launch in another curator's name; a copycat that reuses the root as its own curator cannot sell any listed work |
| `test_L3_RefundReentryBlocked` | a curator account that tries to buy from the launch refund callback hits the re-entry guard (`ReentrancyGuardReentrantCall`), and nothing is sold |
| `test_L4_TokenOfAndEditionOfDefaults` | before a work is taped out `tokenOf` reports it as not taped out (never as id 0), circuits that are not official report `(false, 0)`, and after tape-out the work maps to its circuit id |
| `test_PayeesCannotBeVaultOrRegistry` | neither the treasury, the platform nor the payee can be the vault being created or the registry, and the payee cannot be zero |
| `test_BuyAll_CertifyPayFinalize` | all seven works: `Certified` emitted with the netlist hash, certified with the right index, owned by the buyer (the two reserved works by the treasury), netlist bytes as listed, transistors consumed exactly as predicted by the tool; every sale paid out at once to the platform and the payee, nothing left in the vault; leftover 9,814 NAND and 3 LATCH burned |
| `test_M1_FinalizeAfterSaleEnd` | after the sale end, buying stops; with reserved works unclaimed the burn waits for the grace period, then the leftover supply is burned although works remain unsold |
| `test_L1_RejectingPayeeAndWithdrawTo` | only the curator changes the payee; a payee contract that refuses the native coin does not block the purchase, its share is kept in `owed` and it sends it elsewhere with `withdrawTo`; others cannot; switching back to an account pays out directly again; the vault cannot be the payee |
| `test_R1_NoWayToExtractTransistors` | nobody can move, burn or mint the vault's transistors; finalize before sell-out and before the sale end fails |
| `test_R2_SameNetlistElsewhereIsNotOfficial` | the identical netlist taped out on another processor is not official; on the curated processor it cannot be taped out by others (`ERC1155InsufficientBalance`) |
| `test_R3_RefWrapperIsNotOfficial` | a stranger tapes out a 0-transistor REF wrapper into the curated collection; its `circuitInfo` equals the official circuit's; it is not official |
| `test_R4_EachWorkOnceAndStrictInputs` | second purchase of a work, tampered netlist, lower price, wrong proof, wrong pins, a valid work under another index, wrong payment, bad index, zero recipient |
| `test_R5_OnlyBoundVaultCanCertify` | strangers and vaults not deployed by the registry cannot bind or certify (a rogue vault tries both); no double certification; no index out of range |
| `test_R7_WorkListIsFixed` | the root is immutable; an unlisted netlist cannot be sold even with a real proof, index and price |
| `test_SaleStartIsEnforced` | no sale before `saleStart` |
| `test_Sale_CuratorCanPauseAndResume` | only the curator can pause; while paused nobody can buy, reserved claims still work; after resuming, buying works again |
| `test_Sale_PauseAlsoStopsPresale` | a pause also stops the presale, and resuming reopens it |
| `test_Sale_ExtendOnlyLaterWhileOpen` | only the curator can extend; the new end must be later; buying works past the old end and finalize waits for the new one; once the new end has passed the sale cannot be extended or reopened |
| `test_Token_BuyAndWithdraw` | in a collection priced in an ERC-20, a buyer pays the price in the token and only the tape-out fee in native coin (paying the price in native coin is refused, and so is a purchase without approval); the circuit is official; the payee and the platform receive their shares in the token at once and nothing is left in the vault |
| `test_Token_PresaleAndReservedUnchanged` | the presale works the same way in the token; a reserved claim still costs only the native tape-out fee |
| `test_Token_RefusesFeeOnTransfer` | a token that takes 1 % of every transfer is refused with `TokenAmountMismatch`, and the work stays unsold |
| `test_Token_FreeWorkAndParams` | a free work needs no approval; a payment token without code is refused at launch |
| `test_Token_BEMOnBSC` | on BNB Smart Chain, BEM (`0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a`, 8 decimals) works as the payment token: it has no transfer tax, and the payee receives its share in BEM (skipped on other chains) |
| `test_Token_NoReturnToken` | a token whose `transfer` and `transferFrom` return nothing (USDT style) works, also for the direct payouts; the registry is refused as payment token |
| `test_Token_FailedPayoutIsKept` | a token that blocks the payee does not block the purchase; the payee's share is kept in `owed` and withdrawn to another address |
| `test_Token_ReentrantTokenIsBlocked` | a token that calls back into the vault during a purchase or a payout is stopped by the reentrancy guard; nothing else is bought or paid |
| `test_Clones_FixedImplementations` | the registry names its three implementations; none can be initialised, a launched vault cannot be initialised again, its code is the EIP-1167 proxy of the instant implementation, and an unknown sale mode is refused |
| `test_Sale_NoControlsAfterFinalize` | after finalize the sale can be neither paused nor extended |
| `test_Limit_Unlimited` | with the “no limit” option, one wallet buys every public work |
| `test_Limit_CapsEachWallet` | with a limit of 2, a full wallet can no longer buy; buying for another wallet reverts in either direction and counts for nobody; transfers and reserved claims are not limited |
| `test_Royalty_OfficialOnly` | an official work reports the declared 3 % royalty; a REF wrapper in the same collection reports none |
| `test_Royalty_None` | a collection may declare no royalty, and then can never add one |
| `test_Royalty_CuratorCanOnlyLower` | the curator changes the receiver and lowers the rate; raising it, strangers and a second declaration are refused |
| `test_Royalty_ParamsChecked` | a rate above 5 %, a receiver without a rate, or a rate without a receiver is refused at launch; exactly 5 % is accepted |
| `test_Presale_AllowlistedWithinQuota` | an allowlisted wallet buys up to its quota in the presale, then no more |
| `test_Presale_OnlyAllowlisted` | strangers cannot use the presale, nobody can claim a bigger quota, and the public sale stays closed |
| `test_Presale_Window` | the presale opens at `presaleStart` and closes when the public sale opens; then everyone buys |
| `test_Presale_RespectsWalletLimit` | the per-wallet limit applies on top of the presale quota |
| `test_Presale_ParamsChecked` | no presale without an allowlist; the presale must start before the public sale |
| `test_PresalePrice_TiersPayTheirPrice` | each allowlist tier pays its own presale price (the fixture's first tier pays half for work 0; the second pays nothing but the tape-out fee); the curator and the platform are credited with what was paid and `Purchased` carries it; after the presale `buyPresale` is closed and `buy` charges the work-list price |
| `test_PresalePrice_ExactAmountForTheRightWork` | a price leaf for one work cannot buy another, and paying the public price when the presale price is lower is refused |
| `test_PresalePrice_FreeInTokenCollection` | in a token collection a free presale price needs no approval and moves no tokens |
| `test_PresalePrice_OnlyTheListedPriceForTheTier` | a wallet cannot use another tier's price, claim another tier, or pay an unlisted price |
| `test_PresalePrice_NeverAbovePublicPrice` | a presale price list that prices a work above its work-list price is refused on chain with `PresaleAbovePrice` |
| `test_PresalePrice_NoListMeansListPrice` | without a presale price list the presale sells at the work-list price only; a price list without an allowlist is refused at launch |
| `test_Limit_ParamsChecked` | a limit switched on without a number, or a number without the limit, is refused; the limit is readable on chain |
| `test_Reserved_PublicCannotBuy` | a reserved work cannot be bought, at price 0 or any other price |
| `test_Reserved_CuratorClaimsToTreasury` | only the curator can claim, before the public sale opens; the circuit goes to the treasury, is official and reserved, earns nothing, and cannot be claimed twice |
| `test_Reserved_TreasuryCanTransferAndItStaysOfficial` | the treasury gives the work away and the recipient passes it on; it stays official and reserved |
| `test_Reserved_CannotClaimPublicWork` | the curator cannot pull a public work into the treasury |
| `test_Reserved_DeclaredCountIsACap` | claims beyond the reserved count declared at launch fail, even if the tree held more reserved leaves |
| `test_Reserved_Params` | reserved works need a treasury, which cannot be the registry; the reserved count cannot exceed the work count |
| `test_Reserved_ClaimAfterSaleEndWithinGrace` | after the sale ends the curator can still claim a reserved work; finalize waits while one is unclaimed, until exactly the end of the grace period; then anyone can finalize and nothing more can be claimed |
| `test_Reserved_AllClaimedFinalizeAtSaleEnd` | once every reserved work is claimed, finalize works at the sale end without waiting |
| `test_Reserved_BatchClaim` | two reserved works claimed in one transaction to the treasury; strangers, a wrong total fee, a batch containing a public work (nothing is claimed) and a second claim are refused |
| `test_Metadata_Committed` | the registry records the metadata commitment computed by the tool (including a non-ASCII title); a different story gives a different value; a launch without a titles hash is refused |
| `test_Metadata_TokenURIOfficialOnly` | official works (bought and reserved) get `<directory>/<index>.json`; a REF wrapper of an official work, a missing circuit and another processor get `""`; the vault, which is the processor's creator, gives the same answer through `circuitURI` and declares `ICircuitURIProvider` via ERC-165 |
| `test_Metadata_FixedAtLaunch` | the directory cannot be declared again, by the vault or the curator |
| `test_Metadata_None` | a collection launched without a directory returns `""` for every circuit |
| `test_Metadata_OnlyContentAddressed` | `https` URLs, IPNS names (including an IPNS key written as a CID, in base36 and base32), ENS-style names, an ArNS name, a 43-character lower-case name, a CID with a trailing slash, ids of the wrong length, upper-case base32, a non-base58 character and an upper-case scheme are refused at launch; CIDv0, CIDv1 of dag-pb and raw data, and an Arweave id are accepted |
| `test_L5_RejectsStrayFundsAndTokens` | the vault refuses plain native coin, and refuses a real circuit of its own processor sent by a third party |
| `test_ReentrancyFromRecipientFails` | a recipient that re-enters `buy` makes the purchase revert with `ReentrancyGuardReentrantCall` |
| `test_Copies_SoldInOrder_SerialEqualsTapeOutId` | a sequential collection: nothing sells before the reserved run is claimed, unordered `buy` is refused, every copy is official with serial = TapeOut id = index + 1, a used-up run sells nothing more, every sale is paid to the payee |
| `test_Copies_InjectedWrapperShiftsTapeOutIds` | a stranger's REF wrapper takes a TapeOut id; the next work's serial is one less than its TapeOut id, and the wrapper has no serial |
| `test_Copies_PresaleByRun` | presale prices keyed by run start (the price list rebuilt here); the presale also sells in order |
| `test_Reveal_BuyDrawFulfill` | a slot costs price + tape-out fee + reveal fee and the price is paid out at once; no delivery in the purchase block; slots of a pool are served in order, pools independently; wrong work and wrong secret refused; the draw rebuilt here matches; the server's gas (about 575,000 for a small work) is repaid from the reveal fee and the rest returned to the buyer; the circuit has serial 1 and its own metadata file |
| `test_Reveal_HashLockAndRearm` | purchases in consecutive blocks and a later one lock both pending hashes, which still decide the draws 400 blocks later; a slot whose hash expired unlocked cannot be drawn, anyone re-anchors it, anyone locks the new hash |
| `test_Reveal_GasPriceCapAndTopUp` | a caller bidding 1,000 times the cap is repaid at most at the cap; a top-up by anyone; the rest goes to the holder; the curator adds a metadata file to a circuit delivered without one, once; the vault cannot be a recipient |
| `test_Reveal_RefundVoidsTheDrawnWork` | only the curator refunds, only after the sale and only when TapeOut's fee rose above what the slot holds, paying exactly the price back; the buyer gets price, tape-out fee and reveal fee; the drawn work is withdrawn and the next slot gets exactly its own draw |
| `test_Reveal_ReservedAfterSellOutAndFinalize` | reserved works cannot be claimed before sell-out; a pool sells at most its count; a pooled work cannot be claimed as reserved; every work is drawn once; finalize waits for every slot |
| `test_Reveal_ContractHolderCannotBlockThePool` | a holder contract that refuses ERC-721 transfers and the native coin still receives its circuit, the next slot is served, and its reveal-fee refund is kept for it |
| `test_Reveal_PresalePerPool` | presale prices per pool and tier (rebuilt here); a price for another pool is refused |
| `test_Reveal_ParamsChecked` | pools that do not add up, no pools, a pool price above 128 bits, no reveal gas price, a missing or extra commitment, a sequential or metadata-directory hidden sale, and hidden parameters in an instant tape-out are refused |
| `test_Box_PassIsATransferableNFT` | each slot mints a pass the registry recognises (ERC-721 and its metadata extension), with the unopened pass's URI; approvals and transfers work, the vault and a non-receiver are refused; no reveal before the sale is over |
| `test_Box_RevealAndRedeem` | only the curator reveals, only with the committed secret; the seed and the assignment are rebuilt here; each pool is permuted; passes show their result; a pass sold after the reveal is redeemed to its new holder; batches by anyone, repeated batches skip delivered passes; a wrong work is refused; the server's gas (about 390,000 per small work) is repaid; finalize after the reserved claim |
| `test_Box_SameBlockTradeAndRedeem` | in one block, a transfer then a redemption delivers to the new holder; a redemption then a transfer leaves no pass to transfer |
| `test_Box_Refunds` | no refund during the sale; after it and before the reveal the curator refunds a pass (price, tape-out and reveal fee back, pass burned); after the reveal only a pass that TapeOut's higher fee makes unredeemable; a reveal after the sale end with unsold slots |
| `test_Box_Vectors` | the permutation and seed test vectors below |
| `test_Box_SeedRearm` | a seed nobody fixed within 256 blocks re-anchors to a new block; the seed then comes from that block's successor, and redemption works |

Test vectors from the fixture `test/fixtures/manifest.json` (chain id 56, registry `0x00000000000000000000000000000000c0dec0de`, curator `0x00000000000000000000000000000000000c0ffe`), which any implementation of §5, §6, §10 and §11 must reproduce:

| Input | Expected output |
|---|---|
| work leaf (§5): index 0, netlistHash `0x7ca496e2d18c48a09aea26fc7df653df9c3fa5a10cb1a2bb7ec311c8220130b2`, nIn 1, nOut 1, price 10¹⁶ wei, reserved false | `0x14358d2386912617595812f5484d92d4899a96129a8904f771b29454b0524156` |
| root of the seven works (§5) | `0x131d82b25cc3283cc417942e38b63e6d665024c75cc40c645602d13437af1949` |
| allowlist leaf (§6): wallet `0x00000000000000000000000000000000000a11ce`, quota 2, tier 0 | `0xdeb66b034020d2fbb32cbd21ed700f9d996d0b507f43af350630a4cdac5466ee` |
| presale price leaf (§6): the work root above, index 0, tier 0, presale price 5 × 10¹⁵ wei | `0x5fb2da07b2b3ddca0143c094cdd8d8217b6aea6a74da439e4a0c4db241606b88` |
| root of the fixture's presale price list (two tiers × five public works, §6) | `0xa8505c260c45ec9eae4581034acbf48c343f0b4d77b8227e4208026a927ad1fe` |
| `titlesHash` of the seven titles (§10) | `0x1ecdc691abff41d0c4b6f032dd9b4845349526520462790a1fcffac33215ba9a` |
| `metadata` (§10) for name `P05 Test Collection`, symbol `P5TEST`, the fixture's story and that `titlesHash` | `0x131a0d4c42d02f4d670b1f463011bea1aa93a04665aaadcb1fe32dd663cd218c` |
| `isContentAddressed` (§11) of `ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG`, `ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi`, `ar://bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U`, `""` | true |
| `isContentAddressed` (§11) of `ipfs://k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8`, `ar://myundername_mycollectionname-permaweb123456`, `https://example.com/meta` | false |
| run leaf (§5), fixture `copies.json`: first 2, copies 5, the toggle's netlistHash above, nIn 1, nOut 1, price 10¹⁶ wei, reserved false | `0xf1ff4a2cd09c75999fb8275cc2685de0a3783c77a1ffeccf4b2dcc1cdb3b7569` |
| root of `copies.json` (three runs) | `0xbb2baad141cb47fc7d721f13b9d12728c769b088c543bc49affcba97c7d5095a` |
| hidden work leaf (§13.2), fixture `reveal.json`: index 4, netlistHash `0xb221cfe81351ffd08df1f8161d9391ca77871d04e91bad296f6fbd1742cfe0b0` (the 4-bit counter), nIn 0, nOut 4, pool 1, reserved false | `0xe9502f29200b13f42812b2828974b5fe8238695bc7ee3fdee7aa51ea92cc6b93` |
| positional root of the seven hidden works of `reveal.json` and `blindbox.json` (§13.2) | `0xe43ddb96813aae72a64bbc784cfd24e1b0656902f6c1057f7f0fa9e301e855f2` |
| slot secret leaf (§13.3): that root, slot 1, secret `0x0101…01` (32 bytes of 0x01) | `0xdfd80d6c5fd641e6c34f91bc5e25ef139350adff2829885bcf261c94a1df5d24` |
| seed (§13.3, §13.4): secret `0x0101…01`, block hash `0x0202…02` | `0x346d8c96a2454213fcc0daff3c96ad0398148181b9fa6488f7ae2c0af5b20aa0` |
| `permute(x, 6, keccak256("TAP-OCCC"))` for x = 0 … 5 (§13.4) | 2, 5, 0, 1, 4, 3 |
| metadata leaf (§13.5): index 0, title `Toggle`, description `Flips every cycle.`, attributes `[{"trait_type":"Rarity","value":"common"}]`, imageSha256 `0x1111…11` | `0xc411378a5dd39df90529f0acb1c6ce295f31cfba1586ca356bf42b41853b4384` |

The tool's `selftest` checks all 13 TAP-02 vectors (5 valid, 8 ill-formed), 200 random canvas designs, the positional tree, and that `permute` is a bijection for every pool size from 1 to 69; an additional run checked 6,000 random designs (inputs, constants, LATCH feedback, shuffled file order, multiple outputs) and found every encoded netlist to evaluate identically to the canvas graph over 8–24 beats. An end-to-end run on a local fork followed the real workflow: deploy the registry, build the manifest for it (with REF targets checked on chain), launch as the curator (`script/Demo.s.sol`), buy two works, claim both reserved works in one batch, and have a second account tape out a REF wrapper. `curate verify` reported the two works as official with matching netlists, the reserved works as official and reserved, owned by the treasury, and the wrapper as not official, although its `circuitInfo` was identical; `curate checkroot` rebuilt the root from the published works and it matched the chain, as did the treasury and the reserved count.

A sale and verification page (`web/index.html`) was tested in a real browser against local forks of BNB Smart Chain, X Layer and Base (`web/run_e2e.sh`, 28 browser checks plus an on-chain `checkroot`, all passing on each, two of them confirming that an allowlisted wallet is shown and pays its tier's presale price; with `E2E_TOKEN=1` the collection is priced in a test ERC-20 and two more checks confirm that the buyer approves and pays in the token and that the page shows its symbol, passing on BNB Smart Chain and X Layer): it loads the collection and refuses a manifest that differs from the chain, including one with a single changed price, one with a single changed title and one naming another curator; a committed title containing HTML is shown as text and runs no script; switching account in the wallet drops the connection; the page runs under its own content security policy; an allowlisted wallet sees and pays its presale price until its quota is used; after the public sale opens another work is bought, and both are owned by the buyer; a reserved work offers no purchase to buyers; the curator claims one reserved work to the treasury during the sale and the other after the sale has ended; the Verify tab reports an official work with its edition and matching netlist, flags a zero-cost REF wrapper as not official and explains why, and reports a missing circuit; the layout fits a 390-pixel-wide phone.

The tool also refuses work lists with a REF to a circuit that does not exist yet or with wrong pin counts, and warns about pure-REF works, whose byte-identical copies anyone can tape out.

## Reference Implementation

Repository: <https://github.com/gm-lsp/Tapeout-OCCC/tree/786a2b08f577643b87b7d9667ba4106d382998b5> (MIT).

- `src/CuratedRegistry.sol` — registry and launcher (§3, §4): checks the launch parameters, clones the implementation of the sale mode, records serials, per-circuit metadata files and blind-box passes.
- `src/CuratedTypes.sol` — the launch parameters and the sale-mode numbers.
- `src/CuratedVaultBase.sol` — what every vault shares (§6): launch, presale, per-wallet limit, direct payouts with the `owed` fallback, payee, reserved-work checks, finalize, sale controls.
- `src/CuratedVault.sol` — instant tape-out (sale mode 0): fixed prices per work, in any order or sequential with runs of copies.
- `src/CuratedHiddenBase.sol`, `src/CuratedRevealVault.sol`, `src/CuratedBlindBoxVault.sol` — hidden sales (§13): pools and slots, positional trees, reveal fee, refunds; the instant reveal's draw and hash lock; the blind box's pass (ERC-721), reveal, permutation and redemption.
- `src/interfaces/ICuratedRegistry.sol` — the interface of §3, §9 and §11.
- `src/interfaces/ICircuitURIProvider.sol` — the interface recommended to TapeOut in §12.
- `tool/curate.py` — dependency-free Python, knowing the TapeOut factory of each chain, writing `curated-collection-manifest/8` (designs stored once, runs of copies, sale mode, pools, reveal fee, and for hidden sales a private package with the slot secrets or the reveal secret plus a public manifest; `public` derives the latter, `assign` replays draws and assignments, `proof` prints any work's proof) (`build` refuses a spec whose chain the RPC is not on, and `checkroot` checks the registry's `FACTORY()`): TapeOut canvas → TAP-02 netlist encoder (validated with the TAP-02 reference implementation), on-chain checks of REF targets, transistor counts, work-list, allowlist and presale price trees and proofs (`allowproof`), metadata commitment, metadata files for the directory of §11 (`metadata`), launch manifest and fee cap, root and metadata rebuilding (`checkroot`), on-chain verification (`verify`).
- `test/Curated.t.sol`, `test/Modes.t.sol`, `script/Demo.s.sol` — the tests and demo above; `script/Deploy.s.sol` deploys the three implementations and the registry; `script/Launch.s.sol` launches a collection from a manifest (`script/ManifestParams.sol` reads it).
- `web/index.html`, `web/app.js`, `web/run_e2e.sh` — the sale and verification page for instant tape-outs sold in any order, and its browser test (hidden and sequential sales are served by the platform's own site).

## Deployments

Not yet deployed.

| Chain (chainId) | Contract | Address | Implementation it must point to | How to verify read-only | Sealed? |
|---|---|---|---|---|---|
| BNB Smart Chain (56) | CuratedRegistry | TBD | not a proxy | `FACTORY()` returns `0x68224F668083c29e9800Be2a646d42d18cedF7e2`; the runtime bytecode (immutables masked) matches the reference implementation at the linked commit | yes (no owner, no proxy) |
| BNB Smart Chain (56) | CuratedVault | `INSTANT_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| BNB Smart Chain (56) | CuratedRevealVault | `REVEAL_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| BNB Smart Chain (56) | CuratedBlindBoxVault | `BOX_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| X Layer (196) | CuratedRegistry | TBD | not a proxy | `FACTORY()` returns `0x1f09DAeFA827f02CBb40967cc91b259763760761`; the runtime bytecode (immutables masked) matches the reference implementation at the linked commit | yes (no owner, no proxy) |
| X Layer (196) | CuratedVault | `INSTANT_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| X Layer (196) | CuratedRevealVault | `REVEAL_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| X Layer (196) | CuratedBlindBoxVault | `BOX_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| Base (8453) | CuratedRegistry | TBD | not a proxy | `FACTORY()` returns `0x1f09DAeFA827f02CBb40967cc91b259763760761`; the runtime bytecode (immutables masked) matches the reference implementation at the linked commit | yes (no owner, no proxy) |
| Base (8453) | CuratedVault | `INSTANT_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| Base (8453) | CuratedRevealVault | `REVEAL_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |
| Base (8453) | CuratedBlindBoxVault | `BOX_IMPL()` of the registry above | not a proxy; vaults are EIP-1167 clones of it | the runtime bytecode matches the reference implementation; it cannot be initialised | yes (no owner) |

The TapeOut factory addresses are those listed in TAP-10's Deployments. A registry's address may differ from chain to chain; front-ends name the registry per chain (§7.1).

## Security Considerations

- **Trust in TapeOut.** The factory, processor and transistor contracts are upgradeable by TapeOut's multisig, on each chain separately; X Layer and Base have their own factory deployment, separate from BNB Smart Chain's (TAP-10). The fork tests exercise the behaviour below on all three chains. This TAP relies on: `isCPU` being correct; `tapeout` burning only the caller's transistors (the transistor contract has a `burnFrom` callable by the processor contract, so an upgraded processor could burn the vault's stock); the supply cap staying fixed; and transfers to the burn address staying allowed. The registry's launch checks hold at launch time only. Certifications already made are unaffected, because they record provenance at the time of tape-out.
- **Internal review.** The reference implementation went through five rounds of internal review, each by reviewers who did not write the code. The first round found no critical issue, one high (launch in another curator's name; fixed by §4.1 and the curator-bound leaf), two medium (an unsellable work blocking finalize forever; hidden leaves for an index — fixed by the sale end and by §5's publication rule) and five low issues (fixed: `withdrawTo`, the launch-fee cap, reentrancy from the launch refund, `tokenOf` not relying on id 0, and refusing stray circuits). The second round covered the reserve, limit, presale, royalty and page code and found no critical issue; its contract and tool findings were fixed (a limited sale now sells only to the buyer's own wallet, so no one can use up a stranger's quota; a zero presale start and a treasury that is the vault or the registry are refused; `checkroot` now rebuilds every work and allowlist entry and compares every launch setting with the chain), and so were its page findings (see Web page below). A third round re-checked the final code and found no critical, high or medium issue; its low findings were fixed or are listed below (Reserved works, Treasury contract, Work lists, Sale end, Payees). A fourth round reviewed the metadata additions (§11–§12 and the tool and page code for them) and found no critical issue; its findings were fixed: a percent-encoded `..` in an image path could leave a content-addressed root, an IPNS key written as an `ipfs://` CID passed the check, a 43-character ArNS undername could in principle pass as an Arweave id (now refused by the upper-case rule), tools did not read the directory back before launch, and metadata files were not written as UTF-8 on every platform. A fifth round reviewed the sale modes of this version (§13, copies, direct payouts, clones) and found no critical issue and two high ones; all its findings were fixed: a hash fallback known in advance to the secret's holder (now re-anchoring), consecutive purchase blocks whose hashes were not locked automatically (now every pending hash is locked), selective refunds by a curator who can compute draws (now limited to undeliverable slots), reveal-fee budgets that a high gas price or padded call data could take (now a gas-price cap and only the needed call data), no way to top up an undeliverable slot (`topUp`), excess value kept by a refund, token payouts that a hook or a malformed answer could make revert, unchecked narrowing of prices and fees, a pass that could be minted to the vault, and a circuit that could not get its metadata file after delivery. Every on-chain fix has a regression test; the hidden-leaf finding is addressed by the publication rule of §5, which `checkroot` and the reference page enforce.
- **Metadata availability.** The registry fixes the address of the metadata, not its availability. Files on IPFS disappear if no one keeps them pinned; curators should pin them with more than one provider or use Arweave. A front-end that fetches files through an HTTP gateway trusts that gateway to serve the content the address names; it may check the content against the address. A collection launched with an unreachable or wrong directory cannot correct it (§11.1), so tools should read the directory back before launch.
- **What "official" does not promise.** The registry certifies where a circuit came from, not what it does. A curator can list any well-formed netlist, including one that REFs circuits on other processors, whose behaviour then depends on those circuits (TAP-02, Security Considerations).
- **Foreign circuits still appear in the collection.** Pure-REF wrappers can always be taped out into any processor. This TAP makes them distinguishable; it does not and cannot prevent them. Front-ends that ignore §7 will keep showing them.
- **Vault assets.** The vault holds transistors that are only usable on its own processor, the tape-out and reveal fees of hidden slots until they are spent or returned, and payouts that could not be delivered until they are withdrawn by or for their payees. It has no owner. Every sale and claim updates the vault's state before its external calls, and every state-changing entry point that makes external calls (`initialize`, every buy, claim, fulfil, refund and redeem function, `reveal`, `withdraw`, `withdrawTo`, `finalize`) shares one re-entry guard; `setPaused`, `extendSale`, `setPayee`, `lockHash`, `fixSeed` and the pass transfers make no payment; `receive` is unguarded but accepts the native coin only from the processor's transistor contract.
- **Contract and EIP-7702 buyers.** In an instant tape-out the circuit is sent with `safeTransferFrom`. A recipient with code that does not implement `onERC721Received` makes the purchase revert, so no funds are lost; buyers can name a different recipient. In a hidden sale the circuit is delivered in someone else's transaction, so it is sent with a plain `transferFrom` that the holder cannot block; a holder contract that cannot handle ERC-721 tokens then holds a circuit it cannot move, which is the buyer's choice of recipient. Note that some well-known EOAs on BNB Smart Chain and Base carry EIP-7702 delegations.
- **First come, first served.** In an instant tape-out, netlists and proofs are public, so bots can take price-0 or underpriced works as soon as the sale opens, and two buyers can race for the same index (the loser's transaction reverts). A sequential sale has no race for an index, only for the next work. The hidden modes (§13) remove the choice altogether.
- **Hidden sales.** §13.8 lists what holders of the secrets can and cannot do. In addition: the secrets of an instant reveal are the keys to the draw; if they leak, outsiders can compute outcomes one block after each purchase, but still not choose them. The reveal fee is fixed at launch; if gas becomes more expensive than it covers, deliveries wait or the server pays the difference, and a tape-out fee raised by TapeOut above what a slot holds stops that slot's delivery (`FeeShortfall`), after which the curator can refund it. A blind box's secret and directory are given by the curator in one call; a wrong directory cannot be corrected (§11.1), so tools check it before the reveal. Buyers of a hidden sale cannot verify the work list until it is published after the sale; front-ends should say so, show the commitments, and verify the list once it is published.
- **Reserved works.** The treasury holds reserved works like any other circuits, so its key is what protects them; a multisig is recommended. A reserved work can be claimed until the leftover transistors are burned, which anyone can do once the sale has ended and every reserved work is claimed, or otherwise once `RESERVE_GRACE` has passed after the sale end; a reserved work not claimed by then is lost.
- **Treasury contract.** Reserved works are sent to the treasury with `safeTransferFrom`. A treasury contract that does not accept ERC-721 transfers makes every claim revert, and the reserved works are lost when the vault is finalized. Multi-signature wallets such as Safe accept them; curators should claim one reserved work right after launch to confirm.
- **Work lists.** Work and allowlist leaves are bound to the chain, the registry and the curator, not to one collection. A curator who reuses a work list or an allowlist in a second collection makes every proof valid in both (presale price leaves also include the work-list root, so a price list never carries over); tools should build a fresh list per collection, and front-ends identify a collection by its chain id and processor address, never by its name.
- **Sale end.** Until the sale ends, unsold works stay buyable and the leftover transistors stay in the vault. A very distant sale end (the test fixture uses the year 2100) means the supply is effectively never burned; curators should choose a realistic one.
- **Payees.** Proceeds are paid out at once, each native-coin payout with at most 50,000 gas and each token payout with at most 150,000 (reading at most one word of the token's answer, so neither a hook that burns gas nor a malformed answer can make a purchase revert), so a payee contract that needs more (a contract that does work on receipt) gets its share kept in `owed` instead and withdraws it. A payee contract that can neither receive the payment asset nor call `withdrawTo` locks its own share; the curator can point future sales to another payee. The vault rejects zero, the vault and the registry as payees. A compromised curator key can redirect future income by changing the payee, but not income already paid.
- **Payment tokens.** The curator chooses the token and the registry does not vet it. A token can be paused, can blacklist the vault or a buyer, can be upgraded to behave differently, or can call back into the buyer or payee; then purchases, payouts or withdrawals of that collection can fail (a failed payout is kept in `owed`, and a kept amount can be stuck if the token keeps refusing). Officialness, already sold works, the work list and other collections are not affected. Tokens sent to a vault directly, outside a purchase, cannot be refused or recovered (unlike the native coin, which `receive` refuses), and stay locked. Every purchase and withdrawal is guarded against reentrancy and updates state before external calls, and the exact-amount check refuses tokens that deliver less than the price. Buyers approve the vault for one price at a time in the reference page; an approval larger than needed lets only this vault, which has no owner, pull tokens, and only as part of a purchase the approver sends. Front-ends should show which token a collection uses and warn before a purchase in an unknown token.
- **Sale controls.** The curator can pause buying for as long as it likes and can keep moving the sale end later, which also postpones `finalize` and the burn of leftover transistors. Buyers cannot force a purchase while a sale is paused, and an attacker who obtains the curator key can pause or extend the sale (but cannot take proceeds, change prices or add works). Holders and the officialness of sold works are never affected. Front-ends should read `paused()` and the current `SALE_END()` rather than the launch values.
- **Curator key.** The curator address can never be changed. If its key is lost, unclaimed reserved works can no longer be claimed, the royalty and the payee can no longer be changed, a blind box can no longer be revealed, and slots can no longer be refunded. This is deliberate (see Rationale); a multisig curator is recommended, especially for blind boxes.
- **Pure-REF works.** A listed work made only of REF records burns no transistors, so anyone can tape out a byte-identical copy of it into the curated processor. The copy is not official, but it looks the same; tools warn about such works.
- **Fee changes.** The vault reads `TAPEOUT_FEE()` at purchase time, so a fee change is passed to buyers rather than breaking sales. In a hidden sale the fee is read again at delivery and paid from the slot's tape-out and reveal fees (§13.6).
- **Netlist size.** Tape-outs above about 34,000 bytes fail on BNB Smart Chain mainnet (other chains' block gas limits may differ); the tool rejects them. Large works should be split into sub-circuits joined by REF.
- **Merkle leaves** are double-hashed, so an inner node cannot be presented as a leaf.
- **Web page.** The page treats the manifest as untrusted. It takes the chain, the RPC, the registry and the processor only from its own `site.json` (URL overrides work on localhost only), checks that the vault belongs to that registry, rebuilds every work leaf, the allowlist root and the presale price list from the manifest and refuses to load if any differs from the chain, inserts every manifest value as text, loads its script from its own origin under a strict content security policy, and pins the ethers library with a subresource-integrity hash. A circuit that is official in a different collection is reported as not belonging to this one, never as official. It also rebuilds the metadata commitment (§10) and refuses a manifest whose name, symbol, story or titles differ from it.
- **No audit yet.** The reference implementation has had internal reviews only. It should not hold significant value before an independent audit.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
