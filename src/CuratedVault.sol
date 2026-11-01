// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {CuratedVaultBase} from "./CuratedVaultBase.sol";
import {LaunchParams, INSTANT_TAPEOUT} from "./CuratedTypes.sol";

/// @title CuratedVault — instant tape-out (sale mode 0)
/// @notice The work list is public; a buyer pays and the vault tapes the work out to the buyer in the same transaction.
/// In a sequential collection works are sold strictly in list order, each run of copies one copy after another, so the
/// official serial number of every work (the order of official tape-outs, see the registry) equals its position in the
/// list plus one, and, while no one else tapes out on the processor, its TapeOut circuit id.
contract CuratedVault is CuratedVaultBase {
    /// @dev domain tag of presale price leaves keyed by work index (or, in a sequential collection, by run start)
    bytes32 public constant PRESALE_PRICE_TAG = keccak256("TAP-curated-presale-price");
    /// @dev domain tag of run leaves (sequential collections)
    bytes32 public constant RUN_TAG = keccak256("TAP-curated-run");

    bool public SEQUENTIAL;
    mapping(uint256 index => bool) public taken;

    struct Sale {
        address minter; // the recipient of the sale
        uint96 price; // what was paid for the work; 0 once rebated
    }

    /// @notice who received each sold work and what was paid for it (for rebates)
    mapping(uint256 index => Sale) public saleOf;

    event Purchased(uint256 indexed index, uint256 indexed tokenId, address indexed recipient, uint256 price);
    event ReservedClaimed(uint256 indexed index, uint256 indexed tokenId, address indexed treasury);

    error WrongMode();
    error NotNext(uint256 next);

    function _initMode(LaunchParams calldata p) internal override {
        if (p.saleMode != INSTANT_TAPEOUT) revert WrongMode(); // the registry has checked p.hidden is empty
        SEQUENTIAL = p.sequential;
    }

    /// @notice The Merkle leaf of one work (OpenZeppelin double-hashed leaf), bound to this chain, this registry and
    /// this curator. `reserved` marks a work kept for the treasury. Used when the collection is not sequential.
    function leafOf(uint256 index, bytes32 netlistHash, uint32 nIn, uint32 nOut, uint256 price, bool reserved)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(block.chainid, address(REGISTRY), CURATOR, index, netlistHash, nIn, nOut, price, reserved))
            )
        );
    }

    /// @notice The Merkle leaf of a run in a sequential collection: `copies` identical works (same netlist, price and
    /// reserved flag) at indexes [first, first + copies). Each purchase tapes out the run's next copy.
    function runLeafOf(
        uint256 first,
        uint32 copies,
        bytes32 netlistHash,
        uint32 nIn,
        uint32 nOut,
        uint256 price,
        bool reserved
    ) public view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid, address(REGISTRY), CURATOR, RUN_TAG, first, copies, netlistHash, nIn, nOut, price, reserved
                    )
                )
            )
        );
    }

    /// @notice The presale price leaf: work `key` (in a sequential collection, the run starting at `key`) costs
    /// `presalePrice` for allowlist tier `tier`; bound to this collection's work-list root.
    function presalePriceLeafOf(uint256 key, uint32 tier, uint256 presalePrice) public view returns (bytes32) {
        return _priceLeaf(PRESALE_PRICE_TAG, key, tier, presalePrice);
    }

    // ------------------------------------------------------------------ any order (not sequential)

    /// @notice Buy work `index` in the public sale. Pay exactly `price + circuits.TAPEOUT_FEE()` (with a payment token:
    /// the tape-out fee in native coin and `price` in the token).
    function buy(
        uint256 index,
        bytes calldata netlist,
        uint32 nIn,
        uint32 nOut,
        uint256 price,
        bytes32[] calldata proof,
        address recipient
    ) external payable nonReentrant returns (uint256 tokenId) {
        if (block.timestamp < SALE_START) revert SaleNotStarted();
        return _sell(index, netlist, nIn, nOut, price, price, proof, recipient);
    }

    /// @notice Buy work `index` in the presale (see CuratedVaultBase._presale).
    function buyPresale(
        uint256 index,
        bytes calldata netlist,
        uint32 nIn,
        uint32 nOut,
        uint256 price,
        bytes32[] calldata proof,
        address recipient,
        uint32 quota,
        uint32 tier,
        bytes32[] calldata allowProof,
        uint256 presalePrice,
        bytes32[] calldata presaleProof
    ) external payable nonReentrant returns (uint256 tokenId) {
        uint256 charge = _presale(PRESALE_PRICE_TAG, index, price, quota, tier, allowProof, presalePrice, presaleProof);
        return _sell(index, netlist, nIn, nOut, price, charge, proof, recipient);
    }

    function _sell(
        uint256 index,
        bytes calldata netlist,
        uint32 nIn,
        uint32 nOut,
        uint256 price,
        uint256 charge,
        bytes32[] calldata proof,
        address recipient
    ) internal returns (uint256 tokenId) {
        if (SEQUENTIAL) revert WrongMode();
        _checkOpen();
        if (index >= COUNT) revert IndexOutOfRange();
        if (taken[index]) revert AlreadyTaken();
        if (!MerkleProof.verifyCalldata(proof, ROOT, leafOf(index, keccak256(netlist), nIn, nOut, price, false))) {
            revert InvalidProof();
        }
        tokenId = _deliver(index, netlist, nIn, nOut, charge, recipient);
    }

    // ------------------------------------------------------------------ sequential

    /// @notice Buy the next work of a sequential collection, which must be the next copy of the run starting at
    /// `first` (index `sold`). Pay as in `buy`.
    function buyNext(
        uint256 first,
        uint32 copies,
        bytes calldata netlist,
        uint32 nIn,
        uint32 nOut,
        uint256 price,
        bytes32[] calldata proof,
        address recipient
    ) external payable nonReentrant returns (uint256 tokenId) {
        if (block.timestamp < SALE_START) revert SaleNotStarted();
        return _sellNext(first, copies, netlist, nIn, nOut, price, price, proof, recipient);
    }

    /// @notice Buy the next work of a sequential collection in the presale; presale prices are keyed by run start.
    function buyNextPresale(
        uint256 first,
        uint32 copies,
        bytes calldata netlist,
        uint32 nIn,
        uint32 nOut,
        uint256 price,
        bytes32[] calldata proof,
        address recipient,
        uint32 quota,
        uint32 tier,
        bytes32[] calldata allowProof,
        uint256 presalePrice,
        bytes32[] calldata presaleProof
    ) external payable nonReentrant returns (uint256 tokenId) {
        uint256 charge = _presale(PRESALE_PRICE_TAG, first, price, quota, tier, allowProof, presalePrice, presaleProof);
        return _sellNext(first, copies, netlist, nIn, nOut, price, charge, proof, recipient);
    }

    function _sellNext(
        uint256 first,
        uint32 copies,
        bytes calldata netlist,
        uint32 nIn,
        uint32 nOut,
        uint256 price,
        uint256 charge,
        bytes32[] calldata proof,
        address recipient
    ) internal returns (uint256 tokenId) {
        if (!SEQUENTIAL) revert WrongMode();
        _checkOpen();
        uint256 index = _nextOfRun(first, copies);
        if (!MerkleProof.verifyCalldata(proof, ROOT, runLeafOf(first, copies, keccak256(netlist), nIn, nOut, price, false))) {
            revert InvalidProof();
        }
        tokenId = _deliver(index, netlist, nIn, nOut, charge, recipient);
    }

    /// @dev the next index in list order; it must lie in the run [first, first + copies)
    function _nextOfRun(uint256 first, uint32 copies) internal view returns (uint256 index) {
        index = sold;
        if (index >= COUNT) revert IndexOutOfRange();
        if (index < first || index >= first + copies) revert NotNext(index);
    }

    function _deliver(uint256 index, bytes calldata netlist, uint32 nIn, uint32 nOut, uint256 charge, address recipient)
        internal
        returns (uint256 tokenId)
    {
        uint256 fee = circuits.TAPEOUT_FEE();
        // native coin: charge + tape-out fee in msg.value; token: the tape-out fee in msg.value, the charge pulled below
        uint256 due = PAYMENT_TOKEN == address(0) ? charge + fee : fee;
        if (msg.value != due) revert WrongPayment(due);
        _countWallet(recipient);
        taken[index] = true;
        _pullToken(charge);
        tokenId = _tapeOut(index, netlist, nIn, nOut, recipient, false, fee);
        saleOf[index] = Sale(recipient, uint96(charge > type(uint96).max ? type(uint96).max : charge));
        emit Purchased(index, tokenId, recipient, charge);
        _distribute(charge);
    }

    // ------------------------------------------------------------------ reserved works

    struct ReservedWork {
        uint256 index;
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        bytes32[] proof;
    }

    /// @notice Tape out a work that the work list marks as reserved, and send it to the treasury. Curator only, until
    /// the vault is finalized; pays exactly `circuits.TAPEOUT_FEE()`. Not in sequential collections (claimReservedRun).
    function claimReserved(uint256 index, bytes calldata netlist, uint32 nIn, uint32 nOut, bytes32[] calldata proof)
        external
        payable
        nonReentrant
        returns (uint256 tokenId)
    {
        _onlyCurator();
        uint256 fee = circuits.TAPEOUT_FEE();
        if (msg.value != fee) revert WrongPayment(fee);
        tokenId = _claim(index, netlist, nIn, nOut, proof, fee);
    }

    /// @notice Claim several reserved works in one transaction; pays `TAPEOUT_FEE()` once per work.
    function claimReservedBatch(ReservedWork[] calldata works)
        external
        payable
        nonReentrant
        returns (uint256[] memory tokenIds)
    {
        _onlyCurator();
        uint256 fee = circuits.TAPEOUT_FEE();
        if (msg.value != fee * works.length) revert WrongPayment(fee * works.length);
        tokenIds = new uint256[](works.length);
        for (uint256 i; i < works.length; i++) {
            ReservedWork calldata w = works[i];
            tokenIds[i] = _claim(w.index, w.netlist, w.nIn, w.nOut, w.proof, fee);
        }
    }

    function _claim(uint256 index, bytes calldata netlist, uint32 nIn, uint32 nOut, bytes32[] calldata proof, uint256 fee)
        internal
        returns (uint256 tokenId)
    {
        if (SEQUENTIAL) revert WrongMode();
        _reservedCheck(index, index < COUNT && taken[index]);
        if (!MerkleProof.verifyCalldata(proof, ROOT, leafOf(index, keccak256(netlist), nIn, nOut, 0, true))) {
            revert InvalidProof();
        }
        taken[index] = true;
        tokenId = _tapeOut(index, netlist, nIn, nOut, TREASURY, true, fee);
        emit ReservedClaimed(index, tokenId, TREASURY);
    }

    /// @notice Sequential collections: claim the next `n` copies of a reserved run (they must be next in list order,
    /// so reserved runs belong at the start of the list and are claimed before the sale). Curator only.
    function claimReservedRun(
        uint256 first,
        uint32 copies,
        bytes calldata netlist,
        uint32 nIn,
        uint32 nOut,
        bytes32[] calldata proof,
        uint32 n
    ) external payable nonReentrant returns (uint256[] memory tokenIds) {
        _onlyCurator();
        if (!SEQUENTIAL) revert WrongMode();
        uint256 fee = circuits.TAPEOUT_FEE();
        if (msg.value != fee * n) revert WrongPayment(fee * n);
        if (!MerkleProof.verifyCalldata(proof, ROOT, runLeafOf(first, copies, keccak256(netlist), nIn, nOut, 0, true))) {
            revert InvalidProof();
        }
        tokenIds = new uint256[](n);
        for (uint256 i; i < n; i++) {
            uint256 index = _nextOfRun(first, copies);
            _reservedCheck(index, false);
            taken[index] = true;
            tokenIds[i] = _tapeOut(index, netlist, nIn, nOut, TREASURY, true, fee);
            emit ReservedClaimed(index, tokenIds[i], TREASURY);
        }
    }

    /// @notice Curator only, once the sale is over (every work taped out, or the sale end passed): return the price
    /// paid for each of the sold works `indexes` to the address that received it at mint (once per work). The circuits
    /// stay with their holders; the tape-out fee is not returned (it was spent on the tape-out). The curator sends the
    /// total with the call (native coin: exactly; token: approved to this vault).
    function rebate(uint256[] calldata indexes) external payable nonReentrant {
        _onlyCurator();
        if (block.timestamp < saleEnd && sold < COUNT) revert SaleNotOver();
        uint256 left = msg.value;
        for (uint256 i; i < indexes.length; i++) {
            Sale storage x = saleOf[indexes[i]];
            uint256 a = x.price;
            x.price = 0;
            left = _rebate(indexes[i], x.minter, a, left);
        }
        if (left != 0) revert WrongPayment(msg.value - left);
    }

    function finalizable() public view override returns (bool) {
        return _endedAndReservedDone();
    }
}
