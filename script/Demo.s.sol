// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {CuratedRegistry} from "../src/CuratedRegistry.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {ITapeOutCircuits} from "../src/interfaces/ITapeOut.sol";

/// Demo against a local fork (anvil). Expects:
///   REGISTRY  an already deployed CuratedRegistry
///   MANIFEST  a manifest built for that registry with `curate.py build`, curator = address of PK
///   PK        the curator's key (launches, buys works 2 and 3, claims every reserved work to the treasury)
///   PK2       a stranger's key (tapes out a zero-cost REF wrapper of circuit 1)
contract Demo is Script {
    function run() external {
        string memory m = vm.readFile(vm.envString("MANIFEST"));
        CuratedRegistry reg = CuratedRegistry(vm.envAddress("REGISTRY"));
        uint256 pk = vm.envUint("PK");
        uint256 pk2 = vm.envUint("PK2");

        CuratedVault.LaunchParams memory p;
        p.name = vm.parseJsonString(m, ".launch.name");
        p.symbol = vm.parseJsonString(m, ".launch.symbol");
        p.story = vm.parseJsonString(m, ".launch.story");
        p.nandSupply = vm.parseJsonUint(m, ".launch.nandSupply");
        p.latchSupply = vm.parseJsonUint(m, ".launch.latchSupply");
        p.mintPrice = vm.parseJsonUint(m, ".launch.mintPrice");
        p.mintBatch = vm.parseJsonUint(m, ".launch.mintBatch");
        p.root = vm.parseJsonBytes32(m, ".launch.root");
        p.count = uint32(vm.parseJsonUint(m, ".launch.count"));
        p.curator = vm.parseJsonAddress(m, ".launch.curator");
        p.platform = vm.parseJsonAddress(m, ".launch.platform");
        p.platformBps = uint16(vm.parseJsonUint(m, ".launch.platformBps"));
        p.saleStart = uint64(vm.parseJsonUint(m, ".launch.saleStart"));
        p.saleEnd = uint64(vm.parseJsonUint(m, ".launch.saleEnd"));
        p.maxLaunchFees = vm.parseJsonUint(m, ".launch.maxLaunchFees");
        p.treasury = vm.parseJsonAddress(m, ".launch.treasury");
        p.reservedCount = uint32(vm.parseJsonUint(m, ".launch.reservedCount"));
        p.limitPerWallet = vm.parseJsonBool(m, ".launch.limitPerWallet");
        p.maxPerWallet = uint32(vm.parseJsonUint(m, ".launch.maxPerWallet"));
        p.allowRoot = vm.parseJsonBytes32(m, ".launch.allowRoot");
        p.presaleStart = uint64(vm.parseJsonUint(m, ".launch.presaleStart"));
        p.royaltyReceiver = vm.parseJsonAddress(m, ".launch.royaltyReceiver");
        p.royaltyBps = uint16(vm.parseJsonUint(m, ".launch.royaltyBps"));
        p.titlesHash = vm.parseJsonBytes32(m, ".launch.titlesHash");
        p.metadataURI = vm.parseJsonString(m, ".launch.metadataURI");
        // native coin (address(0)) unless the manifest names an ERC-20 for the prices
        if (vm.keyExistsJson(m, ".launch.paymentToken")) p.paymentToken = vm.parseJsonAddress(m, ".launch.paymentToken");

        vm.startBroadcast(pk);
        (address v,, address c) = reg.launch{value: vm.parseJsonUint(m, ".launch.launchValueWei")}(p);
        uint256 fee = ITapeOutCircuits(c).TAPEOUT_FEE();
        for (uint256 i = 2; i <= 3; i++) {
            string memory k = string.concat(".works[", vm.toString(i), "]");
            uint256 price = vm.parseJsonUint(m, string.concat(k, ".priceWei"));
            CuratedVault(payable(v)).buy{value: price + fee}(
                i,
                vm.parseJsonBytes(m, string.concat(k, ".netlist")),
                uint32(vm.parseJsonUint(m, string.concat(k, ".nIn"))),
                uint32(vm.parseJsonUint(m, string.concat(k, ".nOut"))),
                price,
                vm.parseJsonBytes32Array(m, string.concat(k, ".proof")),
                vm.addr(pk)
            );
        }
        // claim every reserved work to the treasury in one transaction
        CuratedVault.ReservedWork[] memory batch = new CuratedVault.ReservedWork[](p.reservedCount);
        uint256 n;
        for (uint256 i; i < p.count; i++) {
            string memory k = string.concat(".works[", vm.toString(i), "]");
            if (!vm.parseJsonBool(m, string.concat(k, ".reserved"))) continue;
            batch[n++] = CuratedVault.ReservedWork(
                i,
                vm.parseJsonBytes(m, string.concat(k, ".netlist")),
                uint32(vm.parseJsonUint(m, string.concat(k, ".nIn"))),
                uint32(vm.parseJsonUint(m, string.concat(k, ".nOut"))),
                vm.parseJsonBytes32Array(m, string.concat(k, ".proof"))
            );
        }
        CuratedVault(payable(v)).claimReservedBatch{value: fee * n}(batch);
        vm.stopBroadcast();

        vm.startBroadcast(pk2);
        ITapeOutCircuits(c).tapeout{value: fee}(abi.encodePacked(uint8(2), c, uint64(1), uint8(0), uint8(7)), 0, 7);
        vm.stopBroadcast();

        console.log("VAULT", v);
        console.log("CIRCUITS", c);
    }
}
