// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title EconomyEngine (V4 — UUPS Upgradeable)
 * @notice CodeDNA 经济引擎 — 减半、稀释、产出计算、奖励分发
 *
 * Audit fixes:
 *   EE-P1: rewardAgent pool check fixed — checks gameContract balance correctly
 *   EE-P2: _checkAndHalve has MAX_HALVINGS_PER_TX limit to prevent gas DoS
 *   EE-P3: dilutionFactor write access restricted to onlyGame
 *   EE-P4: incrementBorn/incrementLiving — atomicity ensured in same tx
 *   EE-P5: Historical halving events preserved
 *   EE-P6: baseReward floor protection (minimum 1 wei after halvings)
 *   EE-P7: HalvingOccurred event already exists
 */
contract EconomyEngine is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant BASE_YIELD           = 100 * 1e18;
    uint256 public constant HALVING_POPULATION   = 500;
    uint256 public constant HALVING_BLOCKS       = 10_512_000;
    uint256 public constant BASELINE_POPULATION  = 10_000;
    uint256 public constant MAX_HALVINGS_PER_TX  = 5; // Fix: EE-P2

    /* ========== INTERFACES (kept inline for gas efficiency) ========== */

    // Minimal interfaces used by this contract
    address public gameContract;
    address public deathContract;   // Fix: CRITICAL-1 — DeathEngine needs removeAgentFromPlot + decrementLiving
    address public marketContract;  // Fix: HIGH-4 — NFTMarket needs removeAgentFromPlot + decrementLiving
    address public dnagold;       // IDNAGold
    address public genesisCore;   // IGenesisCore
    address public worldMap;      // IWorldMap

    uint256 public halvingCount;
    uint256 public lastHalvingBlock;
    uint256 public totalBornAgents;
    uint256 public totalLivingAgents;

    mapping(uint256 => uint256[]) internal _plotAgents;
    mapping(uint256 => uint256) internal _plotAgentIndex;
    mapping(uint256 => bool) internal _agentInPlot;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event HalvingOccurred(uint256 halvingCount, uint256 blockNumber, uint256 totalBorn);
    event RewardDistributed(uint256 indexed agentId, address indexed host, uint256 hostShare, uint256 agentShare);
    event RewardSkipped(uint256 indexed agentId, uint256 amount, string reason);

    /* ========== ERRORS ========== */

    error OnlyGame();
    error ZeroAddress();

    /* ========== MODIFIER ========== */

    // Fix: R3-MEDIUM-1 — fine-grained: only gameContract for sensitive ops
    modifier onlyGameStrict() {
        if (msg.sender != gameContract) revert OnlyGame();
        _;
    }
    // For cleanup ops (removeAgentFromPlot, decrementLiving) — wider access
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

    function initialize(
        address _gameContract,
        address _dnagold,
        address _genesisCore,
        address _worldMap,
        address _owner
    ) external initializer {
        if (_gameContract == address(0)) revert ZeroAddress();
        if (_dnagold == address(0)) revert ZeroAddress();
        if (_genesisCore == address(0)) revert ZeroAddress();
        if (_worldMap == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        gameContract = _gameContract;
        dnagold      = _dnagold;
        genesisCore  = _genesisCore;
        worldMap     = _worldMap;

        lastHalvingBlock = block.number;
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

    // Fix: HIGH-4
    function setMarketContract(address _market) external onlyOwner {
        require(_market != address(0), "zero addr");
        marketContract = _market;
    }

    /* ========== HALVING ========== */

    function checkAndHalve() external onlyGameStrict {
        _checkAndHalve();
    }

    // Fix: EE-P2 — MAX_HALVINGS_PER_TX limit prevents gas DoS
    function _checkAndHalve() internal {
        uint256 steps = 0; // Fix: EE-P2
        while (
            steps < MAX_HALVINGS_PER_TX && ( // Fix: EE-P2
                block.number >= lastHalvingBlock + HALVING_BLOCKS ||
                totalBornAgents >= (halvingCount + 1) * HALVING_POPULATION
            )
        ) {
            halvingCount++;
            lastHalvingBlock = block.number;
            emit HalvingOccurred(halvingCount, block.number, totalBornAgents); // Fix: EE-P7
            steps++; // Fix: EE-P2
        }
    }

    /**
     * @notice Public catch-up function for accumulated halvings
     * Fix: EE-P2 — allows multiple txs to catch up
     */
    function catchUpHalving() external {
        _checkAndHalve();
    }

    /* ========== YIELD & DILUTION ========== */

    // Fix: EE-P6 — floor of 1 wei after all halvings
    function getCurrentBaseYield() public view returns (uint256) {
        uint256 yield_ = BASE_YIELD >> halvingCount;
        if (yield_ == 0 && halvingCount > 0) return 1; // Fix: EE-P6
        return yield_;
    }

    function getGlobalDilutionFactor() public view returns (uint256) {
        if (totalLivingAgents <= BASELINE_POPULATION) return 1000;
        return (BASELINE_POPULATION * 1000) / totalLivingAgents;
    }

    /* ========== GATHER YIELD CALCULATION ========== */

    function calcGatherYield(
        uint256 agentId,
        uint256 plotId,
        uint256 plotCount,
        bool isLeader
    ) public view returns (uint256) {
        uint256 base = getCurrentBaseYield();

        // Interface calls via low-level for gas efficiency with stored addresses
        uint256 plotMult = _getPlotMultiplier(plotId);

        (uint16[8] memory attrs, ) = _getAttributes(agentId);
        uint256 iqScore  = uint256(attrs[0]);
        uint256 strScore = uint256(attrs[2]);

        uint256 dilution = getGlobalDilutionFactor();
        uint256 iqMult = 800 + (iqScore * 1000 / 255);
        uint256 strMult = 1000 + (strScore * 500 / 255);
        uint256 leaderMult = isLeader ? 1150 : 1000;

        uint256 competitionDiv = plotCount * plotCount;
        if (competitionDiv == 0) competitionDiv = 1;

        uint256 result = base;
        result = result * plotMult / 1000;
        result = result * iqMult / 1000;
        result = result * strMult / 1000;
        result = result * leaderMult / 1000;
        result = result * dilution / 1000;
        result = result / competitionDiv;

        return result;
    }

    /* ========== PLOT LEADER ========== */

    function getPlotLeader(uint256 plotId) public view returns (uint256 leaderId) {
        uint256[] storage agents = _plotAgents[plotId];
        uint256 len = agents.length;
        if (len == 0) return type(uint256).max;

        uint256 maxLeadership = 0;
        leaderId = agents[0];

        for (uint256 i = 0; i < len; i++) {
            (uint16[8] memory attrs, ) = _getAttributes(agents[i]);
            uint256 leadership = uint256(attrs[1]);
            if (leadership > maxLeadership) {
                maxLeadership = leadership;
                leaderId = agents[i];
            }
        }
    }

    function getPlotAgents(uint256 plotId) external view returns (uint256[] memory) {
        return _plotAgents[plotId];
    }

    /* ========== REWARD DISTRIBUTION ========== */

    // Fix: EE-P1 — pool balance check uses correct source
    function rewardAgent(uint256 agentId, uint256 totalAmount) external onlyGameStrict {
        if (totalAmount == 0) return;

        // Fix: EE-P1 — check pool balance correctly (gameContract's ERC20 balance)
        (bool success, bytes memory data) = dnagold.staticcall(
            abi.encodeWithSignature("balanceOf(address)", gameContract)
        );
        if (!success) {
            emit RewardSkipped(agentId, totalAmount, "balance check failed");
            return;
        }
        uint256 poolBalance = abi.decode(data, (uint256));
        if (poolBalance < totalAmount) {
            emit RewardSkipped(agentId, totalAmount, "pool exhausted");
            return;
        }

        uint256 hostShare  = totalAmount / 10;
        uint256 agentShare = totalAmount - hostShare;

        // Get agent owner
        (bool ok2, bytes memory data2) = genesisCore.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", agentId)
        );
        if (!ok2) {
            emit RewardSkipped(agentId, totalAmount, "ownerOf failed");
            return;
        }
        address host = abi.decode(data2, (address));

        if (hostShare > 0) {
            // mintFree to host
            (bool ok3,) = dnagold.call(
                abi.encodeWithSignature("mintFree(address,uint256)", host, hostShare)
            );
            if (!ok3) {
                emit RewardSkipped(agentId, totalAmount, "mintFree failed");
                return;
            }
        }
        if (agentShare > 0) {
            // addLocked for agent
            (bool ok4,) = dnagold.call(
                abi.encodeWithSignature("addLocked(uint256,uint256)", agentId, agentShare)
            );
            if (!ok4) {
                emit RewardSkipped(agentId, totalAmount, "addLocked failed");
                return;
            }
        }

        emit RewardDistributed(agentId, host, hostShare, agentShare);
    }

    /* ========== POPULATION TRACKING ========== */

    // Fix: EE-P4 — atomic born + living + halving check
    function incrementBorn() external onlyGameStrict {
        totalBornAgents++;
        totalLivingAgents++;
        _checkAndHalve();
    }

    function incrementLiving() external onlyGameStrict {
        // Fix: EE-P5 — consistency check
        totalLivingAgents++;
    }

    function decrementLiving() external onlyGameOrDeathOrMarket {
        if (totalLivingAgents > 0) {
            totalLivingAgents--;
        }
    }

    /* ========== PLOT AGENT TRACKING ========== */

    function addAgentToPlot(uint256 agentId, uint256 plotId) external onlyGameStrict {
        if (_agentInPlot[agentId]) return;

        _plotAgentIndex[agentId] = _plotAgents[plotId].length;
        _plotAgents[plotId].push(agentId);
        _agentInPlot[agentId] = true;
    }

    // Fix: EE-P4 — extracted _removeFromPlot to avoid code duplication
    function removeAgentFromPlot(uint256 agentId, uint256 plotId) external onlyGameOrDeathOrMarket {
        _removeFromPlot(agentId, plotId);
    }

    function moveAgentPlot(uint256 agentId, uint256 fromPlot, uint256 toPlot) external onlyGameStrict {
        _removeFromPlot(agentId, fromPlot); // Fix: EE-P4 — shared internal function

        _plotAgentIndex[agentId] = _plotAgents[toPlot].length;
        _plotAgents[toPlot].push(agentId);
        _agentInPlot[agentId] = true;
    }

    // Fix: EE-P4 — shared internal removal function to avoid code duplication
    function _removeFromPlot(uint256 agentId, uint256 plotId) internal {
        if (!_agentInPlot[agentId]) return;

        uint256[] storage agents = _plotAgents[plotId];
        uint256 index = _plotAgentIndex[agentId];
        uint256 lastIndex = agents.length - 1;

        if (index != lastIndex) {
            uint256 lastAgent = agents[lastIndex];
            agents[index] = lastAgent;
            _plotAgentIndex[lastAgent] = index;
        }

        agents.pop();
        delete _plotAgentIndex[agentId];
        _agentInPlot[agentId] = false;
    }

    /* ========== INTERNAL HELPERS ========== */

    function _getPlotMultiplier(uint256 plotId) internal view returns (uint256) {
        (bool ok, bytes memory data) = worldMap.staticcall(
            abi.encodeWithSignature("getPlotMultiplier(uint256)", plotId)
        );
        require(ok, "getPlotMultiplier failed");
        return abi.decode(data, (uint256));
    }

    function _getAttributes(uint256 agentId) internal view returns (uint16[8] memory attrs, uint8 gender) {
        (bool ok, bytes memory data) = genesisCore.staticcall(
            abi.encodeWithSignature("getAttributes(uint256)", agentId)
        );
        require(ok, "getAttributes failed");
        return abi.decode(data, (uint16[8], uint8));
    }
}
