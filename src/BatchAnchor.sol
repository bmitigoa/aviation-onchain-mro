// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "./RoleManager.sol";
import "./AircraftRegistry.sol";

/// @title BatchAnchor
/// @notice Anchors a whole maintenance package (e.g. a C-check with hundreds of task cards)
///         as a single Merkle root, in one transaction.
/// @dev Leaves use the OpenZeppelin StandardMerkleTree encoding (double-hashed, abi-encoded),
///      so trees and proofs built with the OpenZeppelin merkle-tree JS library verify here directly:
///        leaf = keccak256(bytes.concat(keccak256(abi.encode(partId, taskRef, docHash))))
///      Any single task card can later be proven to belong to the package without revealing
///      the rest of the package.
contract BatchAnchor {
    error NotAuthorized();
    error EmptyRoot();
    error EmptyBatch();
    error AircraftNotFound();
    error BatchNotFound();

    struct Batch {
        uint256 aircraftId; // 0 for shop packages not tied to one aircraft
        bytes32 root;
        uint32 leafCount;
        string uri; // where the full package is stored, e.g. ipfs://<CID>
        address anchoredBy;
        uint64 timestamp;
    }

    RoleManager public immutable roles;
    AircraftRegistry public immutable aircraft;

    Batch[] private batches;

    event BatchAnchored(
        uint256 indexed batchId,
        uint256 indexed aircraftId,
        bytes32 indexed root,
        uint32 leafCount,
        string uri,
        address anchoredBy
    );

    constructor(RoleManager roleManager, AircraftRegistry aircraftRegistry) {
        roles = roleManager;
        aircraft = aircraftRegistry;
    }

    function anchorBatch(uint256 aircraftId, bytes32 root, uint32 leafCount, string calldata uri)
        external
        returns (uint256 batchId)
    {
        _onlyAdminOrMRO();
        if (root == bytes32(0)) revert EmptyRoot();
        if (leafCount == 0) revert EmptyBatch();
        if (aircraftId != 0 && !aircraft.exists(aircraftId)) revert AircraftNotFound();

        batches.push(
            Batch({
                aircraftId: aircraftId,
                root: root,
                leafCount: leafCount,
                uri: uri,
                anchoredBy: msg.sender,
                timestamp: uint64(block.timestamp)
            })
        );
        batchId = batches.length - 1;

        emit BatchAnchored(batchId, aircraftId, root, leafCount, uri, msg.sender);
    }

    /// @notice Leaf hash for one task card in a package.
    function leafHash(bytes32 partId, string calldata taskRef, bytes32 docHash) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(partId, taskRef, docHash))));
    }

    /// @notice Prove that a task card (part, task reference, document SHA-256) is in batch `batchId`.
    function verifyItem(
        uint256 batchId,
        bytes32 partId,
        string calldata taskRef,
        bytes32 docHash,
        bytes32[] calldata proof
    ) external view returns (bool) {
        if (batchId >= batches.length) revert BatchNotFound();
        return MerkleProof.verifyCalldata(proof, batches[batchId].root, leafHash(partId, taskRef, docHash));
    }

    function get(uint256 batchId) external view returns (Batch memory) {
        if (batchId >= batches.length) revert BatchNotFound();
        return batches[batchId];
    }

    function count() external view returns (uint256) {
        return batches.length;
    }

    function _onlyAdminOrMRO() private view {
        bool ok = roles.hasRole(roles.ADMIN_ROLE(), msg.sender) || roles.hasRole(roles.MRO_ROLE(), msg.sender);
        if (!ok) revert NotAuthorized();
    }
}
