// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// How a collection sells (fixed at launch).
//   0 INSTANT_TAPEOUT  the buyer picks a listed work (or, in a sequential collection, the next one) and it is taped out
//                      in the purchase transaction; the work list is public from the start.
//   1 INSTANT_REVEAL   the buyer buys a slot in a price pool; the work is drawn at random from the pool's remaining
//                      works one block later and taped out to the buyer by whoever holds the slot's secret.
//   2 BLIND_BOX        the buyer gets a transferable pass; after the sale the curator reveals, every pass is assigned
//                      a work by a random permutation of its pool, and anyone redeems passes into circuits.
uint8 constant INSTANT_TAPEOUT = 0;
uint8 constant INSTANT_REVEAL = 1;
uint8 constant BLIND_BOX = 2;

/// @notice Parameters of the hidden sale modes (1 and 2); all zero / empty for mode 0.
struct HiddenParams {
    uint256[] poolPrices; // price of one slot in each pool (payment asset); pools are public
    uint32[] poolCounts; // works in each pool; pool p holds work indexes [start_p, start_p + count_p) in pool order,
    // and reserved works follow all pools
    uint256 revealFee; // native coin paid with every slot, held for the gas of the transaction that tapes it out
    uint256 revealGasPrice; // the highest gas price at which that gas is repaid (so a caller cannot take the budget
    // by bidding a high price, e.g. a block producer including its own transaction)
    bytes32 secretsRoot; // mode 1: Merkle root of one secret per slot
    bytes32 secretHash; // mode 2: keccak256 of the reveal secret
    bytes32 metadataRoot; // commitment to every work's content (checked off chain, see the TAP)
    string passURI; // mode 2: metadata of an unopened pass (content-addressed file, or "")
}

struct LaunchParams {
    string name;
    string symbol;
    string story;
    uint256 nandSupply; // NAND to mint: sum of NAND records over all works (plus spare)
    uint256 latchSupply; // LATCH to mint: sum of LATCH records over all works (plus spare)
    uint256 mintPrice; // processor mint price; 0, or >0 to meet front-end display thresholds
    uint256 mintBatch; // batch size for the mint/withdraw loop when mintPrice > 0
    bytes32 root; // Merkle root of the work list
    uint32 count; // number of works (every copy counts)
    address curator; // launches the collection and runs it
    address platform; // optional platform fee recipient (address(0) = none)
    uint16 platformBps; // platform share of each sale, at most MAX_PLATFORM_BPS
    uint64 saleStart; // unix time when the public sale opens
    uint64 saleEnd; // unix time after which buying closes
    uint256 maxLaunchFees; // cap on deploy fee + protocol fees paid at launch (guards against fee changes)
    address treasury; // receives every reserved work; fixed at launch (address(0) if none are reserved)
    uint32 reservedCount; // number of works marked reserved in the work list; fixed at launch
    bool limitPerWallet; // false = no per-wallet limit; true = at most maxPerWallet public purchases per wallet
    uint32 maxPerWallet; // the limit when limitPerWallet is true (at least 1); must be 0 when it is false
    bytes32 allowRoot; // Merkle root of the presale allowlist (wallet, quota, tier); bytes32(0) = no presale
    uint64 presaleStart; // unix time when the presale opens; must be before saleStart; 0 when there is no presale
    address royaltyReceiver; // optional royalty declaration for resales (ERC-2981 style); address(0) = none
    uint16 royaltyBps; // royalty rate in basis points, at most the registry's MAX_ROYALTY_BPS; 0 when none
    bytes32 titlesHash; // keccak256 of the keccak256 of every work title (UTF-8), in index order
    string metadataURI; // mode 0: content-addressed directory of <index>.json files, or ""; modes 1, 2: must be ""
    address paymentToken; // ERC-20 that prices are paid in; address(0) = the chain's native coin
    bytes32 presalePriceRoot; // presale prices per tier: (index, tier, price) in mode 0, (pool, tier, price) in modes 1, 2
    uint8 saleMode; // INSTANT_TAPEOUT, INSTANT_REVEAL or BLIND_BOX
    bool sequential; // mode 0 only: works are sold strictly in list order from runs of copies (see runLeafOf)
    address payee; // receives the curator's share of every sale directly; the curator may change it later
    HiddenParams hidden; // modes 1, 2
}

interface ICuratedVaultInit {
    function initialize(LaunchParams calldata p, address refundTo) external payable returns (address t, address c);
}
