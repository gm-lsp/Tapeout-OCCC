// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CuratedHiddenBase} from "./CuratedHiddenBase.sol";
import {LaunchParams, INSTANT_REVEAL} from "./CuratedTypes.sol";

/// @title CuratedRevealVault — instant reveal (sale mode 1)
/// @notice A buyer buys a slot in a price pool. From the block after the purchase, whoever holds the slot's secret
/// (committed at launch in SECRETS_ROOT; in practice the platform's server) draws the slot's work from the pool's
/// remaining works, strictly in purchase order within the pool, and tapes it out to the buyer. The draw uses
/// keccak256(abi.encode(secret, blockhash(anchor + 1))), anchor = the purchase block: the server cannot predict it
/// before that block, and cannot choose it afterwards, because the secret is fixed and the order is fixed. The hash is
/// locked as soon as anyone acts (any later purchase, fulfil or lockHash); if nobody does for 256 blocks it is gone,
/// and the slot must be re-anchored to a new block (rearm) before it can be drawn. Unsold works stay unpublished.
contract CuratedRevealVault is CuratedHiddenBase {
    bytes32 public constant SLOT_SECRET_TAG = keccak256("TAP-curated-slot-secret");

    /// @notice positional tree of one secret per slot: slot k at position k - 1 (see _verifyAt)
    bytes32 public SECRETS_ROOT;
    uint8 public SECRET_DEPTH;
    // per-pool purchase queue and the draw ("swap and pop" over the pool's positions)
    mapping(uint32 pool => mapping(uint256 pos => uint256 slot)) public queue;
    mapping(uint32 pool => uint32) public queueHead;
    mapping(uint32 pool => uint32) public remaining;
    mapping(uint32 pool => mapping(uint256 => uint256)) internal _drawMap; // position + 1; 0 = identity

    /// @notice the hash of the block after an anchor block (a purchase block, or a rearm), kept once locked
    mapping(uint256 blockNumber => bytes32) public lockedHash;
    // anchor blocks whose next hash is not locked yet, in order
    mapping(uint256 => uint64) internal _pend;
    uint128 internal _pendHead;
    uint128 internal _pendLen;

    event Drawn(uint256 indexed slot, uint256 indexed index);
    event Rearmed(uint256 indexed slot, uint256 anchorBlock);

    error HashExpired();

    function _initMode(LaunchParams calldata p) internal override {
        _initPools(p, INSTANT_REVEAL);
        SECRETS_ROOT = p.hidden.secretsRoot;
        SECRET_DEPTH = _depth(POOLED);
        for (uint256 i; i < p.hidden.poolCounts.length; i++) {
            remaining[uint32(i)] = p.hidden.poolCounts[i];
        }
    }

    function _onSlot(uint256 slot, uint32 pool, uint32 pos, address) internal override {
        queue[pool][pos] = slot;
        _anchor(block.number);
    }

    /// @dev lock every pending anchor whose next hash exists, then record `b` as an anchor
    function _anchor(uint256 b) internal {
        _lockPending();
        uint128 len = _pendLen;
        if (len == _pendHead || _pend[len - 1] != b) {
            _pend[len] = uint64(b);
            _pendLen = len + 1;
        }
    }

    function _lockPending() internal {
        uint128 h = _pendHead;
        uint128 len = _pendLen;
        for (uint256 n; n < 8 && h < len && uint256(_pend[h]) + 1 < block.number; n++) {
            _lock(uint256(_pend[h]) + 1);
            h++;
        }
        _pendHead = h;
    }

    /// @notice Lock the pending block hashes (every anchor's next hash that exists), and the one slot `slot` draws
    /// with, so draws no longer depend on when slots are fulfilled. Anyone may call (the buyer, the platform); every
    /// purchase and fulfil does it too.
    function lockHash(uint256 slot) external {
        Slot storage s = slots[slot];
        if (s.state == 0) revert NotPending();
        if (block.number <= uint256(s.boughtBlock) + 1) revert TooEarly();
        _lockPending();
        _lock(uint256(s.boughtBlock) + 1);
    }

    function _lock(uint256 b) internal {
        if (lockedHash[b] != 0) return;
        bytes32 h = blockhash(b);
        if (h != 0) lockedHash[b] = h;
    }

    /// @notice A pending slot whose hash was never locked and is gone (more than 256 blocks) is re-anchored to this
    /// block: its draw will use the hash of the next block. Anyone may call. (A fixed fallback value would be known in
    /// advance to the secret's holder, who could then choose between it and the real hash by waiting.)
    function rearm(uint256 slot) external {
        Slot storage s = slots[slot];
        if (s.state != PENDING) revert NotPending();
        uint256 b = uint256(s.boughtBlock) + 1;
        if (block.number <= b || lockedHash[b] != 0 || blockhash(b) != 0) revert TooEarly();
        s.boughtBlock = uint64(block.number);
        _anchor(block.number);
        emit Rearmed(slot, block.number);
    }

    /// @notice The leaf committing to slot `slot`'s secret, bound to the work-list root.
    function secretLeafOf(uint256 slot, bytes32 s) public view returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(block.chainid, address(REGISTRY), CURATOR, SLOT_SECRET_TAG, ROOT, slot, s)))
        );
    }

    // ------------------------------------------------------------------ instant reveal

    /// @notice Instant reveal: draw slot `slot`'s work and tape it out to the slot's recipient. Anyone holding the
    /// slot's secret may call (in practice the platform's server); slots of a pool are served strictly in purchase
    /// order, from the block after the purchase. The caller passes the work the draw selects; `uri` (optional) is
    /// the content-addressed metadata file of that work. The caller's gas is repaid from the slot's reveal fee.
    function fulfill(
        uint256 slot,
        bytes32 slotSecret,
        bytes32[] calldata secretProof,
        HiddenWork calldata w,
        string calldata uri
    ) external nonReentrant returns (uint256 tokenId) {
        uint256 g0 = gasleft();
        _lockPending();
        Slot storage s = _turn(slot);
        uint256 index = _draw(slot, s, slotSecret, secretProof);
        if (w.index != index) revert WrongWork(index);
        _checkHidden(w, s.pool);
        s.state = DELIVERED;
        slotsSettled += 1;
        tokenId = _deliver(slot, s, w);
        if (bytes(uri).length != 0) REGISTRY.declareTokenURI(address(circuits), tokenId, uri);
        // calldata is repaid only for what the call needs (netlist, proofs, a bounded rest), so padding pays nothing
        _settleGas(s, g0 - gasleft() + TX_BASE_GAS + _calldataGas(w) + 512 * secretProof.length);
    }

    /// @notice Curator only: declare the metadata file of a delivered circuit that was taped out without one (the
    /// registry accepts one file per circuit, ever).
    function declareURI(uint256 slot, string calldata uri) external {
        _onlyCurator();
        if (slots[slot].state != DELIVERED) revert NotPending();
        REGISTRY.declareTokenURI(address(circuits), circuitOfSlot[slot], uri);
    }

    /// @notice Instant reveal, curator only, once the sale is over (sold out or past its end): refund the next slot of a
    /// pool that can no longer be delivered because TapeOut's fee has risen above what the slot holds (anyone may top
    /// it up instead, topUp). Only then: otherwise a curator who can compute the draw could refund exactly the buyers
    /// who drew rare works. The slot's draw is still
    /// made and the drawn work is withdrawn from sale, so a refund never changes which work any other slot gets. The
    /// curator sends the price back with the call (native: exactly as msg.value; token: approved to this vault); the
    /// slot's tape-out and reveal fees go back to its holder too.
    function refundPending(uint256 slot, bytes32 slotSecret, bytes32[] calldata secretProof)
        external
        payable
        nonReentrant
    {
        _onlyCurator();
        Slot storage s = _turn(slot);
        if (!_saleOver() || circuits.TAPEOUT_FEE() <= uint256(s.feeHeld) + REVEAL_FEE) revert NotRefundable();
        _draw(slot, s, slotSecret, secretProof);
        if (_refund(slot, s, msg.value) != 0) revert WrongPayment(s.paid);
    }

    /// @dev the slot must be pending and first in its pool's queue
    function _turn(uint256 slot) internal returns (Slot storage s) {
        s = slots[slot];
        if (s.state != PENDING) revert NotPending();
        uint32 head = queueHead[s.pool];
        if (queue[s.pool][head] != slot) revert NotItsTurn();
        queueHead[s.pool] = head + 1;
    }

    /// @dev seed = keccak256(abi.encode(secret, h)), h = the hash of the block after the slot's anchor (locked, or
    /// read now); HashExpired if it is gone (rearm); position = seed mod remaining, swap-and-pop over the pool.
    function _draw(uint256 slot, Slot storage s, bytes32 slotSecret, bytes32[] calldata secretProof)
        internal
        returns (uint256 index)
    {
        if (!_verifyAt(secretProof, SECRETS_ROOT, secretLeafOf(slot, slotSecret), slot - 1, SECRET_DEPTH)) {
            revert InvalidSecret();
        }
        if (block.number <= uint256(s.boughtBlock) + 1) revert TooEarly();
        uint256 b = uint256(s.boughtBlock) + 1;
        bytes32 bh = lockedHash[b];
        if (bh == 0) bh = blockhash(b);
        if (bh == 0) revert HashExpired();
        uint32 p = s.pool;
        uint32 rem = remaining[p];
        uint256 j = uint256(keccak256(abi.encode(slotSecret, bh))) % rem;
        uint256 last = rem - 1;
        uint256 vj = _drawMap[p][j];
        uint256 vl = _drawMap[p][last];
        uint256 pick = vj == 0 ? j : vj - 1;
        _drawMap[p][j] = (vl == 0 ? last : vl - 1) + 1;
        remaining[p] = rem - 1;
        index = uint256(poolStart[p]) + pick;
        emit Drawn(slot, index);
    }
}
