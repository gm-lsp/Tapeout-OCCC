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

A way for an artist or project to sell a fixed list of circuits on TapeOut so that anyone — a buyer, a market, another contract — can check on chain which circuits in the collection are the real works and which were added by someone else.

## Abstract

On TapeOut a processor contract is an NFT collection, but anyone can add circuits to it: with transistors any netlist can be taped out, and without any transistors a netlist made only of REF records can be taped out at zero transistor cost. This TAP defines **curated collections** (the Official Curated Circuit Collections, OCCC, of the title): collections whose official works anyone can check. A curated collection is launched in a single transaction in which a vault contract creates the processor and mints its entire transistor supply to itself. Afterwards, the collection's transistors can be spent only through that vault, and the vault tapes out only netlists from a work list fixed at launch as a Merkle root. A circuit is **official** if and only if the vault taped it out and a registry certified its id in the same transaction. A curator can also mark works in the list as **reserved** for a treasury fixed at launch: the public can never buy them, and they are claimed to the treasury, from which they can be given away or airdropped like any circuit. Optionally, a curator can declare a royalty that markets may read and honour. The TAP specifies the registry interface (`isOfficial`, `editionOf`, `tokenOf`, `isReserved`, `isCurated`, `collectionOf`, the royalty functions and their events), the conditions the registry checks at launch (including that the curator launches personally), the vault's behaviour, a work-list leaf encoding bound to the chain, the registry and the curator, the requirement to publish every leaf, a commitment to the collection's name, symbol, story and titles, an optional metadata directory fixed at launch from which the registry's `tokenURI` gives every official circuit ERC-721 metadata (name, image, attributes), and how front-ends, markets and contracts are to use the record. It also recommends a small change to TapeOut's processor contracts so that wallets and markets that read only the NFT contract show the same metadata.

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
| Curator | The address that launches the collection, receives the curator's share of sale proceeds, is the only one that may claim reserved works, and may change the royalty receiver or lower its rate |
| Reserved work | A work the work list marks as kept for the treasury: it cannot be bought, only claimed to the treasury |
| Treasury | The address, fixed at launch, that receives every reserved work |

### 2. Definition of an official circuit

A circuit `(circuits, tokenId)` is **official** in a registry if and only if:

1. `circuits` is a curated collection in that registry (§4), and
2. the collection's vault taped out circuit `tokenId` by calling `circuits.tapeout`, and
3. in the same transaction, the vault called the registry's `certify(circuits, tokenId, index, netlistHash, reserved)` for a work `index` with `index < count` that had not been certified before.

Officialness belongs to the circuit, not to its holder: it does not change when the circuit is transferred, sold, given away or airdropped.

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
| `collectionOf(address circuits)` | `0x3e94c904` | `(address vault, address curator, address transistors, address treasury, bytes32 root, uint32 count, uint32 reserved, uint32 certified, bytes32 metadata)`; all zero if not curated |
| `certify(address circuits, uint256 tokenId, uint256 index, bytes32 netlistHash, bool reserved)` | `0xaa92a7c0` | not `view`: records an official circuit; callable only by the collection's vault (§3 rule 4) |

| Event | Topic 0 |
|---|---|
| `CollectionLaunched(address indexed circuits, address indexed vault, address indexed curator, address transistors, bytes32 root, uint32 count, address treasury, uint32 reserved, bytes32 metadata)` | `0xfafcf03610954fd778b52f9044d3c3fcbade024c53f03257b287645a997bb10d` |
| `Certified(address indexed circuits, uint256 indexed tokenId, uint256 indexed index, bytes32 netlistHash, bool reserved)` | `0x8d7d8f5d2406ca80fb5e26889f1d3c94eaa0bc9e610a469ca59e18cab4ff1340` |

Rules:

1. For each `circuits`, `CollectionLaunched` MUST be emitted exactly once, and before any `Certified` for it.
2. `Certified` MUST be emitted in the same transaction as the tape-out of `tokenId`, exactly once per `tokenId` and exactly once per `index`.
3. Once `isOfficial(circuits, tokenId)` is true it MUST stay true; `editionOf` and `tokenOf` MUST NOT change once set. `collectionOf(circuits).root`, `.count`, `.vault`, `.curator`, `.transistors`, `.treasury`, `.reserved` and `.metadata` MUST NOT change once set.
4. The registry MUST NOT have an owner, administrator, pause switch or upgrade mechanism, and MUST NOT accept certifications from any address other than the collection's vault.
5. The registry MUST NOT certify more reserved works for a collection than the `reserved` count fixed at launch.

### 4. Launch

A registry MUST bind a collection to a vault only if all of the following hold **at the moment of binding**, checked on chain by the registry itself rather than taken from the vault:

1. The vault was deployed by this registry for this launch, in a call whose sender is the curator. A registry MUST NOT launch a collection whose curator is not the caller, so nobody can launch in an artist's name.
2. `factory.isCPU(circuits)` (selector `0x5f5a364f`) is true for the TapeOut processor factory of the registry's chain, which the registry MUST fix at deployment.
3. `circuits.transistors() == transistors` and `transistors.circuits() == circuits`.
4. `transistors.creator() == vault`.
5. `transistors.minted() == transistors.supplyCap()`, and `transistors.balanceOf(vault, 0) + transistors.balanceOf(vault, 1) == transistors.supplyCap()`.
6. No circuit has been taped out on `circuits` yet. (On the deployed contracts `circuits.nextId()` returns 0 for a fresh processor; see Backwards Compatibility.)
7. `circuits` is not already bound.

Creating the processor, minting its whole supply to the vault and binding MUST happen in one transaction. Because the processor does not exist before that transaction, nobody else can hold any of its transistors.

The launch MUST fix a sale end time, which MUST be later than the launch. The launcher SHOULD state the most it will pay in factory and protocol fees, and the launch MUST revert if the fees read at launch time exceed it, so a fee change between preparing and sending the launch cannot drain the launcher's float.

A launch MAY use a non-zero processor mint price (for example to meet a front-end display threshold). In that case the vault pays itself and recovers the payment with `withdraw()` between mint batches; the vault is the creator, so the net cost is the factory deploy fee and the protocol fees. This "mint revenue" is not real demand, and tools SHOULD say so.

### 5. Work list

Each work is `(index, netlist, nIn, nOut, price, reserved)`, where `netlist` is a well-formed TAP-02 netlist, `price` is the sale price in wei, and `reserved` says whether the work is kept for the treasury. A reserved work MUST have `price = 0`. The leaf of a work is (pseudo-code; `abi.encode` and `keccak256` as in Solidity)

```
leaf = keccak256(bytes.concat(keccak256(abi.encode(
    uint256 chainId, address registry, address curator,
    uint256 index, bytes32 keccak256(netlist), uint32 nIn, uint32 nOut, uint256 price, bool reserved))))
```

and the root is computed with sorted-pair hashing, as verified by OpenZeppelin `MerkleProof` (`hash(a, b) = keccak256(a < b ? a ‖ b : b ‖ a)`). Binding the leaf to the chain, the registry and the curator means a work list cannot be reused by anyone else, on another chain, or in another registry.

Which works are public and which are reserved is therefore fixed at launch, together with the number of reserved works and the treasury address. A curator cannot later move a popular public work into the treasury, and buyers can see every reserved work before the sale opens. Indexes MUST be `0 … count − 1`, each used once. Tools SHOULD reject a work list that contains the same netlist twice.

A Merkle root commits to a set of leaves, not to "exactly `count` works": a dishonest curator could add a hidden second leaf for an index (for example, at price 0) and buy it first. The curator MUST therefore publish every leaf — every work's index, netlist, pins, price and reserved flag — before the sale opens, and verifiers SHOULD rebuild the root from the published list and compare it with `collectionOf(circuits).root`. A collection whose published list does not rebuild the on-chain root MUST NOT be presented as verified.

A REF record in a listed netlist MUST point to a circuit that already exists when the list is built, with matching pin counts. A REF to an id that does not exist yet would let anyone tape out a circuit at that id first and so decide part of the official work's behaviour; a REF with wrong pins can never be taped out.

The netlist does not need to equal what any particular editor would produce for the same design; it needs to be well-formed and to be exactly the bytes the vault will tape out.

### 6. Vault

A vault bound to a collection:

1. MUST tape out only netlists whose leaf is proven against the root, at most once per `index`.
2. MUST call `certify` in the same transaction as each tape-out, with the id returned by `tapeout`.
3. MUST NOT sell a reserved work. It MUST tape out a reserved work only to the treasury fixed at launch (which MUST NOT be the vault or the registry), at most `reserved` times in total, and only until the leftover transistors are burned (item 4). Once in the treasury, a reserved work is an ordinary circuit that the treasury MAY transfer, give away or airdrop; the vault and registry place no restriction on it.
4. MUST NOT transfer, approve or burn transistors except by tape-out, or by sending the remainder to a burn address once all `count` works are taped out, or once the sale has ended and either every reserved work has been claimed or a grace period fixed in the vault has passed. Public works not sold by the sale end can never be taped out, and the grace period is bounded, so one unsellable work cannot keep the supply unburned forever; a reserved work that the curator forgot to claim is not lost when the sale ends.
5. MUST NOT have an owner or functions that change the root, the count, the curator, the platform share, the treasury, the reserved count or the sale start after launch. It MAY let the curator pause and resume buying, and move the sale end later (never earlier) while the sale has not ended and the vault is not finalized; it MUST NOT let anyone move the sale end earlier or reopen an ended sale.
6. MUST NOT let the launcher, or anyone else, buy works during the launch transaction (for example from a refund callback).
7. SHOULD transfer each new circuit to the buyer's chosen recipient in the same transaction, and SHOULD use pull payments for proceeds, letting a payee that cannot receive the native coin direct its proceeds to another address.

The reference vault sells with `buy(index, netlist, nIn, nOut, price, proof, recipient)` (`0x2a21357f`). The curator can stop and resume buying (public sale and presale) with `setPaused(bool)` (`0x16c38b3c`, event `SalePaused(bool)`), and can move the sale end later with `extendSale(uint64 newEnd)` (`0xb69ee020`, event `SaleEndExtended(uint64 previousEnd, uint64 newEnd)`) as long as the current end has not passed; `SALE_END()` (`0x9aa0ff7b`) and `paused()` (`0x5c975abb`) return the current state. Neither control affects reserved claims, the work list or prices, and the reserve grace period counts from the current end. The vault charges exactly `price + circuits.TAPEOUT_FEE()`, splits `price` between the curator and an optional platform (at most 10 %), sells between a fixed `saleStart` and `saleEnd`, accepts only circuits freshly minted to it by its own tape-out, and lets each payee withdraw to itself or (`withdrawTo`) to another address. Reserved works are claimed with `claimReserved(index, netlist, nIn, nOut, proof)` (`0xfc451b6a`), or several at once with `claimReservedBatch((uint256 index, bytes netlist, uint32 nIn, uint32 nOut, bytes32[] proof)[])` (`0x8549fef1`, all or nothing): only the curator may call them, each work costs exactly the tape-out fee, they work before the public sale opens, during it and after it ends, and they send the circuit to the treasury. `finalize()` burns the leftover transistors once every work is taped out, or once the sale has ended and either every reserved work is claimed or `RESERVE_GRACE` (30 days) has passed; anyone may call it, and `finalizable()` (`0x107e8456`) tells whether it may be called now. After that no work can be taped out, so curators SHOULD still claim reserved works soon after launch.

The reference vault also offers an optional per-wallet limit, fixed at launch as two separate settings: `limitPerWallet` (`false` = no limit) and `maxPerWallet` (the limit, at least 1, only when `limitPerWallet` is `true`; a launch whose two settings disagree reverts). With a limit, the reference vault sells only to the buyer's own wallet (`recipient == msg.sender`, else `RecipientMustBeBuyer`), each purchase counts once against that wallet, and a wallet that has reached the limit cannot buy further works. (Counting only the buyer would let one wallet buy for many; counting the recipient as well would let anyone use up a stranger's quota by buying for it.) `remainingFor(wallet)` returns whether a limit applies and how many purchases remain. The limit applies to minting only, not to later transfers, and not to reserved works. It is a sale policy of the vault, not part of the registry standard, and like any address-based limit it does not stop one person who uses many wallets.

The reference vault can also run a presale before the public sale. At launch the curator fixes `allowRoot`, the Merkle root of an allowlist of `(wallet, quota)` entries, and `presaleStart`, which the reference vault requires to be non-zero and before `saleStart`; with no presale both are zero. From `presaleStart` until `saleStart`, `buyPresale(index, netlist, nIn, nOut, price, proof, recipient, quota, allowProof)` (`0xdb7f4eca`) sells only to allowlisted wallets, each at most `quota` times, at the listed prices; the per-wallet limit, if any, also applies. An allowlist leaf is `keccak256(bytes.concat(keccak256(abi.encode(uint256 chainId, address registry, address curator, bytes32 keccak256("TAP-curated-allowlist"), address wallet, uint32 quota))))`; the tag keeps allowlist leaves distinct from work leaves. Curators SHOULD publish the allowlist with the work list so anyone can rebuild `allowRoot`.

### 7. Front-ends and markets

1. A front-end that labels a circuit as an official or verified work of a curated collection MUST base that label on `isOfficial` (or `editionOf`) of a registry, named by the front-end, that is deployed on the same chain as the circuit. It MUST identify a collection by chain id and address together: officialness on one chain says nothing about another, and the same address can be a different processor on another chain (X Layer and Base share TapeOut's contract addresses).
2. It MUST NOT label a circuit as official, verified or "matching" a curated collection based on `circuitInfo`, evaluation results, netlist hash, owner or token URI.
3. For a curated collection, it SHOULD visibly mark circuits that are not official, and SHOULD let users filter them out.
4. It SHOULD show the work index (`editionOf`) and link to the certifying transaction (`Certified` log).
5. It SHOULD show which works of a collection are reserved for the treasury, before and after they are claimed (`isReserved`), and MUST still show a reserved work as official after the treasury transfers it.
6. It SHOULD show a collection as verified only if the curator's published work list rebuilds the on-chain root (§5).

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

with every string UTF-8 encoded and titles in index order. `name`, `symbol` and `story` are the strings the processor was created with; the reference vault computes their hashes on chain from its launch parameters (`metadataOf(name, symbol, story, titlesHash)`, `0xe2e2bef0`), so the commitment cannot disagree with the processor, and the launcher supplies only `titlesHash`, which MUST NOT be zero.

1. `metadata` MUST be fixed at launch and MUST NOT change.
2. A curator MUST publish the name, symbol, story and every title together with the work list.
3. A front-end SHOULD show a collection's name, symbol, story and titles only after rebuilding `metadata` from them and comparing it with `collectionOf(circuits).metadata`, and MUST NOT present them as the curator's if they do not match.

### 11. Token metadata and images (optional)

TapeOut's processor contracts return an empty `tokenURI` for every circuit and give a processor's creator no way to set one, so a circuit NFT has no name, image or attributes in any wallet or market. A registry MUST therefore implement the functions below; a curator MAY record one **content-addressed** metadata directory per collection at launch, and the registry answers `tokenURI` for official circuits:

| Function / event | Selector / topic 0 | Meaning |
|---|---|---|
| `tokenURI(address circuits, uint256 tokenId)` | `0xe9dc6375` | `"<metadataURI>/<index>.json"` for an official circuit, where `index` is its work-list position (`editionOf`); `""` for a circuit that is not official, or when the collection has no directory |
| `metadataURIOf(address circuits)` | `0x9eac0ca2` | the collection's directory: `"ipfs://<CID>"`, `"ar://<transaction id>"` or `""` |
| `MetadataURISet(address indexed circuits, string uri)` | `0xf4ea916416710952791c00e6c397903c99c416633fd82eeb8f5786572a9d899c` | emitted once, in the launch transaction |

1. The directory MUST be fixed at launch and MUST NOT change. Nobody, including the curator, can set it later; a collection launched without one never gets one.
2. The directory MUST be content-addressed, so that its content cannot change either: `"ipfs://"` followed by a CID of immutable content (CIDv0, `Qm` + 44 base58 characters, or CIDv1 in lower-case base32 beginning `bafy` or `bafk`, which covers dag-pb, dag-cbor and raw data with any hash, 50 to 100 characters; no path, no other encoding, never a libp2p-key CID, which names an IPNS record), or `"ar://"` followed by a 43-character Arweave transaction id (base64url) that contains at least one upper-case letter (typically the id of an Arweave path manifest). ArNS names and undernames are lower case, so the upper-case rule keeps a 43-character name from ever passing as an id; a random id lacks an upper-case letter with probability about 2 × 10⁻¹⁰, and an uploader that draws one can re-sign the file. Mutable names (IPNS, DNSLink, ENS, ArNS) and `http(s)` URLs MUST be refused. The reference registry checks this on chain (`isContentAddressed(bytes)`, `0x9bdfd89c`) and reverts the launch otherwise.
3. `tokenURI` MUST return `""` for circuits that are not official, so REF wrappers and copies never show a work's image.
4. The file `<index>.json` SHOULD follow the ERC-721 metadata JSON schema (`name`, `description`, `image`, optionally `animation_url` and `attributes`). Its `name` SHOULD equal the committed title of work `index` (§10), and its `image` and `animation_url` SHOULD themselves be content-addressed (`ipfs://…` or `ar://…`, optionally with a path of plain segments: letters, digits and `. _ ~ -`, no `.` or `..` segment and no percent-encoding, so a link cannot climb out of its content-addressed root). The reference tool also writes `properties` with the work's `index` and `netlistHash`, which ties the image to the circuit design.
5. A front-end SHOULD read a circuit's metadata only through the registry's `tokenURI`, SHOULD show only content-addressed images, and MUST NOT treat the presence of metadata as evidence that a circuit is official (§7.2); `isOfficial` decides that.

Because the directory is fixed before the first sale, the curator uploads it before launch: first the images (each gets its own content address), then one `<index>.json` per work that links to them, then the directory. A launch that stores the directory costs about 90,000 gas (an `ar://` id) to 105,000 gas (a CIDv1) more than one without, measured on a mainnet fork. Storage of the files themselves is outside the chain: Arweave stores them permanently for a one-off fee; IPFS needs at least one party, the curator, a platform or a holder, to keep the files pinned, and anyone holding a copy of the files can re-publish them under the same CID. Collections whose images are computed from the netlist itself MAY instead point `animation_url` at a renderer stored on chain or on Arweave.

### 12. Recommendation to TapeOut (informative)

This section is a recommendation to TapeOut, not a requirement of this standard; nothing else in this TAP depends on it. Wallets and markets that read only an NFT contract's own `tokenURI` cannot see a registry. TapeOut can make every curated collection's metadata visible everywhere, without trusting any particular registry, with one change to the shared processor implementation behind its beacon. Example (informative):

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

**Why at most 10 % platform share and no admin.** A launch tool will often be run by a platform for an artist. Bounding the share and removing every admin path means the artist does not have to trust the platform after launch.

## Backwards Compatibility

This TAP changes no TapeOut contract. Existing processors cannot become curated collections under §4, because their transistors already circulate; their projects may publish signed lists of official ids in another TAP, but such lists are attestations by the project, not provenance guarantees, and are out of scope here.

During this work it was observed on mainnet that `circuits.nextId()` returns the number of circuits taped out so far (0 for a fresh processor, 1 after the first tape-out, whose id is 1), not "the id the next taped-out circuit will get" as TAP-02 §6 states. The reference registry uses `nextId() == 0` for condition §4.6. TAP-02 may want to correct its description.

## Test Cases

The reference implementation ships 50 Foundry tests that run against a fork of BNB Smart Chain, X Layer or Base mainnet (`forge test --fork-url https://bsc-dataseed.bnbchain.org`, `https://rpc.xlayer.tech` or `https://mainnet.base.org`); the tests pick that chain's factory and a work list built for it. The work list has seven throw-away test circuits produced by the reference tool: a toggle, a 4-bit counter, a 7-bit LFSR, an XOR, a REF work (on BNB Smart Chain, genesis circuit #13 with a parity output; on X Layer and Base, circuit #1 of processor `0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b` with an inverse output), and two works the list reserves for the treasury (the TAP-02 vector `popcount8_3151` and an AND gate with a non-ASCII title). All 50 pass on all three chains (2026-10-30), with no change to the contracts. Gas figures and fees below are from BNB Smart Chain. Because free public nodes keep only recent state, the tests fork the latest block rather than a pinned one. The tests are:

| Test | What it shows |
|---|---|
| `test_Launch_AtomicAndVerified` | one transaction creates the processor, mints the full supply to the vault (non-zero mint price, 5 mint batches), binds, fixes the metadata directory, refunds the float; 4.08 M gas; the launcher pays exactly the 0.0015 BNB (on BNB Smart Chain) of factory and protocol fees (0.001 deploy fee + 5 × 0.0001) the tool predicted |
| `test_Launch_ZeroMintPrice` | the same with mint price 0 |
| `test_Launch_RejectsBadParams` | platform share above 10 %, sale end not after sale start, insufficient launch funds |
| `test_L2_LaunchFeeCap` | launch reverts when fees exceed the launcher's cap |
| `test_H1_CopycatLaunchRejected` | nobody can launch in another curator's name; a copycat that reuses the root as its own curator cannot sell any listed work |
| `test_L3_RefundReentryBlocked` | a curator account that tries to buy from the launch refund callback hits the re-entry guard (`ReentrancyGuardReentrantCall`), and nothing is sold |
| `test_L4_TokenOfAndEditionOfDefaults` | before a work is taped out `tokenOf` reports it as not taped out (never as id 0), circuits that are not official report `(false, 0)`, and after tape-out the work maps to its circuit id |
| `test_PayeesCannotBeVaultOrRegistry` | the treasury cannot be the vault being deployed, and the platform can be neither that vault nor the registry |
| `test_BuyAll_CertifyPayFinalize` | all seven works: `Certified` emitted with the netlist hash, certified with the right index, owned by the buyer (the two reserved works by the treasury), netlist bytes as listed, transistors consumed exactly as predicted by the tool; proceeds split; leftover 9,814 NAND and 3 LATCH burned |
| `test_M1_FinalizeAfterSaleEnd` | after the sale end, buying stops; with reserved works unclaimed the burn waits for the grace period, then the leftover supply is burned although works remain unsold |
| `test_L1_WithdrawTo` | a payee sends its proceeds to another address; others cannot |
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

Test vectors from the fixture `test/fixtures/manifest.json` (chain id 56, registry `0x00000000000000000000000000000000c0dec0de`, curator `0x00000000000000000000000000000000000c0ffe`), which any implementation of §5, §6, §10 and §11 must reproduce:

| Input | Expected output |
|---|---|
| work leaf (§5): index 0, netlistHash `0x7ca496e2d18c48a09aea26fc7df653df9c3fa5a10cb1a2bb7ec311c8220130b2`, nIn 1, nOut 1, price 10¹⁶ wei, reserved false | `0x14358d2386912617595812f5484d92d4899a96129a8904f771b29454b0524156` |
| root of the seven works (§5) | `0x131d82b25cc3283cc417942e38b63e6d665024c75cc40c645602d13437af1949` |
| allowlist leaf (§6): wallet `0x00000000000000000000000000000000000a11ce`, quota 2 | `0xdecc2768d819e2e59a3b44125831aaf52623a661945407499fbaf406f8658755` |
| `titlesHash` of the seven titles (§10) | `0x1ecdc691abff41d0c4b6f032dd9b4845349526520462790a1fcffac33215ba9a` |
| `metadata` (§10) for name `P05 Test Collection`, symbol `P5TEST`, the fixture's story and that `titlesHash` | `0x131a0d4c42d02f4d670b1f463011bea1aa93a04665aaadcb1fe32dd663cd218c` |
| `isContentAddressed` (§11) of `ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG`, `ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi`, `ar://bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U`, `""` | true |
| `isContentAddressed` (§11) of `ipfs://k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8`, `ar://myundername_mycollectionname-permaweb123456`, `https://example.com/meta` | false |

The tool's `selftest` checks all 13 TAP-02 vectors (5 valid, 8 ill-formed) and 200 random canvas designs; an additional run checked 6,000 random designs (inputs, constants, LATCH feedback, shuffled file order, multiple outputs) and found every encoded netlist to evaluate identically to the canvas graph over 8–24 beats. An end-to-end run on a local fork followed the real workflow: deploy the registry, build the manifest for it (with REF targets checked on chain), launch as the curator (`script/Demo.s.sol`), buy two works, claim both reserved works in one batch, and have a second account tape out a REF wrapper. `curate verify` reported the two works as official with matching netlists, the reserved works as official and reserved, owned by the treasury, and the wrapper as not official, although its `circuitInfo` was identical; `curate checkroot` rebuilt the root from the published works and it matched the chain, as did the treasury and the reserved count.

A sale and verification page (`web/index.html`) was tested in a real browser against local forks of BNB Smart Chain, X Layer and Base (`web/run_e2e.sh`, 26 browser checks plus an on-chain `checkroot`, all passing on each): it loads the collection and refuses a manifest that differs from the chain, including one with a single changed price, one with a single changed title and one naming another curator; a committed title containing HTML is shown as text and runs no script; switching account in the wallet drops the connection; the page runs under its own content security policy; an allowlisted wallet buys in the presale until its quota is used; after the public sale opens another work is bought, and both are owned by the buyer; a reserved work offers no purchase to buyers; the curator claims one reserved work to the treasury during the sale and the other after the sale has ended; the Verify tab reports an official work with its edition and matching netlist, flags a zero-cost REF wrapper as not official and explains why, and reports a missing circuit; the layout fits a 390-pixel-wide phone.

The tool also refuses work lists with a REF to a circuit that does not exist yet or with wrong pin counts, and warns about pure-REF works, whose byte-identical copies anyone can tape out.

## Reference Implementation

Repository: <https://github.com/gm-lsp/Tapeout-OCCC/tree/b360e8d7ed67ca2ea0c27b85b97d656c9e337f12> (MIT).

- `src/CuratedRegistry.sol` — registry and launcher (§3, §4).
- `src/CuratedVault.sol` — vault (§6), reference sale with fixed prices per work.
- `src/interfaces/ICuratedRegistry.sol` — the interface of §3, §9 and §11.
- `src/interfaces/ICircuitURIProvider.sol` — the interface recommended to TapeOut in §12.
- `tool/curate.py` — dependency-free Python, knowing the TapeOut factory of each chain (`build` refuses a spec whose chain the RPC is not on, and `checkroot` checks the registry's `FACTORY()`): TapeOut canvas → TAP-02 netlist encoder (validated with the TAP-02 reference implementation), on-chain checks of REF targets, transistor counts, work-list Merkle tree and proofs, metadata commitment, metadata files for the directory of §11 (`metadata`), launch manifest and fee cap, root and metadata rebuilding (`checkroot`), on-chain verification (`verify`).
- `test/Curated.t.sol`, `script/Demo.s.sol` — the tests and demo above; `script/Launch.s.sol` launches a collection from a manifest.
- `web/index.html`, `web/app.js`, `web/run_e2e.sh` — the sale and verification page and its browser test.

## Deployments

Not yet deployed.

| Chain (chainId) | Contract | Address | Implementation it must point to | How to verify read-only | Sealed? |
|---|---|---|---|---|---|
| BNB Smart Chain (56) | CuratedRegistry | TBD | not a proxy | `FACTORY()` returns `0x68224F668083c29e9800Be2a646d42d18cedF7e2`, and the runtime bytecode matches the reference implementation at the linked commit | yes (no owner, no proxy) |
| X Layer (196) | CuratedRegistry | TBD | not a proxy | `FACTORY()` returns `0x1f09DAeFA827f02CBb40967cc91b259763760761`, and the runtime bytecode matches the reference implementation at the linked commit | yes (no owner, no proxy) |
| Base (8453) | CuratedRegistry | TBD | not a proxy | `FACTORY()` returns `0x1f09DAeFA827f02CBb40967cc91b259763760761`, and the runtime bytecode matches the reference implementation at the linked commit | yes (no owner, no proxy) |

The TapeOut factory addresses are those listed in TAP-10's Deployments. A registry's address may differ from chain to chain; front-ends name the registry per chain (§7.1).

## Security Considerations

- **Trust in TapeOut.** The factory, processor and transistor contracts are upgradeable by TapeOut's multisig, on each chain separately; X Layer and Base have their own factory deployment, separate from BNB Smart Chain's (TAP-10). The fork tests exercise the behaviour below on all three chains. This TAP relies on: `isCPU` being correct; `tapeout` burning only the caller's transistors (the transistor contract has a `burnFrom` callable by the processor contract, so an upgraded processor could burn the vault's stock); the supply cap staying fixed; and transfers to the burn address staying allowed. The registry's launch checks hold at launch time only. Certifications already made are unaffected, because they record provenance at the time of tape-out.
- **Internal review.** The reference implementation went through four rounds of internal review, each by reviewers who did not write the code. The first round found no critical issue, one high (launch in another curator's name; fixed by §4.1 and the curator-bound leaf), two medium (an unsellable work blocking finalize forever; hidden leaves for an index — fixed by the sale end and by §5's publication rule) and five low issues (fixed: `withdrawTo`, the launch-fee cap, reentrancy from the launch refund, `tokenOf` not relying on id 0, and refusing stray circuits). The second round covered the reserve, limit, presale, royalty and page code and found no critical issue; its contract and tool findings were fixed (a limited sale now sells only to the buyer's own wallet, so no one can use up a stranger's quota; a zero presale start and a treasury that is the vault or the registry are refused; `checkroot` now rebuilds every work and allowlist entry and compares every launch setting with the chain), and so were its page findings (see Web page below). A third round re-checked the final code and found no critical, high or medium issue; its low findings were fixed or are listed below (Reserved works, Treasury contract, Work lists, Sale end, Payees). A fourth round reviewed the metadata additions (§11–§12 and the tool and page code for them) and found no critical issue; its findings were fixed: a percent-encoded `..` in an image path could leave a content-addressed root, an IPNS key written as an `ipfs://` CID passed the check, a 43-character ArNS undername could in principle pass as an Arweave id (now refused by the upper-case rule), tools did not read the directory back before launch, and metadata files were not written as UTF-8 on every platform. Every on-chain fix has a regression test; the hidden-leaf finding is addressed by the publication rule of §5, which `checkroot` and the reference page enforce.
- **Metadata availability.** The registry fixes the address of the metadata, not its availability. Files on IPFS disappear if no one keeps them pinned; curators should pin them with more than one provider or use Arweave. A front-end that fetches files through an HTTP gateway trusts that gateway to serve the content the address names; it may check the content against the address. A collection launched with an unreachable or wrong directory cannot correct it (§11.1), so tools should read the directory back before launch.
- **What "official" does not promise.** The registry certifies where a circuit came from, not what it does. A curator can list any well-formed netlist, including one that REFs circuits on other processors, whose behaviour then depends on those circuits (TAP-02, Security Considerations).
- **Foreign circuits still appear in the collection.** Pure-REF wrappers can always be taped out into any processor. This TAP makes them distinguishable; it does not and cannot prevent them. Front-ends that ignore §7 will keep showing them.
- **Vault assets.** The vault holds transistors that are only usable on its own processor, and holds sale proceeds until they are withdrawn by or for the fixed payees. It has no owner. Every sale and claim updates the vault's state before its external calls, and every state-changing entry point that makes external calls (`initialize`, `buy`, `buyPresale`, `claimReserved`, `claimReservedBatch`, `withdraw`, `withdrawTo`, `finalize`) shares one re-entry guard (`setPaused` and `extendSale` make no external calls); `receive` is unguarded but accepts the native coin only from the processor's transistor contract.
- **Contract and EIP-7702 buyers.** The circuit is sent with `safeTransferFrom`. A recipient with code that does not implement `onERC721Received` makes the purchase revert, so no funds are lost; buyers can name a different recipient. Note that some well-known EOAs on BNB Smart Chain and Base carry EIP-7702 delegations.
- **First come, first served.** Netlists and proofs are public, so bots can take price-0 or underpriced works as soon as the sale opens, and two buyers can race for the same index (the loser's transaction reverts). A blind or commit-reveal sale avoids this and can be built on the same registry.
- **Reserved works.** The treasury holds reserved works like any other circuits, so its key is what protects them; a multisig is recommended. A reserved work can be claimed until the leftover transistors are burned, which anyone can do once the sale has ended and every reserved work is claimed, or otherwise once `RESERVE_GRACE` has passed after the sale end; a reserved work not claimed by then is lost.
- **Treasury contract.** Reserved works are sent to the treasury with `safeTransferFrom`. A treasury contract that does not accept ERC-721 transfers makes every claim revert, and the reserved works are lost when the vault is finalized. Multi-signature wallets such as Safe accept them; curators should claim one reserved work right after launch to confirm.
- **Work lists.** Leaves are bound to the chain, the registry and the curator, not to one collection. A curator who reuses a work list or an allowlist in a second collection makes every proof valid in both; tools should build a fresh list per collection, and front-ends identify a collection by its chain id and processor address, never by its name.
- **Sale end.** Until the sale ends, unsold works stay buyable and the leftover transistors stay in the vault. A very distant sale end (the test fixture uses the year 2100) means the supply is effectively never burned; curators should choose a realistic one.
- **Payees.** Proceeds are pulled. A payee contract that can neither receive the native coin nor call `withdrawTo` locks its own share; the vault rejects only the vault and the registry as payees.
- **Sale controls.** The curator can pause buying for as long as it likes and can keep moving the sale end later, which also postpones `finalize` and the burn of leftover transistors. Buyers cannot force a purchase while a sale is paused, and an attacker who obtains the curator key can pause or extend the sale (but cannot take proceeds, change prices or add works). Holders and the officialness of sold works are never affected. Front-ends should read `paused()` and the current `SALE_END()` rather than the launch values.
- **Curator key.** The curator address can never be changed. If its key is lost, unclaimed reserved works can no longer be claimed and the royalty can no longer be changed, and proceeds can still be withdrawn but only to that address. This is deliberate (see Rationale).
- **Pure-REF works.** A listed work made only of REF records burns no transistors, so anyone can tape out a byte-identical copy of it into the curated processor. The copy is not official, but it looks the same; tools warn about such works.
- **Fee changes.** The vault reads `TAPEOUT_FEE()` at purchase time, so a fee change is passed to buyers rather than breaking sales.
- **Netlist size.** Tape-outs above about 34,000 bytes fail on BNB Smart Chain mainnet (other chains' block gas limits may differ); the tool rejects them. Large works should be split into sub-circuits joined by REF.
- **Merkle leaves** are double-hashed, so an inner node cannot be presented as a leaf.
- **Web page.** The page treats the manifest as untrusted. It takes the chain, the RPC, the registry and the processor only from its own `site.json` (URL overrides work on localhost only), checks that the vault belongs to that registry, rebuilds every work leaf and the allowlist root from the manifest and refuses to load if any differs from the chain, inserts every manifest value as text, loads its script from its own origin under a strict content security policy, and pins the ethers library with a subresource-integrity hash. A circuit that is official in a different collection is reported as not belonging to this one, never as official. It also rebuilds the metadata commitment (§10) and refuses a manifest whose name, symbol, story or titles differ from it.
- **No audit yet.** The reference implementation has had internal reviews only. It should not hold significant value before an independent audit.

## Copyright

Copyright and related rights waived via [CC0](../LICENSE).
