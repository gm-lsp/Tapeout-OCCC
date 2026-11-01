// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {CuratedHiddenBase} from "./CuratedHiddenBase.sol";
import {LaunchParams, BLIND_BOX} from "./CuratedTypes.sol";

interface IERC721Named {
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        returns (bytes4);
}

/// @title CuratedBlindBoxVault — blind box (sale mode 2)
/// @notice A buyer gets a transferable pass (this contract is its ERC-721; pass id = slot id) for a slot in a price
/// pool. Once every slot is sold or the sale has ended, the curator publishes the reveal secret (committed at launch
/// in SECRET_HASH) and the metadata directory; the seed is fixed from the hash of the following block, and every pass
/// is assigned a work by a pseudo-random permutation of its pool. Anyone may then redeem passes: a pass is burned in
/// the same transaction that tapes its work out to the pass's holder at that moment. Passes stay tradable throughout.
contract CuratedBlindBoxVault is CuratedHiddenBase {
    bytes32 public SECRET_HASH;
    string internal PASS_URI; // tokenURI of an unopened pass
    bool public revealed;
    bool public seedFixed;
    bytes32 public secret;
    uint64 public revealBlock;
    bytes32 public seed;
    string internal revealURI; // the metadata directory, also the registry's metadataURIOf
    mapping(address => uint256) internal _balance;
    mapping(uint256 => address) internal _approved;
    mapping(address => mapping(address => bool)) internal _operator;

    event Revealed(bytes32 secret, string metadataURI);
    event SeedFixed(bytes32 seed);
    event Rearmed(uint256 anchorBlock);
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function _initMode(LaunchParams calldata p) internal override {
        _initPools(p, BLIND_BOX);
        SECRET_HASH = p.hidden.secretHash;
        PASS_URI = p.hidden.passURI;
    }

    function _onSlot(uint256 slot, uint32, uint32, address recipient) internal override {
        _balance[recipient] += 1;
        emit Transfer(address(0), recipient, slot);
    }

    // ------------------------------------------------------------------ blind box

    /// @notice Blind box, curator only: publish the reveal secret and the metadata directory, once every slot is sold
    /// or the sale has ended. The assignment is fixed from the block after this one (fixSeed), so whoever reveals
    /// cannot know it in advance.
    function reveal(bytes32 revealSecret, string calldata metadataURI) external nonReentrant {
        _onlyCurator();
        if (revealed) revert AlreadyRevealed();
        if (!_saleOver()) revert NotRevealable();
        if (keccak256(abi.encode(revealSecret)) != SECRET_HASH) revert InvalidSecret();
        revealed = true;
        secret = revealSecret;
        revealBlock = uint64(block.number);
        revealURI = metadataURI;
        REGISTRY.declareMetadataURI(address(circuits), metadataURI);
        emit Revealed(revealSecret, metadataURI);
    }

    /// @notice Blind box: fix the seed, seed = keccak256(abi.encode(secret, blockhash(revealBlock + 1))). Anyone may
    /// call; redeem calls it when needed. If nobody did within 256 blocks the hash is gone: the call then moves the
    /// anchor to this block (Rearmed) and the seed comes from the next block's hash (a fixed fallback value would let
    /// the curator, who knows the secret, choose between two outcomes by waiting).
    function fixSeed() public {
        if (!revealed) revert NotRevealed();
        if (seedFixed) return;
        if (block.number <= uint256(revealBlock) + 1) revert TooEarly();
        bytes32 bh = blockhash(uint256(revealBlock) + 1);
        if (bh == 0) {
            revealBlock = uint64(block.number);
            emit Rearmed(block.number);
            return;
        }
        seed = keccak256(abi.encode(secret, bh));
        seedFixed = true;
        emit SeedFixed(seed);
    }

    /// @notice The work index a blind-box slot is assigned (seed fixed): poolStart + permute(pos, count, poolKey).
    function assignedIndex(uint256 slot) public view returns (uint256) {
        if (!seedFixed) revert NotRevealed();
        Slot storage s = slots[slot];
        if (s.state == 0) revert NotPass();
        return uint256(poolStart[s.pool]) + permute(s.pos, poolCount[s.pool], keccak256(abi.encode(seed, s.pool)));
    }

    /// @notice A pseudo-random permutation of [0, n): a 4-round Feistel network on 2k bits (4^k >= n, k >= 1) with
    /// round function keccak256(abi.encode(key, round, right)) masked to k bits, cycle-walked into [0, n).
    function permute(uint256 x, uint256 n, bytes32 key) public pure returns (uint256) {
        uint256 k = 1;
        while ((uint256(1) << (2 * k)) < n) k++;
        uint256 mask = (uint256(1) << k) - 1;
        do {
            uint256 l = x >> k;
            uint256 r = x & mask;
            for (uint256 i; i < 4; i++) {
                (l, r) = (r, l ^ (uint256(keccak256(abi.encode(key, i, r))) & mask));
            }
            x = (l << k) | r;
        } while (x >= n);
        return x;
    }

    /// @notice Blind box: tape out the assigned works of `ids` to their passes' holders at this moment, burning the
    /// passes in the same transaction. Anyone may call (the platform does it in batches; holders can do it
    /// themselves). Slots already delivered or refunded are skipped. Each slot's reveal fee repays its share of gas.
    function redeem(uint256[] calldata ids, HiddenWork[] calldata works) external nonReentrant {
        uint256 g0 = gasleft();
        if (ids.length == 0 || ids.length != works.length) revert BadParams("lengths");
        fixSeed();
        if (!seedFixed) return; // re-anchored: redeem from the block after next
        // calldata is repaid only for what each delivery needs (_calldataGas), so padding pays nothing
        uint256 shared = (TX_BASE_GAS + (g0 - gasleft())) / ids.length;
        for (uint256 i; i < ids.length; i++) {
            uint256 gi = gasleft();
            Slot storage s = slots[ids[i]];
            if (s.state != PENDING) continue;
            uint256 index = assignedIndex(ids[i]);
            if (works[i].index != index) revert WrongWork(index);
            _checkHidden(works[i], s.pool);
            _burnPass(ids[i], s);
            s.state = DELIVERED;
            slotsSettled += 1;
            _deliver(ids[i], s, works[i]);
            _settleGas(s, gi - gasleft() + shared + _calldataGas(works[i]));
        }
    }

    /// @notice Blind box, curator only, once the sale is over (sold out or past its end): refund passes that have not
    /// been redeemed, to their current holders: any pass before the reveal; after it, only a pass that can no longer be
    /// redeemed because TapeOut's fee has risen above what the pass holds (so the curator, who knows the assignment
    /// then, cannot pick which buyers lose their work). The curator sends exactly the prices back with the call
    /// (native: msg.value; token: approved to this vault); each pass's fees go back too. Its work is never sold.
    function refund(uint256[] calldata ids) external payable nonReentrant {
        _onlyCurator();
        if (!_saleOver()) revert NotRefundable();
        uint256 left = msg.value;
        for (uint256 i; i < ids.length; i++) {
            Slot storage s = slots[ids[i]];
            if (s.state != PENDING) revert NotPending();
            if (revealed && circuits.TAPEOUT_FEE() <= uint256(s.feeHeld) + REVEAL_FEE) revert NotRefundable();
            _burnPass(ids[i], s);
            left = _refund(ids[i], s, left);
        }
        if (left != 0) revert WrongPayment(msg.value - left);
    }

    // ------------------------------------------------------------------ the pass (ERC-721)

    /// @notice "<processor name> · blind box" and "<processor symbol>BOX" (the processor has the collection's name)
    function name() external view returns (string memory) {
        return string.concat(IERC721Named(address(circuits)).name(), unicode" · blind box");
    }

    function symbol() external view returns (string memory) {
        return string.concat(IERC721Named(address(circuits)).symbol(), "BOX");
    }

    /// @notice An unopened pass shows PASS_URI; once the seed is fixed it shows the work it will be redeemed for
    /// ("<metadata directory>/<index>.json"), so every market sees the real result before the redemption.
    function tokenURI(uint256 id) external view returns (string memory) {
        ownerOf(id);
        if (!seedFixed || bytes(revealURI).length == 0) return PASS_URI;
        return string.concat(revealURI, "/", Strings.toString(assignedIndex(id)), ".json");
    }

    function balanceOf(address owner) external view returns (uint256) {
        if (owner == address(0)) revert ZeroRecipient();
        return _balance[owner];
    }

    function ownerOf(uint256 id) public view returns (address) {
        Slot storage s = slots[id];
        if (s.state != PENDING) revert NotPass();
        return s.holder;
    }

    function getApproved(uint256 id) external view returns (address) {
        ownerOf(id);
        return _approved[id];
    }

    function isApprovedForAll(address owner, address operator) external view returns (bool) {
        return _operator[owner][operator];
    }

    function approve(address to, uint256 id) external {
        address owner = ownerOf(id);
        if (msg.sender != owner && !_operator[owner][msg.sender]) revert NotAuthorized();
        _approved[id] = to;
        emit Approval(owner, to, id);
    }

    function setApprovalForAll(address operator, bool approved) external {
        _operator[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 id) public {
        address owner = ownerOf(id);
        if (owner != from) revert NotAuthorized();
        if (msg.sender != owner && !_operator[owner][msg.sender] && _approved[id] != msg.sender) revert NotAuthorized();
        if (to == address(0) || to == address(this)) revert ZeroRecipient();
        delete _approved[id];
        _balance[from] -= 1;
        _balance[to] += 1;
        slots[id].holder = to;
        emit Transfer(from, to, id);
    }

    function safeTransferFrom(address from, address to, uint256 id) external {
        safeTransferFrom(from, to, id, "");
    }

    function safeTransferFrom(address from, address to, uint256 id, bytes memory data) public {
        transferFrom(from, to, id);
        if (to.code.length > 0 && IERC721Receiver(to).onERC721Received(msg.sender, from, id, data) != 0x150b7a02) {
            revert UnsafeRecipient();
        }
    }

    function _burnPass(uint256 id, Slot storage s) internal {
        delete _approved[id];
        _balance[s.holder] -= 1;
        emit Transfer(s.holder, address(0), id);
    }

    /// @notice ERC-165: ERC-721 and its metadata extension and ICircuitURIProvider.
    function supportsInterface(bytes4 id) public view override returns (bool) {
        if (id == 0x80ac58cd || id == 0x5b5e139f) return true;
        return super.supportsInterface(id);
    }
}
