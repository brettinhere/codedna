// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title DeathEngine (V4 — UUPS Upgradeable)
 * @notice CodeDNA 死亡引擎 — Agent 正式死亡处理、赏金猎人机制
 *
 * Audit fixes:
 *   DE-P1: _formallyDie uses direct call instead of try-catch to prevent silent failure
 *   DE-P2: WorldMap.removeAgent & Economy.removeAgentFromPlot executed atomically
 *   DE-P3: claimDeathBounty requires nonReentrant
 *   DE-P4: Bounty mint check uses correct pool balance
 *   DE-P5: requireAlive check properly handles already-dead agents
 *   DE-P6: Zero energy detection handles lastEatBlock=0 edge case
 */
contract DeathEngine is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable, // Fix: DE-P3
    PausableUpgradeable,         // Fix: DE-P6 — Pausable per TASK.md
    UUPSUpgradeable
{
    /* ========== ENUMS ========== */

    enum Status { ALIVE, DEAD }

    /* ========== CONSTANTS ========== */

    uint256 public constant DYING_WINDOW        = 14_400;
    uint256 public constant ENERGY_DECAY_PERIOD  = 9_600;
    uint256 public constant ENERGY_DECAY_AMOUNT  = 10;
    uint256 public constant DEATH_BOUNTY         = 50 * 1e18;

    /* ========== STATE ========== */

    address public dnagold;
    address public genesisCore;
    address public worldMapAddr;
    address public economyAddr;
    address public familyAddr;
    address public gameContract;
    address public nftMarketAddr; // Fix: NM-P3 — for dead listing cleanup

    mapping(uint256 => Status) public agentStatus;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event AgentDied(uint256 indexed agentId, uint256 burnedGold, uint256 blockNumber);
    event BountyPaid(uint256 indexed agentId, address indexed hunter, uint256 bounty);

    /* ========== ERRORS ========== */

    error OnlyGame();
    error AgentIsDead(uint256 agentId);
    error AgentNotDead(uint256 agentId);
    error ZeroAddress();

    /* ========== MODIFIER ========== */

    modifier onlyGame() {
        if (msg.sender != gameContract) revert OnlyGame();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(
        address _dnagold,
        address _genesisCore,
        address _worldMap,
        address _economy,
        address _family,
        address _gameContract,
        address _owner
    ) external initializer {
        if (_dnagold == address(0)) revert ZeroAddress();
        if (_genesisCore == address(0)) revert ZeroAddress();
        if (_worldMap == address(0)) revert ZeroAddress();
        if (_economy == address(0)) revert ZeroAddress();
        if (_family == address(0)) revert ZeroAddress();
        if (_gameContract == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __ReentrancyGuard_init(); // Fix: DE-P3
        __Pausable_init();        // Fix: DE-P6
        __UUPSUpgradeable_init();

        dnagold       = _dnagold;
        genesisCore   = _genesisCore;
        worldMapAddr  = _worldMap;
        economyAddr   = _economy;
        familyAddr    = _family;
        gameContract  = _gameContract;
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

    function setNFTMarket(address _nftMarket) external onlyOwner {
        nftMarketAddr = _nftMarket; // Fix: NM-P3
    }

    // Fix: DE-P6 — Pausable
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /* ========== ENERGY VIEW ========== */

    function getCurrentEnergy(uint256 id) public view returns (uint256) {
        if (agentStatus[id] == Status.DEAD) return 0;

        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("agentEnergy(uint256)", id)
        );
        if (!ok1) return 0;
        uint256 base = abi.decode(d1, (uint256));

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("lastEatBlock(uint256)", id)
        );
        if (!ok2) return 0;
        uint256 lastEat = abi.decode(d2, (uint256));

        if (lastEat == 0) return 0; // Fix: DE-P6

        uint256 periods = (block.number - lastEat) / ENERGY_DECAY_PERIOD;
        uint256 decay   = periods * ENERGY_DECAY_AMOUNT;
        return decay >= base ? 0 : base - decay;
    }

    function isEffectivelyDead(uint256 id) public view returns (bool) {
        if (agentStatus[id] == Status.DEAD) return true;

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("lastEatBlock(uint256)", id)
        );
        if (!ok2) return false;
        uint256 lastEat = abi.decode(d2, (uint256));
        if (lastEat == 0) return false; // Fix: DE-P6 — never minted

        if (getCurrentEnergy(id) > 0) return false;

        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("agentEnergy(uint256)", id)
        );
        if (!ok1) return false;
        uint256 base = abi.decode(d1, (uint256));

        uint256 zeroAt = lastEat + (base / ENERGY_DECAY_AMOUNT) * ENERGY_DECAY_PERIOD;
        return block.number > zeroAt + DYING_WINDOW;
    }

    function inDyingWindow(uint256 id) public view returns (bool) {
        if (agentStatus[id] == Status.DEAD) return false;
        if (getCurrentEnergy(id) > 0) return false;

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("lastEatBlock(uint256)", id)
        );
        if (!ok2) return false;
        uint256 lastEat = abi.decode(d2, (uint256));
        if (lastEat == 0) return false; // Fix: DE-P6

        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("agentEnergy(uint256)", id)
        );
        if (!ok1) return false;
        uint256 base = abi.decode(d1, (uint256));

        uint256 zeroAt = lastEat + (base / ENERGY_DECAY_AMOUNT) * ENERGY_DECAY_PERIOD;
        return block.number <= zeroAt + DYING_WINDOW;
    }

    /* ========== FORMAL DEATH ========== */

    // Fix: DE-P1 — uses require instead of try-catch for critical calls
    function _formallyDie(uint256 id) internal {
        if (agentStatus[id] == Status.DEAD) return;

        // Fix: R3-LOW-2 — set DEAD status FIRST to prevent re-entrancy
        agentStatus[id] = Status.DEAD;

        // 1. Burn locked DNAGOLD
        (bool ok0, bytes memory d0) = dnagold.staticcall(
            abi.encodeWithSignature("lockedBalance(uint256)", id)
        );
        uint256 burned = ok0 ? abi.decode(d0, (uint256)) : 0;

        // Fix: DE-P1 — direct call, revert on failure (no silent swallowing)
        (bool ok1,) = dnagold.call(abi.encodeWithSignature("burnLocked(uint256)", id));
        require(ok1, "burnLocked failed"); // Fix: DE-P1

        // 2. Mark dead in GenesisCore
        (bool ok2,) = genesisCore.call(abi.encodeWithSignature("markDead(uint256)", id));
        require(ok2, "markDead failed"); // Fix: DE-P1

        // 3. Remove from WorldMap + EconomyEngine
        // Fix: DE-P2 — get plotId before removal
        (bool ok3, bytes memory d3) = worldMapAddr.staticcall(
            abi.encodeWithSignature("agentLocation(uint256)", id)
        );
        uint256 plotId = ok3 ? abi.decode(d3, (uint256)) : 0;

        (bool ok4,) = worldMapAddr.call(abi.encodeWithSignature("removeAgent(uint256)", id));
        require(ok4, "removeAgent failed"); // Fix: DE-P1

        (bool ok5,) = economyAddr.call(
            abi.encodeWithSignature("removeAgentFromPlot(uint256,uint256)", id, plotId)
        );
        require(ok5, "removeAgentFromPlot failed"); // Fix: DE-P1

        // 4. Decrement living
        (bool ok6,) = economyAddr.call(abi.encodeWithSignature("decrementLiving()"));
        require(ok6, "decrementLiving failed"); // Fix: DE-P1

        // 5. Family cleanup (try-catch OK here — agent may not be registered)
        (bool ok7, bytes memory d7) = familyAddr.staticcall(
            abi.encodeWithSignature("registered(uint256)", id)
        );
        bool isRegistered = ok7 && abi.decode(d7, (bool));
        if (isRegistered) {
            // Fix: FT-P3 — removeAgent now clears all family state
            (bool ok8,) = familyAddr.call(abi.encodeWithSignature("removeAgent(uint256)", id));
            // Non-critical: if family cleanup fails, death still proceeds
            ok8; // silence unused warning
        }

        // 6. Sync to BehaviorEngine
        // Fix: R3-HIGH-1 — sync formallyDead to BehaviorEngine (prevent ghost agents)
        if (gameContract != address(0)) {
            gameContract.call(abi.encodeWithSignature("syncFormallyDead(uint256)", id));
        }

        emit AgentDied(id, burned, block.number);
    }

    /* ========== PUBLIC: checkDeath ========== */

    // Fix: R3-LOW-2 — added nonReentrant
    function checkDeath(uint256 targetId) external whenNotPaused nonReentrant {
        if (agentStatus[targetId] == Status.DEAD) return;
        if (isEffectivelyDead(targetId)) {
            _formallyDie(targetId);
        }
    }

    /* ========== PUBLIC: claimDeathBounty ========== */

    // Fix: DE-P3 — nonReentrant protection
    function claimDeathBounty(uint256 targetId) external whenNotPaused nonReentrant { // Fix: DE-P3, DE-P6
        if (agentStatus[targetId] == Status.DEAD) revert AgentIsDead(targetId);
        if (!isEffectivelyDead(targetId)) revert AgentNotDead(targetId);

        _formallyDie(targetId);

        // Fix: DE-P4 — bounty from gameContract pool, check balance correctly
        (bool ok1, bytes memory d1) = dnagold.staticcall(
            abi.encodeWithSignature("balanceOf(address)", gameContract)
        );
        uint256 poolBalance = ok1 ? abi.decode(d1, (uint256)) : 0;

        if (poolBalance >= DEATH_BOUNTY) {
            (bool ok2,) = dnagold.call(
                abi.encodeWithSignature("mintFree(address,uint256)", msg.sender, DEATH_BOUNTY)
            );
            if (ok2) {
                emit BountyPaid(targetId, msg.sender, DEATH_BOUNTY);
            }
        }
    }

    /* ========== GAME-ONLY ========== */

    // Fix: DE-P5 — requireAlive check properly
    function requireAlive(uint256 id) external onlyGame {
        if (agentStatus[id] == Status.DEAD) revert AgentIsDead(id);
        if (isEffectivelyDead(id)) {
            _formallyDie(id);
            revert AgentIsDead(id);
        }
    }

    function isDead(uint256 id) external view returns (bool) {
        return agentStatus[id] == Status.DEAD;
    }

    /// @notice Fix: V4-H1 — allow BehaviorEngine to sync death state
    function syncDeath(uint256 id) external onlyGame {
        if (agentStatus[id] == Status.DEAD) return; // already dead
        agentStatus[id] = Status.DEAD;
    }
}
