// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {CuratedVaultBase} from "./CuratedVaultBase.sol";
import {LaunchParams} from "./CuratedTypes.sol";

/// @title CuratedHiddenBase — what instant reveal (sale mode 1, CuratedRevealVault) and blind box (sale mode 2,
/// CuratedBlindBoxVault) share
/// @notice Buyers buy a slot in a price pool, not a work. Which work a slot gets is decided by randomness nobody can
/// predict or choose: in instant reveal, from the slot's committed secret and the hash of the block after the purchase,
/// drawn from the pool's remaining works in purchase order; in a blind box, by a random permutation of the pool fixed
/// from the revealed secret and the hash of the block after the reveal. Unsold works stay unpublished during the sale.
/// In blind-box mode every slot is a transferable pass (this contract is its ERC-721); a pass is burned in the same
/// transaction that tapes its work out to the pass's holder at that moment.
abstract contract CuratedHiddenBase is CuratedVaultBase {
    using SafeERC20 for IERC20;

    bytes32 public constant HIDDEN_WORK_TAG = keccak256("TAP-curated-hidden-work");
    bytes32 public constant POOL_PRICE_TAG = keccak256("TAP-curated-presale-pool-price");
    /// @notice pool number of reserved works in their leaves
    uint32 public constant NO_POOL = type(uint32).max;
    /// @dev intrinsic gas of a transaction, added (shared per slot) to the gas measured for a fulfil or redeem
    uint256 internal constant TX_BASE_GAS = 21_000;

    uint8 internal constant PENDING = 1;
    uint8 internal constant DELIVERED = 2;
    uint8 internal constant REFUNDED = 3;

    struct Slot {
        address holder; // the buyer's recipient; in blind-box mode the pass's current holder
        uint64 boughtBlock;
        uint32 pool;
        uint32 pos; // position among the pool's slots, in purchase order (0-based)
        uint8 state;
        uint128 paid; // what the buyer paid for the work (payment asset)
        uint96 feeHeld; // tape-out fee paid with the slot (native coin)
    }

    uint256[] public poolPrice;
    uint32[] public poolCount;
    uint32[] public poolStart;
    uint32[] public poolSold; // slots bought per pool (refunded slots included)
    uint256 public REVEAL_FEE;
    uint256 public REVEAL_GAS_PRICE;
    bytes32 public METADATA_ROOT;
    uint32 public POOLED; // works in all pools; reserved works are [POOLED, COUNT)
    /// @notice depth of the work-list tree: a positional tree of 2^depth leaves, leaf i at position i (see _verifyAt)
    uint8 public WORK_DEPTH;

    uint32 public slotsSold;
    uint32 public slotsSettled; // delivered or refunded
    mapping(uint256 slot => Slot) public slots;
    mapping(uint256 slot => uint256) public circuitOfSlot; // tape-out id of a delivered slot (0 before)
    /// @notice native coin the curator set aside to make up any slot whose fees fall short (fundFees)
    uint256 public feeReserve;
    mapping(uint256 index => bool) public taken; // reserved works claimed

    event SlotBought(uint256 indexed slot, uint32 indexed pool, address indexed recipient, uint256 price);
    event SlotDelivered(uint256 indexed slot, uint256 indexed index, uint256 indexed tokenId, address holder);
    event SlotRefunded(uint256 indexed slot, address indexed holder, uint256 price);
    event ReservedClaimed(uint256 indexed index, uint256 indexed tokenId, address indexed treasury);
    event FeeReserveFunded(address indexed from, uint256 amount);
    /// @notice the reserve made up `amount` of a slot's tape-out fee or gas repayment
    event FeeReserveUsed(uint256 indexed slot, uint256 amount);
    event FeeReserveWithdrawn(uint256 amount);

    error WrongMode();
    error NoSuchPool();
    error PoolSoldOut();
    error NotPending();
    error NotItsTurn();
    error TooEarly();
    error InvalidSecret();
    error WrongWork(uint256 expected);
    error FeeShortfall();
    error NotRevealable();
    error AlreadyRevealed();
    error NotRevealed();
    error NotClaimableYet();
    error NotRefundable();
    error NotAuthorized();
    error NotPass();
    error UnsafeRecipient();

    struct HiddenWork {
        uint256 index;
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        bytes32[] proof;
    }

    /// @dev the registry has checked the pools and the secrets (CuratedRegistry._check)
    function _initPools(LaunchParams calldata p, uint8 mode) internal {
        if (p.saleMode != mode) revert WrongMode();
        uint32 start;
        for (uint256 i; i < p.hidden.poolPrices.length; i++) {
            uint32 c = p.hidden.poolCounts[i];
            poolPrice.push(p.hidden.poolPrices[i]);
            poolCount.push(c);
            poolStart.push(start);
            poolSold.push(0);
            start += c;
        }
        POOLED = start;
        WORK_DEPTH = _depth(p.count);
        REVEAL_FEE = p.hidden.revealFee;
        REVEAL_GAS_PRICE = p.hidden.revealGasPrice;
        METADATA_ROOT = p.hidden.metadataRoot;
    }

    // ------------------------------------------------------------------ leaves

    /// @dev the smallest d with 2^d >= n
    function _depth(uint256 n) internal pure returns (uint8 d) {
        while ((uint256(1) << d) < n) d++;
    }

    /// @dev A positional Merkle tree: `depth` levels, leaf `position` hashed with its siblings in position order
    /// (keccak256(left ‖ right)), unused positions bytes32(0). Unlike a sorted-pair tree, it holds exactly one leaf per
    /// position, so a hidden list can never carry a second leaf for the same work or slot: before the reveal nobody
    /// could see one, and whoever delivers could pick between them.
    function _verifyAt(bytes32[] calldata proof, bytes32 root, bytes32 leaf, uint256 position, uint8 depth)
        internal
        pure
        returns (bool)
    {
        if (proof.length != depth || position >> depth != 0) return false;
        bytes32 h = leaf;
        for (uint256 i; i < depth; i++) {
            h = (position >> i) & 1 == 0 ? keccak256(abi.encode(h, proof[i])) : keccak256(abi.encode(proof[i], h));
        }
        return h == root;
    }

    /// @notice The Merkle leaf of a work in a hidden collection: like the instant leaf, but tagged and with the work's
    /// pool instead of a price (reserved works: pool NO_POOL).
    function hiddenLeafOf(uint256 index, bytes32 netlistHash, uint32 nIn, uint32 nOut, uint32 pool, bool reserved)
        internal
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid, address(REGISTRY), CURATOR, HIDDEN_WORK_TAG, index, netlistHash, nIn, nOut, pool, reserved
                    )
                )
            )
        );
    }

    /// @notice The presale price leaf of a pool for allowlist tier `tier`, bound to the work-list root.
    function presalePriceLeafOf(uint256 pool, uint32 tier, uint256 presalePrice) internal view returns (bytes32) {
        return _priceLeaf(POOL_PRICE_TAG, pool, tier, presalePrice);
    }

    // ------------------------------------------------------------------ buying slots

    /// @notice Buy a slot in `pool` in the public sale. Pay `poolPrice[pool] + TAPEOUT_FEE() + REVEAL_FEE` (with a
    /// payment token: the price in the token, the two fees in native coin).
    function buySlot(uint32 pool, address recipient) external payable nonReentrant returns (uint256 slot) {
        if (block.timestamp < SALE_START) revert SaleNotStarted();
        if (pool >= poolPrice.length) revert NoSuchPool();
        return _buySlot(pool, poolPrice[pool], recipient);
    }

    /// @notice Buy a slot in `pool` in the presale; presale prices are per pool and tier (see _presale).
    function buySlotPresale(
        uint32 pool,
        address recipient,
        uint32 quota,
        uint32 tier,
        bytes32[] calldata allowProof,
        uint256 presalePrice,
        bytes32[] calldata presaleProof
    ) external payable nonReentrant returns (uint256 slot) {
        if (pool >= poolPrice.length) revert NoSuchPool();
        uint256 charge =
            _presale(POOL_PRICE_TAG, pool, poolPrice[pool], quota, tier, allowProof, presalePrice, presaleProof);
        return _buySlot(pool, charge, recipient);
    }

    function _buySlot(uint32 pool, uint256 charge, address recipient) internal returns (uint256 slot) {
        _checkOpen();
        uint32 pos = poolSold[pool];
        if (pos >= poolCount[pool]) revert PoolSoldOut();
        uint256 fee = circuits.TAPEOUT_FEE();
        uint256 due = (PAYMENT_TOKEN == address(0) ? charge : 0) + fee + REVEAL_FEE;
        if (msg.value != due) revert WrongPayment(due);
        _countWallet(recipient);
        if (recipient == address(this)) revert ZeroRecipient();
        poolSold[pool] = pos + 1;
        slot = ++slotsSold;
        slots[slot] = Slot(recipient, uint64(block.number), pool, pos, PENDING, uint128(charge), uint96(fee));
        _onSlot(slot, pool, pos, recipient);
        _pullToken(charge);
        emit SlotBought(slot, pool, recipient, charge);
        _distribute(charge);
    }

    /// @notice Mint refund. Curator only, once the sale is over: return the mint price paid for each delivered slot of
    /// `ids` to its circuit's current holder (once per slot). The circuit stays with its holder; the tape-out and
    /// reveal fees are not returned. The curator sends the total with the call (native coin: exactly; token: approved).
    function mintRefund(uint256[] calldata ids) external payable nonReentrant {
        _onlyCurator();
        if (!_saleOver()) revert SaleNotOver();
        uint256 left = msg.value;
        for (uint256 i; i < ids.length; i++) {
            Slot storage s = slots[ids[i]];
            if (s.state != DELIVERED) revert NothingToRefund();
            uint256 a = s.paid;
            s.paid = 0;
            left = _mintRefund(ids[i], circuits.ownerOf(circuitOfSlot[ids[i]]), a, left);
        }
        if (left != 0) revert WrongPayment(msg.value - left);
    }

    /// @notice Where the surplus of hidden slots' fees goes: the platform, or the payee when there is none.
    function _feeCollector() internal view returns (address) {
        return PLATFORM != address(0) ? PLATFORM : payee;
    }

    /// @dev credits what is left of a slot's fees to the fee collector, who withdraws it (withdraw / withdrawTo)
    function _surplus(uint256 slot, uint256 amount) internal {
        if (amount == 0) return;
        owedNative[_feeCollector()] += amount;
        emit FeeSurplus(slot, amount);
    }

    /// @dev mode-specific bookkeeping of a new slot
    function _onSlot(uint256 slot, uint32 pool, uint32 pos, address recipient) internal virtual;

    /// @dev every pool sold out, or the sale end passed: refunds, reserved claims and the blind-box reveal wait for it
    function _saleOver() internal view returns (bool) {
        return block.timestamp >= saleEnd || soldOut();
    }

    /// @notice True once every pool has sold all its slots.
    function soldOut() public view returns (bool) {
        for (uint256 i; i < poolCount.length; i++) {
            if (poolSold[i] < poolCount[i]) return false;
        }
        return true;
    }

    // ------------------------------------------------------------------ shared delivery

    function _checkHidden(HiddenWork calldata w, uint32 pool) internal view {
        if (!_verifyAt(w.proof, ROOT, hiddenLeafOf(w.index, keccak256(w.netlist), w.nIn, w.nOut, pool, false), w.index, WORK_DEPTH))
        {
            revert InvalidProof();
        }
    }

    function _deliver(uint256 slot, Slot storage s, HiddenWork calldata w) internal returns (uint256 tokenId) {
        uint256 fee = circuits.TAPEOUT_FEE();
        uint256 have = uint256(s.feeHeld) + REVEAL_FEE;
        // TapeOut raised its fee above what the slot paid: the curator's reserve makes up the difference
        if (fee > have) have += _fromReserve(slot, fee - have, true);
        tokenId = _tapeOut(w.index, w.netlist, w.nIn, w.nOut, s.holder, false, fee);
        circuitOfSlot[slot] = tokenId;
        // what is left of the slot's fees after the tape-out: the reveal budget
        s.feeHeld = uint96(have - fee);
        emit SlotDelivered(slot, w.index, tokenId, s.holder);
    }

    /// @notice Add native coin to the fee reserve, which makes up any slot's shortfall: a tape-out fee TapeOut raised
    /// above what the slot paid, or gas dearer than the slot's reveal fee covers (still at most REVEAL_GAS_PRICE).
    /// Meant for the curator, so that the project, not its buyers, bears a shortfall; anyone may add.
    function fundFees() external payable {
        feeReserve += msg.value;
        emit FeeReserveFunded(msg.sender, msg.value);
    }

    /// @notice Curator only: take back what is left of the fee reserve, once the sale is over and every slot is
    /// delivered or refunded (so no slot can still need it).
    function withdrawFeeReserve() external nonReentrant {
        _onlyCurator();
        if (!_saleOver() || slotsSettled != slotsSold) revert NotClaimableYet();
        uint256 r = feeReserve;
        feeReserve = 0;
        _sendNative(msg.sender, r);
        emit FeeReserveWithdrawn(r);
    }

    /// @dev takes up to `need` from the reserve for `slot` (all of it, or FeeShortfall, when `all`); returns the amount
    function _fromReserve(uint256 slot, uint256 need, bool all) internal returns (uint256 d) {
        uint256 r = feeReserve;
        if (need > r) {
            if (all) revert FeeShortfall();
            need = r;
        }
        if (need == 0) return 0;
        feeReserve = r - need;
        emit FeeReserveUsed(slot, need);
        return need;
    }

    /// @dev the call data a delivery of `w` needs: its netlist and proof, plus a bounded rest (16 gas per byte)
    function _calldataGas(HiddenWork calldata w) internal pure returns (uint256) {
        return 16 * w.netlist.length + 512 * w.proof.length + 16 * 640;
    }

    /// @dev repays the caller gas used x min(gas price, REVEAL_GAS_PRICE) from the slot's remaining budget, made up
    /// from the fee reserve as far as it goes; what the slot does not need is surplus, credited to the fee collector
    function _settleGas(uint256 slot, Slot storage s, uint256 gasUsed) internal {
        uint256 budget = s.feeHeld;
        s.feeHeld = 0;
        uint256 gp = tx.gasprice < REVEAL_GAS_PRICE ? tx.gasprice : REVEAL_GAS_PRICE;
        uint256 cost = gasUsed * gp;
        if (cost > budget) {
            // gas dearer than the slot's budget: the reserve makes up what it can
            _sendNative(msg.sender, budget + _fromReserve(slot, cost - budget, false));
        } else {
            _sendNative(msg.sender, cost);
            _surplus(slot, budget - cost);
        }
    }

    /// @dev returns `paid` (from the curator) and the slot's fees, never spent (nothing was taped out), to its holder;
    /// returns what is left of `value`
    function _refund(uint256 slot, Slot storage s, uint256 value) internal returns (uint256) {
        s.state = REFUNDED;
        slotsSettled += 1;
        uint256 paid = s.paid;
        if (paid > 0) value = _payBack(s.holder, paid, value);
        uint256 fees = uint256(s.feeHeld) + REVEAL_FEE;
        s.feeHeld = 0;
        _sendNative(s.holder, fees);
        emit SlotRefunded(slot, s.holder, paid);
        return value;
    }

    // ------------------------------------------------------------------ reserved works

    /// @notice Tape out reserved works to the treasury. Curator only; in hidden collections only once every slot is
    /// sold or the sale has ended (a tape-out publishes the netlist), and until finalize. Pays TAPEOUT_FEE() per work.
    function claimReservedBatch(HiddenWork[] calldata works) external payable nonReentrant returns (uint256[] memory ids) {
        _onlyCurator();
        if (!_saleOver()) revert NotClaimableYet();
        uint256 fee = circuits.TAPEOUT_FEE();
        if (msg.value != fee * works.length) revert WrongPayment(fee * works.length);
        ids = new uint256[](works.length);
        for (uint256 i; i < works.length; i++) {
            HiddenWork calldata w = works[i];
            _reservedCheck(w.index, w.index < POOLED || (w.index < COUNT && taken[w.index]));
            if (!_verifyAt(w.proof, ROOT, hiddenLeafOf(w.index, keccak256(w.netlist), w.nIn, w.nOut, NO_POOL, true), w.index, WORK_DEPTH))
            {
                revert InvalidProof();
            }
            taken[w.index] = true;
            ids[i] = _tapeOut(w.index, w.netlist, w.nIn, w.nOut, TREASURY, true, fee);
            emit ReservedClaimed(w.index, ids[i], TREASURY);
        }
    }

    /// @notice Every slot delivered or refunded, and then: every pool sold out and every reserved work claimed, or
    /// the sale over and the reserved works claimed (or RESERVE_GRACE passed).
    function finalizable() public view override returns (bool) {
        if (slotsSettled != slotsSold) return false;
        if (soldOut() && reservedClaimed == RESERVED_COUNT) return true;
        return _endedAndReservedDone();
    }


}
