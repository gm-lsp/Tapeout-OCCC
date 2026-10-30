// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ITapeOutFactory, ITapeOutTransistors, ITapeOutCircuits} from "./interfaces/ITapeOut.sol";
import {CuratedRegistry} from "./CuratedRegistry.sol";
import {ICircuitURIProvider} from "./interfaces/ICircuitURIProvider.sol";

/// @title CuratedVault
/// @notice Holds the entire transistor supply of one curated processor and is the only way to
/// tape out an official work: a buyer pays, the vault tapes out a listed netlist with its own
/// transistors, the registry certifies the new circuit, and the circuit goes to the buyer.
/// @dev No owner and no setters. Transistors can never leave the vault except by tape-out, or to the burn
/// address once every work is taped out, or once the sale has ended and every reserved work is claimed or
/// RESERVE_GRACE has passed (see finalizable). Proceeds are pull-payments to fixed addresses.
contract CuratedVault is ReentrancyGuard, ICircuitURIProvider {
    struct LaunchParams {
        string name;
        string symbol;
        string story;
        uint256 nandSupply; // NAND to mint: sum of NAND records over all works (plus spare)
        uint256 latchSupply; // LATCH to mint: sum of LATCH records over all works (plus spare)
        uint256 mintPrice; // processor mint price; 0, or >0 to meet front-end display thresholds
        uint256 mintBatch; // batch size for the mint/withdraw loop when mintPrice > 0
        bytes32 root; // Merkle root of the work list (see leafOf)
        uint32 count; // number of works
        address curator; // receives sale proceeds
        address platform; // optional platform fee recipient (address(0) = none)
        uint16 platformBps; // platform share of each sale, at most MAX_PLATFORM_BPS
        uint64 saleStart; // unix time when buy() opens
        uint64 saleEnd; // unix time after which buying closes; finalize() then waits for reserved claims (RESERVE_GRACE)
        uint256 maxLaunchFees; // cap on deploy fee + protocol fees paid at launch (guards against fee changes)
        address treasury; // receives every reserved work; fixed at launch (address(0) if none are reserved)
        uint32 reservedCount; // number of works marked reserved in the work list; fixed at launch
        bool limitPerWallet; // false = no per-wallet limit; true = at most maxPerWallet public works per wallet
        uint32 maxPerWallet; // the limit when limitPerWallet is true (at least 1); must be 0 when it is false
        bytes32 allowRoot; // Merkle root of the presale allowlist (wallet, quota, tier); bytes32(0) = no presale
        uint64 presaleStart; // unix time when the presale opens; must be before saleStart; 0 when there is no presale
        address royaltyReceiver; // optional royalty declaration for resales (ERC-2981 style); address(0) = none
        uint16 royaltyBps; // royalty rate in basis points, at most the registry's MAX_ROYALTY_BPS; 0 when none
        bytes32 titlesHash; // keccak256 of the keccak256 of every work title (UTF-8), in index order; see metadataOf
        string metadataURI; // content-addressed directory of <index>.json metadata files ("ipfs://<CID>" or "ar://<id>"); "" = none
        address paymentToken; // ERC-20 that work prices are paid in; address(0) = the chain's native coin. Tape-out fees
        // are always paid in the native coin
        bytes32 presalePriceRoot; // Merkle root of presale prices (index, tier, price); bytes32(0) = presale at the work-list price
    }

    uint16 public constant MAX_PLATFORM_BPS = 1000; // 10%
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant NAND = 0;
    uint256 internal constant LATCH = 1;
    /// @dev domain tag of allowlist leaves (wallet, quota, tier), so an allowlist leaf can never equal a work leaf
    bytes32 public constant ALLOW_TAG = keccak256("TAP-curated-allowlist-v2");
    /// @dev domain tag of presale price leaves (index, tier, price)
    bytes32 public constant PRESALE_PRICE_TAG = keccak256("TAP-curated-presale-price");
    /// @dev domain tag of the collection metadata commitment
    bytes32 public constant METADATA_TAG = keccak256("TAP-curated-metadata");
    /// @notice after the sale ends, unclaimed reserved works can still be claimed for this long before
    /// anyone may finalize; finalize is allowed earlier once every reserved work is claimed
    uint64 public constant RESERVE_GRACE = 30 days;

    using SafeERC20 for IERC20;

    CuratedRegistry public immutable REGISTRY;
    /// @notice the ERC-20 work prices and payouts are in; address(0) = the native coin
    address public immutable PAYMENT_TOKEN;
    address public immutable CURATOR;
    address public immutable PLATFORM;
    uint16 public immutable PLATFORM_BPS;
    bytes32 public immutable ROOT;
    uint32 public immutable COUNT;
    uint64 public immutable SALE_START;
    address public immutable TREASURY;
    uint32 public immutable RESERVED_COUNT;
    bool public immutable LIMIT_PER_WALLET;
    uint32 public immutable MAX_PER_WALLET;
    bytes32 public immutable ALLOW_ROOT;
    uint64 public immutable PRESALE_START;
    /// @notice Merkle root of the presale price list; bytes32(0) = presale buyers pay the work-list price
    bytes32 public immutable PRESALE_PRICE_ROOT;

    ITapeOutCircuits public circuits;
    ITapeOutTransistors public transistors;
    bool public initialized;
    bool public finalized;
    /// @notice the end of the sale; the curator may move it later (never earlier) while the sale is still open
    uint64 internal saleEnd;
    /// @notice true while the curator has paused buying (public sale and presale); reserved claims are unaffected
    bool public paused;
    uint32 public sold; // all works taped out, public and reserved
    uint32 public reservedClaimed;

    mapping(uint256 index => bool) public taken;
    mapping(address payee => uint256) public owed;
    /// @notice public purchases each wallet made for itself (counted only when a per-wallet limit applies)
    mapping(address wallet => uint32) public mintedBy;
    /// @notice presale purchases each allowlisted wallet has made (paid for)
    mapping(address wallet => uint32) public presaleBought;

    event Purchased(uint256 indexed index, uint256 indexed tokenId, address indexed recipient, uint256 price);
    event ReservedClaimed(uint256 indexed index, uint256 indexed tokenId, address indexed treasury);
    event Withdrawn(address indexed payee, uint256 amount);
    event Finalized(uint256 nandBurned, uint256 latchBurned);
    event SalePaused(bool paused);
    event SaleEndExtended(uint64 previousEnd, uint64 newEnd);

    error OnlyRegistry();
    error AlreadyInitialized();
    error BadParams(string why);
    error InsufficientLaunchFunds();
    error RefundFailed();
    error SaleNotStarted();
    error SaleEnded();
    error LaunchFeesTooHigh(uint256 fees);
    error IndexOutOfRange();
    error AlreadyTaken();
    error InvalidProof();
    error WrongPayment(uint256 expected);
    error ZeroRecipient();
    error NotFinalizable();
    error AlreadyFinalized();
    error NothingOwed();
    error TransferFailed();
    error UnexpectedFunds();
    error OnlyCurator();
    error ReservedQuotaUsed();
    error WalletLimitReached(address wallet);
    error RecipientMustBeBuyer();
    error NoPresale();
    error PresaleNotOpen();
    error SaleIsPaused();
    error CannotExtend();
    error NotAllowlisted();
    error PresaleQuotaUsed();
    error TokenAmountMismatch(uint256 expected, uint256 received);
    error InvalidPresalePrice();
    error PresaleAbovePrice(uint256 presalePrice, uint256 price);

    constructor(CuratedRegistry registry, LaunchParams memory p) {
        if (p.curator == address(0)) revert BadParams("curator");
        if (p.count == 0) revert BadParams("count");
        if (p.root == bytes32(0)) revert BadParams("root");
        if (p.titlesHash == bytes32(0)) revert BadParams("titlesHash");
        if (p.platformBps > MAX_PLATFORM_BPS) revert BadParams("platformBps");
        if (p.platformBps > 0 && p.platform == address(0)) revert BadParams("platform");
        if (p.mintPrice > 0 && p.mintBatch == 0) revert BadParams("mintBatch");
        if (p.saleEnd <= p.saleStart || p.saleEnd <= block.timestamp) revert BadParams("saleEnd");
        if (p.reservedCount > p.count) revert BadParams("reservedCount");
        if (p.reservedCount > 0 && p.treasury == address(0)) revert BadParams("treasury");
        if (p.limitPerWallet ? p.maxPerWallet == 0 : p.maxPerWallet != 0) revert BadParams("maxPerWallet");
        if (p.allowRoot == bytes32(0) ? p.presaleStart != 0 : (p.presaleStart == 0 || p.presaleStart >= p.saleStart)) {
            revert BadParams("presale");
        }
        // the vault, the registry and the deployer creating this vault (msg.sender) can receive neither circuits nor
        // payouts, so a work or a share sent there would be locked forever
        if (p.treasury == address(this) || p.treasury == address(registry) || p.treasury == msg.sender) {
            revert BadParams("treasury");
        }
        if (p.platform == address(this) || p.platform == address(registry) || p.platform == msg.sender) {
            revert BadParams("platform");
        }
        if (p.paymentToken != address(0)
            && (p.paymentToken.code.length == 0 || p.paymentToken == address(registry) || p.paymentToken == msg.sender)
        ) revert BadParams("paymentToken");
        REGISTRY = registry;
        PAYMENT_TOKEN = p.paymentToken;
        CURATOR = p.curator;
        PLATFORM = p.platform;
        PLATFORM_BPS = p.platformBps;
        ROOT = p.root;
        COUNT = p.count;
        SALE_START = p.saleStart;
        saleEnd = p.saleEnd;
        TREASURY = p.treasury;
        RESERVED_COUNT = p.reservedCount;
        LIMIT_PER_WALLET = p.limitPerWallet;
        MAX_PER_WALLET = p.maxPerWallet;
        ALLOW_ROOT = p.allowRoot;
        PRESALE_START = p.presaleStart;
        if (p.presalePriceRoot != bytes32(0) && p.allowRoot == bytes32(0)) revert BadParams("presalePriceRoot");
        PRESALE_PRICE_ROOT = p.presalePriceRoot;
    }

    // ------------------------------------------------------------------ launch

    /// @notice Create the processor, mint the whole supply to this vault, bind to the registry.
    /// Callable once, by the registry, inside its launch transaction.
    function initialize(LaunchParams calldata p, address refundTo)
        external
        payable
        nonReentrant
        returns (address t, address c)
    {
        if (msg.sender != address(REGISTRY)) revert OnlyRegistry();
        if (initialized) revert AlreadyInitialized();
        initialized = true;

        ITapeOutFactory factory = REGISTRY.FACTORY();
        uint256 supply = p.nandSupply + p.latchSupply;
        uint256 deployFee = factory.deployFee();
        (t, c) = factory.createCPU{value: deployFee}(p.name, p.symbol, p.story, supply, p.mintPrice);
        transistors = ITapeOutTransistors(t);
        circuits = ITapeOutCircuits(c);

        uint256 fee = transistors.protocolFee();
        uint256 fees = deployFee + fee * (_calls(p.latchSupply, p.mintPrice, p.mintBatch) + _calls(p.nandSupply, p.mintPrice, p.mintBatch));
        if (fees > p.maxLaunchFees) revert LaunchFeesTooHigh(fees);
        _mintAll(LATCH, p.latchSupply, p.mintPrice, p.mintBatch, fee);
        _mintAll(NAND, p.nandSupply, p.mintPrice, p.mintBatch, fee);

        REGISTRY.bind(c, t, CURATOR, ROOT, COUNT, TREASURY, RESERVED_COUNT, metadataOf(p.name, p.symbol, p.story, p.titlesHash));
        REGISTRY.declareRoyalty(c, p.royaltyReceiver, p.royaltyBps);
        REGISTRY.declareMetadataURI(c, p.metadataURI);

        // everything left is the launcher's unused float
        uint256 rest = address(this).balance;
        if (rest > 0) {
            (bool ok,) = refundTo.call{value: rest}("");
            if (!ok) revert RefundFailed();
        }
    }

    function _calls(uint256 amount, uint256 price, uint256 batch) internal pure returns (uint256) {
        if (amount == 0) return 0;
        if (price == 0) return 1;
        return (amount + batch - 1) / batch;
    }

    function _mintAll(uint256 id, uint256 amount, uint256 price, uint256 batch, uint256 fee) internal {
        if (amount == 0) return;
        if (price == 0) {
            if (address(this).balance < fee) revert InsufficientLaunchFunds();
            transistors.mint{value: fee}(id, amount);
            return;
        }
        // pay ourselves the mint price and take it back after every batch
        while (amount > 0) {
            uint256 n = amount < batch ? amount : batch;
            uint256 cost = price * n + fee;
            if (address(this).balance < cost) revert InsufficientLaunchFunds();
            transistors.mint{value: cost}(id, n);
            transistors.withdraw();
            amount -= n;
        }
    }

    // ------------------------------------------------------------------ sale

    /// @notice The Merkle leaf of a work (OpenZeppelin standard double-hashed leaf), bound to this chain,
    /// this registry and this curator, so a work list cannot be reused by anyone else or elsewhere.
    /// `reserved` marks a work kept for the treasury: it can never be bought, only claimed to TREASURY.
    function leafOf(uint256 index, bytes32 netlistHash, uint32 nIn, uint32 nOut, uint256 price, bool reserved)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid, address(REGISTRY), CURATOR, index, netlistHash, nIn, nOut, price, reserved
                    )
                )
            )
        );
    }

    /// @notice The metadata commitment recorded in the registry: it binds the processor's name, symbol and story
    /// (the same strings the processor was created with) and the titles of all works.
    function metadataOf(string calldata name, string calldata symbol, string calldata story, bytes32 titlesHash)
        public
        pure
        returns (bytes32)
    {
        return keccak256(
            abi.encode(METADATA_TAG, keccak256(bytes(name)), keccak256(bytes(symbol)), keccak256(bytes(story)), titlesHash)
        );
    }

    /// @notice The Merkle leaf of a presale allowlist entry: `wallet` may buy up to `quota` works in the presale, at
    /// the presale prices of allowlist tier `tier`.
    /// Bound to this chain, this registry and this curator, and tagged so it can never be confused with a work.
    function allowLeafOf(address wallet, uint32 quota, uint32 tier) public view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(abi.encode(block.chainid, address(REGISTRY), CURATOR, ALLOW_TAG, wallet, quota, tier))
            )
        );
    }

    /// @notice Leaf of the presale price list: work `index` costs `presalePrice` for allowlist tier `tier`. The leaf is
    /// bound to this collection's work-list root, so a price list can never be reused for another collection.
    function presalePriceLeafOf(uint256 index, uint32 tier, uint256 presalePrice) public view returns (bytes32) {
        return keccak256(
            bytes.concat(
                keccak256(
                    abi.encode(
                        block.chainid, address(REGISTRY), CURATOR, PRESALE_PRICE_TAG, ROOT, index, tier, presalePrice
                    )
                )
            )
        );
    }

    /// @notice Buy work `index` in the public sale. Pay exactly `price + circuits.TAPEOUT_FEE()`.
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

    /// @notice Buy work `index` in the presale, as an allowlisted wallet (msg.sender) with `quota` presale purchases
    /// in allowlist tier `tier`. `price` and `proof` prove the work as in `buy`. With a presale price list, the buyer
    /// pays `presalePrice`, proven for (index, tier) by `presaleProof`, which may not exceed `price`; without one,
    /// `presalePrice` must equal `price`. Each presale purchase uses one unit of the payer's quota, whoever the
    /// recipient is. The per-wallet limit, if any, applies as well. After the public sale opens, allowlisted wallets
    /// buy with `buy` at the work-list price like everyone else.
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
        if (ALLOW_ROOT == bytes32(0)) revert NoPresale();
        if (block.timestamp < PRESALE_START || block.timestamp >= SALE_START) revert PresaleNotOpen();
        if (!MerkleProof.verifyCalldata(allowProof, ALLOW_ROOT, allowLeafOf(msg.sender, quota, tier))) {
            revert NotAllowlisted();
        }
        if (PRESALE_PRICE_ROOT == bytes32(0)) {
            if (presalePrice != price) revert InvalidPresalePrice();
        } else {
            if (!MerkleProof.verifyCalldata(presaleProof, PRESALE_PRICE_ROOT, presalePriceLeafOf(index, tier, presalePrice)))
            {
                revert InvalidPresalePrice();
            }
            if (presalePrice > price) revert PresaleAbovePrice(presalePrice, price);
        }
        if (presaleBought[msg.sender] >= quota) revert PresaleQuotaUsed();
        presaleBought[msg.sender] += 1;
        return _sell(index, netlist, nIn, nOut, price, presalePrice, proof, recipient);
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
        if (block.timestamp >= saleEnd) revert SaleEnded();
        if (paused) revert SaleIsPaused();
        if (index >= COUNT) revert IndexOutOfRange();
        if (taken[index]) revert AlreadyTaken();
        if (recipient == address(0)) revert ZeroRecipient();
        bytes32 netlistHash = keccak256(netlist);
        if (!MerkleProof.verifyCalldata(proof, ROOT, leafOf(index, netlistHash, nIn, nOut, price, false))) {
            revert InvalidProof();
        }
        uint256 fee = circuits.TAPEOUT_FEE();
        // native coin: charge + tape-out fee in msg.value; token: the tape-out fee in msg.value, the charge pulled below
        uint256 due = PAYMENT_TOKEN == address(0) ? charge + fee : fee;
        if (msg.value != due) revert WrongPayment(due);

        // effects
        if (LIMIT_PER_WALLET) {
            // with a limit, each wallet buys for itself only: a wallet can neither buy many works for others,
            // nor be pushed to its limit by works others "give" it
            if (recipient != msg.sender) revert RecipientMustBeBuyer();
            _countWallet(msg.sender);
        }
        taken[index] = true;
        sold += 1;
        uint256 cut = (charge * PLATFORM_BPS) / 10_000;
        if (cut > 0) owed[PLATFORM] += cut;
        owed[CURATOR] += charge - cut;

        // interactions
        if (PAYMENT_TOKEN != address(0) && charge > 0) {
            // only tokens that deliver exactly the amount sent: fee-on-transfer and rebasing tokens are refused
            IERC20 token = IERC20(PAYMENT_TOKEN);
            uint256 before = token.balanceOf(address(this));
            token.safeTransferFrom(msg.sender, address(this), charge);
            uint256 afterwards = token.balanceOf(address(this));
            if (afterwards < before || afterwards - before != charge) {
                revert TokenAmountMismatch(charge, afterwards > before ? afterwards - before : 0);
            }
        }
        tokenId = circuits.tapeout{value: fee}(netlist, nIn, nOut);
        REGISTRY.certify(address(circuits), tokenId, index, netlistHash, false);
        circuits.safeTransferFrom(address(this), recipient, tokenId);
        emit Purchased(index, tokenId, recipient, charge);
    }

    function _countWallet(address w) internal {
        if (mintedBy[w] >= MAX_PER_WALLET) revert WalletLimitReached(w);
        mintedBy[w] += 1;
    }

    /// @notice Whether a per-wallet limit applies, and if so how many more public works `wallet` may buy.
    function remainingFor(address wallet) external view returns (bool limited, uint32 remaining) {
        if (!LIMIT_PER_WALLET) return (false, 0);
        uint32 m = mintedBy[wallet];
        return (true, m >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - m);
    }

    struct ReservedWork {
        uint256 index;
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        bytes32[] proof;
    }

    /// @notice Tape out a work that the work list marks as reserved, and send it to the treasury.
    /// Only the curator may call, at any time until the vault is finalized: before the sale starts, during it,
    /// and after it ends (see RESERVE_GRACE). The caller pays exactly `circuits.TAPEOUT_FEE()`.
    /// Reserved works are official like every other work.
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
        if (finalized) revert AlreadyFinalized();
        if (index >= COUNT) revert IndexOutOfRange();
        if (taken[index]) revert AlreadyTaken();
        if (reservedClaimed >= RESERVED_COUNT) revert ReservedQuotaUsed();
        bytes32 netlistHash = keccak256(netlist);
        if (!MerkleProof.verifyCalldata(proof, ROOT, leafOf(index, netlistHash, nIn, nOut, 0, true))) {
            revert InvalidProof();
        }

        taken[index] = true;
        sold += 1;
        reservedClaimed += 1;

        tokenId = circuits.tapeout{value: fee}(netlist, nIn, nOut);
        REGISTRY.certify(address(circuits), tokenId, index, netlistHash, true);
        circuits.safeTransferFrom(address(this), TREASURY, tokenId);
        emit ReservedClaimed(index, tokenId, TREASURY);
    }

    /// @notice Send `payee` what it is owed. Anyone may call; funds only go to the payee.
    function withdraw(address payee) external nonReentrant {
        _pay(payee, payee);
    }

    /// @notice For a payee that cannot receive the payment (native coin or token) itself: send what the caller is owed to `to`.
    function withdrawTo(address to) external nonReentrant {
        if (to == address(0)) revert ZeroRecipient();
        _pay(msg.sender, to);
    }

    function _pay(address payee, address to) internal {
        uint256 amount = owed[payee];
        if (amount == 0) revert NothingOwed();
        owed[payee] = 0;
        if (PAYMENT_TOKEN == address(0)) {
            (bool ok,) = to.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            IERC20(PAYMENT_TOKEN).safeTransfer(to, amount);
        }
        emit Withdrawn(payee, amount);
    }

    /// @notice Send the leftover transistors to the burn address. Anyone may call once every work is taped out,
    /// or once the sale has ended and either every reserved work is claimed or RESERVE_GRACE has passed.
    /// Works not taped out by then can never be taped out.
    function finalize() external nonReentrant {
        if (!finalizable()) revert NotFinalizable();
        if (finalized) revert AlreadyFinalized();
        finalized = true;
        uint256 n = transistors.balanceOf(address(this), NAND);
        uint256 l = transistors.balanceOf(address(this), LATCH);
        if (n > 0) transistors.safeTransferFrom(address(this), BURN, NAND, n, "");
        if (l > 0) transistors.safeTransferFrom(address(this), BURN, LATCH, l, "");
        emit Finalized(n, l);
    }

    /// @notice Whether finalize() may be called now (ignoring whether it already was).
    function finalizable() public view returns (bool) {
        if (sold == COUNT) return true;
        if (block.timestamp < saleEnd) return false;
        return reservedClaimed == RESERVED_COUNT || block.timestamp >= uint256(saleEnd) + RESERVE_GRACE;
    }

    // ------------------------------------------------------------------ sale controls (curator)

    function _onlyCurator() internal view {
        if (msg.sender != CURATOR) revert OnlyCurator();
    }

    /// @notice The sale end as it stands now (the launch value, or a later one set by extendSale).
    function SALE_END() external view returns (uint64) {
        return saleEnd;
    }

    /// @notice Curator only: stop or resume buying (public sale and presale). Nothing else changes: the work list,
    /// prices, the sale end and reserved claims stay as they are, and anyone can still finalize when finalizable.
    function setPaused(bool p) external {
        _onlyCurator();
        if (finalized) revert AlreadyFinalized();
        paused = p;
        emit SalePaused(p);
    }

    /// @notice Curator only: move the sale end later, while the sale has not ended and the vault is not finalized.
    /// It can never move earlier, and an ended sale cannot be reopened.
    function extendSale(uint64 newEnd) external {
        _onlyCurator();
        if (finalized || block.timestamp >= saleEnd || newEnd <= saleEnd) revert CannotExtend();
        emit SaleEndExtended(saleEnd, newEnd);
        saleEnd = newEnd;
    }

    // ------------------------------------------------------------------ receivers

    /// @dev Only the transistor contract (mint-price withdrawals during launch) may send plain BNB.
    receive() external payable {
        if (msg.sender != address(transistors)) revert UnexpectedFunds();
    }

    /// @dev Only circuits of this processor freshly minted to the vault by its own tapeout are accepted.
    function onERC721Received(address, address from, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(circuits) || from != address(0)) revert UnexpectedFunds();
        return this.onERC721Received.selector;
    }

    /// @dev Only this processor's own transistors are accepted.
    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(transistors)) revert UnexpectedFunds();
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(transistors)) revert UnexpectedFunds();
        return this.onERC1155BatchReceived.selector;
    }

    // ------------------------------------------------------------------ metadata

    /// @notice This vault is its processor's creator. If TapeOut's processors ever ask their creator for
    /// token metadata (see the TAP draft), they get the registry's answer: official works only.
    function circuitURI(address c, uint256 tokenId) external view returns (string memory) {
        if (c != address(circuits)) return "";
        return REGISTRY.tokenURI(c, tokenId);
    }

    /// @notice ERC-165: this vault provides circuit metadata (ICircuitURIProvider).
    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == type(ICircuitURIProvider).interfaceId;
    }
}
