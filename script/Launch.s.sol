// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {CuratedRegistry} from "../src/CuratedRegistry.sol";
import {CuratedVault} from "../src/CuratedVault.sol";

/// Launch a curated collection from a manifest built by `tool/curate.py build`.
///
///   MANIFEST=test/fixtures/my_manifest.json forge script script/Launch.s.sol \
///       --rpc-url https://bsc-dataseed.bnbchain.org --broadcast --private-key <curator key>
///   (or --rpc-url https://rpc.xlayer.tech for X Layer, https://mainnet.base.org for Base; the manifest must be
///   built for that chain)
///
/// The sender must be the manifest's curator. The manifest must sit under test/fixtures/ (Foundry's read
/// permission). Prints the processor (circuits) address to put in web/site.json.
contract Launch is Script {
    function run() external {
        string memory m = vm.readFile(vm.envString("MANIFEST"));
        CuratedRegistry reg = CuratedRegistry(vm.parseJsonAddress(m, ".registry"));

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
        // presale at the work-list price unless the manifest has a presale price list
        if (vm.keyExistsJson(m, ".launch.presalePriceRoot")) p.presalePriceRoot = vm.parseJsonBytes32(m, ".launch.presalePriceRoot");

        vm.startBroadcast();
        require(msg.sender == p.curator, "the sender must be the manifest's curator");
        (address v, address t, address c) = reg.launch{value: vm.parseJsonUint(m, ".launch.launchValueWei")}(p);
        vm.stopBroadcast();

        console.log("CIRCUITS", c);
        console.log("VAULT", v);
        console.log("TRANSISTORS", t);
    }
}
