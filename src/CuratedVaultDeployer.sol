// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CuratedVault} from "./CuratedVault.sol";
import {CuratedRegistry} from "./CuratedRegistry.sol";

/// @title CuratedVaultDeployer
/// @notice Holds the vault's creation code for one registry, so the registry stays under the contract size limit.
/// Created by the registry in its constructor; only that registry can deploy vaults through it.
contract CuratedVaultDeployer {
    address public immutable REGISTRY;

    error OnlyRegistry();

    constructor() {
        REGISTRY = msg.sender;
    }

    function deploy(CuratedVault.LaunchParams calldata p) external returns (address) {
        if (msg.sender != REGISTRY) revert OnlyRegistry();
        return address(new CuratedVault(CuratedRegistry(REGISTRY), p));
    }
}
