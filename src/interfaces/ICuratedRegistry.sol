// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Curated Collections registry — the interface standardised by the TAP draft.
/// @notice A circuit is *official* for a curated collection if and only if it was taped out
/// by that collection's vault and recorded here in the same transaction. Netlist content,
/// `circuitInfo` and evaluation results are NOT evidence of officialness: REF wrappers copy
/// all of them, and identical netlists can be taped out by anyone who holds transistors.
/// "Official" is relative to one processor: consumers must use the processor address the curator
/// announced, because a curator may launch several collections.
interface ICuratedRegistry {
    struct Collection {
        address vault; // the only address allowed to certify circuits of this collection
        address curator; // the artist / project that receives sale proceeds
        address transistors; // the processor's transistor contract
        address treasury; // receives every reserved work; fixed at launch
        bytes32 root; // Merkle root of the work list, fixed at launch
        uint32 count; // number of works in the list
        uint32 reserved; // number of works the list reserves for the treasury, fixed at launch
        uint32 certified; // number of works taped out and certified so far
        bytes32 metadata; // commitment to the name, symbol, story and all work titles, fixed at launch
    }

    /// @notice Emitted once, in the launch transaction, after the vault holds the whole supply.
    event CollectionLaunched(
        address indexed circuits,
        address indexed vault,
        address indexed curator,
        address transistors,
        bytes32 root,
        uint32 count,
        address treasury,
        uint32 reserved,
        bytes32 metadata
    );

    /// @notice Emitted when a collection's royalty is declared at launch, and on every later change.
    event RoyaltySet(address indexed circuits, address receiver, uint16 bps);

    /// @notice Emitted once, in the launch transaction: the collection's metadata directory ("" = none).
    event MetadataURISet(address indexed circuits, string uri);

    /// @notice Emitted in the same transaction as the tape-out of an official circuit.
    event Certified(
        address indexed circuits, uint256 indexed tokenId, uint256 indexed index, bytes32 netlistHash, bool reserved
    );

    /// @return true iff circuit `tokenId` of processor `circuits` is an official work.
    function isOfficial(address circuits, uint256 tokenId) external view returns (bool);

    /// @return official whether the circuit is official; index its position in the work list.
    function editionOf(address circuits, uint256 tokenId) external view returns (bool official, uint256 index);

    /// @return taped whether work `index` has been taped out; tokenId its circuit id.
    function tokenOf(address circuits, uint256 index) external view returns (bool taped, uint256 tokenId);

    /// @return true iff circuit `tokenId` is an official work that the work list reserved for the treasury.
    function isReserved(address circuits, uint256 tokenId) external view returns (bool);

    /// @notice Optional royalty declaration, in the shape of ERC-2981 with the processor as an extra argument.
    /// Returns (address(0), 0) for circuits that are not official. Advisory: markets decide whether to pay it.
    function royaltyInfo(address circuits, uint256 tokenId, uint256 salePrice)
        external
        view
        returns (address receiver, uint256 royaltyAmount);

    /// @return receiver the declared royalty receiver; bps the declared rate (both zero if none).
    function royaltyOf(address circuits) external view returns (address receiver, uint16 bps);

    /// @notice Curator only: change the royalty receiver or lower the rate; the rate can never rise.
    function setRoyalty(address circuits, address receiver, uint16 bps) external;

    /// @return true iff `circuits` is a curated collection launched through this registry.
    function isCurated(address circuits) external view returns (bool);

    function collectionOf(address circuits) external view returns (Collection memory);

    /// @return the content-addressed metadata directory fixed at launch ("ipfs://<CID>", "ar://<id>" or "").
    function metadataURIOf(address circuits) external view returns (string memory);

    /// @return "<metadataURI>/<index>.json" for an official circuit; "" for anything else or when there is no directory.
    function tokenURI(address circuits, uint256 tokenId) external view returns (string memory);
}
