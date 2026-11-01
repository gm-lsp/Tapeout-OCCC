// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CuratedRegistry} from "../src/CuratedRegistry.sol";
import {ICircuitURIProvider} from "../src/interfaces/ICircuitURIProvider.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {CuratedVaultBase} from "../src/CuratedVaultBase.sol";
import {CuratedRevealVault} from "../src/CuratedRevealVault.sol";
import {CuratedBlindBoxVault} from "../src/CuratedBlindBoxVault.sol";
import {LaunchParams, HiddenParams} from "../src/CuratedTypes.sol";
import {ICuratedRegistry} from "../src/interfaces/ICuratedRegistry.sol";
import {ITapeOutFactory, ITapeOutTransistors, ITapeOutCircuits} from "../src/interfaces/ITapeOut.sol";

/// A plain ERC-20 for the payment-token tests (8 decimals, like BEM).
contract MockToken {
    string public constant symbol = "MOCK";
    uint8 public constant decimals = 8;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal virtual {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Takes 1 % of every transfer: the vault must refuse it.
contract FeeToken is MockToken {
    function _move(address from, address to, uint256 amount) internal override {
        uint256 tax = amount / 100;
        balanceOf[from] -= amount;
        balanceOf[to] += amount - tax;
        totalSupply -= tax;
    }
}

/// Like USDT: transfer and transferFrom return nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external {
        allowance[msg.sender][spender] = amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}

/// Calls back into the vault on every transfer (like an ERC-777 hook) and records whether that call got in.
contract HookToken is MockToken {
    address public vault;
    bytes public hook;
    bool public reentered;

    function arm(address v, bytes calldata data) external {
        vault = v;
        hook = data;
    }

    function _move(address from, address to, uint256 amount) internal override {
        super._move(from, to, amount);
        if (vault != address(0) && hook.length > 0) {
            (bool ok,) = vault.call(hook);
            if (ok) reentered = true;
        }
    }
}

interface IERC20Meta {
    function decimals() external view returns (uint8);
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IFactoryFees {
    function protocolFee() external view returns (uint256);
}

/// Fork tests against live TapeOut state on BNB Smart Chain, X Layer or Base. Run with one of:
///   forge test --fork-url https://bsc-dataseed.bnbchain.org   (chain 56)
///   forge test --fork-url https://rpc.xlayer.tech             (chain 196)
///   forge test --fork-url https://mainnet.base.org            (chain 8453)
/// Works come from test/fixtures/manifest.json (chain 56) or manifest.<chainId>.json, produced by
/// `tool/curate.py build`. The manifest's leaves are bound to the chain, the registry address REG and the curator,
/// so the registry is placed at REG.
contract CuratedForkTest is Test {
    ITapeOutFactory FACTORY;
    // a circuit of another processor on the same chain (its netlist is not in the work list)
    ITapeOutCircuits FOREIGN;
    uint256 FOREIGN_ID;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant REG = 0x00000000000000000000000000000000c0dEc0DE;
    bytes4 constant ERC1155_INSUFFICIENT_BALANCE = 0x03dee4c5;

    CuratedRegistry reg;
    address IMPL0;
    address IMPL1;
    address IMPL2;
    string manifest;
    uint256 count;
    uint256 launchValue;

    address curator;
    address buyer = makeAddr("buyer");
    // the curator's payee in these tests (the fixture's payee is the curator); a plain account, so balances are exact
    address PAYEE = makeAddr("p05-payee");
    address attacker = makeAddr("attacker");

    CuratedVault vault;
    ITapeOutTransistors T;
    ITapeOutCircuits C;
    uint256 fee; // cached so that vm.prank / vm.expectRevert are not consumed by a fee lookup

    function setUp() public {
        string memory path;
        if (block.chainid == 56) {
            FACTORY = ITapeOutFactory(0x68224F668083c29e9800Be2a646d42d18cedF7e2);
            (FOREIGN, FOREIGN_ID) = (ITapeOutCircuits(0x50A994E71615474b55559fF4F500928fbc339DD9), 50);
            path = "test/fixtures/manifest.json";
        } else if (block.chainid == 196 || block.chainid == 8453) {
            // X Layer and Base: same deployer, same addresses. Base's circuit #1 is a XOR byte-identical to work 3,
            // so the foreign netlist there is circuit #2.
            FACTORY = ITapeOutFactory(0x1f09DAeFA827f02CBb40967cc91b259763760761);
            (FOREIGN, FOREIGN_ID) =
                (ITapeOutCircuits(0x0565EA48CA41Ae559d8d491dbb0a9ec945DB551b), block.chainid == 196 ? 1 : 2);
            path = string.concat("test/fixtures/manifest.", vm.toString(block.chainid), ".json");
        } else {
            revert("fork BNB Smart Chain (56), X Layer (196) or Base (8453)");
        }
        // the three vault implementations, then the registry that clones them (at the address the leaves are bound to)
        IMPL0 = address(new CuratedVault());
        IMPL1 = address(new CuratedRevealVault());
        IMPL2 = address(new CuratedBlindBoxVault());
        deployCodeTo("CuratedRegistry.sol:CuratedRegistry", abi.encode(FACTORY, IMPL0, IMPL1, IMPL2), REG);
        reg = CuratedRegistry(REG);
        manifest = vm.readFile(path);
        count = vm.parseJsonUint(manifest, ".launch.count");
        launchValue = vm.parseJsonUint(manifest, ".launch.launchValueWei");
        curator = vm.parseJsonAddress(manifest, ".launch.curator");
        assertEq(vm.parseJsonAddress(manifest, ".registry"), REG);
        assertEq(block.chainid, vm.parseJsonUint(manifest, ".chainId"));
        // the test actors are plain accounts (a labelled address can hold code on a live chain)
        vm.etch(buyer, "");
        vm.etch(attacker, "");
        vm.etch(PAYEE, "");
        vm.deal(curator, 10 ether);
        vm.deal(buyer, 100 ether);
        vm.deal(attacker, 100 ether);
    }

    // ------------------------------------------------------------------ helpers

    /// The factory's protocol fee per mint call (not in ITapeOutFactory; src/ is unchanged).
    function _protocolFee() internal view returns (uint256) {
        return IFactoryFees(address(FACTORY)).protocolFee();
    }

    /// A labelled plain account: on a live chain the address makeAddr derives can hold code (e.g. EIP-7702).
    function _eoa(string memory name) internal returns (address a) {
        a = makeAddr(name);
        vm.etch(a, "");
    }


    function _params() internal view returns (LaunchParams memory p) {
        p.name = vm.parseJsonString(manifest, ".launch.name");
        p.symbol = vm.parseJsonString(manifest, ".launch.symbol");
        p.story = vm.parseJsonString(manifest, ".launch.story");
        p.nandSupply = vm.parseJsonUint(manifest, ".launch.nandSupply");
        p.latchSupply = vm.parseJsonUint(manifest, ".launch.latchSupply");
        p.mintPrice = vm.parseJsonUint(manifest, ".launch.mintPrice");
        p.mintBatch = vm.parseJsonUint(manifest, ".launch.mintBatch");
        p.root = vm.parseJsonBytes32(manifest, ".launch.root");
        p.count = uint32(vm.parseJsonUint(manifest, ".launch.count"));
        p.curator = vm.parseJsonAddress(manifest, ".launch.curator");
        p.platform = vm.parseJsonAddress(manifest, ".launch.platform");
        p.platformBps = uint16(vm.parseJsonUint(manifest, ".launch.platformBps"));
        p.saleStart = uint64(vm.parseJsonUint(manifest, ".launch.saleStart"));
        p.saleEnd = uint64(vm.parseJsonUint(manifest, ".launch.saleEnd"));
        p.maxLaunchFees = vm.parseJsonUint(manifest, ".launch.maxLaunchFees");
        p.treasury = vm.parseJsonAddress(manifest, ".launch.treasury");
        p.reservedCount = uint32(vm.parseJsonUint(manifest, ".launch.reservedCount"));
        p.limitPerWallet = vm.parseJsonBool(manifest, ".launch.limitPerWallet");
        p.maxPerWallet = uint32(vm.parseJsonUint(manifest, ".launch.maxPerWallet"));
        p.allowRoot = vm.parseJsonBytes32(manifest, ".launch.allowRoot");
        p.presaleStart = uint64(vm.parseJsonUint(manifest, ".launch.presaleStart"));
        p.royaltyReceiver = vm.parseJsonAddress(manifest, ".launch.royaltyReceiver");
        p.royaltyBps = uint16(vm.parseJsonUint(manifest, ".launch.royaltyBps"));
        p.titlesHash = vm.parseJsonBytes32(manifest, ".launch.titlesHash");
        p.metadataURI = vm.parseJsonString(manifest, ".launch.metadataURI");
        p.paymentToken = vm.parseJsonAddress(manifest, ".launch.paymentToken");
        p.presalePriceRoot = vm.parseJsonBytes32(manifest, ".launch.presalePriceRoot");
        p.saleMode = uint8(vm.parseJsonUint(manifest, ".launch.saleMode"));
        p.sequential = vm.parseJsonBool(manifest, ".launch.sequential");
        p.payee = vm.parseJsonAddress(manifest, ".launch.payee");
        if (p.payee == p.curator) p.payee = PAYEE;
        p.hidden.poolPrices = vm.parseJsonUintArray(manifest, ".launch.hidden.poolPrices");
        uint256[] memory pc = vm.parseJsonUintArray(manifest, ".launch.hidden.poolCounts");
        p.hidden.poolCounts = new uint32[](pc.length);
        for (uint256 i; i < pc.length; i++) {
            p.hidden.poolCounts[i] = uint32(pc[i]);
        }
        p.hidden.revealFee = vm.parseJsonUint(manifest, ".launch.hidden.revealFee");
        p.hidden.revealGasPrice = vm.parseJsonUint(manifest, ".launch.hidden.revealGasPrice");
        p.hidden.secretsRoot = vm.parseJsonBytes32(manifest, ".launch.hidden.secretsRoot");
        p.hidden.secretHash = vm.parseJsonBytes32(manifest, ".launch.hidden.secretHash");
        p.hidden.metadataRoot = vm.parseJsonBytes32(manifest, ".launch.hidden.metadataRoot");
        p.hidden.passURI = vm.parseJsonString(manifest, ".launch.hidden.passURI");
    }

    struct Work {
        uint256 index;
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        uint256 price;
        bytes32[] proof;
        uint256 nand;
        uint256 latch;
        bool reserved;
    }

    /// Work `i` of a fixture whose runs are single works (manifest /8: a run names its design, stored once).
    function _work(uint256 i) internal view returns (Work memory w) {
        string memory k = string.concat(".works[", vm.toString(i), "]");
        w.index = vm.parseJsonUint(manifest, string.concat(k, ".first"));
        require(vm.parseJsonUint(manifest, string.concat(k, ".copies")) == 1, "a run of copies");
        string memory d = string.concat(".designs[", vm.toString(vm.parseJsonUint(manifest, string.concat(k, ".design"))), "]");
        w.netlist = vm.parseJsonBytes(manifest, string.concat(d, ".netlist"));
        w.nIn = uint32(vm.parseJsonUint(manifest, string.concat(d, ".nIn")));
        w.nOut = uint32(vm.parseJsonUint(manifest, string.concat(d, ".nOut")));
        w.price = vm.parseJsonUint(manifest, string.concat(k, ".priceWei"));
        w.proof = vm.parseJsonBytes32Array(manifest, string.concat(k, ".proof"));
        w.nand = vm.parseJsonUint(manifest, string.concat(d, ".nand"));
        w.latch = vm.parseJsonUint(manifest, string.concat(d, ".latch"));
        w.reserved = vm.parseJsonBool(manifest, string.concat(k, ".reserved"));
    }

    uint256 constant RESERVED_WORK = 5; // the fixture reserves works 5 and 6 for the treasury
    uint256 constant RESERVED_WORK2 = 6;

    function _claim(uint256 i) internal returns (uint256 id) {
        Work memory w = _work(i);
        vm.prank(curator);
        id = vault.claimReserved{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.proof);
    }

    function _launchWith(LaunchParams memory p) internal returns (uint256 gasUsed, uint256 cost) {
        uint256 b0 = p.curator.balance;
        vm.prank(p.curator);
        uint256 g = gasleft();
        (address v, address t, address c) = reg.launch{value: launchValue}(p);
        gasUsed = g - gasleft();
        cost = b0 - p.curator.balance;
        vault = CuratedVault(payable(v));
        T = ITapeOutTransistors(t);
        C = ITapeOutCircuits(c);
        fee = C.TAPEOUT_FEE();
    }

    function _launch() internal returns (uint256, uint256) {
        return _launchWith(_params());
    }

    function _buy(uint256 i, address to) internal returns (uint256 id) {
        Work memory w = _work(i);
        vm.prank(buyer);
        id = vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, to);
    }

    // ------------------------------------------------------------------ launch

    function test_Launch_AtomicAndVerified() public {
        (uint256 gasUsed, uint256 cost) = _launch();
        emit log_named_uint("launch gas", gasUsed);
        emit log_named_decimal_uint("launch cost (native coin)", cost, 18);

        LaunchParams memory p = _params();
        assertTrue(reg.isCurated(address(C)));
        ICuratedRegistry.Collection memory col = reg.collectionOf(address(C));
        assertEq(col.vault, address(vault));
        assertEq(col.curator, p.curator);
        assertEq(col.transistors, address(T));
        assertEq(col.root, p.root);
        assertEq(col.count, p.count);
        assertEq(col.certified, 0);

        assertEq(T.creator(), address(vault));
        assertEq(T.minted(), T.supplyCap());
        assertEq(T.supplyCap(), p.nandSupply + p.latchSupply);
        assertEq(T.balanceOf(address(vault), 0), p.nandSupply);
        assertEq(T.balanceOf(address(vault), 1), p.latchSupply);
        assertEq(T.mintPrice(), p.mintPrice);
        assertEq(C.nextId(), 0);
        assertEq(address(vault).balance, 0);
        // the launcher paid exactly the protocol fees the tool predicted
        assertEq(cost, p.maxLaunchFees);
    }

    function test_Launch_ZeroMintPrice() public {
        LaunchParams memory p = _params();
        p.mintPrice = 0;
        p.mintBatch = 0;
        // deploy fee plus one protocol fee per id (no mint price, so one mint call each), with a margin
        uint256 value = 2 * (FACTORY.deployFee() + 2 * _protocolFee());
        vm.prank(curator);
        (address v,, address c) = reg.launch{value: value}(p);
        assertTrue(reg.isCurated(c));
        assertEq(reg.collectionOf(c).vault, v);
    }

    function test_Launch_RejectsBadParams() public {
        LaunchParams memory p = _params();
        p.platformBps = 1001;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("platformBps")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.saleEnd = p.saleStart;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("saleEnd")));
        reg.launch{value: launchValue}(p);

        p = _params();
        uint256 tooLittle = FACTORY.deployFee() + _protocolFee(); // deploy fee and one protocol fee only
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.InsufficientLaunchFunds.selector);
        reg.launch{value: tooLittle}(p);
    }

    /// L-2: the launcher caps what it is willing to pay in factory and protocol fees.
    function test_L2_LaunchFeeCap() public {
        LaunchParams memory p = _params();
        p.maxLaunchFees = p.maxLaunchFees - 1;
        vm.prank(curator);
        vm.expectPartialRevert(CuratedVaultBase.LaunchFeesTooHigh.selector);
        reg.launch{value: launchValue}(p);
    }

    /// H-1: nobody can launch a collection in another curator's name, and a copied root is useless.
    function test_H1_CopycatLaunchRejected() public {
        LaunchParams memory p = _params();
        vm.prank(attacker);
        vm.expectRevert(CuratedRegistry.CuratorMustLaunch.selector);
        reg.launch{value: launchValue}(p);

        // same root and name, attacker as curator: it launches, but no listed work can be sold,
        // because every leaf is bound to the real curator
        p.curator = attacker;
        vm.prank(attacker);
        (address v,, address c) = reg.launch{value: launchValue}(p);
        uint256 f = ITapeOutCircuits(c).TAPEOUT_FEE();
        Work memory w = _work(3); // price 0
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        CuratedVault(payable(v)).buy{value: f}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, attacker);
    }

    /// L-3: the launch refund cannot be used to buy works inside the launch transaction: the attempt hits the
    /// reentrancy guard (the hook records the exact error), and nothing is sold.
    function test_L3_RefundReentryBlocked() public {
        deployCodeTo("Curated.t.sol:RefundReenter", abi.encode(address(this)), curator);
        vm.deal(curator, 10 ether);
        _launch();
        assertEq(RefundReenter(payable(curator)).seen(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(vault.sold(), 0);
    }

    /// L-4: tokenOf never reports a work as taped out by reading a default id 0; editionOf of a circuit that
    /// is not official is (false, 0), and a work keeps its circuit id after it is taped out.
    function test_L4_TokenOfAndEditionOfDefaults() public {
        _launch();
        (bool taped, uint256 tid) = reg.tokenOf(address(C), 0);
        assertFalse(taped);
        assertEq(tid, 0);
        (bool off, uint256 idx) = reg.editionOf(address(C), 0);
        assertFalse(off);
        assertEq(idx, 0);
        uint256 id = _buy(0, buyer);
        (taped, tid) = reg.tokenOf(address(C), 0);
        assertTrue(taped);
        assertEq(tid, id);
        (taped,) = reg.tokenOf(address(C), 1);
        assertFalse(taped);
        assertFalse(reg.isOfficial(address(C), 0));
        assertFalse(reg.isOfficial(address(0xbeef), id));
    }

    /// The treasury, the platform and the payee can be neither the vault being created nor the registry.
    function test_PayeesCannotBeVaultOrRegistry() public {
        // vaults are clones the registry creates
        address nextVault = vm.computeCreateAddress(REG, vm.getNonce(REG));
        LaunchParams memory p = _params();
        p.treasury = nextVault;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("treasury")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.platform = nextVault;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("platform")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.platform = REG;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("platform")));
        reg.launch{value: launchValue}(p);

        address[3] memory bad = [address(0), nextVault, REG];
        for (uint256 i; i < 3; i++) {
            p = _params();
            p.payee = bad[i];
            vm.prank(curator);
            vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("payee")));
            reg.launch{value: launchValue}(p);
        }
        // the address really is the next vault
        (address v,,) = _launch2();
        assertEq(v, nextVault);
    }

    function _launch2() internal returns (address v, address t, address c) {
        vm.prank(curator);
        (v, t, c) = reg.launch{value: launchValue}(_params());
    }

    // ------------------------------------------------------------------ sale, end to end

    function test_BuyAll_CertifyPayFinalize() public {
        _launch();
        LaunchParams memory p = _params();
        uint256 gross;
        uint256 payee0 = PAYEE.balance;
        uint256 plat0 = p.platform.balance;
        for (uint256 i; i < count; i++) {
            Work memory w = _work(i);
            uint256 nand0 = T.balanceOf(address(vault), 0);
            uint256 latch0 = T.balanceOf(address(vault), 1);
            uint256 expectedId = C.nextId() + 1;
            uint256 g = gasleft();
            vm.expectEmit(true, true, true, true, address(reg));
            emit ICuratedRegistry.Certified(address(C), expectedId, i, keccak256(w.netlist), w.reserved);
            uint256 id = w.reserved ? _claim(i) : _buy(i, buyer);
            emit log_named_uint(
                string.concat(w.reserved ? "claim gas, work " : "buy gas, work ", vm.toString(i), ", bytes ",
                    vm.toString(w.netlist.length)),
                g - gasleft()
            );

            assertEq(id, expectedId);
            assertEq(C.ownerOf(id), w.reserved ? p.treasury : buyer);
            assertEq(reg.isReserved(address(C), id), w.reserved);
            assertTrue(reg.isOfficial(address(C), id));
            (bool off, uint256 idx) = reg.editionOf(address(C), id);
            assertTrue(off);
            assertEq(idx, i);
            (bool taped, uint256 tid) = reg.tokenOf(address(C), i);
            assertTrue(taped);
            assertEq(tid, id);
            assertEq(keccak256(C.netlist(id)), keccak256(w.netlist));
            (uint32 a, uint32 b,,) = C.circuitInfo(id);
            assertEq(a, w.nIn);
            assertEq(b, w.nOut);
            assertEq(nand0 - T.balanceOf(address(vault), 0), w.nand);
            assertEq(latch0 - T.balanceOf(address(vault), 1), w.latch);
            gross += w.price;

            if (i + 1 < count) {
                vm.expectRevert(CuratedVaultBase.NotFinalizable.selector);
                vault.finalize();
            }
        }
        assertEq(vault.sold(), count);
        assertEq(vault.reservedClaimed(), p.reservedCount);
        assertEq(reg.collectionOf(address(C)).certified, count);

        uint256 cut;
        for (uint256 i; i < count; i++) {
            cut += (_work(i).price * p.platformBps) / 10_000;
        }
        // every sale was paid out at once: the platform's share to the platform, the rest to the payee
        assertEq(p.platform.balance - plat0, cut);
        assertEq(PAYEE.balance - payee0, gross - cut);
        assertEq(address(vault).balance, 0);
        assertEq(vault.owed(PAYEE), 0);
        vm.expectRevert(CuratedVaultBase.NothingOwed.selector);
        vault.withdraw(PAYEE);

        // finalize burns every leftover NAND and LATCH
        uint256 n = T.balanceOf(address(vault), 0);
        uint256 l = T.balanceOf(address(vault), 1);
        assertGt(l, 0, "fixture keeps spare LATCH so the LATCH burn path runs");
        uint256 dn = T.balanceOf(DEAD, 0);
        uint256 dl = T.balanceOf(DEAD, 1);
        vault.finalize();
        assertEq(T.balanceOf(address(vault), 0), 0);
        assertEq(T.balanceOf(address(vault), 1), 0);
        assertEq(T.balanceOf(DEAD, 0) - dn, n);
        assertEq(T.balanceOf(DEAD, 1) - dl, l);
        emit log_named_uint("leftover NAND burned", n);
        emit log_named_uint("leftover LATCH burned", l);
        vm.expectRevert(CuratedVaultBase.AlreadyFinalized.selector);
        vault.finalize();
    }

    /// Mint refund: after the sale the curator can return the mint price of sold works to the circuits' current
    /// holders (once each); circuits stay.
    function test_MintRefund_PriceToHolderCircuitStays() public {
        _launch();
        uint256 id0 = _buy(0, buyer);
        uint256 id1 = _buy(1, buyer);
        uint256 id3 = _buy(3, buyer); // free
        Work memory w0 = _work(0);
        Work memory w1 = _work(1);
        uint256[] memory both = new uint256[](2);
        both[0] = 0;
        both[1] = 1;
        uint256 total = w0.price + w1.price;
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.SaleNotOver.selector);
        vault.mintRefund{value: total}(both);
        vm.warp(vault.SALE_END());
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault.mintRefund{value: total}(both);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, total));
        vault.mintRefund{value: total + 1}(both);
        vm.prank(buyer);
        C.transferFrom(buyer, attacker, id1); // sold on: the refund follows the circuit
        uint256 b0 = buyer.balance;
        uint256 a0 = attacker.balance;
        vm.prank(curator);
        vault.mintRefund{value: total}(both);
        assertEq(buyer.balance - b0, w0.price, "the mint price back to the holder, not the tape-out fee");
        assertEq(attacker.balance - a0, w1.price, "the current holder, not the minter");
        assertEq(C.ownerOf(id0), buyer);
        assertEq(C.ownerOf(id1), attacker);
        assertTrue(reg.isOfficial(address(C), id0));
        uint256[] memory one = new uint256[](1);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.NothingToRefund.selector);
        vault.mintRefund{value: w0.price}(both);
        one[0] = 3; // a free work
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.NothingToRefund.selector);
        vault.mintRefund(one);
        assertEq(C.ownerOf(id3), buyer);
    }

    /// M-1: an unsold (or unbuyable) work cannot block finalize forever.
    function test_M1_FinalizeAfterSaleEnd() public {
        _launch();
        uint256 id = _buy(0, buyer);
        vm.expectRevert(CuratedVaultBase.NotFinalizable.selector);
        vault.finalize();
        vm.warp(vault.SALE_END());
        Work memory w = _work(1);
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.SaleEnded.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        // reserved works are still unclaimed, so finalize waits for the grace period
        vm.expectRevert(CuratedVaultBase.NotFinalizable.selector);
        vault.finalize();
        vm.warp(uint256(vault.SALE_END()) + vault.RESERVE_GRACE());
        vault.finalize();
        assertEq(T.balanceOf(address(vault), 0) + T.balanceOf(address(vault), 1), 0);
        assertTrue(reg.isOfficial(address(C), id)); // the sold work stays official
    }

    /// L-1: a payee that refuses payments never blocks a purchase: its share is kept in `owed`, and it can send it
    /// elsewhere with withdrawTo. The curator can change the payee at any time.
    function test_L1_RejectingPayeeAndWithdrawTo() public {
        _launch();
        RejectPayee rp = new RejectPayee();
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault.setPayee(address(rp));
        vm.prank(curator);
        vault.setPayee(address(rp));
        assertEq(vault.payee(), address(rp));
        Work memory w = _work(1);
        _buy(1, buyer);
        uint256 cut = (w.price * vault.PLATFORM_BPS()) / 10_000;
        uint256 owed = vault.owed(address(rp));
        assertEq(owed, w.price - cut, "the share is kept for the payee");
        assertEq(address(vault).balance, owed);
        address to = _eoa("cold");
        rp.pull(vault, to);
        assertEq(to.balance, owed);
        assertEq(vault.owed(address(rp)), 0);
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.NothingOwed.selector);
        vault.withdrawTo(attacker);
        // a payee can be moved back to an account that accepts payments; payouts go there directly again
        vm.prank(curator);
        vault.setPayee(PAYEE);
        uint256 b0 = PAYEE.balance;
        Work memory w2 = _work(2);
        _buy(2, buyer);
        assertEq(PAYEE.balance - b0, w2.price - (w2.price * vault.PLATFORM_BPS()) / 10_000);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("payee")));
        vault.setPayee(address(vault));
    }

    // ------------------------------------------------------------------ R1: transistors never leave the vault

    function test_R1_NoWayToExtractTransistors() public {
        _launch();
        vm.startPrank(attacker);
        (bool ok1,) = address(T).call(
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256,uint256,bytes)", address(vault), attacker, 0, 1, ""
            )
        );
        (bool ok2,) = address(T).call(abi.encodeWithSignature("burnFrom(address,uint256,uint256)", address(vault), 0, 1));
        (bool ok3,) = address(T).call{value: 1 ether}(abi.encodeWithSignature("mint(uint256,uint256)", 0, 1));
        vm.stopPrank();
        assertFalse(ok1, "transfer from vault");
        assertFalse(ok2, "burnFrom vault");
        assertFalse(ok3, "mint after the supply is exhausted");
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.AlreadyInitialized.selector);
        vault.initialize(_params(), attacker);
        vm.expectRevert(CuratedVaultBase.NotFinalizable.selector);
        vault.finalize();
        assertEq(T.balanceOf(attacker, 0) + T.balanceOf(attacker, 1), 0);
    }

    // ------------------------------------------------------------------ R2: same netlist taped out by someone else

    function test_R2_SameNetlistElsewhereIsNotOfficial() public {
        _launch();
        uint256 official = _buy(1, buyer);
        Work memory w = _work(1);

        vm.startPrank(attacker);
        (address t2, address c2) = FACTORY.createCPU{value: FACTORY.deployFee()}("Copy", "CPY", "", 10_000, 0);
        uint256 pf = ITapeOutTransistors(t2).protocolFee();
        ITapeOutTransistors(t2).mint{value: pf}(0, 9000);
        ITapeOutTransistors(t2).mint{value: pf}(1, 1000);
        uint256 copy = ITapeOutCircuits(c2).tapeout{value: fee}(w.netlist, w.nIn, w.nOut);
        vm.stopPrank();

        assertEq(keccak256(ITapeOutCircuits(c2).netlist(copy)), keccak256(C.netlist(official)));
        assertFalse(reg.isOfficial(c2, copy), "copy on another processor");
        assertFalse(reg.isCurated(c2));
        assertTrue(reg.isOfficial(address(C), official));

        // on the curated processor the attacker holds no transistors, so the burn fails
        vm.prank(attacker);
        vm.expectPartialRevert(ERC1155_INSUFFICIENT_BALANCE);
        C.tapeout{value: fee}(w.netlist, w.nIn, w.nOut);
    }

    // ------------------------------------------------------------------ R3: zero-cost REF wrappers

    function test_R3_RefWrapperIsNotOfficial() public {
        _launch();
        uint256 official = _buy(2, buyer); // the 7-bit LFSR
        Work memory w = _work(2);

        // circuit ids here are tiny, so the uint64 REF id field cannot truncate
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory wrapper = abi.encodePacked(uint8(2), address(C), uint64(official), uint8(0), uint8(w.nOut));
        vm.prank(attacker);
        uint256 fake = C.tapeout{value: fee}(wrapper, 0, w.nOut);

        assertEq(C.ownerOf(fake), attacker);
        (uint32 a1, uint32 b1, uint32 s1, uint32 g1) = C.circuitInfo(official);
        (uint32 a2, uint32 b2, uint32 s2, uint32 g2) = C.circuitInfo(fake);
        assertEq(abi.encode(a1, b1, s1, g1), abi.encode(a2, b2, s2, g2));
        assertFalse(reg.isOfficial(address(C), fake));
        (bool off,) = reg.editionOf(address(C), fake);
        assertFalse(off);
        (, uint256 tid) = reg.tokenOf(address(C), 2);
        assertEq(tid, official);
    }

    // ------------------------------------------------------------------ R4: one tape-out per work; strict inputs

    function test_R4_EachWorkOnceAndStrictInputs() public {
        _launch();
        _buy(0, buyer);
        Work memory w = _work(0);
        uint256 v = w.price + fee;

        vm.startPrank(buyer);
        vm.expectRevert(CuratedVaultBase.AlreadyTaken.selector);
        vault.buy{value: v}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);

        Work memory x = _work(1);
        uint256 vx = x.price + fee;
        bytes memory bad = bytes.concat(x.netlist, hex"00");
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: vx}(x.index, bad, x.nIn, x.nOut, x.price, x.proof, buyer);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: fee}(x.index, x.netlist, x.nIn, x.nOut, 0, x.proof, buyer);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: vx}(x.index, x.netlist, x.nIn, x.nOut, x.price, w.proof, buyer);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: vx}(x.index, x.netlist, x.nIn, x.nOut + 1, x.price, x.proof, buyer);
        // a valid work presented under another index
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: vx}(4, x.netlist, x.nIn, x.nOut, x.price, x.proof, buyer);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, vx));
        vault.buy{value: vx + 1}(x.index, x.netlist, x.nIn, x.nOut, x.price, x.proof, buyer);
        vm.expectRevert(CuratedVaultBase.IndexOutOfRange.selector);
        vault.buy{value: vx}(count, x.netlist, x.nIn, x.nOut, x.price, x.proof, buyer);
        vm.expectRevert(CuratedVaultBase.ZeroRecipient.selector);
        vault.buy{value: vx}(x.index, x.netlist, x.nIn, x.nOut, x.price, x.proof, address(0));
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ R5: only the bound vault writes the record

    function test_R5_OnlyBoundVaultCanCertify() public {
        _launch();
        vm.prank(attacker);
        vm.expectRevert(CuratedRegistry.NotBoundVault.selector);
        reg.certify(address(C), 1, 0, bytes32(0), false);

        vm.prank(attacker);
        vm.expectRevert(CuratedRegistry.NotVault.selector);
        reg.bind(address(C), address(T), attacker, bytes32(uint256(1)), 1, attacker, 0, 0);

        CuratedVault rogue = new CuratedVault();
        vm.prank(address(rogue));
        vm.expectRevert(CuratedRegistry.NotBoundVault.selector);
        reg.certify(address(C), 1, 0, bytes32(0), false);
        vm.prank(address(rogue));
        vm.expectRevert(CuratedRegistry.NotVault.selector);
        reg.bind(address(C), address(T), attacker, bytes32(uint256(1)), 1, attacker, 0, 0);

        vm.prank(address(vault));
        vm.expectRevert(CuratedRegistry.AlreadyBound.selector);
        reg.bind(address(C), address(T), attacker, bytes32(uint256(1)), 1, attacker, 0, 0);
        uint256 id = _buy(3, buyer);
        vm.prank(address(vault));
        vm.expectRevert(CuratedRegistry.AlreadyCertified.selector);
        reg.certify(address(C), id, 4, bytes32(0), false);
        vm.prank(address(vault));
        vm.expectRevert(CuratedRegistry.AlreadyCertified.selector);
        reg.certify(address(C), id + 100, 3, bytes32(0), false);
        vm.prank(address(vault));
        vm.expectRevert(CuratedRegistry.IndexOutOfRange.selector);
        reg.certify(address(C), id + 100, count, bytes32(0), false);
    }

    // ------------------------------------------------------------------ R7: the work list cannot change

    function test_R7_WorkListIsFixed() public {
        _launch();
        assertEq(vault.ROOT(), _params().root);
        assertEq(reg.collectionOf(address(C)).root, _params().root);
        // an unlisted netlist cannot be sold even with a real proof, index and price from the list
        Work memory w = _work(3);
        bytes memory foreign = FOREIGN.netlist(FOREIGN_ID);
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: w.price + fee}(w.index, foreign, w.nIn, w.nOut, w.price, w.proof, buyer);
    }

    // ------------------------------------------------------------------ misc safety

    function test_SaleStartIsEnforced() public {
        LaunchParams memory p = _params();
        p.saleStart = uint64(block.timestamp + 1 days);
        _launchWith(p);
        Work memory w = _work(0);
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.SaleNotStarted.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
    }

    /// L-5: only circuits freshly minted to the vault by its own tapeout are accepted.
    function test_L5_RejectsStrayFundsAndTokens() public {
        _launch();
        vm.prank(attacker);
        (bool ok,) = address(vault).call{value: 1 ether}("");
        assertFalse(ok, "plain native coin");

        // a real circuit of this processor, owned by the attacker, sent to the vault
        uint256 official = _buy(2, buyer);
        // circuit ids here are tiny, so the uint64 REF id field cannot truncate
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory wrapper = abi.encodePacked(uint8(2), address(C), uint64(official), uint8(0), uint8(7));
        vm.startPrank(attacker);
        uint256 fake = C.tapeout{value: fee}(wrapper, 0, 7);
        vm.expectRevert(CuratedVaultBase.UnexpectedFunds.selector);
        C.safeTransferFrom(attacker, address(vault), fake);
        vm.stopPrank();
        assertEq(C.ownerOf(fake), attacker);
    }

    function test_ReentrancyFromRecipientFails() public {
        _launch();
        Reenter r = new Reenter(vault, this);
        Work memory w = _work(3);
        vm.deal(address(r), 1 ether);
        vm.prank(buyer);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, address(r));
        assertFalse(vault.taken(3));
    }

    // ------------------------------------------------------------------ reserved works for the treasury

    /// The public can never buy a work the list reserves for the treasury, at any price.
    function test_Reserved_PublicCannotBuy() public {
        _launch();
        Work memory w = _work(RESERVED_WORK);
        assertTrue(w.reserved);
        vm.startPrank(buyer);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, 0, w.proof, buyer);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.buy{value: 1 ether + fee}(w.index, w.netlist, w.nIn, w.nOut, 1 ether, w.proof, buyer);
        vm.stopPrank();
    }

    /// Only the curator can claim, the work always goes to the fixed treasury, and it is official and marked
    /// reserved. Claiming works before the public sale opens.
    function test_Reserved_CuratorClaimsToTreasury() public {
        LaunchParams memory p = _params();
        p.saleStart = uint64(block.timestamp + 7 days);
        _launchWith(p);
        Work memory w = _work(RESERVED_WORK);

        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault.claimReserved{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.proof);

        uint256 owedBefore = PAYEE.balance;
        uint256 id = _claim(RESERVED_WORK);
        assertEq(C.ownerOf(id), p.treasury);
        assertTrue(reg.isOfficial(address(C), id));
        assertTrue(reg.isReserved(address(C), id));
        (bool off, uint256 idx) = reg.editionOf(address(C), id);
        assertTrue(off);
        assertEq(idx, RESERVED_WORK);
        assertEq(PAYEE.balance, owedBefore, "a reserved work earns nothing");

        ICuratedRegistry.Collection memory col = reg.collectionOf(address(C));
        assertEq(col.treasury, p.treasury);
        assertEq(col.reserved, p.reservedCount);

        // cannot be claimed twice
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.AlreadyTaken.selector);
        vault.claimReserved{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.proof);
    }

    // ------------------------------------------------------------------ per-wallet limit

    function _buyAs(address payer, uint256 i, address to) internal returns (uint256 id) {
        Work memory w = _work(i);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        id = vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, to);
    }

    function _expectBuyRevert(address payer, uint256 i, address to, address limited) internal {
        Work memory w = _work(i);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WalletLimitReached.selector, limited));
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, to);
    }

    function _wallet(string memory name) internal returns (address w) {
        w = _eoa(string.concat("p05-limit-", name));
    }

    function _remaining(address w) internal view returns (uint32 r) {
        bool limited;
        (limited, r) = vault.remainingFor(w);
        assertTrue(limited);
    }

    /// Option "no limit": one wallet can buy every public work.
    function test_Limit_Unlimited() public {
        _launch();
        assertFalse(vault.LIMIT_PER_WALLET());
        assertEq(vault.MAX_PER_WALLET(), 0);
        for (uint256 i; i < count; i++) {
            if (!_work(i).reserved) _buyAs(buyer, i, buyer);
        }
        (bool limited,) = vault.remainingFor(buyer);
        assertFalse(limited);
    }

    /// Option "limit to 2": the third purchase fails; with a limit each wallet buys for itself only, so nobody can
    /// buy many works for others or push someone else to the limit by "gifting" works.
    function test_Limit_CapsEachWallet() public {
        LaunchParams memory p = _params();
        p.limitPerWallet = true;
        p.maxPerWallet = 2;
        _launchWith(p);
        address alice = _wallet("alice");
        address bob = _wallet("bob");

        _buyAs(alice, 0, alice);
        assertEq(_remaining(alice), 1);
        _buyAs(alice, 1, alice);
        assertEq(_remaining(alice), 0);
        _expectBuyRevert(alice, 2, alice, alice);

        // buying for someone else is refused while a limit applies, in both directions
        Work memory w = _work(2);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(CuratedVaultBase.RecipientMustBeBuyer.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, bob);
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        vm.expectRevert(CuratedVaultBase.RecipientMustBeBuyer.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, alice);
        assertEq(_remaining(bob), 2, "a refused purchase counts for nobody");

        // bob buys for himself
        _buyAs(bob, 2, bob);
        assertEq(_remaining(bob), 1);

        // a full wallet can still receive and send circuits on the market; the limit is on minting only
        (, uint256 bobs) = reg.tokenOf(address(C), 2);
        vm.prank(bob);
        C.safeTransferFrom(bob, alice, bobs);
        assertEq(C.ownerOf(bobs), alice);

        // reserved claims for the treasury are not limited
        _claim(RESERVED_WORK);
    }

    /// The two settings must agree, and the chosen limit is fixed at launch and readable on chain.
    function test_Limit_ParamsChecked() public {
        LaunchParams memory p = _params();
        p.limitPerWallet = true;
        p.maxPerWallet = 0; // limit switched on without a number
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("maxPerWallet")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.limitPerWallet = false;
        p.maxPerWallet = 3; // a number without switching the limit on
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("maxPerWallet")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.limitPerWallet = true;
        p.maxPerWallet = 3;
        _launchWith(p);
        assertTrue(vault.LIMIT_PER_WALLET());
        assertEq(vault.MAX_PER_WALLET(), 3);
        assertEq(_remaining(_wallet("nobody")), 3);
    }

    // ------------------------------------------------------------------ presale (allowlist)

    struct Allow {
        address wallet;
        uint32 quota;
        uint32 tier;
        bytes32[] proof;
    }

    function _allow(uint256 k) internal view returns (Allow memory a) {
        string memory key = string.concat(".allowlist[", vm.toString(k), "]");
        a.wallet = vm.parseJsonAddress(manifest, string.concat(key, ".address"));
        a.quota = uint32(vm.parseJsonUint(manifest, string.concat(key, ".quota")));
        a.tier = uint32(vm.parseJsonUint(manifest, string.concat(key, ".tier")));
        a.proof = vm.parseJsonBytes32Array(manifest, string.concat(key, ".proof"));
    }

    // ------------------------------------------------------------------ presale price list (rebuilt here, independently
    // of the tool: every (tier, index, price) leaf from the manifest's table, a sorted-pair tree as OpenZeppelin verifies)

    function _tierCount() internal view returns (uint256 n) {
        while (vm.keyExistsJson(manifest, string.concat(".presaleTiers[", vm.toString(n), "]"))) n++;
    }

    function _tierPrice(uint256 t, uint256 i) internal view returns (uint256) {
        return vm.parseJsonUint(manifest, string.concat(".presaleTiers[", vm.toString(t), "].prices[", vm.toString(i), "]"));
    }

    function _presaleLeaves() internal view returns (bytes32[] memory leaves) {
        uint256 nt = _tierCount();
        uint256 open;
        for (uint256 i; i < count; i++) if (!_work(i).reserved) open++;
        leaves = new bytes32[](nt * open);
        uint256 k;
        for (uint256 t; t < nt; t++) {
            for (uint256 i; i < count; i++) {
                if (_work(i).reserved) continue;
                // forge-lint: disable-next-line(unsafe-typecast)
                leaves[k++] = vault.presalePriceLeafOf(i, uint32(t), _tierPrice(t, i));
            }
        }
    }

    function _sortedTree(bytes32[] memory leaves) internal pure returns (bytes32[][] memory layers) {
        for (uint256 a = 1; a < leaves.length; a++) {
            for (uint256 b = a; b > 0 && leaves[b - 1] > leaves[b]; b--) {
                (leaves[b - 1], leaves[b]) = (leaves[b], leaves[b - 1]);
            }
        }
        uint256 depth = 1;
        for (uint256 n = leaves.length; n > 1; n = (n + 1) / 2) depth++;
        layers = new bytes32[][](depth);
        layers[0] = leaves;
        for (uint256 d = 1; d < depth; d++) {
            bytes32[] memory cur = layers[d - 1];
            bytes32[] memory nxt = new bytes32[]((cur.length + 1) / 2);
            for (uint256 j; j < cur.length; j += 2) {
                if (j + 1 == cur.length) nxt[j / 2] = cur[j];
                else nxt[j / 2] = cur[j] < cur[j + 1]
                    ? keccak256(abi.encode(cur[j], cur[j + 1])) : keccak256(abi.encode(cur[j + 1], cur[j]));
            }
            layers[d] = nxt;
        }
    }

    /// The presale price of work `i` for `tier`, and its proof (none when the vault has no presale price list).
    function _pp(uint256 i, uint32 tier) internal view returns (uint256 price, bytes32[] memory proof) {
        if (vault.PRESALE_PRICE_ROOT() == bytes32(0)) return (_work(i).price, new bytes32[](0));
        price = _tierPrice(tier, i);
        bytes32 leaf = vault.presalePriceLeafOf(i, tier, price);
        bytes32[][] memory layers = _sortedTree(_presaleLeaves());
        uint256 pos;
        while (layers[0][pos] != leaf) pos++;
        bytes32[] memory tmp = new bytes32[](layers.length);
        uint256 n;
        for (uint256 d; d + 1 < layers.length; d++) {
            uint256 sib = pos ^ 1;
            if (sib < layers[d].length) tmp[n++] = layers[d][sib];
            pos /= 2;
        }
        proof = new bytes32[](n);
        for (uint256 j; j < n; j++) proof[j] = tmp[j];
        assertEq(layers[layers.length - 1][0], vault.PRESALE_PRICE_ROOT(), "presale price root rebuilt");
    }

    /// presale open now, public sale in one day
    function _launchPresale() internal returns (LaunchParams memory p) {
        p = _params();
        p.presaleStart = uint64(block.timestamp);
        p.saleStart = uint64(block.timestamp + 1 days);
        _launchWith(p);
    }

    function _presaleBuy(Allow memory a, address payer, uint256 i, uint32 quota) internal returns (uint256 id) {
        Work memory w = _work(i);
        (uint256 pp, bytes32[] memory pproof) = _pp(i, a.tier);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        id = vault.buyPresale{value: pp + fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, payer, quota, a.tier, a.proof, pp, pproof
        );
    }

    function _presaleExpect(Allow memory a, address payer, uint256 i, uint32 quota, bytes memory err) internal {
        Work memory w = _work(i);
        (uint256 pp, bytes32[] memory pproof) = _pp(i, a.tier);
        vm.deal(payer, 10 ether);
        vm.prank(payer);
        vm.expectRevert(err);
        vault.buyPresale{value: pp + fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, payer, quota, a.tier, a.proof, pp, pproof
        );
    }

    event Purchased(uint256 indexed index, uint256 indexed tokenId, address indexed recipient, uint256 price);

    /// Each allowlist tier pays its own presale price, fixed at launch; the payout and the event use what was paid.
    function test_PresalePrice_TiersPayTheirPrice() public {
        _launchPresale();
        Allow memory alice = _allow(0); // tier 0 (OG)
        Allow memory bob = _allow(1); // tier 1 (Friends: everything free in the presale)
        assertEq(alice.tier, 0);
        assertEq(bob.tier, 1);
        (uint256 pa,) = _pp(0, 0);
        assertEq(pa, _work(0).price / 2, "OG pays half for work 0");
        uint256 owedBefore = PAYEE.balance;
        uint256 plat0 = vault.PLATFORM().balance;
        vm.expectEmit(true, false, true, true, address(vault));
        emit Purchased(0, 0, alice.wallet, pa);
        uint256 id = _presaleBuy(alice, alice.wallet, 0, alice.quota);
        assertEq(C.ownerOf(id), alice.wallet);
        uint256 cut = (pa * vault.PLATFORM_BPS()) / 10_000;
        assertEq(PAYEE.balance - owedBefore, pa - cut, "the payee is paid the presale price");
        // a free presale price: the buyer pays only the tape-out fee
        (uint256 pb,) = _pp(1, 1);
        assertEq(pb, 0);
        vm.deal(bob.wallet, 10 ether);
        uint256 bal = bob.wallet.balance;
        Work memory w = _work(1);
        (, bytes32[] memory pproof) = _pp(1, 1);
        vm.prank(bob.wallet);
        vault.buyPresale{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, bob.wallet, bob.quota, 1, bob.proof, 0, pproof);
        assertEq(bal - bob.wallet.balance, fee);
        assertEq(vault.PLATFORM().balance - plat0, cut, "the platform's share is of the presale price");
        // after the presale, buyPresale is closed and buy charges the work-list price
        vm.warp(vault.SALE_START());
        Work memory w2 = _work(2);
        (, bytes32[] memory p2) = _pp(2, 1);
        vm.prank(bob.wallet);
        vm.expectRevert(CuratedVaultBase.PresaleNotOpen.selector);
        vault.buyPresale{value: fee}(w2.index, w2.netlist, w2.nIn, w2.nOut, w2.price, w2.proof, bob.wallet, bob.quota, 1, bob.proof, 0, p2);
        vm.prank(bob.wallet);
        vault.buy{value: w2.price + fee}(w2.index, w2.netlist, w2.nIn, w2.nOut, w2.price, w2.proof, bob.wallet);
        assertEq(PAYEE.balance - owedBefore, pa - cut + w2.price - (w2.price * vault.PLATFORM_BPS()) / 10_000);
    }

    /// A price leaf only fits its own work, and the buyer pays exactly the presale price: no more, no less.
    function test_PresalePrice_ExactAmountForTheRightWork() public {
        _launchPresale();
        Allow memory alice = _allow(0);
        Work memory w0 = _work(0);
        (uint256 p3, bytes32[] memory proof3) = _pp(3, 0); // work 3 (free) for tier 0
        assertEq(p3, 0);
        vm.deal(alice.wallet, 10 ether);
        // work 3's free price leaf presented for work 0
        vm.prank(alice.wallet);
        vm.expectRevert(CuratedVaultBase.InvalidPresalePrice.selector);
        vault.buyPresale{value: fee}(
            w0.index, w0.netlist, w0.nIn, w0.nOut, w0.price, w0.proof, alice.wallet, alice.quota, 0, alice.proof, p3, proof3
        );
        // paying the public price when the presale price is lower is refused, not kept
        (uint256 pa, bytes32[] memory pproof) = _pp(0, 0);
        vm.prank(alice.wallet);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, pa + fee));
        vault.buyPresale{value: w0.price + fee}(
            w0.index, w0.netlist, w0.nIn, w0.nOut, w0.price, w0.proof, alice.wallet, alice.quota, 0, alice.proof, pa, pproof
        );
    }

    /// In a token collection a free presale price needs no approval and moves no tokens.
    function test_PresalePrice_FreeInTokenCollection() public {
        MockToken tok = new MockToken();
        LaunchParams memory p = _params();
        p.paymentToken = address(tok);
        p.presaleStart = uint64(block.timestamp);
        p.saleStart = uint64(block.timestamp + 1 days);
        _launchWith(p);
        Allow memory bob = _allow(1);
        Work memory w = _work(0);
        (uint256 pb, bytes32[] memory pproof) = _pp(0, 1);
        assertEq(pb, 0);
        vm.deal(bob.wallet, 1 ether);
        vm.prank(bob.wallet);
        uint256 id = vault.buyPresale{value: fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, bob.wallet, bob.quota, 1, bob.proof, 0, pproof
        );
        assertEq(C.ownerOf(id), bob.wallet);
        assertEq(tok.balanceOf(address(vault)), 0);
        assertEq(tok.balanceOf(PAYEE), 0);
    }

    /// A wallet cannot use another tier's price or another tier, nor a price that is not in the list.
    function test_PresalePrice_OnlyTheListedPriceForTheTier() public {
        _launchPresale();
        Allow memory alice = _allow(0);
        Work memory w = _work(0);
        (uint256 friends, bytes32[] memory friendsProof) = _pp(0, 1); // tier 1's (free) price for work 0
        vm.deal(alice.wallet, 10 ether);
        // alice (tier 0) presents tier 1's price: the price leaf is for tier 1, so it does not verify for tier 0
        vm.prank(alice.wallet);
        vm.expectRevert(CuratedVaultBase.InvalidPresalePrice.selector);
        vault.buyPresale{value: friends + fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, alice.wallet, alice.quota, 0, alice.proof, friends, friendsProof
        );
        // alice claims tier 1: her allowlist leaf says tier 0
        vm.prank(alice.wallet);
        vm.expectRevert(CuratedVaultBase.NotAllowlisted.selector);
        vault.buyPresale{value: friends + fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, alice.wallet, alice.quota, 1, alice.proof, friends, friendsProof
        );
        // an unlisted lower price
        (uint256 pa, bytes32[] memory pproof) = _pp(0, 0);
        vm.prank(alice.wallet);
        vm.expectRevert(CuratedVaultBase.InvalidPresalePrice.selector);
        vault.buyPresale{value: pa - 1 + fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, alice.wallet, alice.quota, 0, alice.proof, pa - 1, pproof
        );
        assertEq(vault.presaleBought(alice.wallet), 0);
    }

    /// Even a listed presale price above the public price is refused on chain.
    function test_PresalePrice_NeverAbovePublicPrice() public {
        LaunchParams memory p = _params();
        p.presaleStart = uint64(block.timestamp);
        p.saleStart = uint64(block.timestamp + 1 days);
        Work memory w = _work(0);
        uint256 high = w.price + 1;
        // a one-leaf list (the root is the leaf) that prices work 0 above its public price for tier 0
        p.presalePriceRoot = keccak256(bytes.concat(keccak256(abi.encode(
            block.chainid, REG, curator, keccak256("TAP-curated-presale-price"), p.root, uint256(0), uint32(0), high
        ))));
        _launchWith(p);
        Allow memory alice = _allow(0);
        vm.deal(alice.wallet, 10 ether);
        vm.prank(alice.wallet);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.PresaleAbovePrice.selector, high, w.price));
        vault.buyPresale{value: high + fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, alice.wallet, alice.quota, 0, alice.proof, high,
            new bytes32[](0)
        );
    }

    /// Without a presale price list the presale sells at the work-list price; a price list needs an allowlist.
    function test_PresalePrice_NoListMeansListPrice() public {
        LaunchParams memory p = _params();
        p.presaleStart = uint64(block.timestamp);
        p.saleStart = uint64(block.timestamp + 1 days);
        p.presalePriceRoot = bytes32(0);
        _launchWith(p);
        assertEq(vault.PRESALE_PRICE_ROOT(), bytes32(0));
        Allow memory alice = _allow(0);
        Work memory w = _work(0);
        vm.deal(alice.wallet, 10 ether);
        vm.prank(alice.wallet);
        vm.expectRevert(CuratedVaultBase.InvalidPresalePrice.selector);
        vault.buyPresale{value: w.price / 2 + fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, alice.wallet, alice.quota, 0, alice.proof, w.price / 2,
            new bytes32[](0)
        );
        uint256 id = _presaleBuy(alice, alice.wallet, 0, alice.quota); // _pp gives the list price
        assertEq(C.ownerOf(id), alice.wallet);

        p = _params();
        p.allowRoot = bytes32(0);
        p.presaleStart = 0;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("presalePriceRoot")));
        reg.launch{value: launchValue}(p);
    }

    /// An allowlisted wallet buys up to its quota during the presale, then no more.
    function test_Presale_AllowlistedWithinQuota() public {
        _launchPresale();
        Allow memory alice = _allow(0); // quota 2
        assertEq(alice.wallet.code.length, 0);
        assertEq(alice.quota, 2);
        uint256 id = _presaleBuy(alice, alice.wallet, 0, alice.quota);
        assertEq(C.ownerOf(id), alice.wallet);
        assertTrue(reg.isOfficial(address(C), id));
        _presaleBuy(alice, alice.wallet, 1, alice.quota);
        assertEq(vault.presaleBought(alice.wallet), 2);
        _presaleExpect(alice, alice.wallet, 2, alice.quota, abi.encodeWithSelector(CuratedVaultBase.PresaleQuotaUsed.selector));
    }

    /// Strangers cannot use the presale, nobody can claim a bigger quota, and the public sale is still closed.
    function test_Presale_OnlyAllowlisted() public {
        _launchPresale();
        Allow memory alice = _allow(0);
        // a stranger presents alice's proof
        _presaleExpect(alice, buyer, 0, alice.quota, abi.encodeWithSelector(CuratedVaultBase.NotAllowlisted.selector));
        // alice claims a bigger quota than the list gives her
        _presaleExpect(alice, alice.wallet, 0, 5, abi.encodeWithSelector(CuratedVaultBase.NotAllowlisted.selector));
        // the public sale has not opened
        Work memory w = _work(0);
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.SaleNotStarted.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
    }

    /// The presale runs from presaleStart until the public sale opens; then everyone buys with buy().
    function test_Presale_Window() public {
        LaunchParams memory p = _params();
        p.presaleStart = uint64(block.timestamp + 1 hours);
        p.saleStart = uint64(block.timestamp + 1 days);
        _launchWith(p);
        Allow memory bob = _allow(1);
        _presaleExpect(bob, bob.wallet, 0, bob.quota, abi.encodeWithSelector(CuratedVaultBase.PresaleNotOpen.selector));
        vm.warp(p.presaleStart);
        _presaleBuy(bob, bob.wallet, 0, bob.quota);
        vm.warp(p.saleStart);
        _presaleExpect(bob, bob.wallet, 1, bob.quota, abi.encodeWithSelector(CuratedVaultBase.PresaleNotOpen.selector));
        _buyAs(buyer, 1, buyer); // public sale for everyone
        _buyAs(bob.wallet, 2, bob.wallet); // allowlisted wallets too, beyond their presale quota
    }

    /// The per-wallet limit applies on top of the presale quota.
    function test_Presale_RespectsWalletLimit() public {
        LaunchParams memory p = _params();
        p.presaleStart = uint64(block.timestamp);
        p.saleStart = uint64(block.timestamp + 1 days);
        p.limitPerWallet = true;
        p.maxPerWallet = 1;
        _launchWith(p);
        Allow memory alice = _allow(0); // presale quota 2, but wallet limit 1
        _presaleBuy(alice, alice.wallet, 0, alice.quota);
        _presaleExpect(
            alice, alice.wallet, 1, alice.quota,
            abi.encodeWithSelector(CuratedVaultBase.WalletLimitReached.selector, alice.wallet)
        );
    }

    /// Without a presale, buyPresale is closed; presale settings must be consistent.
    function test_Presale_ParamsChecked() public {
        LaunchParams memory p = _params();
        p.allowRoot = bytes32(0);
        p.presalePriceRoot = bytes32(0);
        p.presaleStart = 0;
        _launchWith(p);
        Allow memory alice = _allow(0);
        _presaleExpect(alice, alice.wallet, 0, alice.quota, abi.encodeWithSelector(CuratedVaultBase.NoPresale.selector));

        p = _params();
        p.presaleStart = p.saleStart; // the presale must start before the public sale
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("presale")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.presaleStart = 0; // an allowlist without a presale time
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("presale")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.allowRoot = bytes32(0);
        p.presalePriceRoot = bytes32(0);
        p.presaleStart = 1; // a presale time without an allowlist
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("presale")));
        reg.launch{value: launchValue}(p);
    }

    // ------------------------------------------------------------------ royalty declaration (optional, advisory)

    /// Official works report the declared royalty; REF wrappers and other foreign circuits report none.
    function test_Royalty_OfficialOnly() public {
        _launch();
        LaunchParams memory p = _params();
        (address r0, uint16 b0) = reg.royaltyOf(address(C));
        assertEq(r0, p.royaltyReceiver);
        assertEq(b0, 300);
        uint256 official = _buy(2, buyer);
        (address r, uint256 amt) = reg.royaltyInfo(address(C), official, 1 ether);
        assertEq(r, p.royaltyReceiver);
        assertEq(amt, 0.03 ether);

        // circuit ids here are tiny, so the uint64 REF id field cannot truncate
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory wrapper = abi.encodePacked(uint8(2), address(C), uint64(official), uint8(0), uint8(7));
        vm.prank(attacker);
        uint256 fake = C.tapeout{value: fee}(wrapper, 0, 7);
        (address rf, uint256 af) = reg.royaltyInfo(address(C), fake, 1 ether);
        assertEq(rf, address(0));
        assertEq(af, 0);
    }

    /// A collection may declare no royalty at all.
    function test_Royalty_None() public {
        LaunchParams memory p = _params();
        p.royaltyReceiver = address(0);
        p.royaltyBps = 0;
        _launchWith(p);
        uint256 id = _buy(0, buyer);
        (address r, uint256 amt) = reg.royaltyInfo(address(C), id, 1 ether);
        assertEq(r, address(0));
        assertEq(amt, 0);
        // and none can be added later, because the rate can never rise
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.RoyaltyCannotRise.selector);
        reg.setRoyalty(address(C), curator, 100);
    }

    /// The curator can change the receiver or lower the rate, never raise it; nobody else can touch it.
    function test_Royalty_CuratorCanOnlyLower() public {
        _launch();
        address newReceiver = _eoa("p05-royalty-new");
        vm.prank(attacker);
        vm.expectRevert(CuratedRegistry.OnlyCurator.selector);
        reg.setRoyalty(address(C), attacker, 100);

        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.RoyaltyCannotRise.selector);
        reg.setRoyalty(address(C), newReceiver, 301);

        vm.expectEmit(true, true, true, true, address(reg));
        emit ICuratedRegistry.RoyaltySet(address(C), newReceiver, 250);
        vm.prank(curator);
        reg.setRoyalty(address(C), newReceiver, 250);
        (address r, uint16 b) = reg.royaltyOf(address(C));
        assertEq(r, newReceiver);
        assertEq(b, 250);

        // the vault cannot re-declare, and a declared royalty cannot point at nobody
        vm.prank(address(vault));
        vm.expectRevert(CuratedRegistry.AlreadyBound.selector);
        reg.declareRoyalty(address(C), attacker, 1000);
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.BadRoyalty.selector);
        reg.setRoyalty(address(C), address(0), 100);
    }

    /// Launch refuses a rate above 5 % or a receiver without a rate (and the reverse); exactly 5 % is accepted.
    function test_Royalty_ParamsChecked() public {
        LaunchParams memory p = _params();
        p.royaltyBps = 501;
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.BadRoyalty.selector);
        reg.launch{value: launchValue}(p);
        assertEq(reg.MAX_ROYALTY_BPS(), 500);

        p = _params();
        p.royaltyBps = 0; // receiver set, no rate
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.BadRoyalty.selector);
        reg.launch{value: launchValue}(p);

        p = _params();
        p.royaltyReceiver = address(0); // rate set, no receiver
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.BadRoyalty.selector);
        reg.launch{value: launchValue}(p);

        p = _params();
        p.royaltyBps = 500; // the cap itself is allowed
        _launchWith(p);
        (, uint16 bps) = reg.royaltyOf(address(C));
        assertEq(bps, 500);
    }

    /// A reserved work is an ordinary circuit NFT once it is in the treasury: the treasury can give it away or
    /// airdrop it, and it stays official (and marked as reserved) whoever holds it.
    function test_Reserved_TreasuryCanTransferAndItStaysOfficial() public {
        _launch();
        uint256 id = _claim(RESERVED_WORK);
        address treasury = _params().treasury;
        address fan = _eoa("fan");
        address fan2 = _eoa("fan2");
        vm.prank(treasury);
        C.safeTransferFrom(treasury, fan, id); // gift / airdrop
        assertEq(C.ownerOf(id), fan);
        vm.prank(fan);
        C.safeTransferFrom(fan, fan2, id); // and it trades on like any other circuit
        assertEq(C.ownerOf(id), fan2);
        assertTrue(reg.isOfficial(address(C), id));
        assertTrue(reg.isReserved(address(C), id));
        (, uint256 idx) = reg.editionOf(address(C), id);
        assertEq(idx, RESERVED_WORK);
    }

    /// The curator cannot pull a public work into the treasury.
    function test_Reserved_CannotClaimPublicWork() public {
        _launch();
        Work memory w = _work(1);
        assertFalse(w.reserved);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.claimReserved{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.proof);
    }

    /// The reserved count declared at launch caps claims: here the list marks a reserved work but the launch declares
    /// none, so the work cannot be claimed. (A list hiding extra reserved leaves is caught off chain by checkroot.)
    function test_Reserved_DeclaredCountIsACap() public {
        LaunchParams memory p = _params();
        p.reservedCount = 0; // declares no reserved works although the list marks two
        _launchWith(p);
        Work memory w = _work(RESERVED_WORK);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.ReservedQuotaUsed.selector);
        vault.claimReserved{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.proof);
        assertEq(reg.collectionOf(address(C)).reserved, 0);
    }

    /// Reserved works need a treasury, which can be neither the registry nor the vault.
    function test_Reserved_Params() public {
        LaunchParams memory p = _params();
        p.treasury = address(0);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("treasury")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.treasury = REG; // the registry (or the vault itself) can never receive reserved works
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("treasury")));
        reg.launch{value: launchValue}(p);

        p = _params();
        p.reservedCount = p.count + 1;
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("reservedCount")));
        reg.launch{value: launchValue}(p);
    }

    /// A forgotten reserved work is not lost when the sale ends: the curator can still claim it, and finalize
    /// waits until every reserved work is claimed or RESERVE_GRACE has passed. After finalize nothing can be claimed.
    function test_Reserved_ClaimAfterSaleEndWithinGrace() public {
        _launch();
        uint64 end = vault.SALE_END();
        vm.warp(end);
        assertFalse(vault.finalizable());
        vm.expectRevert(CuratedVaultBase.NotFinalizable.selector);
        vault.finalize();

        uint256 id = _claim(RESERVED_WORK); // after the sale has ended
        assertEq(C.ownerOf(id), _params().treasury);
        assertTrue(reg.isOfficial(address(C), id));
        vm.expectRevert(CuratedVaultBase.NotFinalizable.selector);
        vault.finalize(); // one reserved work is still unclaimed

        vm.warp(uint256(end) + vault.RESERVE_GRACE() - 1);
        vm.expectRevert(CuratedVaultBase.NotFinalizable.selector);
        vault.finalize();
        vm.warp(uint256(end) + vault.RESERVE_GRACE());
        vm.prank(attacker); // anyone may finalize once the grace period is over
        vault.finalize();

        Work memory w = _work(RESERVED_WORK2);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.AlreadyFinalized.selector);
        vault.claimReserved{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.proof);
    }

    /// Once every reserved work is claimed, finalize no longer waits for the grace period.
    function test_Reserved_AllClaimedFinalizeAtSaleEnd() public {
        _launch();
        _claim(RESERVED_WORK);
        _claim(RESERVED_WORK2);
        vm.warp(vault.SALE_END());
        assertTrue(vault.finalizable());
        vault.finalize();
    }

    function _batch(uint256[] memory idx) internal view returns (CuratedVault.ReservedWork[] memory b) {
        b = new CuratedVault.ReservedWork[](idx.length);
        for (uint256 i; i < idx.length; i++) {
            Work memory w = _work(idx[i]);
            b[i] = CuratedVault.ReservedWork(w.index, w.netlist, w.nIn, w.nOut, w.proof);
        }
    }

    /// Several reserved works in one transaction: curator only, exact fee per work, all or nothing.
    function test_Reserved_BatchClaim() public {
        _launch();
        uint256[] memory both = new uint256[](2);
        both[0] = RESERVED_WORK;
        both[1] = RESERVED_WORK2;
        CuratedVault.ReservedWork[] memory b = _batch(both);

        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault.claimReservedBatch{value: 2 * fee}(b);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, 2 * fee));
        vault.claimReservedBatch{value: fee}(b);

        // a public work in the batch makes the whole batch fail
        uint256[] memory mixed = new uint256[](2);
        mixed[0] = RESERVED_WORK;
        mixed[1] = 1;
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.InvalidProof.selector);
        vault.claimReservedBatch{value: 2 * fee}(_batch(mixed));
        assertEq(vault.reservedClaimed(), 0);

        vm.prank(curator); // an empty batch is a harmless no-op
        assertEq(vault.claimReservedBatch(new CuratedVault.ReservedWork[](0)).length, 0);
        assertEq(vault.reservedClaimed(), 0);

        vm.prank(curator);
        uint256[] memory ids = vault.claimReservedBatch{value: 2 * fee}(b);
        assertEq(ids.length, 2);
        for (uint256 i; i < 2; i++) {
            assertEq(C.ownerOf(ids[i]), _params().treasury);
            assertTrue(reg.isReserved(address(C), ids[i]));
            (bool off, uint256 idx) = reg.editionOf(address(C), ids[i]);
            assertTrue(off);
            assertEq(idx, both[i]);
        }
        assertEq(vault.reservedClaimed(), 2);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.AlreadyTaken.selector);
        vault.claimReservedBatch{value: fee}(_batch(_one(RESERVED_WORK)));
    }

    function _one(uint256 i) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = i;
    }

    // ------------------------------------------------------------------ metadata commitment

    /// The registry records a commitment to the name, symbol, story and every title; the tool computes the same
    /// value (including a non-ASCII title), and the story the processor is created with is part of it.
    function test_Metadata_Committed() public {
        LaunchParams memory p = _params();
        _launch();
        bytes32 m = reg.collectionOf(address(C)).metadata;
        assertEq(m, vm.parseJsonBytes32(manifest, ".launch.metadataHash"));
        assertEq(m, reg.metadataOf(p.name, p.symbol, p.story, p.titlesHash));
        assertTrue(reg.metadataOf(p.name, p.symbol, "another story", p.titlesHash) != m);

        p.titlesHash = bytes32(0);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("titlesHash")));
        reg.launch{value: launchValue}(p);
    }

    // ------------------------------------------------------------------ sale controls

    function test_Sale_CuratorCanPauseAndResume() public {
        _launch();
        Work memory w = _work(0);
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault.setPaused(true);

        vm.prank(curator);
        vm.expectEmit(address(vault));
        emit CuratedVaultBase.SalePaused(true);
        vault.setPaused(true);
        assertTrue(vault.paused());
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.SaleIsPaused.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);

        // reserved claims are not affected by a pause
        uint256 r = _claim(6);
        assertTrue(reg.isReserved(address(C), r));

        vm.prank(curator);
        vault.setPaused(false);
        uint256 id = _buy(0, buyer);
        assertEq(C.ownerOf(id), buyer);
    }

    function test_Sale_PauseAlsoStopsPresale() public {
        _launchPresale();
        vm.prank(curator);
        vault.setPaused(true);
        Allow memory a = _allow(0);
        _presaleExpect(a, a.wallet, 0, a.quota, abi.encodeWithSelector(CuratedVaultBase.SaleIsPaused.selector));
        vm.prank(curator);
        vault.setPaused(false);
        uint256 id = _presaleBuy(a, a.wallet, 0, a.quota);
        assertEq(C.ownerOf(id), a.wallet);
    }

    function test_Sale_ExtendOnlyLaterWhileOpen() public {
        _launch();
        uint64 end = vault.SALE_END();
        vm.prank(attacker);
        vm.expectRevert(CuratedVaultBase.OnlyCurator.selector);
        vault.extendSale(end + 1 days);

        vm.startPrank(curator);
        vm.expectRevert(CuratedVaultBase.CannotExtend.selector);
        vault.extendSale(end); // not later
        vm.expectRevert(CuratedVaultBase.CannotExtend.selector);
        vault.extendSale(end - 1); // earlier
        vm.expectEmit(address(vault));
        emit CuratedVaultBase.SaleEndExtended(end, end + 30 days);
        vault.extendSale(end + 30 days);
        vm.stopPrank();
        assertEq(vault.SALE_END(), end + 30 days);
        assertEq(vault.SALE_END(), end + 30 days);

        // buying works past the old end, finalize waits for the new one
        vm.warp(end + 1);
        uint256 id = _buy(0, buyer);
        assertEq(C.ownerOf(id), buyer);
        assertFalse(vault.finalizable());

        // once the (new) end has passed, the sale cannot be reopened
        vm.warp(uint256(end) + 30 days);
        vm.prank(curator);
        vm.expectRevert(CuratedVaultBase.CannotExtend.selector);
        vault.extendSale(end + 60 days);
        Work memory w = _work(1);
        vm.prank(buyer);
        vm.expectRevert(CuratedVaultBase.SaleEnded.selector);
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
    }

    function test_Sale_NoControlsAfterFinalize() public {
        _launch();
        vm.warp(uint256(vault.SALE_END()) + vault.RESERVE_GRACE());
        vault.finalize();
        vm.startPrank(curator);
        vm.expectRevert(CuratedVaultBase.AlreadyFinalized.selector);
        vault.setPaused(true);
        vm.expectRevert(CuratedVaultBase.CannotExtend.selector);
        vault.extendSale(type(uint64).max);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ metadata (images)

    function test_Metadata_TokenURIOfficialOnly() public {
        string memory base = vm.parseJsonString(manifest, ".launch.metadataURI");
        _launch();
        assertEq(reg.metadataURIOf(address(C)), base);
        uint256 a = _buy(2, buyer);
        uint256 b = _buy(0, buyer);
        uint256 r = _claim(6);
        assertEq(reg.tokenURI(address(C), a), string.concat(base, "/2.json"));
        assertEq(reg.tokenURI(address(C), b), string.concat(base, "/0.json"));
        assertEq(reg.tokenURI(address(C), r), string.concat(base, "/6.json"));

        // a REF wrapper of an official work, and a circuit that does not exist, get nothing
        Work memory w = _work(2);
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes memory wrapper = abi.encodePacked(uint8(2), address(C), uint64(a), uint8(0), uint8(w.nOut));
        vm.prank(attacker);
        uint256 fake = C.tapeout{value: fee}(wrapper, 0, w.nOut);
        assertEq(reg.tokenURI(address(C), fake), "");
        assertEq(reg.tokenURI(address(C), 999), "");
        assertEq(reg.tokenURI(address(0xBEEF), a), "");

        // the vault answers for its processor (what TapeOut's tokenURI could ask the creator), and for nothing else
        assertEq(vault.circuitURI(address(C), a), string.concat(base, "/2.json"));
        assertEq(vault.circuitURI(address(C), fake), "");
        assertEq(vault.circuitURI(address(0xBEEF), a), "");
        assertTrue(vault.supportsInterface(type(ICircuitURIProvider).interfaceId));
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertFalse(vault.supportsInterface(0xffffffff));
        assertEq(T.creator(), address(vault));
    }

    function test_Metadata_FixedAtLaunch() public {
        _launch();
        // nobody, not even the vault or the curator, can declare it again
        vm.prank(address(vault));
        vm.expectRevert(CuratedRegistry.AlreadyBound.selector);
        reg.declareMetadataURI(address(C), "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.NotBoundVault.selector);
        reg.declareMetadataURI(address(C), "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    }

    function test_Metadata_None() public {
        LaunchParams memory p = _params();
        p.metadataURI = "";
        _launchWith(p);
        uint256 a = _buy(2, buyer);
        assertEq(reg.metadataURIOf(address(C)), "");
        assertEq(reg.tokenURI(address(C), a), "");
    }

    function test_Metadata_OnlyContentAddressed() public {
        string[14] memory bad = [
            "https://example.com/meta",
            "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG/", // trailing slash / path
            "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbd", // too short for a CID
            "ipns://k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8", // mutable name
            "ipfs://my.domain.eth",
            "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", // 42 characters
            "ar://ardrive", // an ArNS name, which its owner can repoint
            "ar://AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA.",
            "IPFS://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG",
            "ar://myundername_mycollectionname-permaweb123456", // 43 lower-case characters: could be an ArNS undername
            "ipfs://k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8", // an IPNS key written as a CID
            "ipfs://bafzaajaiaejcaxykhmgsz2mhscluhm6bkliibattya2l2lld7xayj6owtdoyalvh", // libp2p-key CIDv1 (IPNS)
            "ipfs://BAFYBEIGDYRZT5SFP7UDM7HU76UH7Y26NF3EFUYLQABF3OCLGTQY55FBZDI", // upper-case base32
            "ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbd0" // 0 is not base58
        ];
        for (uint256 i = 0; i < bad.length; i++) {
            assertFalse(reg.isContentAddressed(bytes(bad[i])), bad[i]);
            LaunchParams memory p = _params();
            p.metadataURI = bad[i];
            vm.prank(curator);
            vm.expectRevert(CuratedRegistry.BadMetadataURI.selector);
            reg.launch{value: launchValue}(p);
        }
        assertTrue(reg.isContentAddressed(bytes("")));
        assertTrue(reg.isContentAddressed(bytes("ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG")));
        assertTrue(reg.isContentAddressed(bytes("ipfs://bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi")));
        assertTrue(reg.isContentAddressed(bytes("ipfs://bafkreidivzimqfqtoqxkrpge6bjyhlvxqs3rhe73owtmdulaxr5do5in7u")));
        assertTrue(reg.isContentAddressed(bytes("ar://bNbA3TEQVL60xlgCcqdz4ZPHFZ711cZ3hmkpGttDt_U")));
    }

    function workFor(uint256 i) external view returns (Work memory) {
        return _work(i);
    }

    // ------------------------------------------------------------------ payment token (ERC-20 prices)

    function _launchToken(address token) internal {
        LaunchParams memory p = _params();
        p.paymentToken = token;
        _launchWith(p);
    }

    function _tokenBuy(MockToken tok, uint256 i, address payer) internal returns (uint256 id) {
        Work memory w = _work(i);
        tok.mint(payer, w.price);
        vm.prank(payer);
        tok.approve(address(vault), w.price);
        vm.prank(payer);
        id = vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, payer);
    }

    /// Prices are paid in the token and the tape-out fee in the native coin; payouts are in the token.
    function test_Token_BuyAndWithdraw() public {
        MockToken tok = new MockToken();
        _launchToken(address(tok));
        assertEq(vault.PAYMENT_TOKEN(), address(tok));
        Work memory w = _work(0);
        assertGt(w.price, 0);

        // the native-coin way of paying is refused: msg.value must be exactly the tape-out fee
        tok.mint(buyer, w.price);
        vm.prank(buyer);
        tok.approve(address(vault), w.price);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.WrongPayment.selector, fee));
        vault.buy{value: w.price + fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        // without an allowance the purchase reverts as a whole
        address poor = _eoa("p05-token-noallowance");
        vm.deal(poor, 1 ether);
        vm.prank(poor);
        vm.expectRevert();
        vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, poor);

        uint256 nativeBefore = buyer.balance;
        vm.prank(buyer);
        uint256 id = vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        assertEq(buyer.balance, nativeBefore - fee, "only the tape-out fee in native coin");
        assertEq(tok.balanceOf(buyer), 0);
        assertTrue(reg.isOfficial(address(C), id));
        assertEq(C.ownerOf(id), buyer);

        // paid out in the token at once
        uint256 cut = (w.price * vault.PLATFORM_BPS()) / 10_000;
        assertEq(vault.owed(vault.PLATFORM()) + vault.owed(PAYEE), 0);
        assertEq(tok.balanceOf(PAYEE), w.price - cut);
        assertEq(tok.balanceOf(vault.PLATFORM()), cut);
        assertEq(tok.balanceOf(address(vault)), 0);
        assertEq(address(vault).balance, 0, "no native coin left behind");
    }

    /// Presale and per-work prices work the same way in the token; reserved claims still cost only the native fee.
    function test_Token_PresaleAndReservedUnchanged() public {
        MockToken tok = new MockToken();
        LaunchParams memory p = _params();
        p.paymentToken = address(tok);
        p.presaleStart = uint64(block.timestamp);
        p.saleStart = uint64(block.timestamp + 1 days);
        _launchWith(p);
        Allow memory alice = _allow(0);
        Work memory w = _work(1);
        (uint256 pp, bytes32[] memory pproof) = _pp(1, alice.tier);
        assertLt(pp, w.price);
        tok.mint(alice.wallet, pp);
        vm.deal(alice.wallet, 1 ether);
        vm.prank(alice.wallet);
        tok.approve(address(vault), pp);
        vm.prank(alice.wallet);
        uint256 id = vault.buyPresale{value: fee}(
            w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, alice.wallet, alice.quota, alice.tier, alice.proof,
            pp, pproof
        );
        assertEq(C.ownerOf(id), alice.wallet);
        assertEq(tok.balanceOf(address(vault)), 0);
        assertEq(tok.balanceOf(PAYEE), pp - (pp * vault.PLATFORM_BPS()) / 10_000, "the presale price, in the token");

        Work memory r = _work(RESERVED_WORK);
        vm.prank(curator);
        uint256 rid = vault.claimReserved{value: fee}(r.index, r.netlist, r.nIn, r.nOut, r.proof);
        assertTrue(reg.isReserved(address(C), rid));
    }

    /// A token that delivers less than the amount sent (transfer tax) is refused, and nothing changes.
    function test_Token_RefusesFeeOnTransfer() public {
        FeeToken tok = new FeeToken();
        _launchToken(address(tok));
        Work memory w = _work(0);
        tok.mint(buyer, w.price);
        vm.prank(buyer);
        tok.approve(address(vault), w.price);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.TokenAmountMismatch.selector, w.price, w.price - w.price / 100));
        vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        assertFalse(vault.taken(w.index));
        assertEq(tok.balanceOf(buyer), w.price);
    }

    /// A free work in a token collection needs no allowance; an address without code is refused as payment token.
    function test_Token_FreeWorkAndParams() public {
        LaunchParams memory p = _params();
        p.paymentToken = _eoa("p05-not-a-token");
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("paymentToken")));
        reg.launch{value: launchValue}(p);

        MockToken tok = new MockToken();
        _launchToken(address(tok));
        Work memory w = _work(3); // the XOR is free
        assertEq(w.price, 0);
        vm.prank(buyer);
        uint256 id = vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, 0, w.proof, buyer);
        assertTrue(reg.isOfficial(address(C), id));
    }

    /// A token that returns nothing (USDT style) works, also for direct payouts.
    function test_Token_NoReturnToken() public {
        NoReturnToken tok = new NoReturnToken();
        _launchToken(address(tok));
        Work memory w = _work(0);
        tok.mint(buyer, w.price);
        vm.prank(buyer);
        tok.approve(address(vault), w.price);
        vm.prank(buyer);
        vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        uint256 cut = (w.price * vault.PLATFORM_BPS()) / 10_000;
        assertEq(tok.balanceOf(PAYEE), w.price - cut);
        assertEq(tok.balanceOf(vault.PLATFORM()), cut);
        assertEq(vault.owed(PAYEE), 0);
        // the registry is refused as payment token
        LaunchParams memory p = _params();
        p.paymentToken = address(reg);
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedVaultBase.BadParams.selector, bytes32("paymentToken")));
        reg.launch{value: launchValue}(p);
    }

    /// A token payout that fails (a blocked payee) is kept in `owed` and the purchase still goes through.
    function test_Token_FailedPayoutIsKept() public {
        BlockToken tok = new BlockToken();
        _launchToken(address(tok));
        tok.block_(PAYEE);
        Work memory w = _work(0);
        tok.mint(buyer, w.price);
        vm.prank(buyer);
        tok.approve(address(vault), w.price);
        vm.prank(buyer);
        uint256 id = vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        assertEq(C.ownerOf(id), buyer);
        uint256 cut = (w.price * vault.PLATFORM_BPS()) / 10_000;
        assertEq(vault.owed(PAYEE), w.price - cut);
        assertEq(tok.balanceOf(address(vault)), w.price - cut);
        address cold = _eoa("p05-token-cold");
        vm.prank(PAYEE);
        vault.withdrawTo(cold);
        assertEq(tok.balanceOf(cold), w.price - cut);
        assertEq(vault.owed(PAYEE), 0);
    }

    /// A token that calls back into the vault during a purchase or a withdrawal cannot get in.
    function test_Token_ReentrantTokenIsBlocked() public {
        HookToken tok = new HookToken();
        _launchToken(address(tok));
        Work memory w = _work(0);
        Work memory w1 = _work(1);
        tok.arm(address(vault), abi.encodeCall(
            CuratedVault.buy, (w1.index, w1.netlist, w1.nIn, w1.nOut, w1.price, w1.proof, attacker)
        ));
        tok.mint(buyer, w.price);
        vm.prank(buyer);
        tok.approve(address(vault), w.price);
        vm.prank(buyer);
        vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        assertFalse(tok.reentered(), "buy re-entered");
        assertFalse(vault.taken(w1.index));
        // the payout transfers inside the purchase cannot get in either
        tok.arm(address(vault), abi.encodeCall(CuratedVaultBase.withdraw, (PAYEE)));
        Work memory w2 = _work(2);
        tok.mint(buyer, w2.price);
        vm.prank(buyer);
        tok.approve(address(vault), w2.price);
        vm.prank(buyer);
        vault.buy{value: fee}(w2.index, w2.netlist, w2.nIn, w2.nOut, w2.price, w2.proof, buyer);
        assertFalse(tok.reentered(), "withdraw re-entered");
    }

    /// Vaults are clones of three fixed implementations; nobody can initialise an implementation, a launched vault
    /// again, or a clone of their own into this registry.
    function test_Clones_FixedImplementations() public {
        assertEq(reg.INSTANT_IMPL(), IMPL0);
        assertEq(reg.REVEAL_IMPL(), IMPL1);
        assertEq(reg.BOX_IMPL(), IMPL2);
        LaunchParams memory p = _params();
        address[3] memory impls = [IMPL0, IMPL1, IMPL2];
        for (uint256 i; i < 3; i++) {
            vm.prank(attacker);
            vm.expectRevert(CuratedVaultBase.AlreadyInitialized.selector);
            CuratedVault(payable(impls[i])).initialize(p, attacker);
        }
        _launch();
        // the vault is a minimal proxy to the instant implementation
        assertEq(address(vault).code, abi.encodePacked(hex"363d3d373d3d3d363d73", IMPL0, hex"5af43d82803e903d91602b57fd5bf3"));
        vm.prank(address(reg));
        vm.expectRevert(CuratedVaultBase.AlreadyInitialized.selector);
        vault.initialize(p, attacker);
        // a clone made by someone else binds to their own "registry", never to this one
        p.saleMode = 3;
        vm.prank(curator);
        vm.expectRevert(CuratedRegistry.BadSaleMode.selector);
        reg.launch{value: launchValue}(p);
    }

    /// On BNB Smart Chain, BEM itself works as a payment token (no transfer tax).
    function test_Token_BEMOnBSC() public {
        vm.skip(block.chainid != 56);
        address bem = 0x5ce033B2bFCa3Af30b3e8C8457DeaF776A8b695a;
        assertEq(IERC20Meta(bem).decimals(), 8);
        _launchToken(bem);
        Work memory w = _work(0);
        deal(bem, buyer, w.price);
        vm.prank(buyer);
        IERC20Meta(bem).approve(address(vault), w.price);
        vm.prank(buyer);
        uint256 id = vault.buy{value: fee}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, buyer);
        assertTrue(reg.isOfficial(address(C), id));
        assertEq(IERC20Meta(bem).balanceOf(address(vault)), 0);
        assertEq(IERC20Meta(bem).balanceOf(PAYEE), w.price - (w.price * vault.PLATFORM_BPS()) / 10_000);
    }
}

/// A payee contract that refuses native coin; it can send what it is owed elsewhere.
contract RejectPayee {
    function pull(CuratedVault v, address to) external {
        v.withdrawTo(to);
    }

    receive() external payable {
        revert("no");
    }
}

/// A token that refuses transfers to blocked addresses (like USDC's blacklist).
contract BlockToken is MockToken {
    mapping(address => bool) public blocked;

    function block_(address a) external {
        blocked[a] = true;
    }

    function _move(address from, address to, uint256 amount) internal override {
        require(!blocked[to], "blocked");
        super._move(from, to, amount);
    }
}

/// Recipient that tries to buy again while receiving the circuit.
contract Reenter {
    CuratedVault immutable v;
    CuratedForkTest immutable t;

    constructor(CuratedVault v_, CuratedForkTest t_) {
        v = v_;
        t = t_;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        CuratedForkTest.Work memory w = t.workFor(0);
        uint256 f = v.circuits().TAPEOUT_FEE();
        v.buy{value: w.price + f}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, address(this));
        return this.onERC721Received.selector;
    }

    receive() external payable {}
}

/// Curator account whose refund hook tries to buy a work inside the launch transaction.
contract RefundReenter {
    CuratedForkTest immutable t;

    constructor(CuratedForkTest t_) {
        t = t_;
    }

    bytes4 public seen;

    receive() external payable {
        CuratedForkTest.Work memory w = t.workFor(3); // price 0
        // the vault sends the refund; buying now must hit the reentrancy guard
        CuratedVault v = CuratedVault(payable(msg.sender));
        uint256 f = v.circuits().TAPEOUT_FEE();
        try v.buy{value: f}(w.index, w.netlist, w.nIn, w.nOut, w.price, w.proof, address(this)) {
            seen = bytes4(0xffffffff); // must never happen
        } catch (bytes memory err) {
            // the first four bytes of the revert data are the error selector
            // forge-lint: disable-next-line(unsafe-typecast)
            seen = bytes4(err);
        }
    }
}
