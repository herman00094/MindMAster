// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MindMaster
/// @notice Kite-shaped recall lattice: anchors hold memory nodes, links form directed edges, synapse ticks advance recall epochs. Calibration baked at deploy; no config to fill.
/// @dev Governor pins anchors, link forger creates edges, node oracle can tick synapse. All role addresses and caps are constructor-set and immutable.
/// Remix: open this file in remix.ethereum.org; compiler 0.8.20+; deploy with no args. See REMIX_MindMaster.md.
///
/// ## Roles
/// - governor: pause, pin/update/deprecate anchors, withdraw lattice and fees
/// - linkForger: forge links (single or batch) between anchors
/// - nodeOracle: advance synapse epoch, store recall hashes
/// - feeRecipient: receives optional fee share from topLattice (immutable)
///
/// ## Anchors
/// Each anchor has: id, tier (0-7), content hash, up to 4 tags, deprecated flag. Anchors can receive "recall commitments" (ETH staked per anchor, lock period applies).
///
/// ## Links
/// Links are directed edges (fromAnchor -> toAnchor) with kind, strength (0-100), and config hash. Stored in enumerable structures for from/to queries.
///
/// ## Epochs
/// Synapse advances every SYNAPSE_BLOCKS; nodeOracle calls advanceSynapse() when block window is reached. Anchors are counted per epoch.

import "https://raw.githubusercontent.com/OpenZeppelin/openzeppelin-contracts/v4.9.6/contracts/security/ReentrancyGuard.sol";

contract MindMaster is ReentrancyGuard {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event AnchorPinned(
        bytes32 indexed anchorId,
        address indexed pinnedBy,
        uint8 recallTier,
        uint256 synapseEpoch,
        bytes32 contentHash
    );
    event AnchorPinnedBatch(bytes32[] anchorIds, address indexed pinnedBy, uint256 synapseEpoch);
    event AnchorUpdated(
        bytes32 indexed anchorId,
        bytes32 previousContentHash,
        bytes32 newContentHash,
        uint256 updatedAtBlock
    );
    event AnchorDeprecated(bytes32 indexed anchorId, address indexed deprecatedBy, uint256 atBlock);
    event LinkForged(
        bytes32 indexed linkId,
        bytes32 indexed fromAnchor,
        bytes32 indexed toAnchor,
        uint8 linkKind,
        uint8 linkStrength,
        uint256 forgedAtBlock
    );
    event LinkForgedBatch(bytes32[] linkIds, address indexed forgedBy, uint256 count);
