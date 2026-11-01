// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ITapeOutFactory, ITapeOutTransistors, ITapeOutCircuits} from "./interfaces/ITapeOut.sol";
import {ICircuitURIProvider} from "./interfaces/ICircuitURIProvider.sol";
import {LaunchParams, ICuratedVaultInit} from "./CuratedTypes.sol";

interface IRegistryForVault {
    function FACTORY() external view returns (ITapeOutFactory);
    function bind(
        address circuits,
        address transistors,
        address curator,
        bytes32 root,
        uint32 count,
        address treasury,
        uint32 reservedCount,
        uint8 saleMode
    ) external;
    function declareRoyalty(address circuits, address receiver, uint16 bps) external;
    function declareMetadataURI(address circuits, string calldata uri) external;
    function declareTokenURI(address circuits, uint256 tokenId, string calldata uri) external;
    function certify(address circuits, uint256 tokenId, uint256 index, bytes32 netlistHash, bool reserved) external;
    function tokenURI(address circuits, uint256 tokenId) external view returns (string memory);
}

/// @title CuratedVaultBase
/// @notice What every curated vault shares: launching the processor and holding its entire transistor supply, taping
/// out and certifying official works, paying each sale out directly, the allowlist, the per-wallet limit, sale
/// controls and finalisation. Vaults are minimal clones created by the registry; `initialize` runs once, from the
/// registry, in the launch transaction.
/// @dev No owner. Transistors leave the vault only by tape-out, or to the burn address at finalize.
abstract contract CuratedVaultBase is ReentrancyGuard, ICircuitURIProvider, ICuratedVaultInit {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_PLATFORM_BPS = 1000; // 10%
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant NAND = 0;
    uint256 internal constant LATCH = 1;
    /// @dev gas forwarded with a direct native payout; a payee that needs more (or reverts) is paid through `owed`
    uint256 internal constant PAYOUT_GAS = 50_000;
    /// @dev gas forwarded with a direct token payout (a plain transfer needs 30,000 to 60,000)
    uint256 internal constant TOKEN_PAYOUT_GAS = 150_000;
    /// @dev domain tag of allowlist leaves (wallet, quota, tier)
    bytes32 public constant ALLOW_TAG = keccak256("TAP-curated-allowlist-v2");
    /// @dev domain tag of the collection metadata commitment
    /// @notice after the sale ends, unclaimed reserved works can still be claimed for this long before
    /// anyone may finalize; finalize is allowed earlier once every reserved work is claimed
    uint64 public constant RESERVE_GRACE = 30 days;

    // launch parameters (clones have no immutables; set once in initialize)
    IRegistryForVault public REGISTRY;
    address public PAYMENT_TOKEN; // address(0) = native coin
    address public CURATOR;
    address public PLATFORM;
    uint16 public PLATFORM_BPS;
    uint8 public SALE_MODE;
    bool public LIMIT_PER_WALLET;
    bool public initialized;
    bool public finalized;
    bool public paused;
    bytes32 public ROOT;
    uint32 public COUNT;
    uint32 public RESERVED_COUNT;
    uint32 public MAX_PER_WALLET;
    uint64 public SALE_START;
    uint64 public PRESALE_START;
    /// @notice the end of the sale; the curator may move it later (never earlier) while the sale is still open
    uint64 internal saleEnd;
    address public TREASURY;
    bytes32 public ALLOW_ROOT;
    bytes32 public PRESALE_PRICE_ROOT;
    /// @notice receives the curator's share of every sale; the curator may change it
    address public payee;

    ITapeOutCircuits public circuits;
    ITapeOutTransistors public transistors;
    uint32 public sold; // all works taped out, public and reserved
    uint32 public reservedClaimed;

    /// @notice payouts that could not be sent directly (a payee that rejected them), and refunds of the same kind
    mapping(address => uint256) public owed;
    /// @notice native-coin amounts owed (gas refunds and remainders in modes 1, 2) when a direct send failed
    mapping(address => uint256) public owedNative;
    /// @notice public purchases each wallet made for itself (counted only when a per-wallet limit applies)
    mapping(address wallet => uint32) public mintedBy;
    /// @notice presale purchases each allowlisted wallet has made
    mapping(address wallet => uint32) public presaleBought;

    event Paid(address indexed to, uint256 amount, bool deferred);
    event Withdrawn(address indexed payee, uint256 amount);
    /// @notice the curator returned the price of an already minted work to its minter, who keeps the circuit
    event Rebated(uint256 indexed key, address indexed minter, uint256 amount);
    event Finalized(uint256 nandBurned, uint256 latchBurned);
    event SalePaused(bool paused);
    event SaleEndExtended(uint64 previousEnd, uint64 newEnd);
    event PayeeChanged(address payee);

    error AlreadyInitialized();
    error BadParams(bytes32 why); // why: a short ASCII tag, right-padded with zero bytes
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
    error NothingToRebate();
    error SaleNotOver();

    /// @dev the implementation itself can never be initialised; only its clones can
    constructor() {
        initialized = true;
    }

    // ------------------------------------------------------------------ launch

    /// @notice Create the processor, mint the whole supply to this vault, bind to the registry.
    /// Callable once, by the registry that created this clone, inside its launch transaction.
    function initialize(LaunchParams calldata p, address refundTo)
        external
        payable
        nonReentrant
        returns (address t, address c)
    {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        REGISTRY = IRegistryForVault(msg.sender);
        _checkCommon(p);
        _initMode(p);

        ITapeOutFactory factory = REGISTRY.FACTORY();
        uint256 deployFee = factory.deployFee();
        (t, c) = factory.createCPU{value: deployFee}(p.name, p.symbol, p.story, p.nandSupply + p.latchSupply, p.mintPrice);
        transistors = ITapeOutTransistors(t);
        circuits = ITapeOutCircuits(c);
        // TAP §12.2 (recommended to TapeOut): if the processor lets its creator restrict tape-outs to itself, do so;
        // without that feature the call fails and changes nothing
        (bool restricted,) = c.call{gas: 100_000}(abi.encodeWithSignature("restrictTapeoutToCreator()"));
        restricted;

        uint256 fee = transistors.protocolFee();
        uint256 fees =
            deployFee + fee * (_calls(p.latchSupply, p.mintPrice, p.mintBatch) + _calls(p.nandSupply, p.mintPrice, p.mintBatch));
        if (fees > p.maxLaunchFees) revert LaunchFeesTooHigh(fees);
        _mintAll(LATCH, p.latchSupply, p.mintPrice, p.mintBatch, fee);
        _mintAll(NAND, p.nandSupply, p.mintPrice, p.mintBatch, fee);

        REGISTRY.bind(c, t, CURATOR, ROOT, COUNT, TREASURY, RESERVED_COUNT, SALE_MODE);
        REGISTRY.declareRoyalty(c, p.royaltyReceiver, p.royaltyBps);
        // hidden collections declare their metadata when the works are revealed
        if (SALE_MODE == 0) REGISTRY.declareMetadataURI(c, p.metadataURI);

        // everything left is the launcher's unused float
        uint256 rest = address(this).balance;
        if (rest > 0) {
            (bool ok,) = refundTo.call{value: rest}("");
            if (!ok) revert RefundFailed();
        }
    }

    function _checkCommon(LaunchParams calldata p) internal {
        // the registry has checked p (CuratedRegistry._check) before calling initialize
        PAYMENT_TOKEN = p.paymentToken;
        CURATOR = p.curator;
        payee = p.payee;
        PLATFORM = p.platform;
        PLATFORM_BPS = p.platformBps;
        SALE_MODE = p.saleMode;
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
        PRESALE_PRICE_ROOT = p.presalePriceRoot;
    }

    /// @dev mode-specific checks and state
    function _initMode(LaunchParams calldata p) internal virtual;

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

    // ------------------------------------------------------------------ leaves and commitments

    /// @notice The Merkle leaf of a presale allowlist entry: `wallet` may buy up to `quota` works in the presale, at
    /// the presale prices of allowlist tier `tier`. Bound to this chain, this registry and this curator.
    function allowLeafOf(address wallet, uint32 quota, uint32 tier) public view returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(block.chainid, address(REGISTRY), CURATOR, ALLOW_TAG, wallet, quota, tier)))
        );
    }

    /// @dev keccak256(bytes.concat(keccak256(abi.encode(chainid, registry, curator, tag, ROOT, key, tier, price))))
    function _priceLeaf(bytes32 tag, uint256 key, uint32 tier, uint256 price) internal view returns (bytes32) {
        return keccak256(
            bytes.concat(keccak256(abi.encode(block.chainid, address(REGISTRY), CURATOR, tag, ROOT, key, tier, price)))
        );
    }

    // ------------------------------------------------------------------ shared sale steps

    function _checkOpen() internal view {
        if (block.timestamp >= saleEnd) revert SaleEnded();
        if (paused) revert SaleIsPaused();
    }

    /// @dev Checks the allowlist and the presale window, and uses one unit of the payer's quota. Returns the amount the
    /// buyer pays: `presalePrice` proven for (key, tier) against PRESALE_PRICE_ROOT (never above `price`), or `price`.
    function _presale(
        bytes32 priceTag,
        uint256 key,
        uint256 price,
        uint32 quota,
        uint32 tier,
        bytes32[] calldata allowProof,
        uint256 presalePrice,
        bytes32[] calldata presaleProof
    ) internal returns (uint256) {
        if (ALLOW_ROOT == bytes32(0)) revert NoPresale();
        if (block.timestamp < PRESALE_START || block.timestamp >= SALE_START) revert PresaleNotOpen();
        if (!MerkleProof.verifyCalldata(allowProof, ALLOW_ROOT, allowLeafOf(msg.sender, quota, tier))) {
            revert NotAllowlisted();
        }
        if (PRESALE_PRICE_ROOT == bytes32(0)) {
            if (presalePrice != price) revert InvalidPresalePrice();
        } else {
            if (!MerkleProof.verifyCalldata(presaleProof, PRESALE_PRICE_ROOT, _priceLeaf(priceTag, key, tier, presalePrice)))
            {
                revert InvalidPresalePrice();
            }
            if (presalePrice > price) revert PresaleAbovePrice(presalePrice, price);
        }
        if (presaleBought[msg.sender] >= quota) revert PresaleQuotaUsed();
        presaleBought[msg.sender] += 1;
        return presalePrice;
    }

    /// @dev with a limit, each wallet buys for itself only: a wallet can neither buy many works for others,
    /// nor be pushed to its limit by works others "give" it
    function _countWallet(address recipient) internal {
        if (recipient == address(0)) revert ZeroRecipient();
        if (!LIMIT_PER_WALLET) return;
        if (recipient != msg.sender) revert RecipientMustBeBuyer();
        if (mintedBy[msg.sender] >= MAX_PER_WALLET) revert WalletLimitReached(msg.sender);
        mintedBy[msg.sender] += 1;
    }

    /// @notice Whether a per-wallet limit applies, and if so how many more public purchases `wallet` may make.
    function remainingFor(address wallet) external view returns (bool limited, uint32 remaining) {
        if (!LIMIT_PER_WALLET) return (false, 0);
        uint32 m = mintedBy[wallet];
        return (true, m >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - m);
    }

    /// @dev Takes `charge` in the payment token from msg.sender, refusing tokens that deliver any other amount
    /// (fee-on-transfer, rebasing). Native-coin charges arrive in msg.value and are checked by the caller.
    function _pullToken(uint256 charge) internal {
        if (PAYMENT_TOKEN == address(0) || charge == 0) return;
        IERC20 token = IERC20(PAYMENT_TOKEN);
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), charge);
        uint256 afterwards = token.balanceOf(address(this));
        if (afterwards < before || afterwards - before != charge) {
            revert TokenAmountMismatch(charge, afterwards > before ? afterwards - before : 0);
        }
    }

    /// @dev Pays a sale out at once: PLATFORM_BPS to the platform, the rest to the payee. A transfer that fails is
    /// credited to `owed` instead, so a payee that rejects payments can never block a purchase.
    function _distribute(uint256 charge) internal {
        if (charge == 0) return;
        uint256 cut = (charge * PLATFORM_BPS) / 10_000;
        if (cut > 0) _send(PLATFORM, cut);
        _send(payee, charge - cut);
    }

    /// @dev Sends `amount` of the payment asset to `to`, or credits it to `owed[to]` if the transfer fails.
    function _send(address to, uint256 amount) internal {
        bool ok;
        if (PAYMENT_TOKEN == address(0)) {
            ok = _call(to, amount);
        } else {
            // a token transfer with a gas limit, reading at most one word of its answer: neither a token hook that
            // burns gas nor a malformed answer can make the purchase revert
            address t = PAYMENT_TOKEN;
            bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
            uint256 r;
            uint256 n;
            assembly ("memory-safe") {
                ok := call(TOKEN_PAYOUT_GAS, t, 0, add(data, 32), mload(data), 0, 32)
                n := returndatasize()
                r := mload(0)
            }
            ok = ok && (n == 0 ? t.code.length > 0 : (n >= 32 && r == 1));
        }
        if (!ok) owed[to] += amount;
        emit Paid(to, amount, !ok);
    }

    /// @dev Sends native coin to `to`, or credits it to `owedNative[to]` if the transfer fails.
    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!_call(to, amount)) owedNative[to] += amount;
    }

    /// @dev native coin with PAYOUT_GAS and no copy of the return data (a receiver cannot make the payer pay for it)
    function _call(address to, uint256 amount) internal returns (bool ok) {
        assembly ("memory-safe") {
            ok := call(PAYOUT_GAS, to, amount, 0, 0, 0, 0)
        }
    }

    /// @dev Tape out a work with the vault's transistors, certify it, and send it to `to`.
    function _tapeOut(uint256 index, bytes calldata netlist, uint32 nIn, uint32 nOut, address to, bool reserved, uint256 fee)
        internal
        returns (uint256 tokenId)
    {
        sold += 1;
        if (reserved) reservedClaimed += 1;
        tokenId = circuits.tapeout{value: fee}(netlist, nIn, nOut);
        REGISTRY.certify(address(circuits), tokenId, index, keccak256(netlist), reserved);
        // a hidden sale delivers in a transaction the holder does not send (fulfil, redeem): a plain transfer, so a
        // holder contract can never block it (and with it, in instant reveal, the queue of its pool)
        if (SALE_MODE == 0 || reserved) circuits.safeTransferFrom(address(this), to, tokenId);
        else circuits.transferFrom(address(this), to, tokenId);
    }

    function _reservedCheck(uint256 index, bool isTaken) internal view {
        if (finalized) revert AlreadyFinalized();
        if (index >= COUNT) revert IndexOutOfRange();
        if (isTaken) revert AlreadyTaken();
        if (reservedClaimed >= RESERVED_COUNT) revert ReservedQuotaUsed();
    }

    // ------------------------------------------------------------------ rebates (the curator returns a price)

    /// @dev Pays one rebate of `amount` to `to`, taken from the curator (native: from `left`, what is left of msg.value;
    /// token: pulled, exact), kept in `owed` if the transfer fails. Returns what is left of msg.value.
    function _rebate(uint256 key, address to, uint256 amount, uint256 left) internal returns (uint256) {
        if (amount == 0) revert NothingToRebate();
        if (PAYMENT_TOKEN == address(0)) {
            if (left < amount) revert WrongPayment(amount);
            left -= amount;
        } else {
            _pullToken(amount);
        }
        _send(to, amount);
        emit Rebated(key, to, amount);
        return left;
    }

    // ------------------------------------------------------------------ payouts kept in the vault

    /// @notice Send `who` what the vault owes it (failed direct payouts). Anyone may call; funds only go to `who`.
    function withdraw(address who) external nonReentrant {
        _pay(who, who);
    }

    /// @notice For a payee that cannot receive the payment itself: send what the caller is owed to `to`.
    function withdrawTo(address to) external nonReentrant {
        if (to == address(0)) revert ZeroRecipient();
        _pay(msg.sender, to);
    }

    function _pay(address who, address to) internal {
        uint256 amount = owed[who];
        uint256 native = owedNative[who];
        if (amount == 0 && native == 0) revert NothingOwed();
        owed[who] = 0;
        owedNative[who] = 0;
        if (amount > 0) {
            if (PAYMENT_TOKEN == address(0)) {
                native += amount;
            } else {
                IERC20(PAYMENT_TOKEN).safeTransfer(to, amount);
            }
        }
        if (native > 0) {
            (bool ok,) = to.call{value: native}("");
            if (!ok) revert TransferFailed();
        }
        emit Withdrawn(who, amount + native);
    }

    // ------------------------------------------------------------------ finalize and sale controls

    /// @notice Send the leftover transistors to the burn address, once finalizable(). Anyone may call.
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
    function finalizable() public view virtual returns (bool);

    /// @dev every work taped out, or the sale over and the reserved works claimed (or RESERVE_GRACE passed)
    function _endedAndReservedDone() internal view returns (bool) {
        if (sold == COUNT) return true;
        if (block.timestamp < saleEnd) return false;
        return reservedClaimed == RESERVED_COUNT || block.timestamp >= uint256(saleEnd) + RESERVE_GRACE;
    }

    function _onlyCurator() internal view {
        if (msg.sender != CURATOR) revert OnlyCurator();
    }

    /// @notice The sale end as it stands now (the launch value, or a later one set by extendSale).
    function SALE_END() external view returns (uint64) {
        return saleEnd;
    }

    /// @notice Curator only: stop or resume buying (public sale and presale).
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

    /// @notice Curator only: change the address that receives the curator's share of sales.
    function setPayee(address newPayee) external {
        _onlyCurator();
        if (newPayee == address(0) || newPayee == address(this) || newPayee == address(REGISTRY)) revert BadParams("payee");
        payee = newPayee;
        emit PayeeChanged(newPayee);
    }

    // ------------------------------------------------------------------ receivers

    /// @dev Only the transistor contract (mint-price withdrawals during launch) may send plain native coin.
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

    /// @notice This vault is its processor's creator. If TapeOut's processors ever ask their creator for
    /// token metadata (see the TAP draft), they get the registry's answer: official works only.
    function circuitURI(address c, uint256 tokenId) external view returns (string memory) {
        if (c != address(circuits)) return "";
        return REGISTRY.tokenURI(c, tokenId);
    }

    /// @notice ERC-165
    function supportsInterface(bytes4 id) public view virtual returns (bool) {
        return id == 0x01ffc9a7 || id == type(ICircuitURIProvider).interfaceId;
    }
}
