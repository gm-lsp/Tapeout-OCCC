// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {CuratedRegistry} from "../src/CuratedRegistry.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {CuratedRevealVault} from "../src/CuratedRevealVault.sol";
import {CuratedBlindBoxVault} from "../src/CuratedBlindBoxVault.sol";
import {ITapeOutFactory} from "../src/interfaces/ITapeOut.sol";

/// Deploy the three vault implementations and the registry that clones them (four transactions, no owner).
///
///   FACTORY=<TapeOut factory of the chain> forge script script/Deploy.s.sol --rpc-url <RPC> --broadcast \
///       --private-key <any key>
contract Deploy is Script {
    function run() external {
        ITapeOutFactory factory = ITapeOutFactory(vm.envAddress("FACTORY"));
        vm.startBroadcast();
        address i0 = address(new CuratedVault());
        address i1 = address(new CuratedRevealVault());
        address i2 = address(new CuratedBlindBoxVault());
        CuratedRegistry reg = new CuratedRegistry(factory, i0, i1, i2);
        vm.stopBroadcast();
        console.log("REGISTRY", address(reg));
        console.log("INSTANT_IMPL", i0);
        console.log("REVEAL_IMPL", i1);
        console.log("BOX_IMPL", i2);
    }
}
