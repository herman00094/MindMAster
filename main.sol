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
    event SynapseTicked(uint256 previousEpoch, uint256 newEpoch, uint256 atBlock);
    event RecallStored(
        bytes32 indexed anchorId,
        bytes32 recallHash,
        uint256 storedAtBlock
    );
    event LatticeTopped(uint256 amount, address indexed from, uint256 newBalance);
    event LatticePaused(address indexed by, uint256 atBlock);
    event LatticeUnpaused(address indexed by, uint256 atBlock);
    event LatticeWithdrawn(address indexed to, uint256 amount, uint256 atBlock);
    event FeesWithdrawn(address indexed to, uint256 amount, uint256 atBlock);
    event RecallCommitment(bytes32 indexed anchorId, address indexed from, uint256 amount, uint256 atBlock);
    event RecallCommitmentWithdrawn(bytes32 indexed anchorId, address indexed to, uint256 amount);

    // -------------------------------------------------------------------------
    // ERRORS
    // -------------------------------------------------------------------------

    error MindMaster_AnchorSlotFull();
    error MindMaster_NotGovernor();
    error MindMaster_SynapseWindowNotReached();
    error MindMaster_LinkSlotInvalid();
    error MindMaster_DuplicateAnchorId();
    error MindMaster_AnchorNotFound();
    error MindMaster_ZeroAnchorId();
    error MindMaster_LinkCapReached();
    error MindMaster_NotLinkForger();
    error MindMaster_NotNodeOracle();
    error MindMaster_RecallAlreadyStored();
    error MindMaster_ZeroRecallHash();
    error MindMaster_InvalidLinkEndpoints();
    error MindMaster_Paused();
    error MindMaster_AnchorDeprecated();
    error MindMaster_BatchTooLarge();
    error MindMaster_ZeroLength();
    error MindMaster_WithdrawZero();
    error MindMaster_InvalidTier();
    error MindMaster_InvalidStrength();
    error MindMaster_LinkNotFound();
    error MindMaster_DuplicateLinkId();
    error MindMaster_NoCommitment();
    error MindMaster_CommitmentLocked();
    error MindMaster_ArrayLengthMismatch();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant ANCHORS_PER_EPOCH = 512;
    uint256 public constant LINK_SLOTS = 32;
    uint256 public constant SYNAPSE_BLOCKS = 128;
    uint256 public constant MAX_SYNAPSE_EPOCHS = 4096;
    uint256 public constant MAX_BATCH_PIN = 64;
    uint256 public constant MAX_BATCH_LINK = 48;
    uint256 public constant MAX_LINKS_TOTAL = 4096;
