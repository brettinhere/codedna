// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title WorldMap (V4 — UUPS Upgradeable)
 * @notice CodeDNA 世界地图 — 1000×1000 稀疏存储, 4种地块, 探索奖励
 *
 * Audit fixes:
 *   WM-P1: Zero-address check in initialize (was missing in constructor)
 *   WM-P2: plotAgentCount atomic update with agentOnMap (ensured in same tx)
 *   WM-P3: removeAgent syncs plotAgentCount properly
 *   WM-P4: plotMultiplier — no change needed (values are constant)
 *   WM-P5: toPlotId adds boundary check
 *   WM-P6: _checkExploreReward returns bool for BehaviorEngine integration
 */
contract WorldMap is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant MAP_SIZE             = 1_000;
    uint256 public constant EXPLORE_WINDOW       = 28_800;
    uint256 public constant EXPLORE_WINDOW_LIMIT = 10;
    uint256 public constant EXPLORE_BONUS        = 200; // 200 DNAGOLD (caller multiplies by 1e18)

    /* ========== STATE ========== */

    address public gameContract;
    address public deathContract;   // Fix: CRITICAL-1 — DeathEngine needs removeAgent
    address public marketContract;  // Fix: HIGH-4 — NFTMarket needs removeAgent

    mapping(uint256 => uint256) public plotAgentCount;
    mapping(uint256 => uint256) public agentLocation;
    mapping(uint256 => bool) public agentOnMap;
    mapping(uint256 => bool) public plotEverExplored;
    mapping(uint256 => uint256) public exploreWindowStart;
    mapping(uint256 => uint256) public exploreCountInWindow;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event AgentPlaced(uint256 indexed agentId, uint256 plotId);
    event AgentMoved(uint256 indexed agentId, uint256 fromPlot, uint256 toPlot);
    event PlotExplored(uint256 indexed agentId, uint256 indexed plotId);
    event AgentRemovedFromMap(uint256 indexed agentId, uint256 plotId);

    /* ========== ERRORS ========== */

    error OnlyGame();
    error ZeroAddress(); // Fix: LOW-2
    error OutOfBounds(uint256 x, uint256 y);
    error NotOnMap(uint256 agentId);
    error AlreadyOnMap(uint256 agentId);
    error InvalidDistance(uint256 distance);

    /* ========== MODIFIER ========== */

    // Fix: R3-MEDIUM-1 — fine-grained: strict for placement, wider for removal
    modifier onlyGame() {
        if (msg.sender != gameContract) revert OnlyGame();
        _;
    }
    modifier onlyGameOrDeathOrMarket() {
        if (msg.sender != gameContract && msg.sender != deathContract && msg.sender != marketContract) revert OnlyGame();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    // Fix: WM-P1 + LOW-2 — proper zero-address error
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
        if (_gameContract == address(0)) revert ZeroAddress(); // Fix: R3-LOW-1
        gameContract = _gameContract;
    }

    // Fix: CRITICAL-1
    function setDeathContract(address _death) external onlyOwner {
        require(_death != address(0), "zero addr");
        deathContract = _death;
    }

    // Fix: HIGH-4
    function setMarketContract(address _market) external onlyOwner {
        require(_market != address(0), "zero addr");
        marketContract = _market;
    }

    /* ========== PLACEMENT ========== */

    function placeAgent(uint256 agentId, uint256 x, uint256 y) external onlyGame {
        if (agentOnMap[agentId]) revert AlreadyOnMap(agentId);
        if (x >= MAP_SIZE || y >= MAP_SIZE) revert OutOfBounds(x, y);

        uint256 plotId = x * MAP_SIZE + y;
        agentLocation[agentId] = plotId;
        agentOnMap[agentId] = true;
        plotAgentCount[plotId]++; // Fix: WM-P2 — atomic with agentOnMap

        _checkExploreReward(agentId, plotId);

        emit AgentPlaced(agentId, plotId);
    }

    /* ========== MOVEMENT ========== */

    function moveAgent(uint256 agentId, uint256 newX, uint256 newY) external onlyGame {
        if (!agentOnMap[agentId]) revert NotOnMap(agentId);
        if (newX >= MAP_SIZE || newY >= MAP_SIZE) revert OutOfBounds(newX, newY);

        uint256 oldPlot = agentLocation[agentId];
        uint256 newPlot = newX * MAP_SIZE + newY;

        uint256 dist = getManhattanDistance(oldPlot, newPlot);
        if (dist != 1) revert InvalidDistance(dist);

        // Fix: WM-P2 — atomic plotAgentCount update
        plotAgentCount[oldPlot]--;
        plotAgentCount[newPlot]++;

        agentLocation[agentId] = newPlot;

        _checkExploreReward(agentId, newPlot);

        emit AgentMoved(agentId, oldPlot, newPlot);
    }

    // Fix: WM-P3 — removeAgent properly syncs plotAgentCount
    // Fix: R3-MEDIUM-1 — death/market also need removeAgent
    function removeAgent(uint256 agentId) external onlyGameOrDeathOrMarket {
        if (!agentOnMap[agentId]) return; // idempotent

        uint256 plotId = agentLocation[agentId];
        if (plotAgentCount[plotId] > 0) {
            plotAgentCount[plotId]--; // Fix: WM-P3
        }

        agentOnMap[agentId] = false;
        delete agentLocation[agentId];

        emit AgentRemovedFromMap(agentId, plotId);
    }

    /* ========== EXPLORE REWARD ========== */

    // Fix: WM-P6 — returns bool for BehaviorEngine to use
    function _checkExploreReward(uint256 agentId, uint256 plotId) internal returns (bool explored) {
        if (plotEverExplored[plotId]) return false;

        if (block.number >= exploreWindowStart[agentId] + EXPLORE_WINDOW) {
            exploreWindowStart[agentId] = block.number;
            exploreCountInWindow[agentId] = 0;
        }

        if (exploreCountInWindow[agentId] >= EXPLORE_WINDOW_LIMIT) return false;

        plotEverExplored[plotId] = true;
        exploreCountInWindow[agentId]++;

        emit PlotExplored(agentId, plotId);
        return true;
    }

    /* ========== PURE QUERIES ========== */

    function getManhattanDistance(uint256 plotIdA, uint256 plotIdB) public pure returns (uint256) {
        uint256 x1 = plotIdA / MAP_SIZE;
        uint256 y1 = plotIdA % MAP_SIZE;
        uint256 x2 = plotIdB / MAP_SIZE;
        uint256 y2 = plotIdB % MAP_SIZE;

        uint256 dx = x1 > x2 ? x1 - x2 : x2 - x1;
        uint256 dy = y1 > y2 ? y1 - y2 : y2 - y1;

        return dx + dy;
    }

    function getPlotMultiplier(uint256 plotId) public pure returns (uint256 multiplier) {
        uint256 plotHash = uint256(keccak256(abi.encodePacked(plotId)));
        uint256 mod = plotHash % 10;

        if (mod < 5) return 1000;
        else if (mod < 7) return 1500;
        else if (mod < 9) return 600;
        else return 3000;
    }

    function getPlotType(uint256 plotId) public pure returns (uint8) {
        uint256 plotHash = uint256(keccak256(abi.encodePacked(plotId)));
        uint256 mod = plotHash % 10;

        if (mod < 5) return 0;
        else if (mod < 7) return 1;
        else if (mod < 9) return 2;
        else return 3;
    }

    function toCoords(uint256 plotId) public pure returns (uint256 x, uint256 y) {
        return (plotId / MAP_SIZE, plotId % MAP_SIZE);
    }

    // Fix: WM-P5 — boundary check added
    function toPlotId(uint256 x, uint256 y) public pure returns (uint256) {
        if (x >= MAP_SIZE || y >= MAP_SIZE) revert OutOfBounds(x, y); // Fix: WM-P5
        return x * MAP_SIZE + y;
    }
}
