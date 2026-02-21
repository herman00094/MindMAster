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
    uint256 public constant MAX_TAGS_PER_ANCHOR = 4;
    uint256 public constant MAX_RECALL_TIER = 7;
    uint256 public constant MAX_LINK_STRENGTH = 100;
    uint256 public constant COMMITMENT_LOCK_BLOCKS = 128;
    uint256 public constant BASIS_DENOMINATOR = 10_000;
    uint256 public constant FEE_BASIS_POINTS = 25; // 0.25% of topLattice optional
    bytes32 public constant LATTICE_DOMAIN =
        bytes32(uint256(0x8f7e6d5c4b3a2918e0d1c2b3a495867e8f9a0b1c2d3e4f5a6b7c8d9e0f1a2b));

    // -------------------------------------------------------------------------
    // IMMUTABLE STATE
    // -------------------------------------------------------------------------

    address public immutable governor;
    address public immutable linkForger;
    address public immutable nodeOracle;
    address public immutable feeRecipient;
    uint256 public immutable genesisBlock;
    bytes32 public immutable latticeSeed;

    // -------------------------------------------------------------------------
    // MUTABLE STATE
    // -------------------------------------------------------------------------

    bool public paused;
    uint256 public currentSynapseEpoch;
    uint256 public totalAnchorsPinned;
    uint256 public totalLinksForged;
    uint256 public latticeBalance;
    uint256 public accumulatedFees;
    mapping(uint256 => uint256) private _anchorsInEpoch;
    mapping(bytes32 => MemoryAnchor) private _anchors;
    mapping(bytes32 => bytes32) private _recallHashes;
    bytes32[] private _anchorIdList;
    mapping(uint256 => LinkSlot) private _linkSlots;
    mapping(uint256 => bool) private _epochAdvanced;
    mapping(bytes32 => StoredLink) private _links;
    mapping(bytes32 => bytes32[]) private _outLinkIds;
    mapping(bytes32 => bytes32[]) private _inLinkIds;
    bytes32[] private _linkIdList;
    mapping(bytes32 => mapping(address => uint256)) private _recallCommitments;
    mapping(bytes32 => uint256) private _commitmentLockedUntilBlock;
    mapping(bytes32 => uint256) private _totalCommitmentPerAnchor;

    // -------------------------------------------------------------------------
    // STRUCTS
    // -------------------------------------------------------------------------

    struct MemoryAnchor {
        bytes32 anchorId;
        address pinnedBy;
        uint8 recallTier;
        uint256 synapseEpoch;
        uint256 pinnedAtBlock;
        uint256 updatedAtBlock;
        bytes32 contentHash;
        bytes32[MAX_TAGS_PER_ANCHOR] tags;
        bool recallStored;
        bool deprecated;
    }

    struct LinkSlot {
        bytes32 linkId;
        uint8 slotIndex;
        uint256 forgedAtBlock;
        bytes32 configHash;
    }

    struct StoredLink {
        bytes32 linkId;
        bytes32 fromAnchor;
        bytes32 toAnchor;
        uint8 linkKind;
        uint8 linkStrength;
        uint256 forgedAtBlock;
        bytes32 configHash;
        bool exists;
    }

    struct LatticeStats {
        uint256 totalAnchors;
        uint256 totalLinks;
        uint256 currentEpoch;
        uint256 genesisBlock;
        uint256 balance;
        uint256 accumulatedFees;
        bool isPaused;
    }

    struct AnchorView {
        bytes32 anchorId;
        address pinnedBy;
        uint8 recallTier;
        uint256 synapseEpoch;
        uint256 pinnedAtBlock;
        uint256 updatedAtBlock;
        bytes32 contentHash;
        bytes32[MAX_TAGS_PER_ANCHOR] tags;
        bool recallStored;
        bool deprecated;
        uint256 outLinkCount;
        uint256 inLinkCount;
    }

    // -------------------------------------------------------------------------
    // MODIFIERS
    // -------------------------------------------------------------------------

    modifier onlyGovernor() {
        if (msg.sender != governor) revert MindMaster_NotGovernor();
        _;
    }

    modifier onlyLinkForger() {
        if (msg.sender != linkForger) revert MindMaster_NotLinkForger();
        _;
    }

    modifier onlyNodeOracle() {
        if (msg.sender != nodeOracle) revert MindMaster_NotNodeOracle();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert MindMaster_Paused();
        _;
    }

    // -------------------------------------------------------------------------
    // CONSTRUCTOR
    // -------------------------------------------------------------------------

    constructor() {
        governor = address(0x9B2f4A6c8E0d1F3b5a7C9e2D4f6A8c0E1b3D5a7);
        linkForger = address(0xF1e3C5a7B9d2F4a6C8e0B1d3E5f7A9c2D4b6E8f);
        nodeOracle = address(0x2C4e6A8c0E1b3D5f7A9c2E4b6D8f0A1c3E5a7B9);
        feeRecipient = address(0x3D5f7A9c2E4b6D8f0A1c3E5a7B9d2F4a6C8e0B1);
        genesisBlock = block.number;
        latticeSeed = keccak256(abi.encodePacked(block.number, block.prevrandao, block.chainid));
        currentSynapseEpoch = 0;
        totalAnchorsPinned = 0;
        totalLinksForged = 0;
        latticeBalance = 0;
        accumulatedFees = 0;
        paused = false;
    }

    // -------------------------------------------------------------------------
    // GOVERNOR: PAUSE
    // -------------------------------------------------------------------------

    function setPaused(bool _paused) external onlyGovernor {
        paused = _paused;
        if (_paused) emit LatticePaused(msg.sender, block.number);
        else emit LatticeUnpaused(msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // GOVERNOR: PIN ANCHOR (SINGLE)
    // -------------------------------------------------------------------------

    function pinAnchor(bytes32 anchorId, uint8 recallTier, bytes32 contentHash)
        external
        onlyGovernor
        whenNotPaused
        nonReentrant
    {
        _pinOne(anchorId, recallTier, contentHash, new bytes32[](0));
    }

    function pinAnchorWithTags(
        bytes32 anchorId,
        uint8 recallTier,
        bytes32 contentHash,
        bytes32[4] calldata tags
    ) external onlyGovernor whenNotPaused nonReentrant {
        bytes32[] memory tagList = new bytes32[](MAX_TAGS_PER_ANCHOR);
        for (uint256 i = 0; i < MAX_TAGS_PER_ANCHOR; i++) tagList[i] = tags[i];
        _pinOne(anchorId, recallTier, contentHash, tagList);
    }

    function _pinOne(
        bytes32 anchorId,
        uint8 recallTier,
        bytes32 contentHash,
        bytes32[] memory tags
    ) internal {
        if (anchorId == bytes32(0)) revert MindMaster_ZeroAnchorId();
        if (_anchors[anchorId].pinnedAtBlock != 0) revert MindMaster_DuplicateAnchorId();
        if (_anchorsInEpoch[currentSynapseEpoch] >= ANCHORS_PER_EPOCH) revert MindMaster_AnchorSlotFull();
        if (recallTier > MAX_RECALL_TIER) recallTier = 0;

        _anchorsInEpoch[currentSynapseEpoch] += 1;
        totalAnchorsPinned += 1;

        bytes32[MAX_TAGS_PER_ANCHOR] memory tagArr;
        for (uint256 i = 0; i < tags.length && i < MAX_TAGS_PER_ANCHOR; i++) {
            tagArr[i] = tags[i];
        }

        _anchors[anchorId] = MemoryAnchor({
            anchorId: anchorId,
            pinnedBy: msg.sender,
            recallTier: recallTier,
            synapseEpoch: currentSynapseEpoch,
            pinnedAtBlock: block.number,
            updatedAtBlock: block.number,
            contentHash: contentHash,
            tags: tagArr,
            recallStored: false,
            deprecated: false
        });
        _anchorIdList.push(anchorId);

        emit AnchorPinned(anchorId, msg.sender, recallTier, currentSynapseEpoch, contentHash);
    }

    // -------------------------------------------------------------------------
    // GOVERNOR: BATCH PIN
    // -------------------------------------------------------------------------

    function pinAnchorsBatch(
        bytes32[] calldata anchorIds,
        uint8[] calldata recallTiers,
        bytes32[] calldata contentHashes
    ) external onlyGovernor whenNotPaused nonReentrant {
        if (anchorIds.length == 0) revert MindMaster_ZeroLength();
        if (anchorIds.length > MAX_BATCH_PIN) revert MindMaster_BatchTooLarge();
        if (anchorIds.length != recallTiers.length || anchorIds.length != contentHashes.length) {
            revert MindMaster_ArrayLengthMismatch();
        }
        bytes32[] memory emptyTags = new bytes32[](0);
        for (uint256 i = 0; i < anchorIds.length; i++) {
            _pinOne(anchorIds[i], recallTiers[i], contentHashes[i], emptyTags);
        }
        emit AnchorPinnedBatch(anchorIds, msg.sender, currentSynapseEpoch);
    }

    // -------------------------------------------------------------------------
    // GOVERNOR: UPDATE ANCHOR
    // -------------------------------------------------------------------------

    function updateAnchorContent(bytes32 anchorId, bytes32 newContentHash) external onlyGovernor whenNotPaused nonReentrant {
        if (anchorId == bytes32(0)) revert MindMaster_ZeroAnchorId();
        MemoryAnchor storage a = _anchors[anchorId];
        if (a.pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        if (a.deprecated) revert MindMaster_AnchorDeprecated();
        bytes32 prev = a.contentHash;
        a.contentHash = newContentHash;
        a.updatedAtBlock = block.number;
        emit AnchorUpdated(anchorId, prev, newContentHash, block.number);
    }

    // -------------------------------------------------------------------------
    // GOVERNOR: DEPRECATE ANCHOR
    // -------------------------------------------------------------------------

    function setAnchorDeprecated(bytes32 anchorId) external onlyGovernor whenNotPaused nonReentrant {
        if (anchorId == bytes32(0)) revert MindMaster_ZeroAnchorId();
        MemoryAnchor storage a = _anchors[anchorId];
        if (a.pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        a.deprecated = true;
        emit AnchorDeprecated(anchorId, msg.sender, block.number);
    }

    // -------------------------------------------------------------------------
    // GOVERNOR: WITHDRAW LATTICE
    // -------------------------------------------------------------------------

    function withdrawLattice(address payable to, uint256 amount) external onlyGovernor nonReentrant {
        if (amount == 0) revert MindMaster_WithdrawZero();
        if (amount > latticeBalance) amount = latticeBalance;
        latticeBalance -= amount;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "MindMaster: transfer failed");
        emit LatticeWithdrawn(to, amount, block.number);
    }

    // -------------------------------------------------------------------------
    // GOVERNOR: WITHDRAW FEES
    // -------------------------------------------------------------------------

    function withdrawFees(address payable to) external onlyGovernor nonReentrant {
        uint256 amount = accumulatedFees;
        if (amount == 0) revert MindMaster_WithdrawZero();
        accumulatedFees = 0;
        (bool ok,) = to.call{value: amount}("");
        require(ok, "MindMaster: fee transfer failed");
        emit FeesWithdrawn(to, amount, block.number);
    }

    // -------------------------------------------------------------------------
    // LINK FORGER: FORGE LINK (SINGLE)
    // -------------------------------------------------------------------------

    function forgeLink(
        bytes32 linkId,
        bytes32 fromAnchor,
        bytes32 toAnchor,
        uint8 linkKind,
        bytes32 configHash
    ) external onlyLinkForger whenNotPaused nonReentrant {
        forgeLinkWithStrength(linkId, fromAnchor, toAnchor, linkKind, 100, configHash);
    }

    function forgeLinkWithStrength(
        bytes32 linkId,
        bytes32 fromAnchor,
        bytes32 toAnchor,
        uint8 linkKind,
        uint8 linkStrength,
        bytes32 configHash
    ) public onlyLinkForger whenNotPaused nonReentrant {
        if (fromAnchor == bytes32(0) || toAnchor == bytes32(0)) revert MindMaster_InvalidLinkEndpoints();
        MemoryAnchor storage fromA = _anchors[fromAnchor];
        MemoryAnchor storage toA = _anchors[toAnchor];
        if (fromA.pinnedAtBlock == 0 || toA.pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        if (fromA.deprecated || toA.deprecated) revert MindMaster_AnchorDeprecated();
        if (linkKind >= LINK_SLOTS) linkKind = 0;
        if (linkStrength > MAX_LINK_STRENGTH) linkStrength = MAX_LINK_STRENGTH;
        if (_links[linkId].exists) revert MindMaster_DuplicateLinkId();
        if (totalLinksForged >= MAX_LINKS_TOTAL) revert MindMaster_LinkCapReached();

        uint256 slotIndex = uint256(keccak256(abi.encodePacked(linkId))) % LINK_SLOTS;
        if (_linkSlots[slotIndex].forgedAtBlock != 0) {
            slotIndex = (slotIndex + 1) % LINK_SLOTS;
        }

        _linkSlots[slotIndex] = LinkSlot({
            linkId: linkId,
            slotIndex: uint8(slotIndex),
            forgedAtBlock: block.number,
            configHash: configHash
        });

        _links[linkId] = StoredLink({
            linkId: linkId,
            fromAnchor: fromAnchor,
            toAnchor: toAnchor,
            linkKind: linkKind,
            linkStrength: linkStrength,
            forgedAtBlock: block.number,
            configHash: configHash,
            exists: true
        });
        _linkIdList.push(linkId);
        _outLinkIds[fromAnchor].push(linkId);
        _inLinkIds[toAnchor].push(linkId);
        totalLinksForged += 1;

        emit LinkForged(linkId, fromAnchor, toAnchor, linkKind, linkStrength, block.number);
    }

    // -------------------------------------------------------------------------
    // LINK FORGER: BATCH FORGE
    // -------------------------------------------------------------------------

    function forgeLinksBatch(
        bytes32[] calldata linkIds,
        bytes32[] calldata fromAnchors,
        bytes32[] calldata toAnchors,
        uint8[] calldata linkKinds,
        bytes32[] calldata configHashes
    ) external onlyLinkForger whenNotPaused nonReentrant {
        if (linkIds.length == 0) revert MindMaster_ZeroLength();
        if (linkIds.length > MAX_BATCH_LINK) revert MindMaster_BatchTooLarge();
        if (
            linkIds.length != fromAnchors.length ||
            linkIds.length != toAnchors.length ||
            linkIds.length != linkKinds.length ||
            linkIds.length != configHashes.length
        ) revert MindMaster_ArrayLengthMismatch();

        for (uint256 i = 0; i < linkIds.length; i++) {
            forgeLinkWithStrength(linkIds[i], fromAnchors[i], toAnchors[i], linkKinds[i], 100, configHashes[i]);
        }
        emit LinkForgedBatch(linkIds, msg.sender, linkIds.length);
    }

    // -------------------------------------------------------------------------
    // NODE ORACLE: ADVANCE SYNAPSE
    // -------------------------------------------------------------------------

    function advanceSynapse() external onlyNodeOracle nonReentrant {
        if (block.number < genesisBlock + (currentSynapseEpoch + 1) * SYNAPSE_BLOCKS) {
            revert MindMaster_SynapseWindowNotReached();
        }
        if (currentSynapseEpoch >= MAX_SYNAPSE_EPOCHS) return;
        if (_epochAdvanced[currentSynapseEpoch]) return;

        uint256 prev = currentSynapseEpoch;
        currentSynapseEpoch += 1;
        _epochAdvanced[prev] = true;

        emit SynapseTicked(prev, currentSynapseEpoch, block.number);
    }

    // -------------------------------------------------------------------------
    // NODE ORACLE: STORE RECALL
    // -------------------------------------------------------------------------

    function storeRecall(bytes32 anchorId, bytes32 recallHash) external onlyNodeOracle nonReentrant {
        if (anchorId == bytes32(0)) revert MindMaster_ZeroAnchorId();
        if (recallHash == bytes32(0)) revert MindMaster_ZeroRecallHash();
        MemoryAnchor storage a = _anchors[anchorId];
        if (a.pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        if (a.recallStored) revert MindMaster_RecallAlreadyStored();

        a.recallStored = true;
        _recallHashes[anchorId] = recallHash;

        emit RecallStored(anchorId, recallHash, block.number);
    }

    // -------------------------------------------------------------------------
    // ANYONE: TOP LATTICE (PAYABLE)
    // -------------------------------------------------------------------------

    function topLattice() external payable nonReentrant {
        if (msg.value == 0) return;
        uint256 fee = (msg.value * FEE_BASIS_POINTS) / BASIS_DENOMINATOR;
        uint256 toLattice = msg.value - fee;
        latticeBalance += toLattice;
        if (fee > 0 && feeRecipient != address(0)) {
            accumulatedFees += fee;
        } else {
            latticeBalance += fee;
        }
        emit LatticeTopped(msg.value, msg.sender, latticeBalance);
    }

    // -------------------------------------------------------------------------
    // ANYONE: RECALL COMMITMENT (STAKE PER ANCHOR)
    // -------------------------------------------------------------------------

    function addRecallCommitment(bytes32 anchorId) external payable whenNotPaused nonReentrant {
        if (anchorId == bytes32(0)) revert MindMaster_ZeroAnchorId();
        if (_anchors[anchorId].pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        if (msg.value == 0) revert MindMaster_WithdrawZero();
        _recallCommitments[anchorId][msg.sender] += msg.value;
        _totalCommitmentPerAnchor[anchorId] += msg.value;
        if (_commitmentLockedUntilBlock[anchorId] == 0 || block.number > _commitmentLockedUntilBlock[anchorId]) {
            _commitmentLockedUntilBlock[anchorId] = block.number + COMMITMENT_LOCK_BLOCKS;
        }
        latticeBalance += msg.value;
        emit RecallCommitment(anchorId, msg.sender, msg.value, block.number);
    }

    function withdrawRecallCommitment(bytes32 anchorId) external nonReentrant {
        if (anchorId == bytes32(0)) revert MindMaster_ZeroAnchorId();
        uint256 amount = _recallCommitments[anchorId][msg.sender];
        if (amount == 0) revert MindMaster_NoCommitment();
        if (block.number < _commitmentLockedUntilBlock[anchorId]) revert MindMaster_CommitmentLocked();
        _recallCommitments[anchorId][msg.sender] = 0;
        _totalCommitmentPerAnchor[anchorId] -= amount;
        latticeBalance -= amount;
        (bool ok,) = msg.sender.call{value: amount}("");
        require(ok, "MindMaster: commitment withdraw failed");
        emit RecallCommitmentWithdrawn(anchorId, msg.sender, amount);
    }

    // -------------------------------------------------------------------------
    // VIEW: ANCHOR
    // -------------------------------------------------------------------------

    function getAnchor(bytes32 anchorId) external view returns (
        bytes32 id,
        address pinnedBy,
        uint8 recallTier,
        uint256 synapseEpoch,
        uint256 pinnedAtBlock,
        bytes32 contentHash,
        bool recallStored
    ) {
        MemoryAnchor storage a = _anchors[anchorId];
        if (a.pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        return (
            a.anchorId,
            a.pinnedBy,
            a.recallTier,
            a.synapseEpoch,
            a.pinnedAtBlock,
            a.contentHash,
            a.recallStored
        );
    }

    function getAnchorFull(bytes32 anchorId) external view returns (
        bytes32 id,
        address pinnedBy,
        uint8 recallTier,
        uint256 synapseEpoch,
        uint256 pinnedAtBlock,
        uint256 updatedAtBlock,
        bytes32 contentHash,
        bytes32[4] memory tags,
        bool recallStored,
        bool deprecated,
        uint256 outLinkCount,
        uint256 inLinkCount
    ) {
        MemoryAnchor storage a = _anchors[anchorId];
        if (a.pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        return (
            a.anchorId,
            a.pinnedBy,
            a.recallTier,
            a.synapseEpoch,
            a.pinnedAtBlock,
            a.updatedAtBlock,
            a.contentHash,
            a.tags,
            a.recallStored,
            a.deprecated,
            _outLinkIds[anchorId].length,
            _inLinkIds[anchorId].length
        );
    }

    function getRecallHash(bytes32 anchorId) external view returns (bytes32) {
        return _recallHashes[anchorId];
    }

    function getRecallCommitment(bytes32 anchorId, address account) external view returns (uint256) {
        return _recallCommitments[anchorId][account];
    }

    function commitmentLockedUntil(bytes32 anchorId) external view returns (uint256) {
        return _commitmentLockedUntilBlock[anchorId];
    }

    // -------------------------------------------------------------------------
    // VIEW: LINKS
    // -------------------------------------------------------------------------

    function getLink(bytes32 linkId) external view returns (
        bytes32 id,
        bytes32 fromAnchor,
        bytes32 toAnchor,
        uint8 linkKind,
        uint8 linkStrength,
        uint256 forgedAtBlock,
        bytes32 configHash
    ) {
        StoredLink storage l = _links[linkId];
        if (!l.exists) revert MindMaster_LinkNotFound();
        return (
            l.linkId,
            l.fromAnchor,
            l.toAnchor,
            l.linkKind,
            l.linkStrength,
            l.forgedAtBlock,
            l.configHash
        );
    }

    function getLinksFromAnchor(bytes32 anchorId) external view returns (bytes32[] memory linkIds) {
        return _outLinkIds[anchorId];
    }

    function getLinksToAnchor(bytes32 anchorId) external view returns (bytes32[] memory linkIds) {
        return _inLinkIds[anchorId];
    }

    function linkCount() external view returns (uint256) {
        return _linkIdList.length;
    }

    function linkIdAt(uint256 index) external view returns (bytes32) {
        return _linkIdList[index];
    }

    // -------------------------------------------------------------------------
    // VIEW: ANCHOR LIST / PAGINATION
    // -------------------------------------------------------------------------

    function anchorCount() external view returns (uint256) {
        return _anchorIdList.length;
    }

    function anchorIdAt(uint256 index) external view returns (bytes32) {
        return _anchorIdList[index];
    }

    function getAnchorIdRange(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 total = _anchorIdList.length;
        if (offset >= total) return new bytes32[](0);
        if (offset + limit > total) limit = total - offset;
        ids = new bytes32[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = _anchorIdList[offset + i];
        }
    }

    function getLinkIdRange(uint256 offset, uint256 limit) external view returns (bytes32[] memory ids) {
        uint256 total = _linkIdList.length;
        if (offset >= total) return new bytes32[](0);
        if (offset + limit > total) limit = total - offset;
        ids = new bytes32[](limit);
        for (uint256 i = 0; i < limit; i++) {
            ids[i] = _linkIdList[offset + i];
        }
    }

    function anchorsInEpoch(uint256 epoch) external view returns (uint256) {
        return _anchorsInEpoch[epoch];
    }

    // -------------------------------------------------------------------------
    // VIEW: LATTICE STATS
    // -------------------------------------------------------------------------

    function getLatticeStats() external view returns (LatticeStats memory stats) {
        stats = LatticeStats({
            totalAnchors: _anchorIdList.length,
            totalLinks: _linkIdList.length,
            currentEpoch: currentSynapseEpoch,
            genesisBlock: genesisBlock,
            balance: latticeBalance,
            accumulatedFees: accumulatedFees,
            isPaused: paused
        });
    }

    function getAnchorsByEpoch(uint256 epoch) external view returns (bytes32[] memory anchorIds) {
        uint256 n = _anchorIdList.length;
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            if (_anchors[_anchorIdList[i]].synapseEpoch == epoch) count++;
        }
        anchorIds = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < n; i++) {
            if (_anchors[_anchorIdList[i]].synapseEpoch == epoch) {
                anchorIds[count] = _anchorIdList[i];
                count++;
            }
        }
    }

    function getAnchorIdsByTier(uint8 tier) external view returns (bytes32[] memory anchorIds) {
        if (tier > MAX_RECALL_TIER) return new bytes32[](0);
        uint256 n = _anchorIdList.length;
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            if (_anchors[_anchorIdList[i]].recallTier == tier) count++;
        }
        anchorIds = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < n; i++) {
            if (_anchors[_anchorIdList[i]].recallTier == tier) {
                anchorIds[count] = _anchorIdList[i];
                count++;
            }
        }
    }

    function anchorExists(bytes32 anchorId) external view returns (bool) {
        return _anchors[anchorId].pinnedAtBlock != 0;
    }

    function linkExists(bytes32 linkId) external view returns (bool) {
        return _links[linkId].exists;
    }

    function isEpochAdvanced(uint256 epoch) external view returns (bool) {
        return _epochAdvanced[epoch];
    }

    function canAdvanceSynapse() external view returns (bool) {
        if (currentSynapseEpoch >= MAX_SYNAPSE_EPOCHS) return false;
        if (_epochAdvanced[currentSynapseEpoch]) return false;
        return block.number >= genesisBlock + (currentSynapseEpoch + 1) * SYNAPSE_BLOCKS;
    }

    function nextSynapseBlock() external view returns (uint256) {
        return genesisBlock + (currentSynapseEpoch + 1) * SYNAPSE_BLOCKS;
    }

    // -------------------------------------------------------------------------
    // VIEW: BATCH ANCHOR / LINK DATA
    // -------------------------------------------------------------------------

    /// @notice Fetch multiple anchors by id; skips missing (returns empty struct for missing).
    function getAnchorsBatch(bytes32[] calldata anchorIds)
        external
        view
        returns (
            address[] memory pinnedBys,
            uint8[] memory recallTiers,
            uint256[] memory pinnedAtBlocks,
            bytes32[] memory contentHashes,
            bool[] memory recallStoreds,
            bool[] memory deprecateds
        )
    {
        uint256 n = anchorIds.length;
        pinnedBys = new address[](n);
        recallTiers = new uint8[](n);
        pinnedAtBlocks = new uint256[](n);
        contentHashes = new bytes32[](n);
        recallStoreds = new bool[](n);
        deprecateds = new bool[](n);
        for (uint256 i = 0; i < n; i++) {
            MemoryAnchor storage a = _anchors[anchorIds[i]];
            if (a.pinnedAtBlock != 0) {
                pinnedBys[i] = a.pinnedBy;
                recallTiers[i] = a.recallTier;
                pinnedAtBlocks[i] = a.pinnedAtBlock;
                contentHashes[i] = a.contentHash;
                recallStoreds[i] = a.recallStored;
                deprecateds[i] = a.deprecated;
            }
        }
    }

    /// @notice Fetch multiple links by id; skips missing.
    function getLinksBatch(bytes32[] calldata linkIds)
        external
        view
        returns (
            bytes32[] memory fromAnchors,
            bytes32[] memory toAnchors,
            uint8[] memory linkKinds,
            uint8[] memory linkStrengths,
            uint256[] memory forgedAtBlocks
        )
    {
        uint256 n = linkIds.length;
        fromAnchors = new bytes32[](n);
        toAnchors = new bytes32[](n);
        linkKinds = new uint8[](n);
        linkStrengths = new uint8[](n);
        forgedAtBlocks = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            StoredLink storage l = _links[linkIds[i]];
            if (l.exists) {
                fromAnchors[i] = l.fromAnchor;
                toAnchors[i] = l.toAnchor;
                linkKinds[i] = l.linkKind;
                linkStrengths[i] = l.linkStrength;
                forgedAtBlocks[i] = l.forgedAtBlock;
            }
        }
    }

    // -------------------------------------------------------------------------
    // VIEW: EPOCH & TIER STATS
    // -------------------------------------------------------------------------

    struct EpochInfo {
        uint256 epoch;
        uint256 anchorsInEpoch;
        bool advanced;
        uint256 blockStart;
        uint256 blockEnd;
    }

    function getEpochInfo(uint256 epoch) external view returns (EpochInfo memory info) {
        info.epoch = epoch;
        info.anchorsInEpoch = _anchorsInEpoch[epoch];
        info.advanced = _epochAdvanced[epoch];
        info.blockStart = genesisBlock + epoch * SYNAPSE_BLOCKS;
        info.blockEnd = genesisBlock + (epoch + 1) * SYNAPSE_BLOCKS - 1;
    }

    function getTierCounts() external view returns (uint256[8] memory counts) {
        uint256 n = _anchorIdList.length;
        for (uint256 i = 0; i < n; i++) {
            uint8 t = _anchors[_anchorIdList[i]].recallTier;
            if (t <= MAX_RECALL_TIER) counts[t]++;
        }
    }

    /// @notice Anchors that have a given tag in any of the four tag slots.
    function getAnchorIdsWithTag(bytes32 tag) external view returns (bytes32[] memory anchorIds) {
        uint256 n = _anchorIdList.length;
        uint256 count = 0;
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = _anchorIdList[i];
            MemoryAnchor storage a = _anchors[id];
            for (uint256 j = 0; j < MAX_TAGS_PER_ANCHOR; j++) {
                if (a.tags[j] == tag) {
                    count++;
                    break;
                }
            }
        }
        anchorIds = new bytes32[](count);
        count = 0;
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = _anchorIdList[i];
            MemoryAnchor storage a = _anchors[id];
            for (uint256 j = 0; j < MAX_TAGS_PER_ANCHOR; j++) {
                if (a.tags[j] == tag) {
                    anchorIds[count] = id;
                    count++;
                    break;
                }
            }
        }
    }

    /// @notice Total recall commitment (all accounts) for an anchor.
    function totalCommitmentForAnchor(bytes32 anchorId) external view returns (uint256) {
        return _totalCommitmentPerAnchor[anchorId];
    }

    // -------------------------------------------------------------------------
    // VIEW: LATTICE SNAPSHOT (LARGE READ FOR UIs)
    // -------------------------------------------------------------------------

    struct LatticeSnapshot {
        LatticeStats stats;
        bytes32[] anchorIds;
        bytes32[] linkIds;
        uint256 blockNumber;
    }

    function getLatticeSnapshot(uint256 maxAnchors, uint256 maxLinks)
        external
        view
        returns (LatticeSnapshot memory snapshot)
    {
        snapshot.stats = LatticeStats({
            totalAnchors: _anchorIdList.length,
            totalLinks: _linkIdList.length,
            currentEpoch: currentSynapseEpoch,
            genesisBlock: genesisBlock,
            balance: latticeBalance,
            accumulatedFees: accumulatedFees,
            isPaused: paused
        });
        uint256 na = _anchorIdList.length;
        uint256 nl = _linkIdList.length;
        if (maxAnchors > na) maxAnchors = na;
        if (maxLinks > nl) maxLinks = nl;
        snapshot.anchorIds = new bytes32[](maxAnchors);
        snapshot.linkIds = new bytes32[](maxLinks);
        for (uint256 i = 0; i < maxAnchors; i++) snapshot.anchorIds[i] = _anchorIdList[i];
        for (uint256 i = 0; i < maxLinks; i++) snapshot.linkIds[i] = _linkIdList[i];
        snapshot.blockNumber = block.number;
    }

    // -------------------------------------------------------------------------
    // VIEW: RECALL / CONTENT HELPERS
    // -------------------------------------------------------------------------

    function getAnchorContentHash(bytes32 anchorId) external view returns (bytes32) {
        return _anchors[anchorId].contentHash;
    }

    function getAnchorTags(bytes32 anchorId) external view returns (bytes32[4] memory) {
        if (_anchors[anchorId].pinnedAtBlock == 0) revert MindMaster_AnchorNotFound();
        return _anchors[anchorId].tags;
    }

    function isAnchorDeprecated(bytes32 anchorId) external view returns (bool) {
        return _anchors[anchorId].deprecated;
    }

    function hasRecall(bytes32 anchorId) external view returns (bool) {
        return _anchors[anchorId].recallStored;
    }

    // -------------------------------------------------------------------------
    // VIEW: CONFIG / CONSTANTS EXPOSED FOR FRONTS
    // -------------------------------------------------------------------------

    function getLatticeDomain() external pure returns (bytes32) {
        return LATTICE_DOMAIN;
    }

    function getMaxBatchPin() external pure returns (uint256) {
        return MAX_BATCH_PIN;
    }

    function getMaxBatchLink() external pure returns (uint256) {
        return MAX_BATCH_LINK;
    }

    function getMaxLinksTotal() external pure returns (uint256) {
        return MAX_LINKS_TOTAL;
    }

    function getCommitmentLockBlocks() external pure returns (uint256) {
        return COMMITMENT_LOCK_BLOCKS;
    }

    function getFeeBasisPoints() external pure returns (uint256) {
        return FEE_BASIS_POINTS;
    }

    function getFeeRecipient() external view returns (address) {
        return feeRecipient;
    }

    // -------------------------------------------------------------------------
    // VIEW: ROLE HELPERS
    // -------------------------------------------------------------------------

    function isGovernor(address account) external view returns (bool) {
        return account == governor;
    }

    function isLinkForger(address account) external view returns (bool) {
        return account == linkForger;
    }

    function isNodeOracle(address account) external view returns (bool) {
        return account == nodeOracle;
    }

    function getRoles() external view returns (address _governor, address _linkForger, address _nodeOracle) {
        return (governor, linkForger, nodeOracle);
    }

    // -------------------------------------------------------------------------
    // RECEIVE ETHER (OPTIONAL TOP-UP)
    // -------------------------------------------------------------------------

    receive() external payable {
        latticeBalance += msg.value;
        emit LatticeTopped(msg.value, msg.sender, latticeBalance);
    }

    // -------------------------------------------------------------------------
    // VIEW: ADDITIONAL LATTICE QUERIES
    // -------------------------------------------------------------------------

    /// @notice Returns the number of anchors that have recall stored.
    function anchorsWithRecallCount() external view returns (uint256 count) {
        uint256 n = _anchorIdList.length;
        for (uint256 i = 0; i < n; i++) {
            if (_anchors[_anchorIdList[i]].recallStored) count++;
        }
    }

    /// @notice Returns the number of deprecated anchors.
    function deprecatedAnchorsCount() external view returns (uint256 count) {
        uint256 n = _anchorIdList.length;
        for (uint256 i = 0; i < n; i++) {
            if (_anchors[_anchorIdList[i]].deprecated) count++;
        }
    }

    /// @notice Check if both anchors exist and a link from -> to exists (any link).
    function hasLinkBetween(bytes32 fromAnchor, bytes32 toAnchor) external view returns (bool) {
        bytes32[] storage outIds = _outLinkIds[fromAnchor];
        for (uint256 i = 0; i < outIds.length; i++) {
            if (_links[outIds[i]].toAnchor == toAnchor) return true;
        }
        return false;
    }

    /// @notice Get link id between two anchors (first match); returns bytes32(0) if none.
    function getLinkBetween(bytes32 fromAnchor, bytes32 toAnchor) external view returns (bytes32 linkId) {
        bytes32[] storage outIds = _outLinkIds[fromAnchor];
        for (uint256 i = 0; i < outIds.length; i++) {
            if (_links[outIds[i]].toAnchor == toAnchor) return outIds[i];
        }
        return bytes32(0);
    }

    /// @notice Sum of all link strengths for links originating from an anchor.
    function outboundStrength(bytes32 anchorId) external view returns (uint256 sum) {
        bytes32[] storage outIds = _outLinkIds[anchorId];
        for (uint256 i = 0; i < outIds.length; i++) {
            sum += _links[outIds[i]].linkStrength;
        }
    }

    /// @notice Sum of all link strengths for links pointing to an anchor.
    function inboundStrength(bytes32 anchorId) external view returns (uint256 sum) {
        bytes32[] storage inIds = _inLinkIds[anchorId];
        for (uint256 i = 0; i < inIds.length; i++) {
            sum += _links[inIds[i]].linkStrength;
        }
    }

    /// @notice Block number at which the given epoch starts.
    function epochBlockStart(uint256 epoch) external view returns (uint256) {
        return genesisBlock + epoch * SYNAPSE_BLOCKS;
    }

    /// @notice Block number at which the given epoch ends (inclusive range end).
    function epochBlockEnd(uint256 epoch) external view returns (uint256) {
        return genesisBlock + (epoch + 1) * SYNAPSE_BLOCKS - 1;
    }
