// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CuratedRegistry} from "../src/CuratedRegistry.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {CuratedVaultBase} from "../src/CuratedVaultBase.sol";
import {CuratedHiddenBase} from "../src/CuratedHiddenBase.sol";
import {CuratedRevealVault} from "../src/CuratedRevealVault.sol";
import {CuratedBlindBoxVault} from "../src/CuratedBlindBoxVault.sol";
import {LaunchParams} from "../src/CuratedTypes.sol";
import {ICuratedRegistry} from "../src/interfaces/ICuratedRegistry.sol";
import {ITapeOutFactory, ITapeOutTransistors, ITapeOutCircuits} from "../src/interfaces/ITapeOut.sol";
import {ManifestParams} from "../script/ManifestParams.sol";

/// Fork tests of the sequential copies sale (instant tape-out), instant reveal and blind box, on BNB Smart Chain,
/// X Layer or Base (as test/Curated.t.sol). Fixtures: test/fixtures/{copies,reveal,blindbox}[.<chainId>].json, built
/// by `tool/curate.py build` from tool/examples. Proofs of runs of copies and the secret proofs are rebuilt here from
/// the manifest's designs and secrets, independently of the tool.
abstract contract ModesBase is Test {
    address constant REG = 0x00000000000000000000000000000000c0dEc0DE;
    ITapeOutFactory FACTORY;
    CuratedRegistry reg;
    string manifest;
    LaunchParams P;
    address curator;
    address buyer = makeAddr("modes-buyer");
    address buyer2 = makeAddr("modes-buyer2");
    address server = makeAddr("modes-server");
    address attacker = makeAddr("modes-attacker");
    address PAYEE = makeAddr("modes-payee");
    ITapeOutTransistors T;
    ITapeOutCircuits C;
    address vaultAddr;
    uint256 fee;

    struct Item {
        uint256 index;
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        uint32 pool;
        bool reserved;
        uint256 price;
        uint256 first;
        uint32 copies;
    }

    Item[] items;

    function _fixture() internal pure virtual returns (string memory);

    function setUp() public {
        string memory sfx;
        if (block.chainid == 56) {
            FACTORY = ITapeOutFactory(0x68224F668083c29e9800Be2a646d42d18cedF7e2);
        } else if (block.chainid == 196 || block.chainid == 8453) {
            FACTORY = ITapeOutFactory(0x1f09DAeFA827f02CBb40967cc91b259763760761);
            sfx = string.concat(".", vm.toString(block.chainid));
        } else {
            revert("fork BNB Smart Chain (56), X Layer (196) or Base (8453)");
        }
        address i0 = address(new CuratedVault());
        address i1 = address(new CuratedRevealVault());
        address i2 = address(new CuratedBlindBoxVault());
        deployCodeTo("CuratedRegistry.sol:CuratedRegistry", abi.encode(FACTORY, i0, i1, i2), REG);
        reg = CuratedRegistry(REG);
        manifest = vm.readFile(string.concat("test/fixtures/", _fixture(), sfx, ".json"));
        assertEq(vm.parseJsonAddress(manifest, ".registry"), REG);
        P = ManifestParams.read(manifest);
        curator = P.curator;
        if (P.payee == curator) P.payee = PAYEE;
        PAYEE = P.payee;
        address[6] memory eoas = [buyer, buyer2, server, attacker, PAYEE, curator];
        for (uint256 i; i < eoas.length; i++) {
            vm.etch(eoas[i], "");
            vm.deal(eoas[i], 100 ether);
        }
        // every work, one per index (runs of copies expanded)
        for (uint256 r; vm.keyExistsJson(manifest, string.concat(".works[", vm.toString(r), "]")); r++) {
            string memory k = string.concat(".works[", vm.toString(r), "]");
            string memory d =
                string.concat(".designs[", vm.toString(vm.parseJsonUint(manifest, string.concat(k, ".design"))), "]");
            Item memory it;
            it.first = vm.parseJsonUint(manifest, string.concat(k, ".first"));
            it.copies = uint32(vm.parseJsonUint(manifest, string.concat(k, ".copies")));
            it.netlist = vm.parseJsonBytes(manifest, string.concat(d, ".netlist"));
            it.nIn = uint32(vm.parseJsonUint(manifest, string.concat(d, ".nIn")));
            it.nOut = uint32(vm.parseJsonUint(manifest, string.concat(d, ".nOut")));
            it.reserved = vm.parseJsonBool(manifest, string.concat(k, ".reserved"));
            if (vm.keyExistsJson(manifest, string.concat(k, ".pool"))) {
                it.pool = uint32(vm.parseJsonUint(manifest, string.concat(k, ".pool")));
            } else {
                it.pool = type(uint32).max;
            }
            if (vm.keyExistsJson(manifest, string.concat(k, ".priceWei"))) {
                it.price = vm.parseJsonUint(manifest, string.concat(k, ".priceWei"));
            }
            for (uint256 c; c < it.copies; c++) {
                it.index = it.first + c;
                items.push(it);
            }
        }
        assertEq(items.length, P.count);
    }

    function _launch() internal {
        vm.prank(curator);
        (address v, address t, address c) = reg.launch{value: vm.parseJsonUint(manifest, ".launch.launchValueWei")}(P);
        vaultAddr = v;
        T = ITapeOutTransistors(t);
        C = ITapeOutCircuits(c);
        fee = C.TAPEOUT_FEE();
    }

    // ------------------------------------------------------------------ an OpenZeppelin sorted-pair tree, rebuilt here

    function _sort(bytes32[] memory a) internal pure {
        for (uint256 i = 1; i < a.length; i++) {
            for (uint256 j = i; j > 0 && a[j - 1] > a[j]; j--) {
                (a[j - 1], a[j]) = (a[j], a[j - 1]);
            }
        }
    }

    function _hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// the positional tree of hidden sales: leaf i at position i, 2^depth positions, zero padding, keccak(left ‖ right)
    function _ptree(bytes32[] memory leaves, uint256 position) internal pure returns (bytes32 root, bytes32[] memory proof) {
        uint256 depth;
        while ((uint256(1) << depth) < leaves.length) depth++;
        bytes32[] memory cur = new bytes32[](uint256(1) << depth);
        for (uint256 i; i < leaves.length; i++) cur[i] = leaves[i];
        proof = new bytes32[](depth);
        for (uint256 d; d < depth; d++) {
            proof[d] = cur[position ^ 1];
            for (uint256 k; k < (cur.length >> (d + 1)); k++) cur[k] = keccak256(abi.encode(cur[2 * k], cur[2 * k + 1]));
            position >>= 1;
        }
        root = cur[0];
    }

    /// every hidden work leaf of the fixture, computed by the vault
    function _hiddenLeaves() internal view returns (bytes32[] memory leaves) {
        leaves = new bytes32[](items.length);
        for (uint256 i; i < items.length; i++) {
            Item storage x = items[i];
            leaves[i] = _hiddenLeaf(x.index, keccak256(x.netlist), x.nIn, x.nOut, x.pool, x.reserved);
        }
    }

    /// a hidden work leaf, computed here from the TAP's formula (§13)
    function _hiddenLeaf(uint256 index, bytes32 nh, uint32 nIn, uint32 nOut, uint32 pool, bool reserved)
        internal
        view
        returns (bytes32)
    {
        CuratedHiddenBase v = CuratedHiddenBase(payable(vaultAddr));
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(v.REGISTRY()), v.CURATOR(),
            keccak256("TAP-curated-hidden-work"), index, nh, nIn, nOut, pool, reserved))));
    }

    /// a presale pool-price leaf, computed here from the TAP's formula (§13.1)
    function _poolPriceLeaf(uint256 pool, uint32 tier, uint256 price) internal view returns (bytes32) {
        CuratedHiddenBase v = CuratedHiddenBase(payable(vaultAddr));
        return keccak256(bytes.concat(keccak256(abi.encode(block.chainid, address(v.REGISTRY()), v.CURATOR(),
            keccak256("TAP-curated-presale-pool-price"), v.ROOT(), pool, tier, price))));
    }

    function _hwork(uint256 index) internal view returns (CuratedHiddenBase.HiddenWork memory w) {
        bytes32 root;
        (root, w.proof) = _ptree(_hiddenLeaves(), index);
        assertEq(root, CuratedHiddenBase(payable(vaultAddr)).ROOT(), "work-list root rebuilt");
        Item storage it = items[index];
        w.index = index;
        w.netlist = it.netlist;
        w.nIn = it.nIn;
        w.nOut = it.nOut;
    }

    /// root of the tree and the proof of `leaf`
    function _tree(bytes32[] memory leaves, bytes32 leaf) internal pure returns (bytes32 root, bytes32[] memory proof) {
        bytes32[] memory cur = new bytes32[](leaves.length);
        for (uint256 i; i < leaves.length; i++) cur[i] = leaves[i];
        _sort(cur);
        uint256 pos = type(uint256).max;
        for (uint256 i; i < cur.length; i++) if (cur[i] == leaf) pos = i;
        bytes32[] memory tmp = new bytes32[](256);
        uint256 n;
        while (cur.length > 1) {
            if (pos != type(uint256).max && (pos ^ 1) < cur.length) tmp[n++] = cur[pos ^ 1];
            bytes32[] memory nxt = new bytes32[]((cur.length + 1) / 2);
            for (uint256 j; j < cur.length; j += 2) {
                nxt[j / 2] = j + 1 == cur.length ? cur[j] : _hashPair(cur[j], cur[j + 1]);
            }
            cur = nxt;
            if (pos != type(uint256).max) pos /= 2;
        }
        root = cur[0];
        proof = new bytes32[](n);
        for (uint256 j; j < n; j++) proof[j] = tmp[j];
    }
}

// ====================================================================== same design, many copies, sold in list order

contract CopiesForkTest is ModesBase {
    function _fixture() internal pure override returns (string memory) {
        return "copies";
    }

    function vault() internal view returns (CuratedVault) {
        return CuratedVault(payable(vaultAddr));
    }

    // runs of the fixture: [0, 2) AND reserved, [2, 7) Toggle, [7, 10) XOR (free)
    function _run(uint256 r) internal view returns (Item memory it, bytes32[] memory proof) {
        string memory k = string.concat(".works[", vm.toString(r), "]");
        it = items[vm.parseJsonUint(manifest, string.concat(k, ".first"))];
        proof = vm.parseJsonBytes32Array(manifest, string.concat(k, ".proof"));
    }

    function _buyNext(uint256 r, address who) internal returns (uint256 id) {
        (Item memory it, bytes32[] memory proof) = _run(r);
        vm.prank(who);
        id = vault().buyNext{value: it.price + fee}(it.first, it.copies, it.netlist, it.nIn, it.nOut, it.price, proof, who);
    }

    /// The design is stored once in the manifest; one run leaf covers all its copies; every copy is official, in list
    /// order, and its official serial equals its TapeOut circuit id and its position in the list plus one.
    function test_Copies_SoldInOrder_SerialEqualsTapeOutId() public {
        _launch();
        assertTrue(vault().SEQUENTIAL());
        // nothing can be bought before the reserved run (first in the list) is claimed
        (Item memory t0, bytes32[] memory tp) = _run(1);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CuratedVault.NotNext.selector, 0));
        vault().buyNext{value: t0.price + fee}(t0.first, t0.copies, t0.netlist, t0.nIn, t0.nOut, t0.price, tp, buyer);
        // the per-index buy and claim of an unordered collection are refused
        vm.prank(buyer);
        vm.expectRevert(CuratedVault.WrongMode.selector);
        vault().buy{value: t0.price + fee}(2, t0.netlist, t0.nIn, t0.nOut, t0.price, tp, buyer);

        (Item memory r0, bytes32[] memory rp) = _run(0);
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault().claimReservedRun{value: 2 * fee}(r0.first, r0.copies, r0.netlist, r0.nIn, r0.nOut, rp, 2);
        vm.prank(curator);
        uint256[] memory res = vault().claimReservedRun{value: 2 * fee}(r0.first, r0.copies, r0.netlist, r0.nIn, r0.nOut, rp, 2);
        assertEq(res[0], 1);
        assertEq(res[1], 2);

        uint256 payee0 = PAYEE.balance;
        uint256 gross;
        for (uint256 r = 1; r <= 2; r++) {
            (Item memory it,) = _run(r);
            for (uint256 c; c < it.copies; c++) {
                uint256 expected = C.nextId() + 1;
                vm.expectEmit(true, true, false, true, address(reg));
                emit ICuratedRegistry.Serial(address(C), expected, expected);
                uint256 id = _buyNext(r, c % 2 == 0 ? buyer : buyer2);
                assertEq(id, expected);
                assertEq(id, it.first + c + 1, "TapeOut id = list position + 1");
                assertEq(reg.serialOf(address(C), id), id, "official serial = TapeOut id");
                (bool taped, uint256 tid) = reg.tokenOfSerial(address(C), id);
                assertTrue(taped);
                assertEq(tid, id);
                (bool off, uint256 idx) = reg.editionOf(address(C), id);
                assertTrue(off);
                assertEq(idx, it.first + c);
                assertEq(keccak256(C.netlist(id)), keccak256(it.netlist));
                gross += it.price;
            }
            // the run is used up: its leaf sells nothing more
            if (r == 1) {
                (Item memory it1, bytes32[] memory p1) = _run(1);
                vm.prank(buyer);
                vm.expectRevert(abi.encodeWithSelector(CuratedVault.NotNext.selector, 7));
                vault().buyNext{value: it1.price + fee}(it1.first, it1.copies, it1.netlist, it1.nIn, it1.nOut, it1.price, p1, buyer);
            }
        }
        (Item memory x, bytes32[] memory xp) = _run(2);
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.IndexOutOfRange.selector);
        vault().buyNext{value: fee}(x.first, x.copies, x.netlist, x.nIn, x.nOut, 0, xp, buyer);
        uint256 cut = (gross * P.platformBps) / 10_000;
        // every sale is paid to the payee at once (5 % platform share rounded per sale: 0.01 has no remainder)
        assertEq(PAYEE.balance - payee0, gross - cut);
        assertEq(vaultAddr.balance, 0);
        assertEq(reg.collectionOf(address(C)).certified, P.count);
        assertEq(uint256(reg.collectionOf(address(C)).saleMode), 0);
        vault().finalize();
    }

    /// A wrapper injected by an outsider takes a TapeOut id: from then on serial and TapeOut id differ by one (the
    /// registry records both; TAP §12.2 recommends that TapeOut let a creator restrict tape-outs to itself).
    function test_Copies_InjectedWrapperShiftsTapeOutIds() public {
        _launch();
        (Item memory r0, bytes32[] memory rp) = _run(0);
        vm.prank(curator);
        vault().claimReservedRun{value: 2 * fee}(r0.first, r0.copies, r0.netlist, r0.nIn, r0.nOut, rp, 2);
        // a zero-cost REF wrapper of circuit 1, taped out by a stranger
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory wrapper = abi.encodePacked(uint8(2), address(C), uint64(1), uint8(2), uint8(1), uint24(2), uint24(3));
        vm.prank(attacker);
        uint256 fake = C.tapeout{value: fee}(wrapper, r0.nIn, r0.nOut);
        assertEq(fake, 3);
        assertEq(reg.serialOf(address(C), fake), 0);
        uint256 id = _buyNext(1, buyer);
        assertEq(id, 4);
        assertEq(reg.serialOf(address(C), id), 3);
        (, uint256 idx) = reg.editionOf(address(C), id);
        assertEq(idx, 2);
    }

    /// Presale prices of a sequential collection are keyed by run start; the presale still sells strictly in order.
    function test_Copies_PresaleByRun() public {
        P.presaleStart = uint64(block.timestamp);
        P.saleStart = uint64(block.timestamp + 1 days);
        _launch();
        (Item memory r0, bytes32[] memory rp) = _run(0);
        vm.prank(curator);
        vault().claimReservedRun{value: 2 * fee}(r0.first, r0.copies, r0.netlist, r0.nIn, r0.nOut, rp, 2);
        address alice = vm.parseJsonAddress(manifest, ".allowlist[0].address");
        vm.etch(alice, "");
        vm.deal(alice, 1 ether);
        bytes32[] memory ap = vm.parseJsonBytes32Array(manifest, ".allowlist[0].proof");
        uint256 og = vm.parseJsonUint(manifest, ".presaleTiers[0].prices[1]");
        // the tier's price list, rebuilt: (run start, tier, price) for each run that is sold
        bytes32[] memory leaves = new bytes32[](4);
        uint256 k;
        for (uint32 t; t < 2; t++) {
            for (uint256 r = 1; r <= 2; r++) {
                (Item memory it,) = _run(r);
                uint256 price = vm.parseJsonUint(
                    manifest, string.concat(".presaleTiers[", vm.toString(t), "].prices[", vm.toString(r), "]")
                );
                leaves[k++] = CuratedVault(payable(vaultAddr)).presalePriceLeafOf(it.first, t, price);
            }
        }
        (bytes32 root, bytes32[] memory pproof) = _tree(leaves, CuratedVault(payable(vaultAddr)).presalePriceLeafOf(2, 0, og));
        assertEq(root, vault().PRESALE_PRICE_ROOT());
        (Item memory it1, bytes32[] memory p1) = _run(1);
        vm.prank(alice);
        uint256 id = vault().buyNextPresale{value: og + fee}(
            it1.first, it1.copies, it1.netlist, it1.nIn, it1.nOut, it1.price, p1, alice, 2, 0, ap, og, pproof
        );
        assertEq(id, 3);
        assertEq(C.ownerOf(id), alice);
    }
}

// ====================================================================== instant reveal

contract RevealForkTest is ModesBase {
    function _fixture() internal pure override returns (string memory) {
        return "reveal";
    }

    function vault() internal view returns (CuratedRevealVault) {
        return CuratedRevealVault(payable(vaultAddr));
    }

    function _secret(uint256 slot) internal view returns (bytes32) {
        return vm.parseJsonBytes32(manifest, string.concat(".secrets[", vm.toString(slot - 1), "]"));
    }

    function _secretProof(uint256 slot) internal view returns (bytes32[] memory proof) {
        uint256 n = vault().POOLED();
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 s = 1; s <= n; s++) leaves[s - 1] = vault().secretLeafOf(s, _secret(s));
        bytes32 root;
        (root, proof) = _ptree(leaves, slot - 1);
        assertEq(root, vault().SECRETS_ROOT(), "secrets root rebuilt");
    }

    function _work(uint256 index) internal view returns (CuratedHiddenBase.HiddenWork memory) {
        return _hwork(index);
    }

    function _buy(uint32 pool, address who) internal returns (uint256 slot) {
        vm.prank(who);
        slot = vault().buySlot{value: vault().poolPrice(pool) + fee + vault().REVEAL_FEE()}(pool, who);
    }

    // the draw, computed here: a mirror of the pool's remaining positions
    mapping(uint32 => uint256[]) left;

    function _mirror() internal {
        for (uint32 p; p < 2; p++) {
            delete left[p];
            for (uint256 i; i < vault().poolCount(p); i++) left[p].push(i);
        }
    }

    function _expect(uint256 slot, bytes32 bh) internal returns (uint256 index) {
        (,, uint32 pool,,,,) = vault().slots(slot);
        uint256 j = uint256(keccak256(abi.encode(_secret(slot), bh))) % left[pool].length;
        index = vault().poolStart(pool) + left[pool][j];
        left[pool][j] = left[pool][left[pool].length - 1];
        left[pool].pop();
    }

    function _fulfill(uint256 slot, uint256 index) internal returns (uint256 id) {
        vm.prank(server);
        id = vault().fulfill(slot, _secret(slot), _secretProof(slot), _work(index), "");
    }

    /// A buyer pays price + tape-out fee + reveal fee for a slot in a pool; the sale is paid out at once; from the
    /// next block the server tapes out the drawn work, in purchase order per pool, and its gas is repaid from the slot.
    function test_Reveal_BuyDrawFulfill() public {
        _launch();
        _mirror();
        assertEq(uint256(reg.collectionOf(address(C)).saleMode), 1);
        assertEq(reg.metadataURIOf(address(C)), "");
        assertFalse(reg.isBlindBoxPass(vaultAddr));
        uint256 rf = vault().REVEAL_FEE();
        uint256 pp0 = vault().poolPrice(0);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, pp0 + fee + rf));
        vault().buySlot{value: pp0 + fee}(0, buyer);
        uint256 payee0 = PAYEE.balance;
        uint256 b = vm.getBlockNumber(); // (via-ir may re-read block.number after vm.roll)
        uint256 s1 = _buy(0, buyer);
        uint256 s2 = _buy(0, buyer2);
        uint256 s3 = _buy(1, buyer);
        assertEq(s1, 1);
        assertEq(s3, 3);
        uint256 price0 = vault().poolPrice(0);
        assertEq(PAYEE.balance - payee0, 2 * (price0 - price0 * P.platformBps / 10_000)
            + vault().poolPrice(1) - vault().poolPrice(1) * P.platformBps / 10_000);
        assertEq(vaultAddr.balance, 3 * (fee + rf), "only the fees stay, held per slot");

        // not in the purchase block's successor: its hash is not known yet
        CuratedHiddenBase.HiddenWork memory w0 = _work(0);
        bytes32[] memory sp1_ = _secretProof(s1);
        bytes32 sec1_ = _secret(s1);
        vm.prank(server);
        vm.expectRevert(CuratedHiddenBase.TooEarly.selector);
        vault().fulfill(s1, sec1_, sp1_, w0, "");
        bytes32 h = keccak256("block after purchase");
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, h);

        // a slot is served only in its turn; another pool has its own queue
        uint256 e1 = _expect(s1, h);
        uint256 e2 = _expect(s2, h);
        uint256 e3 = _expect(s3, h);
        {
            CuratedHiddenBase.HiddenWork memory w2_ = _work(e2);
            bytes32[] memory sp2_ = _secretProof(s2);
            bytes32 sec2_ = _secret(s2);
            vm.prank(server);
            vm.expectRevert(CuratedHiddenBase.NotItsTurn.selector);
            vault().fulfill(s2, sec2_, sp2_, w2_, "");
            // the wrong work, or a wrong secret, is refused
            CuratedHiddenBase.HiddenWork memory ww = _work(e1 == 0 ? 1 : 0);
            vm.prank(server);
            vm.expectRevert(abi.encodeWithSelector(CuratedHiddenBase.WrongWork.selector, e1));
            vault().fulfill(s1, sec1_, sp1_, ww, "");
            CuratedHiddenBase.HiddenWork memory w1_ = _work(e1);
            vm.prank(server);
            vm.expectRevert(CuratedHiddenBase.InvalidSecret.selector);
            vault().fulfill(s1, sec2_, sp1_, w1_, "");
        }

        // the server's gas is repaid from the slot (at most the reveal fee), the rest goes to the buyer
        vm.txGasPrice(1 gwei);
        uint256 srv0 = server.balance;
        uint256 buy0 = buyer.balance;
        address col = vault().PLATFORM() == address(0) ? vault().payee() : vault().PLATFORM();
        uint256 col0 = vault().owedNative(col);
        string memory uri = "ar://P05RevealedWorkMetadata_File_NotUploaded_00";
        CuratedHiddenBase.HiddenWork memory w1 = _work(e1);
        bytes32[] memory sp1 = _secretProof(s1);
        bytes32 sec1 = _secret(s1);
        vm.prank(server);
        uint256 g = gasleft();
        uint256 id1 = vault().fulfill(s1, sec1, sp1, w1, uri);
        g = g - gasleft();
        emit log_named_uint("fulfil gas", g);
        uint256 repaid = server.balance - srv0;
        assertGt(repaid, 0);
        assertLe(repaid, rf);
        assertEq(buyer.balance, buy0, "nothing back to the buyer");
        assertEq(repaid + vault().owedNative(col) - col0, rf, "reveal fee = repaid gas + fee surplus");
        assertEq(C.ownerOf(id1), buyer);
        assertEq(vault().circuitOfSlot(s1), id1);
        (bool off, uint256 idx) = reg.editionOf(address(C), id1);
        assertTrue(off);
        assertEq(idx, e1);
        assertEq(reg.serialOf(address(C), id1), 1);
        assertEq(reg.tokenURI(address(C), id1), uri, "the work's own metadata file");
        vm.prank(server);
        vm.expectRevert(CuratedHiddenBase.NotPending.selector);
        vault().fulfill(s1, sec1, sp1, w1, "");
        vm.txGasPrice(0);

        uint256 id3 = _fulfill(s3, e3); // pool 1 before pool 0's second slot
        uint256 id2 = _fulfill(s2, e2);
        assertEq(C.ownerOf(id2), buyer2);
        assertEq(C.ownerOf(id3), buyer);
        assertTrue(e1 != e2);
        assertGe(e3, 4);
        assertEq(vaultAddr.balance, vault().owedNative(col), "only the fee surplus is left, owed to the platform");
        // the fee collector withdraws its surplus, on record
        uint256 owedCol = vault().owedNative(col) + vault().owed(col);
        uint256 cb = col.balance;
        vm.expectEmit(true, true, false, true, vaultAddr);
        emit CuratedVaultBase.Withdrawn(col, col, owedCol);
        vault().withdraw(col);
        assertEq(col.balance - cb, owedCol);
        assertEq(vaultAddr.balance, 0, "nothing left behind once withdrawn");
    }

    /// Purchases lock the hashes of earlier purchase blocks, also of consecutive blocks; anyone may lock; a slot whose
    /// hash expired unlocked cannot be drawn until anyone re-anchors it to a new block.
    function test_Reveal_HashLockAndRearm() public {
        _launch();
        _mirror();
        uint256 b = vm.getBlockNumber(); // (via-ir may re-read block.number after vm.roll)
        uint256 s1 = _buy(0, buyer);
        vm.roll(b + 1);
        uint256 s2 = _buy(0, buyer2); // the very next block: nothing to lock yet
        vm.roll(b + 3);
        vm.setBlockhash(b + 1, keccak256("h1"));
        vm.setBlockhash(b + 2, keccak256("h2"));
        _buy(1, buyer); // locks the hashes of b + 1 and b + 2
        assertEq(vault().lockedHash(b + 1), keccak256("h1"));
        assertEq(vault().lockedHash(b + 2), keccak256("h2"));
        vm.roll(b + 400);
        _fulfill(s1, _expect(s1, keccak256("h1")));
        _fulfill(s2, _expect(s2, keccak256("h2")));
        // a slot whose hash nobody locked within 256 blocks: no draw with a value known in advance, but a re-anchor
        uint256 b3 = vm.getBlockNumber();
        uint256 s4 = _buy(0, buyer);
        vm.roll(b3 + 300);
        CuratedHiddenBase.HiddenWork memory w0 = _work(0);
        bytes32[] memory sp4 = _secretProof(s4);
        bytes32 sec4 = _secret(s4);
        vm.prank(server);
        vm.expectRevert(CuratedRevealVault.HashExpired.selector);
        vault().fulfill(s4, sec4, sp4, w0, "");
        vm.prank(attacker);
        vault().rearm(s4);
        vm.expectRevert(CuratedHiddenBase.TooEarly.selector);
        vault().rearm(s4);
        uint256 b4 = vm.getBlockNumber();
        vm.roll(b4 + 2);
        vm.setBlockhash(b4 + 1, keccak256("h4"));
        vm.prank(attacker);
        vault().lockHash(s4);
        vm.roll(b4 + 1000);
        _fulfill(s4, _expect(s4, keccak256("h4")));
    }

    /// The reveal fee repays gas only up to REVEAL_GAS_PRICE, made up from the curator's fee reserve when it falls
    /// short; what a slot does not need is fee surplus, credited to the platform (or the payee) and withdrawn on record.
    function test_Reveal_GasPriceCapAndReserve() public {
        _launch();
        _mirror();
        uint256 b = vm.getBlockNumber();
        uint256 s1 = _buy(0, buyer);
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, keccak256("g"));
        vm.prank(curator);
        vault().fundFees{value: 0.01 ether}();
        uint256 cap = vault().REVEAL_GAS_PRICE();
        CuratedHiddenBase.HiddenWork memory w = _work(_expect(s1, keccak256("g")));
        bytes32[] memory sp = _secretProof(s1);
        bytes32 sec = _secret(s1);
        vm.txGasPrice(cap * 1000); // a caller bidding a huge price is still repaid at the cap
        address col = vault().PLATFORM() == address(0) ? vault().payee() : vault().PLATFORM();
        uint256 srv0 = server.balance;
        uint256 buy0 = buyer.balance;
        uint256 col0 = vault().owedNative(col);
        vm.prank(server);
        vault().fulfill(s1, sec, sp, w, "");
        vm.txGasPrice(0);
        uint256 repaid = server.balance - srv0;
        uint256 surplus = vault().owedNative(col) - col0;
        uint256 used = 0.01 ether - vault().feeReserve();
        assertLe(repaid, 800_000 * cap, "repaid at most the gas used at the capped price");
        assertEq(buyer.balance, buy0, "the holder's circuit is delivered; the fees are not returned");
        assertEq(repaid + surplus, vault().REVEAL_FEE() + used, "repaid = reveal fee + reserve used - surplus");
        assertTrue(used == 0 || surplus == 0, "the reserve only makes up a shortfall");
        // the curator can add a metadata file to a circuit delivered without one, once
        string memory uri = "ar://P05RevealedWorkMetadata_File_NotUploaded_00";
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault().declareURI(s1, uri);
        vm.prank(curator);
        vault().declareURI(s1, uri);
        assertEq(reg.tokenURI(address(C), vault().circuitOfSlot(s1)), uri);
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.AlreadyBound.selector);
        vault().declareURI(s1, uri);
        // the vault itself cannot be a slot's recipient
        uint256 due = vault().poolPrice(0) + fee + vault().REVEAL_FEE();
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.ZeroRecipient.selector);
        vault().buySlot{value: due}(0, vaultAddr);
    }

    /// TapeOut's fee rises above what a slot paid: delivery waits (FeeShortfall) until the curator's fee reserve covers
    /// the difference, and the tape-out fee and the gas are then made up from it; the curator cannot refund a slot the
    /// reserve can deliver, and takes the rest of the reserve back once every slot is settled after the sale.
    function test_Reveal_FeeReserveMakesUpShortfall() public {
        P.hidden.revealFee = fee / 2; // too little to pay a tape-out fee on its own
        _launch();
        _mirror();
        uint256 b = vm.getBlockNumber();
        uint256 rf = vault().REVEAL_FEE();
        vm.mockCall(address(C), abi.encodeWithSignature("TAPEOUT_FEE()"), abi.encode(uint256(0)));
        vm.prank(buyer);
        uint256 s1 = vault().buySlot{value: vault().poolPrice(0) + rf}(0, buyer); // the slot paid no tape-out fee
        vm.clearMockedCalls(); // TapeOut's fee is `fee` again
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, keccak256("q"));
        CuratedHiddenBase.HiddenWork memory w = _work(_expect(s1, keccak256("q")));
        bytes32[] memory sp = _secretProof(s1);
        bytes32 sec = _secret(s1);
        vm.prank(server);
        vm.expectRevert(CuratedHiddenBase.FeeShortfall.selector);
        vault().fulfill(s1, sec, sp, w, "");
        vm.prank(curator);
        vm.expectEmit(true, false, false, true, vaultAddr);
        emit CuratedHiddenBase.FeeReserveFunded(curator, 1 ether);
        vault().fundFees{value: 1 ether}();
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotClaimableYet.selector);
        vault().withdrawFeeReserve();
        vm.warp(vault().SALE_END());
        uint256 price = vault().poolPrice(0);
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotRefundable.selector);
        vault().refundPending{value: price}(s1, sec, sp);
        uint256 cap = vault().REVEAL_GAS_PRICE();
        vm.txGasPrice(cap);
        uint256 srv0 = server.balance;
        vm.prank(server);
        uint256 id = vault().fulfill(s1, sec, sp, w, "");
        vm.txGasPrice(0);
        uint256 repaid = server.balance - srv0;
        assertEq(C.ownerOf(id), buyer);
        assertGt(repaid, 0, "the server's gas is repaid from the reserve");
        assertEq(1 ether - vault().feeReserve(), fee - rf + repaid, "reserve used = fee shortfall + gas");
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault().withdrawFeeReserve();
        uint256 left = vault().feeReserve();
        uint256 c0 = curator.balance;
        vm.prank(curator);
        vault().withdrawFeeReserve();
        assertEq(curator.balance - c0, left, "the rest goes back to the curator");
        assertEq(vault().feeReserve(), 0);
    }

    /// The curator may refund a pending slot only when TapeOut's fee has risen above what it holds (paying the price
    /// back itself, exactly); the draw is made and the drawn work is withdrawn, so later slots get exactly what they
    /// would have got. Nobody else can refund.
    function test_Reveal_RefundVoidsTheDrawnWork() public {
        _launch();
        _mirror();
        uint256 b = vm.getBlockNumber(); // (via-ir may re-read block.number after vm.roll)
        uint256 s1 = _buy(0, buyer);
        uint256 s2 = _buy(0, buyer2);
        bytes32 h = keccak256("h");
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, h);
        uint256 price = vault().poolPrice(0);
        bytes32[] memory sp = _secretProof(s1);
        bytes32 sec = _secret(s1);
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault().refundPending{value: price}(s1, sec, sp);
        uint256 high = fee + vault().REVEAL_FEE() + 1;
        vm.mockCall(address(C), abi.encodeWithSignature("TAPEOUT_FEE()"), abi.encode(high));
        // not during the sale, even for an undeliverable slot
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotRefundable.selector);
        vault().refundPending{value: price}(s1, sec, sp);
        vm.warp(vault().SALE_END());
        vm.clearMockedCalls();
        // after the sale, not for a slot that can still be delivered
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotRefundable.selector);
        vault().refundPending{value: price}(s1, sec, sp);
        vm.mockCall(address(C), abi.encodeWithSignature("TAPEOUT_FEE()"), abi.encode(high));
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, price));
        vault().refundPending{value: price - 1}(s1, sec, sp);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, price));
        vault().refundPending{value: price + 1}(s1, sec, sp);
        uint256 b0 = buyer.balance;
        vm.prank(curator);
        vault().refundPending{value: price}(s1, sec, sp);
        vm.clearMockedCalls();
        assertEq(buyer.balance - b0, price + fee + vault().REVEAL_FEE(), "price, tape-out fee and reveal fee back");
        _expect(s1, h); // the voided work
        uint256 e2 = _expect(s2, h);
        uint256 id2 = _fulfill(s2, e2);
        (, uint256 idx) = reg.editionOf(address(C), id2);
        assertEq(idx, e2);
        assertEq(vault().slotsSettled(), 2);
    }

    /// Reserved works stay unpublished until the pools are sold out or the sale is over; finalize waits for every slot.
    function test_Reveal_ReservedAfterSellOutAndFinalize() public {
        _launch();
        _mirror();
        uint256 reservedIndex = vault().POOLED();
        CuratedHiddenBase.HiddenWork[] memory rs = new CuratedHiddenBase.HiddenWork[](1);
        rs[0] = _work(reservedIndex);
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotClaimableYet.selector);
        vault().claimReservedBatch{value: fee}(rs);
        uint256 b = vm.getBlockNumber(); // (via-ir may re-read block.number after vm.roll)
        uint256[] memory s = new uint256[](6);
        for (uint256 i; i < 6; i++) s[i] = _buy(i < 4 ? 0 : 1, i % 2 == 0 ? buyer : buyer2);
        assertTrue(vault().soldOut());
        uint256 due = vault().poolPrice(0) + fee + vault().REVEAL_FEE();
        vm.prank(buyer);
        vm.expectRevert(CuratedHiddenBase.PoolSoldOut.selector);
        vault().buySlot{value: due}(0, buyer);
        // a pooled work cannot be claimed as reserved
        CuratedHiddenBase.HiddenWork[] memory bad = new CuratedHiddenBase.HiddenWork[](1);
        bad[0] = _work(0);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.AlreadyTaken.selector);
        vault().claimReservedBatch{value: fee}(bad);
        vm.prank(curator);
        uint256[] memory rid = vault().claimReservedBatch{value: fee}(rs);
        assertEq(C.ownerOf(rid[0]), P.treasury);
        assertTrue(reg.isReserved(address(C), rid[0]));
        assertFalse(vault().finalizable());
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, keccak256("x"));
        bool[6] memory seen;
        for (uint256 i; i < 6; i++) {
            uint256 e = _expect(s[i], keccak256("x"));
            assertFalse(seen[e], "every work drawn once");
            seen[e] = true;
            _fulfill(s[i], e);
        }
        assertTrue(vault().finalizable());
        vault().finalize();
    }

    /// A holder that is a contract which refuses ERC-721 transfers cannot block its pool: delivery is a plain transfer.
    function test_Reveal_ContractHolderCannotBlockThePool() public {
        _launch();
        _mirror();
        NoReceiver nr = new NoReceiver();
        vm.deal(address(nr), 1 ether);
        uint256 b = vm.getBlockNumber(); // (via-ir may re-read block.number after vm.roll)
        vm.prank(buyer);
        uint256 s1 = vault().buySlot{value: vault().poolPrice(0) + fee + vault().REVEAL_FEE()}(0, address(nr));
        uint256 s2 = _buy(0, buyer2);
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, keccak256("y"));
        uint256 id1 = _fulfill(s1, _expect(s1, keccak256("y")));
        assertEq(C.ownerOf(id1), address(nr));
        _fulfill(s2, _expect(s2, keccak256("y")));
        // the fee surplus is the platform's, not the holder's
        assertEq(vault().owedNative(address(nr)), 0);
    }

    /// The registry checks the pools and the commitments of a hidden sale at launch.
    function test_Reveal_ParamsChecked() public {
        LaunchParams memory q = P;
        q.hidden.poolCounts[0] += 1; // pools no longer add up to count - reserved
        _expectBad(q, "pools");
        q = P;
        q.hidden.poolPrices = new uint256[](0);
        _expectBad(q, "pools");
        q = P;
        q.hidden.secretsRoot = 0;
        _expectBad(q, "secret");
        q = P;
        q.hidden.secretHash = keccak256("both");
        _expectBad(q, "secret");
        q = P;
        q.sequential = true;
        _expectBad(q, "hidden");
        q = P;
        q.metadataURI = "ar://P05RevealedWorkMetadata_File_NotUploaded_00";
        _expectBad(q, "hidden");
        q = P;
        q.hidden.revealGasPrice = 0;
        _expectBad(q, "revealFee");
        q = P;
        q.hidden.poolPrices[0] = uint256(type(uint128).max) + 1;
        _expectBad(q, "pools");
        q = P;
        q.saleMode = 0; // an instant tape-out with hidden parameters
        _expectBad(q, "hidden");
    }

    function _expectBad(LaunchParams memory q, bytes32 why) internal {
        uint256 v = vm.parseJsonUint(manifest, ".launch.launchValueWei");
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedRegistry.BadParams.selector, why));
        reg.launch{value: v}(q);
    }

    /// Presale prices are per pool and tier.
    /// Mint refund: only after the sale, only the curator, exactly the price, once, to the circuit's current holder;
    /// the circuit stays.
    function test_Reveal_MintRefund() public {
        _launch();
        _mirror();
        uint256 b = vm.getBlockNumber();
        uint256 s1 = _buy(0, buyer);
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, keccak256("r"));
        uint256 id = _fulfill(s1, _expect(s1, keccak256("r")));
        uint256[] memory ids = new uint256[](1);
        ids[0] = s1;
        uint256 price = vault().poolPrice(0);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.SaleNotOver.selector);
        vault().mintRefund{value: price}(ids);
        vm.warp(vault().SALE_END());
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault().mintRefund{value: price}(ids);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, price));
        vault().mintRefund{value: price - 1}(ids);
        vm.prank(buyer);
        C.transferFrom(buyer, attacker, id);
        uint256 b0 = attacker.balance;
        vm.prank(curator);
        vault().mintRefund{value: price}(ids);
        assertEq(attacker.balance - b0, price, "only the mint price, to the current holder");
        assertEq(C.ownerOf(id), attacker);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.NothingToRefund.selector);
        vault().mintRefund{value: price}(ids);
    }

    function test_Reveal_PresalePerPool() public {
        P.presaleStart = uint64(block.timestamp);
        P.saleStart = uint64(block.timestamp + 1 days);
        _launch();
        address alice = vm.parseJsonAddress(manifest, ".allowlist[0].address");
        vm.etch(alice, "");
        vm.deal(alice, 1 ether);
        bytes32[] memory ap = vm.parseJsonBytes32Array(manifest, ".allowlist[0].proof");
        bytes32[] memory leaves = new bytes32[](4);
        for (uint32 t; t < 2; t++) {
            for (uint256 p; p < 2; p++) {
                uint256 pr = vm.parseJsonUint(manifest, string.concat(".presaleTiers[", vm.toString(t), "].prices[", vm.toString(p), "]"));
                leaves[t * 2 + p] = _poolPriceLeaf(p, t, pr);
            }
        }
        uint256 og1 = vm.parseJsonUint(manifest, ".presaleTiers[0].prices[1]");
        (bytes32 root, bytes32[] memory pp) = _tree(leaves, _poolPriceLeaf(1, 0, og1));
        assertEq(root, vault().PRESALE_PRICE_ROOT());
        uint256 rf = vault().REVEAL_FEE();
        vm.prank(alice);
        vm.expectRevert(CuratedVaultBase.InvalidPresalePrice.selector);
        vault().buySlotPresale{value: og1 + fee + rf}(0, alice, 2, 0, ap, og1, pp);
        vm.prank(alice);
        uint256 s = vault().buySlotPresale{value: og1 + fee + rf}(1, alice, 2, 0, ap, og1, pp);
        (address holder,, uint32 pool,,, uint128 paid,) = vault().slots(s);
        assertEq(holder, alice);
        assertEq(pool, 1);
        assertEq(paid, og1);
    }
}

contract NoReceiver {
    receive() external payable {
        revert("no");
    }
}

// ====================================================================== blind box

contract BlindBoxForkTest is ModesBase {
    function _fixture() internal pure override returns (string memory) {
        return "blindbox";
    }

    function vault() internal view returns (CuratedBlindBoxVault) {
        return CuratedBlindBoxVault(payable(vaultAddr));
    }

    function _work(uint256 index) internal view returns (CuratedHiddenBase.HiddenWork memory) {
        return _hwork(index);
    }

    function _buy(uint32 pool, address who) internal returns (uint256 slot) {
        vm.prank(who);
        slot = vault().buySlot{value: vault().poolPrice(pool) + fee + vault().REVEAL_FEE()}(pool, who);
    }

    function _sellOut() internal returns (uint256[] memory s) {
        s = new uint256[](6);
        for (uint256 i; i < 6; i++) s[i] = _buy(i < 4 ? 0 : 1, i % 2 == 0 ? buyer : buyer2);
    }

    function _reveal() internal returns (bytes32 seed) {
        bytes32 secret = vm.parseJsonBytes32(manifest, ".secret");
        vm.prank(curator);
        vault().reveal(secret, "ar://P05BlindBoxRevealedDirectory_NotUploaded000");
        uint256 b = vm.getBlockNumber(); // (via-ir may re-read block.number after vm.roll)
        vm.roll(b + 2);
        vm.setBlockhash(b + 1, keccak256("after reveal"));
        vault().fixSeed();
        seed = keccak256(abi.encode(secret, keccak256("after reveal")));
        assertEq(vault().seed(), seed);
    }

    /// The assignment, computed here independently: 4-round Feistel on 2k bits, cycle-walked.
    function _permute(uint256 x, uint256 n, bytes32 key) internal pure returns (uint256) {
        uint256 k = 1;
        while ((uint256(1) << (2 * k)) < n) k++;
        uint256 mask = (uint256(1) << k) - 1;
        while (true) {
            uint256 l = x >> k;
            uint256 r = x & mask;
            for (uint256 i; i < 4; i++) {
                uint256 f = uint256(keccak256(abi.encode(key, i, r))) & mask;
                (l, r) = (r, l ^ f);
            }
            x = (l << k) | r;
            if (x < n) return x;
        }
        return 0;
    }

    function _assigned(uint256 slot, bytes32 seed) internal view returns (uint256) {
        (,, uint32 pool, uint32 pos,,,) = vault().slots(slot);
        return vault().poolStart(pool) + _permute(pos, vault().poolCount(pool), keccak256(abi.encode(seed, pool)));
    }

    /// Test vectors of the TAP: the permutation and the seed (also checked by `curate.py selftest`).
    function test_Box_Vectors() public {
        _launch();
        bytes32 key = keccak256("TAP-OCCC");
        uint256[6] memory want = [uint256(2), 5, 0, 1, 4, 3];
        // the contract's permutation is checked against this one in test_Box_RevealAndRedeem (assignedIndex)
        for (uint256 x; x < 6; x++) assertEq(_permute(x, 6, key), want[x]);
        bytes32 s1 = 0x0101010101010101010101010101010101010101010101010101010101010101;
        bytes32 h2 = 0x0202020202020202020202020202020202020202020202020202020202020202;
        assertEq(keccak256(abi.encode(s1, h2)), 0x346d8c96a2454213fcc0daff3c96ad0398148181b9fa6488f7ae2c0af5b20aa0);
    }

    /// Each slot is a transferable pass of this vault (ERC-721), which the registry recognises.
    function test_Box_PassIsATransferableNFT() public {
        _launch();
        assertTrue(reg.isBlindBoxPass(vaultAddr));
        assertFalse(reg.isBlindBoxPass(address(C)));
        assertTrue(vault().supportsInterface(0x80ac58cd));
        assertTrue(vault().supportsInterface(0x5b5e139f));
        uint256 s = _buy(0, buyer);
        assertEq(vault().ownerOf(s), buyer);
        assertEq(vault().balanceOf(buyer), 1);
        assertEq(vault().tokenURI(s), P.hidden.passURI);
        assertEq(vault().symbol(), string.concat(P.symbol, "BOX"));
        vm.prank(attacker);
        vm.expectRevert(CuratedHiddenBase.NotAuthorized.selector);
        vault().transferFrom(buyer, attacker, s);
        vm.prank(buyer);
        vault().approve(attacker, s);
        vm.prank(attacker);
        vault().transferFrom(buyer, buyer2, s);
        assertEq(vault().ownerOf(s), buyer2);
        assertEq(vault().getApproved(s), address(0));
        vm.prank(buyer2);
        vm.expectRevert(CuratedVaultBase.ZeroRecipient.selector);
        vault().transferFrom(buyer2, vaultAddr, s);
        NoReceiver nr = new NoReceiver();
        vm.prank(buyer2);
        vm.expectRevert();
        vault().safeTransferFrom(buyer2, address(nr), s);
        // the reveal waits for the end of the sale (or a sell-out)
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotRevealable.selector);
        vault().reveal(vm.parseJsonBytes32(manifest, ".secret"), "");
    }

    /// After the reveal every pass shows the work it will become; anyone redeems in batches, to the holder at that
    /// moment, burning the pass in the same transaction; the gas is repaid from each pass's reveal fee.
    function test_Box_RevealAndRedeem() public {
        _launch();
        uint256[] memory s = _sellOut();
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault().reveal(vm.parseJsonBytes32(manifest, ".secret"), "");
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.InvalidSecret.selector);
        vault().reveal(keccak256("guess"), "");
        bytes32 seed = _reveal();
        assertEq(reg.metadataURIOf(address(C)), "ar://P05BlindBoxRevealedDirectory_NotUploaded000");
        // a permutation of each pool
        bool[6] memory seen;
        for (uint256 i; i < 6; i++) {
            uint256 e = _assigned(s[i], seed);
            assertEq(vault().assignedIndex(s[i]), e, "assignment rebuilt");
            assertFalse(seen[e]);
            seen[e] = true;
            (,, uint32 pool,,,,) = vault().slots(s[i]);
            assertTrue(e >= vault().poolStart(pool) && e < vault().poolStart(pool) + vault().poolCount(pool));
            assertEq(vault().tokenURI(s[i]),
                string.concat("ar://P05BlindBoxRevealedDirectory_NotUploaded000/", vm.toString(e), ".json"));
        }
        // the pass of slot 1 is sold after the reveal: the new holder gets the circuit
        vm.prank(buyer);
        vault().transferFrom(buyer, attacker, s[0]);
        uint256[] memory ids = new uint256[](3);
        CuratedHiddenBase.HiddenWork[] memory ws = new CuratedHiddenBase.HiddenWork[](3);
        for (uint256 i; i < 3; i++) {
            ids[i] = s[i];
            ws[i] = _work(_assigned(s[i], seed));
        }
        vm.txGasPrice(1 gwei);
        uint256 srv0 = server.balance;
        vm.prank(server);
        uint256 g = gasleft();
        vault().redeem(ids, ws);
        emit log_named_uint("redeem gas, 3 passes", g - gasleft());
        vm.txGasPrice(0);
        assertGt(server.balance, srv0);
        assertLe(server.balance - srv0, 3 * vault().REVEAL_FEE());
        assertEq(C.ownerOf(vault().circuitOfSlot(s[0])), attacker);
        assertEq(C.ownerOf(vault().circuitOfSlot(s[1])), buyer2);
        vm.expectRevert(CuratedHiddenBase.NotPass.selector);
        vault().ownerOf(s[0]);
        assertEq(vault().balanceOf(attacker), 0);
        // the same batch again skips what is delivered
        vault().redeem(ids, ws);
        // a holder redeems its own pass; a wrong work is refused
        uint256[] memory one = new uint256[](1);
        CuratedHiddenBase.HiddenWork[] memory w1 = new CuratedHiddenBase.HiddenWork[](1);
        one[0] = s[3];
        uint256 e3 = _assigned(s[3], seed);
        w1[0] = _work(e3 == 0 ? 1 : 0);
        vm.expectRevert(abi.encodeWithSelector(CuratedHiddenBase.WrongWork.selector, e3));
        vault().redeem(one, w1);
        for (uint256 i = 3; i < 6; i++) {
            one[0] = s[i];
            w1[0] = _work(_assigned(s[i], seed));
            vm.prank(i % 2 == 0 ? buyer : buyer2);
            vault().redeem(one, w1);
        }
        for (uint256 i; i < 6; i++) {
            uint256 id = vault().circuitOfSlot(s[i]);
            (bool off, uint256 idx) = reg.editionOf(address(C), id);
            assertTrue(off);
            assertEq(idx, _assigned(s[i], seed));
            assertEq(reg.tokenURI(address(C), id),
                string.concat("ar://P05BlindBoxRevealedDirectory_NotUploaded000/", vm.toString(idx), ".json"));
        }
        CuratedHiddenBase.HiddenWork[] memory rs = new CuratedHiddenBase.HiddenWork[](1);
        rs[0] = _work(vault().POOLED());
        vm.prank(curator);
        vault().claimReservedBatch{value: fee}(rs);
        vault().finalize();
    }

    /// If nobody fixes the seed within 256 blocks of the reveal, the next call re-anchors it to a new block.
    function test_Box_SeedRearm() public {
        _launch();
        uint256[] memory s = _sellOut();
        bytes32 secret = vm.parseJsonBytes32(manifest, ".secret");
        vm.prank(curator);
        vault().reveal(secret, "ar://P05BlindBoxRevealedDirectory_NotUploaded000");
        uint256 b = vm.getBlockNumber();
        vm.roll(b + 300);
        vm.prank(attacker);
        vault().fixSeed();
        assertFalse(vault().seedFixed());
        assertEq(vault().revealBlock(), b + 300);
        // redeem in that state changes nothing but the anchor, and does not revert
        uint256[] memory one = new uint256[](1);
        one[0] = s[0];
        CuratedHiddenBase.HiddenWork[] memory w = new CuratedHiddenBase.HiddenWork[](1);
        w[0] = _work(0);
        vm.roll(b + 302);
        vm.setBlockhash(b + 301, keccak256("late"));
        vault().fixSeed();
        assertEq(vault().seed(), keccak256(abi.encode(secret, keccak256("late"))));
        w[0] = _work(_assigned(s[0], vault().seed()));
        vault().redeem(one, w);
        assertEq(C.ownerOf(vault().circuitOfSlot(s[0])), buyer);
    }

    /// In one block, a pass sold and then redeemed goes to the buyer; redeemed and then "sold" leaves nothing to sell.
    /// Mint refund: after the sale the curator can return the price of redeemed passes to the circuits' current
    /// holders (not the minters); circuits stay put.
    function test_Box_MintRefundToHolder() public {
        _launch();
        uint256[] memory s = _sellOut();
        bytes32 seed = _reveal();
        vm.prank(buyer);
        vault().transferFrom(buyer, attacker, s[0]); // the pass changes hands before redemption
        uint256[] memory one = new uint256[](1);
        CuratedHiddenBase.HiddenWork[] memory w = new CuratedHiddenBase.HiddenWork[](1);
        one[0] = s[0];
        w[0] = _work(_assigned(s[0], seed));
        vault().redeem(one, w);
        uint256 price = vault().poolPrice(0);
        uint256 b0 = attacker.balance;
        uint256 m0 = buyer.balance;
        vm.prank(curator);
        vault().mintRefund{value: price}(one);
        assertEq(attacker.balance - b0, price, "the circuit's holder gets the mint price back");
        assertEq(buyer.balance, m0, "not the minter");
        assertEq(C.ownerOf(vault().circuitOfSlot(s[0])), attacker, "the circuit stays with its holder");
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.NothingToRefund.selector);
        vault().mintRefund{value: price}(one);
        one[0] = s[1]; // not redeemed yet
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.NothingToRefund.selector);
        vault().mintRefund{value: price}(one);
    }

    function test_Box_SameBlockTradeAndRedeem() public {
        _launch();
        uint256[] memory s = _sellOut();
        bytes32 seed = _reveal();
        uint256[] memory one = new uint256[](1);
        CuratedHiddenBase.HiddenWork[] memory w1 = new CuratedHiddenBase.HiddenWork[](1);
        // order 1: transfer, then redeem (same block)
        one[0] = s[0];
        w1[0] = _work(_assigned(s[0], seed));
        vm.prank(buyer);
        vault().transferFrom(buyer, attacker, s[0]);
        vault().redeem(one, w1);
        assertEq(C.ownerOf(vault().circuitOfSlot(s[0])), attacker);
        // order 2: redeem, then transfer (same block): the pass is gone, the circuit is the holder's
        one[0] = s[1];
        w1[0] = _work(_assigned(s[1], seed));
        vault().redeem(one, w1);
        vm.prank(buyer2);
        vm.expectRevert(CuratedHiddenBase.NotPass.selector);
        vault().transferFrom(buyer2, attacker, s[1]);
        assertEq(C.ownerOf(vault().circuitOfSlot(s[1])), buyer2);
    }

    /// Refunds: the curator only, any pass before the reveal (price from the curator, fees from the vault); after the
    /// reveal only a pass that can no longer be redeemed because TapeOut's fee rose above what it holds.
    function test_Box_Refunds() public {
        _launch();
        uint256 s1 = _buy(0, buyer);
        uint256 s2 = _buy(1, buyer2);
        uint256[] memory ids = new uint256[](1);
        ids[0] = s1;
        uint256 price = vault().poolPrice(0);
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault().refund{value: price}(ids);
        // no refunds while the sale is on
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotRefundable.selector);
        vault().refund{value: price}(ids);
        // the sale ends unsold: refunds before the reveal, then the reveal
        vm.warp(vault().SALE_END());
        uint256 b0 = buyer.balance;
        vm.prank(curator);
        vault().refund{value: price}(ids);
        assertEq(buyer.balance - b0, price + fee + vault().REVEAL_FEE());
        vm.expectRevert(CuratedHiddenBase.NotPass.selector);
        vault().ownerOf(s1);
        bytes32 seed = _reveal();
        ids[0] = s2;
        uint256 p1 = vault().poolPrice(1);
        vm.prank(curator);
        vm.expectRevert(CuratedHiddenBase.NotRefundable.selector);
        vault().refund{value: p1}(ids);
        // TapeOut raises its fee above what the pass holds: redeeming fails, so the curator may refund
        uint256 high = fee + vault().REVEAL_FEE() + 1;
        vm.mockCall(address(C), abi.encodeWithSignature("TAPEOUT_FEE()"), abi.encode(high));
        CuratedHiddenBase.HiddenWork[] memory w = new CuratedHiddenBase.HiddenWork[](1);
        w[0] = _work(_assigned(s2, seed));
        vm.expectRevert(CuratedHiddenBase.FeeShortfall.selector);
        vault().redeem(ids, w);
        vm.prank(curator);
        vault().refund{value: p1}(ids);
        vm.clearMockedCalls();
        assertEq(vault().slotsSettled(), 2);
        vm.warp(uint256(vault().SALE_END()) + vault().RESERVE_GRACE());
        vault().finalize();
    }
}
