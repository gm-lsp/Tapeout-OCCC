// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Circuit metadata provider (proposed to TapeOut in the TAP draft, "Recommendation to TapeOut").
/// @notice A processor's creator contract may implement this, so that a processor's own `tokenURI(id)`
/// can return `ICircuitURIProvider(transistors.creator()).circuitURI(address(this), id)` once TapeOut
/// adopts it. Every curated vault is its processor's creator and implements it by asking the registry,
/// which returns metadata only for official circuits.
interface ICircuitURIProvider {
    /// @return ERC-721 metadata URI of circuit `tokenId` of processor `circuits`, or "" if none.
    function circuitURI(address circuits, uint256 tokenId) external view returns (string memory);
}
