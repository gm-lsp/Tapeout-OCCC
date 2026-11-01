// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {CuratedRegistry} from "../src/CuratedRegistry.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {LaunchParams} from "../src/CuratedTypes.sol";
import {ManifestParams} from "./ManifestParams.sol";

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

        LaunchParams memory p = ManifestParams.read(m);

        vm.startBroadcast();
        require(msg.sender == p.curator, "the sender must be the manifest's curator");
        (address v, address t, address c) = reg.launch{value: vm.parseJsonUint(m, ".launch.launchValueWei")}(p);
        vm.stopBroadcast();

        console.log("CIRCUITS", c);
        console.log("VAULT", v);
        console.log("TRANSISTORS", t);
    }
}
