// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ICuratedRegistry} from "./interfaces/ICuratedRegistry.sol";
import {ITapeOutFactory, ITapeOutTransistors, ITapeOutCircuits} from "./interfaces/ITapeOut.sol";
import {LaunchParams, HiddenParams, ICuratedVaultInit, INSTANT_REVEAL, BLIND_BOX} from "./CuratedTypes.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

/// @title CuratedRegistry
/// @notice Launches curated collections on TapeOut and records which circuits are official.
/// @dev No owner, no admin, no upgrade path, holds no assets. Every collection is launched in one
/// transaction: a fresh vault (an EIP-1167 clone of one of three fixed implementations, chosen by the sale mode)
/// creates the processor, mints its entire transistor supply to itself, and binds itself here. `bind` re-checks
/// all of that on chain instead of trusting the vault. Verifiers check the registry's code and the three
/// implementations' code (their addresses are immutable here).
contract CuratedRegistry is ICuratedRegistry {
    ITapeOutFactory public immutable FACTORY;
    bytes32 public constant METADATA_TAG = keccak256("TAP-curated-metadata");
    /// @notice vault implementation for sale mode 0 (CuratedVault)
    address public immutable INSTANT_IMPL;
    /// @notice vault implementation for sale mode 1 (CuratedRevealVault)
    address public immutable REVEAL_IMPL;
    /// @notice vault implementation for sale mode 2 (CuratedBlindBoxVault)
    address public immutable BOX_IMPL;

    /// @notice vaults deployed by this registry (only they may bind)
    mapping(address vault => bool) public isVault;

    mapping(address circuits => Collection) private _collections;
    /// @dev stores index + 1 so that 0 means "not official"
    mapping(address circuits => mapping(uint256 tokenId => uint256)) private _editionPlusOne;
    /// @dev stores tokenId + 1 so that 0 means "not taped out" even if a processor ever used id 0
    mapping(address circuits => mapping(uint256 index => uint256)) private _tokenPlusOne;
    mapping(address circuits => mapping(uint256 tokenId => bool)) private _reserved;
    mapping(address circuits => uint32) private _reservedCertified;
    /// @notice the collection (processor) a vault was bound to
    mapping(address vault => address) public circuitsOfVault;
    /// @dev official serial: 1 for the first official circuit of a collection, 2 for the next...
    mapping(address circuits => mapping(uint256 tokenId => uint256)) private _serial;
    mapping(address circuits => mapping(uint256 serial => uint256)) private _tokenOfSerial;
    /// @dev per-circuit metadata file (hidden sales), takes precedence over the directory
    mapping(address circuits => mapping(uint256 tokenId => string)) private _tokenURI;

    error NotVault();
    error AlreadyBound();
    error NotBoundVault();
    error BadProcessor(string why);
    error AlreadyCertified();
    error IndexOutOfRange();
    error CuratorMustLaunch();
    error ReservedQuotaExceeded();
    error BadRoyalty();
    error OnlyCurator();
    error RoyaltyCannotRise();
    error BadMetadataURI();
    error NotOfficial();

    /// @notice the highest royalty a collection may declare (5 %)
    uint16 public constant MAX_ROYALTY_BPS = 500;

    struct Royalty {
        address receiver;
        uint16 bps;
        bool declared;
    }

    mapping(address circuits => Royalty) private _royalty;

    /// @dev the collection's metadata directory, fixed at launch; "" = none
    mapping(address circuits => string) private _metadataURI;
    mapping(address circuits => bool) private _metadataDeclared;

    /// @notice Emitted at launch and whenever the curator changes the receiver or lowers the rate.

    error BadSaleMode();
    error BadParams(bytes32 why); // why: a short ASCII tag, right-padded with zero bytes
    /// @notice the highest platform share of a sale (10 %), as in the vaults
    uint16 public constant MAX_PLATFORM_BPS = 1000;

    constructor(ITapeOutFactory factory, address instantImpl, address revealImpl, address boxImpl) {
        FACTORY = factory;
        INSTANT_IMPL = instantImpl;
        REVEAL_IMPL = revealImpl;
        BOX_IMPL = boxImpl;
    }

    /// @notice Launch a curated collection in a single transaction.
    /// @dev msg.value must cover the factory deploy fee, one protocol fee per mint call, and
    /// (if p.mintPrice > 0) the float for one mint batch. Any excess is refunded to msg.sender.
    /// The curator must launch the collection personally, so nobody can launch in an artist's name.
    function launch(LaunchParams calldata p)
        external
        payable
        returns (address vault, address transistors, address circuits)
    {
        if (p.curator != msg.sender) revert CuratorMustLaunch();
        if (p.saleMode > BLIND_BOX) revert BadSaleMode();
        vault = Clones.clone(p.saleMode == 0 ? INSTANT_IMPL : p.saleMode == 1 ? REVEAL_IMPL : BOX_IMPL);
        isVault[vault] = true;
        _check(p, vault);
        (transistors, circuits) = ICuratedVaultInit(vault).initialize{value: msg.value}(p, msg.sender);
        // initialize must have bound the collection to this vault
        if (_collections[circuits].vault != vault) revert NotBoundVault();
        Collection storage col = _collections[circuits];
        bytes32 metadata = metadataOf(p.name, p.symbol, p.story, p.titlesHash);
        col.metadata = metadata;
        emit CollectionLaunched(
            circuits, vault, col.curator, transistors, col.root, col.count, col.treasury, col.reserved, metadata
        );
        emit SaleModeSet(circuits, p.saleMode);
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

    /// @dev launch parameters every sale mode shares (the vault checks its mode's own)
    function _check(LaunchParams calldata p, address vault) internal view {
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
        if (p.presalePriceRoot != bytes32(0) && p.allowRoot == bytes32(0)) revert BadParams("presalePriceRoot");
        // neither the vault nor the registry can receive circuits or payouts: a work or a share sent there is lost
        if (p.treasury == vault || p.treasury == address(this)) revert BadParams("treasury");
        if (p.platform == vault || p.platform == address(this)) revert BadParams("platform");
        if (p.payee == address(0) || p.payee == vault || p.payee == address(this)) revert BadParams("payee");
        if (p.paymentToken != address(0) && (p.paymentToken.code.length == 0 || p.paymentToken == address(this))) {
            revert BadParams("paymentToken");
        }
        _checkMode(p);
    }

    /// @dev sale mode 0: no hidden parameters; 1 and 2: pools that cover every public work, the mode's commitment
    function _checkMode(LaunchParams calldata p) internal pure {
        HiddenParams calldata h = p.hidden;
        uint256 n = h.poolPrices.length;
        if (p.saleMode == 0) {
            if (
                n != 0 || h.poolCounts.length != 0 || h.revealFee != 0 || h.revealGasPrice != 0 || h.secretsRoot != 0
                    || h.secretHash != 0
                    || h.metadataRoot != 0 || bytes(h.passURI).length != 0
            ) revert BadParams("hidden");
            return;
        }
        // hidden sales: works are drawn, not chosen (no sequential order), and metadata is declared at the reveal
        if (p.sequential || bytes(p.metadataURI).length != 0) revert BadParams("hidden");
        if (n == 0 || n != h.poolCounts.length || n > 64) revert BadParams("pools");
        uint256 total;
        for (uint256 i; i < n; i++) {
            // prices are kept per slot in 128 bits
            if (h.poolCounts[i] == 0 || h.poolPrices[i] > type(uint128).max) revert BadParams("pools");
            total += h.poolCounts[i];
        }
        // the fees of a slot are kept in 96 bits together with the tape-out fee
        if (h.revealFee > type(uint64).max || h.revealGasPrice == 0) revert BadParams("revealFee");
        if (total + p.reservedCount != p.count) revert BadParams("pools");
        bool reveal = p.saleMode == INSTANT_REVEAL;
        if (
            (reveal ? h.secretsRoot == 0 || h.secretHash != 0 || bytes(h.passURI).length != 0 : h.secretHash == 0)
                || (!reveal && h.secretsRoot != 0)
        ) revert BadParams("secret");
    }

    /// @notice Called by a vault during its initialisation. All facts are re-verified on chain.
    function bind(
        address circuits,
        address transistors,
        address curator,
        bytes32 root,
        uint32 count,
        address treasury,
        uint32 reservedCount,
        uint8 saleMode
    ) external {
        if (!isVault[msg.sender]) revert NotVault();
        if (_collections[circuits].vault != address(0)) revert AlreadyBound();

        // the processor was created by the real TapeOut factory
        if (!FACTORY.isCPU(circuits)) revert BadProcessor("not a TapeOut processor");
        ITapeOutCircuits c = ITapeOutCircuits(circuits);
        ITapeOutTransistors t = ITapeOutTransistors(transistors);
        if (c.transistors() != transistors || t.circuits() != circuits) revert BadProcessor("pair mismatch");
        // the vault created it, so nobody could mint before the vault did
        if (t.creator() != msg.sender) revert BadProcessor("creator is not vault");
        // the whole supply is minted, and all of it sits in the vault
        uint256 cap = t.supplyCap();
        if (t.minted() != cap) revert BadProcessor("supply not fully minted");
        if (t.balanceOf(msg.sender, 0) + t.balanceOf(msg.sender, 1) != cap) {
            revert BadProcessor("vault does not hold the supply");
        }
        // nothing has been taped out yet. Note: on the deployed contracts nextId() returns the number
        // of circuits taped out so far (0 on a fresh processor, 1 after the first tape-out, whose id is 1),
        // not "the id the next circuit will get" as TAP-02 §6 describes.
        if (c.nextId() != 0) revert BadProcessor("processor not fresh");

        _collections[circuits] = Collection({
            vault: msg.sender,
            curator: curator,
            transistors: transistors,
            treasury: treasury,
            root: root,
            count: count,
            reserved: reservedCount,
            certified: 0,
            metadata: bytes32(0), // set by launch once initialize returns
            saleMode: saleMode
        });
        circuitsOfVault[msg.sender] = circuits;
    }

    /// @notice Called once by the collection's vault during launch. Optional: (address(0), 0) declares no royalty.
    function declareRoyalty(address circuits, address receiver, uint16 bps) external {
        Collection storage col = _collections[circuits];
        if (msg.sender != col.vault || msg.sender == address(0)) revert NotBoundVault();
        if (_royalty[circuits].declared) revert AlreadyBound();
        _checkRoyalty(receiver, bps);
        _royalty[circuits] = Royalty(receiver, bps, true);
        emit RoyaltySet(circuits, receiver, bps);
    }

    /// @notice The curator may change the royalty receiver or lower the rate, never raise it.
    function setRoyalty(address circuits, address receiver, uint16 bps) external {
        if (msg.sender != _collections[circuits].curator || msg.sender == address(0)) revert OnlyCurator();
        if (bps > _royalty[circuits].bps) revert RoyaltyCannotRise();
        _checkRoyalty(receiver, bps);
        _royalty[circuits].receiver = receiver;
        _royalty[circuits].bps = bps;
        emit RoyaltySet(circuits, receiver, bps);
    }

    function _checkRoyalty(address receiver, uint16 bps) internal pure {
        if (bps > MAX_ROYALTY_BPS || (receiver == address(0)) != (bps == 0)) revert BadRoyalty();
    }

    /// @notice ERC-2981-style royalty for an official circuit; (address(0), 0) for anything else.
    /// Advisory: markets decide whether to pay it.
    function royaltyInfo(address circuits, uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount)
    {
        if (_editionPlusOne[circuits][tokenId] == 0) return (address(0), 0);
        Royalty memory r = _royalty[circuits];
        return (r.receiver, (salePrice * r.bps) / 10_000);
    }

    /// @notice The collection's declared royalty receiver and rate (address(0), 0 if none).
    function royaltyOf(address circuits) external view returns (address receiver, uint16 bps) {
        Royalty memory r = _royalty[circuits];
        return (r.receiver, r.bps);
    }

    /// @notice Called once by the collection's vault: at launch in sale mode 0, at the reveal in a blind box (never in
    /// instant reveal, which declares a file per circuit). The URI is a content-addressed directory ("ipfs://<CID>" or
    /// "ar://<transaction id>", no trailing slash; see isContentAddressed) or "" for none. It can never change.
    function declareMetadataURI(address circuits, string calldata uri) external {
        Collection storage col = _collections[circuits];
        if (msg.sender != col.vault || msg.sender == address(0)) revert NotBoundVault();
        if (_metadataDeclared[circuits]) revert AlreadyBound();
        if (!isContentAddressed(bytes(uri))) revert BadMetadataURI();
        _metadataDeclared[circuits] = true;
        _metadataURI[circuits] = uri;
        emit MetadataURISet(circuits, uri);
    }

    /// @notice Called by the collection's vault in the transaction that tapes out an official circuit of an instant
    /// reveal: the circuit's own metadata file (content-addressed, non-empty). Once per circuit; never changes.
    function declareTokenURI(address circuits, uint256 tokenId, string calldata uri) external {
        Collection storage col = _collections[circuits];
        if (msg.sender != col.vault || msg.sender == address(0)) revert NotBoundVault();
        if (_editionPlusOne[circuits][tokenId] == 0) revert NotOfficial();
        if (bytes(_tokenURI[circuits][tokenId]).length != 0) revert AlreadyBound();
        if (bytes(uri).length == 0 || !isContentAddressed(bytes(uri))) revert BadMetadataURI();
        _tokenURI[circuits][tokenId] = uri;
        emit TokenURISet(circuits, tokenId, uri);
    }

    /// @notice True for "", for "ipfs://" + a CID of immutable content, and for "ar://" + an Arweave transaction id.
    /// CIDs: CIDv0 ("Qm" + 44 base58 characters) or CIDv1 in base32 for dag-pb ("bafy…") or raw ("bafk…") data,
    /// 50..100 characters; never a libp2p-key CID (an IPNS name), a path, a DNS name or another encoding.
    /// Arweave ids: exactly 43 base64url characters with at least one upper-case letter; ArNS names and undernames
    /// are lower case, so this can never be a name that its owner could repoint.
    function isContentAddressed(bytes memory u) public pure returns (bool) {
        if (u.length == 0) return true;
        if (u.length > 7 && _startsWith(u, "ipfs://")) {
            uint256 n = u.length - 7;
            if (n == 46 && u[7] == "Q" && u[8] == "m") {
                for (uint256 i = 9; i < u.length; i++) {
                    bytes1 b = u[i];
                    if (!_isAlnum(b) || b == "0" || b == "O" || b == "I" || b == "l") return false; // base58
                }
                return true;
            }
            if (n >= 50 && n <= 100 && u[7] == "b" && u[8] == "a" && u[9] == "f" && (u[10] == "y" || u[10] == "k")) {
                for (uint256 i = 11; i < u.length; i++) {
                    bytes1 b = u[i];
                    if (!((b >= "a" && b <= "z") || (b >= "2" && b <= "7"))) return false; // base32, lower case
                }
                return true;
            }
            return false;
        }
        if (u.length == 5 + 43 && _startsWith(u, "ar://")) {
            bool upper;
            for (uint256 i = 5; i < u.length; i++) {
                bytes1 b = u[i];
                if (!_isAlnum(b) && b != "-" && b != "_") return false;
                if (b >= "A" && b <= "Z") upper = true;
            }
            return upper;
        }
        return false;
    }

    function _startsWith(bytes memory u, bytes memory prefix) private pure returns (bool) {
        for (uint256 i = 0; i < prefix.length; i++) {
            if (u[i] != prefix[i]) return false;
        }
        return true;
    }

    function _isAlnum(bytes1 b) private pure returns (bool) {
        return (b >= "0" && b <= "9") || (b >= "a" && b <= "z") || (b >= "A" && b <= "Z");
    }

    /// @notice Called by the collection's vault in the same transaction as the tape-out.
    function certify(address circuits, uint256 tokenId, uint256 index, bytes32 netlistHash, bool reserved)
        external
    {
        Collection storage col = _collections[circuits];
        if (msg.sender != col.vault || msg.sender == address(0)) revert NotBoundVault();
        if (index >= col.count) revert IndexOutOfRange();
        if (_editionPlusOne[circuits][tokenId] != 0 || _tokenPlusOne[circuits][index] != 0) revert AlreadyCertified();
        _editionPlusOne[circuits][tokenId] = index + 1;
        _tokenPlusOne[circuits][index] = tokenId + 1;
        if (reserved) {
            // belt and braces: never more reserved works than the collection declared at launch
            if (_reservedCertified[circuits] >= col.reserved) revert ReservedQuotaExceeded();
            _reservedCertified[circuits] += 1;
            _reserved[circuits][tokenId] = true;
        }
        uint32 serial = col.certified + 1;
        col.certified = serial;
        _serial[circuits][tokenId] = serial;
        _tokenOfSerial[circuits][serial] = tokenId;
        emit Certified(circuits, tokenId, index, netlistHash, reserved);
        emit Serial(circuits, tokenId, serial);
    }

    // ------------------------------------------------------------------ views

    function isOfficial(address circuits, uint256 tokenId) external view returns (bool) {
        return _editionPlusOne[circuits][tokenId] != 0;
    }

    function editionOf(address circuits, uint256 tokenId) external view returns (bool official, uint256 index) {
        uint256 e = _editionPlusOne[circuits][tokenId];
        return e == 0 ? (false, 0) : (true, e - 1);
    }

    function tokenOf(address circuits, uint256 index) external view returns (bool taped, uint256 tokenId) {
        uint256 t = _tokenPlusOne[circuits][index];
        return t == 0 ? (false, 0) : (true, t - 1);
    }

    /// @notice The official serial of a circuit: the order in which the collection's works were taped out, from 1
    /// (0 = not official). When nobody else tapes out on the processor during the sale it equals the TapeOut id.
    function serialOf(address circuits, uint256 tokenId) external view returns (uint256) {
        return _serial[circuits][tokenId];
    }

    /// @return taped whether an official circuit has serial `serial`; tokenId its circuit id.
    function tokenOfSerial(address circuits, uint256 serial) external view returns (bool taped, uint256 tokenId) {
        if (serial == 0 || serial > _collections[circuits].certified) return (false, 0);
        return (true, _tokenOfSerial[circuits][serial]);
    }

    /// @return true iff `token` is the pass contract (vault) of a blind-box collection launched here. Markets use it
    /// to label unopened passes; a pass is not an official circuit.
    function isBlindBoxPass(address token) external view returns (bool) {
        address c = circuitsOfVault[token];
        return c != address(0) && _collections[c].saleMode == BLIND_BOX;
    }

    function isReserved(address circuits, uint256 tokenId) external view returns (bool) {
        return _reserved[circuits][tokenId];
    }

    function isCurated(address circuits) external view returns (bool) {
        return _collections[circuits].vault != address(0);
    }

    function collectionOf(address circuits) external view returns (Collection memory) {
        return _collections[circuits];
    }

    /// @return the collection's metadata directory ("" if none, not yet declared, or not curated).
    function metadataURIOf(address circuits) external view returns (string memory) {
        return _metadataURI[circuits];
    }

    /// @notice ERC-721 metadata for an official circuit: its own file if one was declared (instant reveal), else
    /// "<metadataURI>/<index>.json", where index is the work's position in the work list. "" for circuits that are
    /// not official and when there is neither, so copies and REF wrappers never show the work's image.
    function tokenURI(address circuits, uint256 tokenId) external view returns (string memory) {
        uint256 e = _editionPlusOne[circuits][tokenId];
        if (e == 0) return "";
        string memory own = _tokenURI[circuits][tokenId];
        if (bytes(own).length != 0) return own;
        string memory base = _metadataURI[circuits];
        if (bytes(base).length == 0) return "";
        return string.concat(base, "/", Strings.toString(e - 1), ".json");
    }
}
