// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interfaces of the deployed TapeOut contracts on BNB Smart Chain.
/// Selectors were checked against the deployed implementations on 2026-10-25:
///   factory proxy  0x68224F668083c29e9800Be2a646d42d18cedF7e2
///   circuits impl  0x8E1D125Def6d3826C278299273a0760D47626068 (beacon proxy)
///   transistors impl 0x32e1fa125B6Abe0FF12eeC43E2daB482019a1E97 (beacon proxy)

interface ITapeOutFactory {
    /// 0x47f9b5fd
    function createCPU(
        string calldata name,
        string calldata symbol,
        string calldata story,
        uint256 transistorSupply,
        uint256 mintPrice
    ) external payable returns (address transistors, address circuits);

    /// 0x5f5a364f — true for a processor (circuits) contract created by the factory
    function isCPU(address cpu) external view returns (bool);

    function deployFee() external view returns (uint256);
}

/// @notice A processor's transistor contract (ERC-1155; id 0 = NAND, id 1 = LATCH).
interface ITapeOutTransistors {
    function mint(uint256 id, uint256 amount) external payable;
    function withdraw() external;
    function creator() external view returns (address);
    function circuits() external view returns (address);
    function supplyCap() external view returns (uint256);
    function minted() external view returns (uint256);
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
    function safeTransferFrom(address from, address to, uint256 id, uint256 value, bytes calldata data) external;
}

/// @notice A processor contract (ERC-721 of circuits). See TAP-02 §6.
interface ITapeOutCircuits {
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256 id);
    function netlist(uint256 id) external view returns (bytes memory);
    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    /// @dev observed: number of circuits taped out so far (0 when fresh); the first circuit id is 1
    function nextId() external view returns (uint256);
    function transistors() external view returns (address);
    function factory() external view returns (address);
    function TAPEOUT_FEE() external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id) external;
}
