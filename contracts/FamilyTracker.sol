// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title FamilyTracker (V4 — UUPS Upgradeable)
 * @notice CodeDNA 血缘追踪 — 家族根节点、人口统计、近亲检查
 *
 * Audit fixes:
 *   FT-P1: isDirectRelative upgraded to isCloseRelative (familyRoot + shared parents check)
 *   FT-P2: registerBirth — duplicate registration protection (already exists)
 *   FT-P3: removeAgent clears registered, familyRoot, parents
 *   FT-P4: familyRoot check added to isDirectRelative (same family = relative)
 *   FT-P5: familyHeadcount uses uint256 key instead of bytes32 for simplicity
 */
contract FamilyTracker is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant NO_PARENT = type(uint256).max;

    /* ========== STRUCTS ========== */

    struct Parents {
        uint256 fatherId;
        uint256 motherId;
    }

    /* ========== STATE ========== */

    address public gameContract;
    address public deathContract; // Fix: CRITICAL-1 — DeathEngine needs removeAgent

    mapping(uint256 => Parents) public parents;
    mapping(uint256 => uint256) public familyRoot;
    // Fix: FT-P5 — use uint256 key directly instead of bytes32
    mapping(uint256 => uint256) public familyHeadcount;
    mapping(uint256 => bool) public registered;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event GenesisRegistered(uint256 indexed tokenId, uint256 familyRootId);
    event BirthRegistered(uint256 indexed childId, uint256 fatherId, uint256 motherId, uint256 familyRootId);
    event AgentRemoved(uint256 indexed tokenId, uint256 familyRootId);

    /* ========== ERRORS ========== */

    error OnlyGame();
    error AlreadyRegistered(uint256 tokenId);
    error NotRegistered(uint256 tokenId);
    error ZeroAddress();

    /* ========== MODIFIER ========== */

    // Fix: CRITICAL-1 — allow deathContract to call removeAgent
    modifier onlyGame() {
        if (msg.sender != gameContract && msg.sender != deathContract) revert OnlyGame();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(address _gameContract, address _owner) external initializer {
        if (_gameContract == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        gameContract = _gameContract;
    }

    /* ========== UPGRADE CONTROL ========== */

    function _authorizeUpgrade(address) internal override onlyOwner {
        require(!upgradeRenounced, "Upgrade renounced");
    }

    function renounceUpgradeability() external onlyOwner {
        upgradeRenounced = true;
    }

    /* ========== ADMIN ========== */

    function setGameContract(address _gameContract) external onlyOwner {
        if (_gameContract == address(0)) revert ZeroAddress();
        gameContract = _gameContract;
    }

    // Fix: CRITICAL-1
    function setDeathContract(address _death) external onlyOwner {
        require(_death != address(0), "zero addr");
        deathContract = _death;
    }

    /* ========== REGISTRATION ========== */

    function registerGenesis(uint256 tokenId) external onlyGame {
        if (registered[tokenId]) revert AlreadyRegistered(tokenId);

        registered[tokenId] = true;
        familyRoot[tokenId] = tokenId;

        parents[tokenId] = Parents({
            fatherId: NO_PARENT,
            motherId: NO_PARENT
        });

        // Fix: FT-P5 — direct uint256 key
        familyHeadcount[tokenId]++;

        emit GenesisRegistered(tokenId, tokenId);
    }

    function registerBirth(uint256 childId, uint256 fatherId, uint256 motherId) external onlyGame {
        if (registered[childId]) revert AlreadyRegistered(childId); // Fix: FT-P2
        if (!registered[fatherId]) revert NotRegistered(fatherId);
        if (!registered[motherId]) revert NotRegistered(motherId);

        registered[childId] = true;

        parents[childId] = Parents({
            fatherId: fatherId,
            motherId: motherId
        });

        // Fix: V4-M3 — inherit smaller familyRoot for symmetry (deterministic)
        uint256 fRoot = familyRoot[fatherId];
        uint256 mRoot = familyRoot[motherId];
        uint256 rootId = fRoot < mRoot ? fRoot : mRoot;
        familyRoot[childId] = rootId;

        // Fix: FT-P5 — direct uint256 key
        familyHeadcount[rootId]++;

        emit BirthRegistered(childId, fatherId, motherId, rootId);
    }

    // Fix: FT-P3 — removeAgent clears all state
    function removeAgent(uint256 tokenId) external onlyGame {
        if (!registered[tokenId]) revert NotRegistered(tokenId);

        uint256 rootId = familyRoot[tokenId];
        if (familyHeadcount[rootId] > 0) {
            familyHeadcount[rootId]--;
        }

        // Fix: FT-P3 — full state cleanup
        registered[tokenId] = false;
        delete familyRoot[tokenId];
        delete parents[tokenId];

        emit AgentRemoved(tokenId, rootId);
    }

    /* ========== QUERIES ========== */

    /**
     * @notice Enhanced relative check — 6 direct relations + familyRoot + shared parents
     * Fix: FT-P1, FT-P4 — covers 2-layer direct + same familyRoot + shared parent check
     */
    function isDirectRelative(uint256 a, uint256 b) public view returns (bool) {
        Parents storage pa = parents[a];
        Parents storage pb = parents[b];

        // 1-4: Direct parent-child
        if (pa.fatherId != NO_PARENT && pa.fatherId == b) return true;
        if (pa.motherId != NO_PARENT && pa.motherId == b) return true;
        if (pb.fatherId != NO_PARENT && pb.fatherId == a) return true;
        if (pb.motherId != NO_PARENT && pb.motherId == a) return true;

        // 5-6: Shared parents (siblings)
        if (pa.fatherId != NO_PARENT && pa.fatherId == pb.fatherId) return true;
        if (pa.motherId != NO_PARENT && pa.motherId == pb.motherId) return true;

        // Fix: FT-P1 — also check grandparent level
        // a's grandparent is b (or vice versa)
        if (pa.fatherId != NO_PARENT) {
            Parents storage gpa = parents[pa.fatherId];
            if (gpa.fatherId != NO_PARENT && gpa.fatherId == b) return true;
            if (gpa.motherId != NO_PARENT && gpa.motherId == b) return true;
        }
        if (pa.motherId != NO_PARENT) {
            Parents storage gma = parents[pa.motherId];
            if (gma.fatherId != NO_PARENT && gma.fatherId == b) return true;
            if (gma.motherId != NO_PARENT && gma.motherId == b) return true;
        }
        if (pb.fatherId != NO_PARENT) {
            Parents storage gpb = parents[pb.fatherId];
            if (gpb.fatherId != NO_PARENT && gpb.fatherId == a) return true;
            if (gpb.motherId != NO_PARENT && gpb.motherId == a) return true;
        }
        if (pb.motherId != NO_PARENT) {
            Parents storage gmb = parents[pb.motherId];
            if (gmb.fatherId != NO_PARENT && gmb.fatherId == a) return true;
            if (gmb.motherId != NO_PARENT && gmb.motherId == a) return true;
        }

        // Fix: V4-C1 — removed familyRoot same-clan check (was too broad, blocked all reproduction within a family)
        // familyRoot check moved to separate isSameClan() for non-breeding queries

        return false;
    }

    /// @notice Dedicated parent-child check for teach() — Fix: V4-M1
    function isParentChild(uint256 parentId, uint256 childId) public view returns (bool) {
        Parents storage pc = parents[childId];
        return (pc.fatherId == parentId || pc.motherId == parentId);
    }

    /// @notice Same clan check (separate from reproduction) — Fix: V4-C1
    function isSameClan(uint256 a, uint256 b) public view returns (bool) {
        if (!registered[a] || !registered[b]) return false;
        return familyRoot[a] == familyRoot[b];
    }

    // Fix: FT-P5 — direct uint256 key
    function getFamilyHeadcount(uint256 rootId) external view returns (uint256) {
        return familyHeadcount[rootId];
    }

    function getParents(uint256 tokenId) external view returns (uint256 fatherId, uint256 motherId) {
        Parents storage p = parents[tokenId];
        return (p.fatherId, p.motherId);
    }
}
