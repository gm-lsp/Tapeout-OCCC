// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {CuratedRegistry} from "../src/CuratedRegistry.sol";
import {CuratedVault} from "../src/CuratedVault.sol";
import {LaunchParams} from "../src/CuratedTypes.sol";
import {ManifestParams} from "./ManifestParams.sol";
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

        LaunchParams memory p = ManifestParams.read(m);

        vm.startBroadcast(pk);
        (address v,, address c) = reg.launch{value: vm.parseJsonUint(m, ".launch.launchValueWei")}(p);
        uint256 fee = ITapeOutCircuits(c).TAPEOUT_FEE();
        for (uint256 i = 2; i <= 3; i++) {
            (bytes memory nl, uint32 a, uint32 b) = _design(m, i);
            string memory k = string.concat(".works[", vm.toString(i), "]");
            uint256 price = vm.parseJsonUint(m, string.concat(k, ".priceWei"));
            CuratedVault(payable(v)).buy{value: price + fee}(
                i, nl, a, b, price, vm.parseJsonBytes32Array(m, string.concat(k, ".proof")), vm.addr(pk)
            );
        }
        // claim every reserved work to the treasury in one transaction (the demo manifest has single works only)
        CuratedVault.ReservedWork[] memory batch = new CuratedVault.ReservedWork[](p.reservedCount);
        uint256 n;
        for (uint256 i; i < p.count; i++) {
            string memory k = string.concat(".works[", vm.toString(i), "]");
            if (!vm.parseJsonBool(m, string.concat(k, ".reserved"))) continue;
            (bytes memory nl, uint32 a, uint32 b) = _design(m, i);
            batch[n++] = CuratedVault.ReservedWork(i, nl, a, b, vm.parseJsonBytes32Array(m, string.concat(k, ".proof")));
        }
        CuratedVault(payable(v)).claimReservedBatch{value: fee * n}(batch);
        vm.stopBroadcast();

        vm.startBroadcast(pk2);
        ITapeOutCircuits(c).tapeout{value: fee}(abi.encodePacked(uint8(2), c, uint64(1), uint8(0), uint8(7)), 0, 7);
        vm.stopBroadcast();

        console.log("VAULT", v);
        console.log("CIRCUITS", c);
    }

    function _design(string memory m, uint256 i) internal pure returns (bytes memory nl, uint32 a, uint32 b) {
        string memory k = string.concat(".works[", vm.toString(i), "]");
        string memory d = string.concat(".designs[", vm.toString(vm.parseJsonUint(m, string.concat(k, ".design"))), "]");
        nl = vm.parseJsonBytes(m, string.concat(d, ".netlist"));
        a = uint32(vm.parseJsonUint(m, string.concat(d, ".nIn")));
        b = uint32(vm.parseJsonUint(m, string.concat(d, ".nOut")));
    }
}
