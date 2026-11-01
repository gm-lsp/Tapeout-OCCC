// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {LaunchParams} from "../src/CuratedTypes.sol";

/// Reads the launch parameters of a manifest built by `tool/curate.py build` (curated-collection-manifest/8).
library ManifestParams {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function read(string memory m) internal pure returns (LaunchParams memory p) {
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
        p.paymentToken = vm.parseJsonAddress(m, ".launch.paymentToken");
        p.presalePriceRoot = vm.parseJsonBytes32(m, ".launch.presalePriceRoot");
        p.saleMode = uint8(vm.parseJsonUint(m, ".launch.saleMode"));
        p.sequential = vm.parseJsonBool(m, ".launch.sequential");
        p.payee = vm.parseJsonAddress(m, ".launch.payee");
        p.hidden.poolPrices = vm.parseJsonUintArray(m, ".launch.hidden.poolPrices");
        uint256[] memory pc = vm.parseJsonUintArray(m, ".launch.hidden.poolCounts");
        p.hidden.poolCounts = new uint32[](pc.length);
        for (uint256 i; i < pc.length; i++) {
            p.hidden.poolCounts[i] = uint32(pc[i]);
        }
        p.hidden.revealFee = vm.parseJsonUint(m, ".launch.hidden.revealFee");
        p.hidden.revealGasPrice = vm.parseJsonUint(m, ".launch.hidden.revealGasPrice");
        p.hidden.secretsRoot = vm.parseJsonBytes32(m, ".launch.hidden.secretsRoot");
        p.hidden.secretHash = vm.parseJsonBytes32(m, ".launch.hidden.secretHash");
        p.hidden.metadataRoot = vm.parseJsonBytes32(m, ".launch.hidden.metadataRoot");
        p.hidden.passURI = vm.parseJsonString(m, ".launch.hidden.passURI");
    }
}
