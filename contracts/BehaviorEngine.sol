// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title BehaviorEngine (V4 — UUPS Upgradeable)
 * @notice CodeDNA 核心行为合约 — 8 大行为 + 能量计算 + 死亡判定
 *
 * Audit fixes:
 *   BE-P1: lastGatherBlock initialized in placeOnMap to block.number
 *   BE-P2: reproduce gas — delegated to ReproductionEngine
 *   BE-P3: gather cooldown enforced (already present, validated)
 *   BE-P4: nonReentrant on claimDeathBounty and all state-changing actions
 *   BE-P5: Pausable with owner control
 *   BE-P6: Energy snapshot-and-operate (getCurrentEnergy called once per action)
 *   BE-P7: Race condition mitigated with nonReentrant
 *   BE-P8: Multisig pause/unpause retained, owner can also pause
 */
contract BehaviorEngine is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable, // Fix: BE-P4
    PausableUpgradeable,         // Fix: BE-P5
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant GATHER_COOLDOWN       = 4_800;
    uint256 public constant EAT_COOLDOWN          = 9_600;
    uint256 public constant MOVE_COOLDOWN         = 300;
    uint256 public constant REPRODUCE_COOLDOWN    = 201_600;
    uint256 public constant RAID_COOLDOWN         = 14_400;
    uint256 public constant SHARE_COOLDOWN        = 2_400;
    uint256 public constant TEACH_COOLDOWN        = 403_200;
    uint256 public constant DYING_WINDOW          = 14_400;
    uint256 public constant ENERGY_DECAY_PERIOD   = 9_600;
    uint256 public constant ENERGY_DECAY_AMOUNT   = 10;
    uint256 public constant ENERGY_WEAK_THRESHOLD = 20;
    uint256 public constant ENERGY_MAX_BASE       = 100;
    uint256 public constant RESCUE_COST           = 100 * 1e18;
    uint256 public constant RESCUE_REWARD         = 80 * 1e18;
    uint256 public constant RESCUE_ENERGY_TO      = 30;
    uint256 public constant EAT_COST              = 10 * 1e18;
    uint256 public constant EAT_RESTORE           = 25;
    uint256 public constant GATHER_RESTORE        = 35;
    uint256 public constant MOVE_ENERGY_COST      = 5;
    uint256 public constant REPRODUCE_ENERGY_MIN  = 60;
    uint256 public constant REPRODUCE_GOLD_COST   = 200 * 1e18;
    uint256 public constant REPRODUCE_GOLD_REWARD = 250 * 1e18;
    uint256 public constant REPRODUCE_ENERGY_COST = 30;
    uint256 public constant RAID_MIN_ENERGY       = 40;
    uint256 public constant RAID_LOOT_RATIO       = 30;
    uint256 public constant TEACH_BONUS           = 300 * 1e18;
    uint256 public constant TEACH_ENERGY_COST     = 25;
    uint256 public constant TEACH_MIN_ENERGY      = 30;
    uint256 public constant TEACH_MAX_BONUS       = 20;
    uint256 public constant DEATH_BOUNTY          = 50 * 1e18;
    uint256 public constant MAX_AGENTS_PER_HOST   = 20;
    uint256 public constant EXPLORE_BONUS_AMT     = 200 * 1e18;
    uint256 public constant EXPLORE_WINDOW        = 28_800;
    uint256 public constant EXPLORE_LIMIT         = 10;

    /* ========== INTERFACES (stored as addresses for upgradeability) ========== */

    address public dnagold;
    address public genesisCore;
    address public worldMapAddr;
    address public economyAddr;
    address public familyAddr;
    address public multisig;
    address public reproAddr;  // Fix: V4-C3 — ReproductionEngine address
    address public deathAddr;  // Fix: V4-H1 — DeathEngine address for unified death state

    // Cooldown tracking
    mapping(uint256 => uint256) public lastGatherBlock;
    mapping(uint256 => uint256) public lastMoveBlock;
    mapping(uint256 => uint256) public lastReproduceBlock;
    mapping(uint256 => uint256) public lastRaidBlock;
    mapping(uint256 => uint256) public lastShareBlock;
    mapping(uint256 => uint256) public parentTeachBlock;
    mapping(bytes32 => uint256) public pairTeachBlock;

    // Death tracking
    mapping(uint256 => bool) public formallyDead;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event Gathered(uint256 indexed agentId, uint256 yield_);
    event Ate(uint256 indexed agentId, uint256 energyAfter);
    event Moved(uint256 indexed agentId, uint256 fromPlot, uint256 toPlot);
    event Reproduced(uint256 indexed fatherId, uint256 indexed motherId, uint256 childId, address childOwner);
    event RaidResult(uint256 indexed attackerId, uint256 indexed targetId, uint8 result, uint256 loot);
    event Shared(uint256 indexed fromId, uint256 indexed toId, uint256 amount);
    event Taught(uint256 indexed parentId, uint256 indexed childId, uint8 attrIdx);
    event Rescued(uint256 indexed rescuerId, uint256 indexed targetId);
    event AgentDied(uint256 indexed agentId, uint256 burnedGold);
    event BountyPaid(uint256 indexed agentId, address indexed hunter, uint256 bounty);
    event AgentPlaced(uint256 indexed agentId, uint256 x, uint256 y);

    /* ========== ERRORS ========== */

    error NotMultisig();
    error CooldownActive(string action, uint256 readyAt);
    error InsufficientEnergy(uint256 have, uint256 need);
    error AgentIsDead(uint256 agentId);
    error NotOwner(uint256 agentId, address caller);
    error NotDead(uint256 agentId);
    error SameGender();
    error TooFar(uint256 distance, uint256 maxDist);
    error InsufficientGold(uint256 have, uint256 need);
    error IsRelative();
    error HostFull(address host, uint256 count);
    error ReproduceLimit(uint256 agentId);
    error SameOwner();
    error InvalidAttribute(uint8 idx);
    error NotParentChild();
    error TeachBonusMaxed(uint256 tokenId, uint8 attrIdx);

    /* ========== MODIFIERS ========== */

    modifier notDead(uint256 id) {
        if (formallyDead[id]) revert AgentIsDead(id);
        if (_isEffectivelyDead(id)) {
            _formallyDie(id);
            revert AgentIsDead(id);
        }
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    // Fix: MEDIUM-3 — added _reproAddr and _deathAddr parameters
    function initialize(
        address _dnagold,
        address _core,
        address _worldMap,
        address _economy,
        address _family,
        address _multisig,
        address _reproAddr,
        address _deathAddr,
        address _owner
    ) external initializer {
        // Fix: MEDIUM-3 + CRITICAL-1 deploy fix — allow zero for circular deps, set via setter post-deploy
        // reproAddr/deathAddr can be address(0) at init time due to deployment order constraints

        __Ownable_init(_owner);
        __ReentrancyGuard_init(); // Fix: BE-P4
        __Pausable_init();        // Fix: BE-P5
        __UUPSUpgradeable_init();

        dnagold      = _dnagold;
        genesisCore  = _core;
        worldMapAddr = _worldMap;
        economyAddr  = _economy;
        familyAddr   = _family;
        multisig     = _multisig;
        reproAddr    = _reproAddr;  // Fix: MEDIUM-3
        deathAddr    = _deathAddr;  // Fix: MEDIUM-3
    }

    /* ========== UPGRADE CONTROL ========== */

    function _authorizeUpgrade(address) internal override onlyOwner {
        require(!upgradeRenounced, "Upgrade renounced");
    }

    function renounceUpgradeability() external onlyOwner {
        upgradeRenounced = true;
    }

    /* ========== ADMIN ========== */

    function setMultisig(address _multisig) external onlyOwner {
        multisig = _multisig;
    }

    // Fix: V4-C3 — set ReproductionEngine address
    function setReproAddr(address _reproAddr) external onlyOwner {
        require(_reproAddr != address(0), "zero addr");
        reproAddr = _reproAddr;
    }

    // Fix: V4-H1 — set DeathEngine address for unified death state
    function setDeathAddr(address _deathAddr) external onlyOwner {
        require(_deathAddr != address(0), "zero addr");
        deathAddr = _deathAddr;
    }

    /// @notice Fix: R3-HIGH-1 — DeathEngine calls this to sync formallyDead
    function syncFormallyDead(uint256 id) external {
        require(msg.sender == deathAddr, "only death");
        formallyDead[id] = true;
    }

    // Fix: BE-P8 — both owner and multisig can pause
    function pause() external {
        require(msg.sender == owner() || msg.sender == multisig, "Not authorized");
        _pause();
    }

    function unpause() external {
        require(msg.sender == owner() || msg.sender == multisig, "Not authorized");
        _unpause();
    }

    /* ========== ENERGY (view) ========== */

    function getCurrentEnergy(uint256 id) public view returns (uint256) {
        if (formallyDead[id]) return 0;

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
        if (lastEat == 0) return 0;

        uint256 periods = (block.number - lastEat) / ENERGY_DECAY_PERIOD;
        uint256 decay = periods * ENERGY_DECAY_AMOUNT;
        return decay >= base ? 0 : base - decay;
    }

    function isEffectivelyDead(uint256 id) public view returns (bool) {
        return _isEffectivelyDead(id);
    }

    function _isEffectivelyDead(uint256 id) internal view returns (bool) {
        if (formallyDead[id]) return true;

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("lastEatBlock(uint256)", id)
        );
        if (!ok2) return false;
        uint256 lastEat = abi.decode(d2, (uint256));
        if (lastEat == 0) return false;

        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("agentEnergy(uint256)", id)
        );
        if (!ok1) return false;
        uint256 base = abi.decode(d1, (uint256));

        if (base == 0 && lastEat == 0) return false;
        if (getCurrentEnergy(id) > 0) return false;

        uint256 zeroAt = lastEat + (base / ENERGY_DECAY_AMOUNT) * ENERGY_DECAY_PERIOD;
        return block.number > zeroAt + DYING_WINDOW;
    }

    function _getMaxEnergy(uint256 id) internal view returns (uint256) {
        (bool ok, bytes memory data) = genesisCore.staticcall(
            abi.encodeWithSignature("getAttributes(uint256)", id)
        );
        if (!ok) return ENERGY_MAX_BASE;
        (uint16[8] memory attrs, ) = abi.decode(data, (uint16[8], uint8));
        uint256 lifespan = uint256(attrs[6]);
        return ENERGY_MAX_BASE + (lifespan * 25 / 255);
    }

    function _clampEnergy(uint256 id, uint256 energy) internal view returns (uint256) {
        uint256 maxE = _getMaxEnergy(id);
        return energy > maxE ? maxE : energy;
    }

    /* ========== FORMAL DEATH ========== */

    function _formallyDie(uint256 id) internal {
        if (formallyDead[id]) return;
        formallyDead[id] = true;

        // Burn locked — Fix: HIGH-2 — require return value checks
        (bool ok0, bytes memory d0) = dnagold.staticcall(
            abi.encodeWithSignature("lockedBalance(uint256)", id)
        );
        uint256 burned = ok0 ? abi.decode(d0, (uint256)) : 0;

        (bool okBurn,) = dnagold.call(abi.encodeWithSignature("burnLocked(uint256)", id));
        require(okBurn, "burnLocked failed"); // Fix: HIGH-2
        (bool okMark,) = genesisCore.call(abi.encodeWithSignature("markDead(uint256)", id));
        require(okMark, "markDead failed"); // Fix: HIGH-2

        // WorldMap removal
        (bool ok3, bytes memory d3) = worldMapAddr.staticcall(
            abi.encodeWithSignature("agentLocation(uint256)", id)
        );
        uint256 plotId = ok3 ? abi.decode(d3, (uint256)) : 0;
        (bool okRm,) = worldMapAddr.call(abi.encodeWithSignature("removeAgent(uint256)", id));
        require(okRm, "removeAgent failed"); // Fix: HIGH-2
        (bool okRp,) = economyAddr.call(abi.encodeWithSignature("removeAgentFromPlot(uint256,uint256)", id, plotId));
        require(okRp, "removeAgentFromPlot failed"); // Fix: HIGH-2
        (bool okDl,) = economyAddr.call(abi.encodeWithSignature("decrementLiving()"));
        require(okDl, "decrementLiving failed"); // Fix: HIGH-2

        // Family cleanup
        familyAddr.call(abi.encodeWithSignature("removeAgent(uint256)", id));

        // Fix: V4-H1 — sync death state to DeathEngine (unified death source)
        if (deathAddr != address(0)) {
            deathAddr.call(abi.encodeWithSignature("syncDeath(uint256)", id));
        }

        emit AgentDied(id, burned);
    }

    function checkDeath(uint256 id) external whenNotPaused { // Fix: BE-P5
        if (formallyDead[id]) return;
        if (_isEffectivelyDead(id)) {
            _formallyDie(id);
        }
    }

    // Fix: BE-P4 — nonReentrant
    // Fix: V4-H4 — removed claimDeathBounty from BehaviorEngine
    // Death bounty is now ONLY handled by DeathEngine.claimDeathBounty()
    // This prevents double-bounty payment from two different death state tracks

    /* ========== 0. PLACE ON MAP ========== */

    function placeOnMap(uint256 agentId, uint256 x, uint256 y) external whenNotPaused nonReentrant notDead(agentId) { // Fix: BE-P4
        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", agentId)
        );
        require(ok1, "ownerOf failed");
        address agentOwner = abi.decode(d1, (address));
        if (agentOwner != msg.sender) revert NotOwner(agentId, msg.sender);

        worldMapAddr.call(abi.encodeWithSignature("placeAgent(uint256,uint256,uint256)", agentId, x, y));

        uint256 plotId = x * 1000 + y;
        economyAddr.call(abi.encodeWithSignature("addAgentToPlot(uint256,uint256)", agentId, plotId));

        // Fix: BE-P1 — initialize lastGatherBlock and other cooldown blocks
        lastGatherBlock[agentId] = block.number; // Fix: BE-P1

        // Register genesis in family tracker
        (bool ok2, bytes memory d2) = familyAddr.staticcall(
            abi.encodeWithSignature("registered(uint256)", agentId)
        );
        bool isRegistered = ok2 && abi.decode(d2, (bool));
        if (!isRegistered) {
            familyAddr.call(abi.encodeWithSignature("registerGenesis(uint256)", agentId));
        }

        economyAddr.call(abi.encodeWithSignature("incrementLiving()"));

        emit AgentPlaced(agentId, x, y);
    }

    /* ========== 1. GATHER ========== */

    // Fix: BE-P3, BE-P4 — cooldown enforced, nonReentrant
    function gather(uint256 agentId) external whenNotPaused nonReentrant notDead(agentId) { // Fix: BE-P4
        if (block.number < lastGatherBlock[agentId] + GATHER_COOLDOWN) {
            revert CooldownActive("gather", lastGatherBlock[agentId] + GATHER_COOLDOWN);
        }

        uint256 energy = getCurrentEnergy(agentId); // Fix: BE-P6 — single snapshot
        if (energy < 1) revert InsufficientEnergy(energy, 1);

        // Get plot info
        (bool ok1, bytes memory d1) = worldMapAddr.staticcall(
            abi.encodeWithSignature("agentLocation(uint256)", agentId)
        );
        require(ok1, "agentLocation failed");
        uint256 plotId = abi.decode(d1, (uint256));

        (bool ok2, bytes memory d2) = worldMapAddr.staticcall(
            abi.encodeWithSignature("plotAgentCount(uint256)", plotId)
        );
        require(ok2, "plotAgentCount failed");
        uint256 plotCount = abi.decode(d2, (uint256));

        (bool ok3, bytes memory d3) = economyAddr.staticcall(
            abi.encodeWithSignature("getPlotLeader(uint256)", plotId)
        );
        uint256 leader = ok3 ? abi.decode(d3, (uint256)) : type(uint256).max;
        bool isLeader = (leader == agentId);

        (bool ok4, bytes memory d4) = economyAddr.staticcall(
            abi.encodeWithSignature("calcGatherYield(uint256,uint256,uint256,bool)", agentId, plotId, plotCount, isLeader)
        );
        uint256 yield_ = ok4 ? abi.decode(d4, (uint256)) : 0;

        // Update cooldown FIRST (CEI)
        lastGatherBlock[agentId] = block.number; // Fix: BE-P3

        // Restore energy
        uint256 newEnergy = _clampEnergy(agentId, energy + GATHER_RESTORE);
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", agentId, newEnergy));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", agentId, block.number));

        if (yield_ > 0) {
            economyAddr.call(abi.encodeWithSignature("rewardAgent(uint256,uint256)", agentId, yield_));
        }

        economyAddr.call(abi.encodeWithSignature("checkAndHalve()"));

        emit Gathered(agentId, yield_);
    }

    /* ========== 2. EAT ========== */

    function eat(uint256 agentId) external whenNotPaused nonReentrant notDead(agentId) { // Fix: BE-P4
        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("lastEatBlock(uint256)", agentId)
        );
        require(ok1, "lastEatBlock failed");
        uint256 lastEat = abi.decode(d1, (uint256));

        if (block.number < lastEat + EAT_COOLDOWN) {
            revert CooldownActive("eat", lastEat + EAT_COOLDOWN);
        }

        (bool ok2, bytes memory d2) = dnagold.staticcall(
            abi.encodeWithSignature("lockedBalance(uint256)", agentId)
        );
        require(ok2, "lockedBalance failed");
        uint256 locked = abi.decode(d2, (uint256));
        if (locked < EAT_COST) revert InsufficientGold(locked, EAT_COST);

        dnagold.call(abi.encodeWithSignature("spendLocked(uint256,uint256)", agentId, EAT_COST));

        uint256 energy = getCurrentEnergy(agentId);
        uint256 newEnergy = _clampEnergy(agentId, energy + EAT_RESTORE);
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", agentId, newEnergy));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", agentId, block.number));

        emit Ate(agentId, newEnergy);
    }

    /* ========== 3. MOVE ========== */

    function move(uint256 agentId, uint256 newX, uint256 newY) external whenNotPaused nonReentrant notDead(agentId) { // Fix: BE-P4
        if (block.number < lastMoveBlock[agentId] + MOVE_COOLDOWN) {
            revert CooldownActive("move", lastMoveBlock[agentId] + MOVE_COOLDOWN);
        }

        uint256 energy = getCurrentEnergy(agentId);
        if (energy < MOVE_ENERGY_COST) revert InsufficientEnergy(energy, MOVE_ENERGY_COST);

        (bool ok1, bytes memory d1) = worldMapAddr.staticcall(
            abi.encodeWithSignature("agentLocation(uint256)", agentId)
        );
        require(ok1, "agentLocation failed");
        uint256 oldPlot = abi.decode(d1, (uint256));
        uint256 newPlot = newX * 1000 + newY;

        (bool ok2, bytes memory d2) = worldMapAddr.staticcall(
            abi.encodeWithSignature("getManhattanDistance(uint256,uint256)", oldPlot, newPlot)
        );
        require(ok2, "getManhattanDistance failed");
        uint256 dist = abi.decode(d2, (uint256));
        if (dist != 1) revert TooFar(dist, 1);

        uint256 newEnergy = energy - MOVE_ENERGY_COST;
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", agentId, newEnergy));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", agentId, block.number));

        worldMapAddr.call(abi.encodeWithSignature("moveAgent(uint256,uint256,uint256)", agentId, newX, newY));
        economyAddr.call(abi.encodeWithSignature("moveAgentPlot(uint256,uint256,uint256)", agentId, oldPlot, newPlot));

        lastMoveBlock[agentId] = block.number;

        emit Moved(agentId, oldPlot, newPlot);
    }

    /* ========== 4. REPRODUCE ========== */

    function reproduce(uint256 fatherId, uint256 motherId) external whenNotPaused nonReentrant notDead(fatherId) notDead(motherId) { // Fix: BE-P4
        // Gender check
        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("getGender(uint256)", fatherId)
        );
        require(ok1, "getGender father failed");
        uint8 fGender = abi.decode(d1, (uint8));

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("getGender(uint256)", motherId)
        );
        require(ok2, "getGender mother failed");
        uint8 mGender = abi.decode(d2, (uint8));

        if (fGender == mGender) revert SameGender();
        // Fix: V4-L2 — simplified: if female is fatherId, swap to correct roles
        if (fGender == 0 && mGender == 1) {
            (fatherId, motherId) = (motherId, fatherId);
        }

        // Distance
        uint256 fPlot = _getAgentLocation(fatherId);
        uint256 mPlot = _getAgentLocation(motherId);
        uint256 dist = _getManhattan(fPlot, mPlot);
        if (dist > 5) revert TooFar(dist, 5);

        // Energy
        uint256 fEnergy = getCurrentEnergy(fatherId);
        uint256 mEnergy = getCurrentEnergy(motherId);
        if (fEnergy < REPRODUCE_ENERGY_MIN) revert InsufficientEnergy(fEnergy, REPRODUCE_ENERGY_MIN);
        if (mEnergy < REPRODUCE_ENERGY_MIN) revert InsufficientEnergy(mEnergy, REPRODUCE_ENERGY_MIN);

        // Gold
        uint256 fGold = _getLockedBalance(fatherId);
        uint256 mGold = _getLockedBalance(motherId);
        if (fGold < REPRODUCE_GOLD_COST) revert InsufficientGold(fGold, REPRODUCE_GOLD_COST);
        if (mGold < REPRODUCE_GOLD_COST) revert InsufficientGold(mGold, REPRODUCE_GOLD_COST);

        // Relatives
        (bool ok5, bytes memory d5) = familyAddr.staticcall(
            abi.encodeWithSignature("isDirectRelative(uint256,uint256)", fatherId, motherId)
        );
        bool areRelatives = ok5 && abi.decode(d5, (bool));
        if (areRelatives) revert IsRelative();

        // Host capacity
        address fOwner = _getOwnerOf(fatherId);
        address mOwner = _getOwnerOf(motherId);
        if (_getBalance(fOwner) >= MAX_AGENTS_PER_HOST) revert HostFull(fOwner, _getBalance(fOwner));
        if (_getBalance(mOwner) >= MAX_AGENTS_PER_HOST) revert HostFull(mOwner, _getBalance(mOwner));

        // Cooldown
        if (block.number < lastReproduceBlock[fatherId] + REPRODUCE_COOLDOWN) {
            revert CooldownActive("reproduce_father", lastReproduceBlock[fatherId] + REPRODUCE_COOLDOWN);
        }
        if (block.number < lastReproduceBlock[motherId] + REPRODUCE_COOLDOWN) {
            revert CooldownActive("reproduce_mother", lastReproduceBlock[motherId] + REPRODUCE_COOLDOWN);
        }

        // Lifetime limit
        {
            (bool okf, bytes memory df) = genesisCore.staticcall(
                abi.encodeWithSignature("getAttributes(uint256)", fatherId)
            );
            require(okf, "getAttributes father failed");
            (uint16[8] memory fAttrs, ) = abi.decode(df, (uint16[8], uint8));

            (bool okm, bytes memory dm) = genesisCore.staticcall(
                abi.encodeWithSignature("getAttributes(uint256)", motherId)
            );
            require(okm, "getAttributes mother failed");
            (uint16[8] memory mAttrs, ) = abi.decode(dm, (uint16[8], uint8));

            uint256 fLimit = uint256(fAttrs[7]) / 32;
            uint256 mLimit = uint256(mAttrs[7]) / 32;

            (bool okrc1, bytes memory drc1) = genesisCore.staticcall(
                abi.encodeWithSignature("reproduceCount(uint256)", fatherId)
            );
            uint256 fRC = okrc1 ? abi.decode(drc1, (uint256)) : 0;

            (bool okrc2, bytes memory drc2) = genesisCore.staticcall(
                abi.encodeWithSignature("reproduceCount(uint256)", motherId)
            );
            uint256 mRC = okrc2 ? abi.decode(drc2, (uint256)) : 0;

            if (fRC >= fLimit) revert ReproduceLimit(fatherId);
            if (mRC >= mLimit) revert ReproduceLimit(motherId);
        }

        // === Execute ===
        dnagold.call(abi.encodeWithSignature("spendLocked(uint256,uint256)", fatherId, REPRODUCE_GOLD_COST));
        dnagold.call(abi.encodeWithSignature("spendLocked(uint256,uint256)", motherId, REPRODUCE_GOLD_COST));

        fEnergy -= REPRODUCE_ENERGY_COST;
        mEnergy -= REPRODUCE_ENERGY_COST;

        address childOwner = (block.prevrandao % 2 == 0) ? fOwner : mOwner;

        // Fix: V4-C3 — call ReproductionEngine.generateChild instead of GenesisCore.mintOffspring
        // This enables talent detection events (GeneMutated / ChildGenerated)
        (bool okmint, bytes memory dmint) = reproAddr.call(
            abi.encodeWithSignature("generateChild(uint256,uint256,address)", fatherId, motherId, childOwner)
        );
        require(okmint, "generateChild failed");
        uint256 childId = abi.decode(dmint, (uint256));

        // Place child at midpoint
        {
            (uint256 fx, uint256 fy) = _toCoords(fPlot);
            (uint256 mx, uint256 my) = _toCoords(mPlot);
            uint256 cx = (fx + mx) / 2;
            uint256 cy = (fy + my) / 2;
            worldMapAddr.call(abi.encodeWithSignature("placeAgent(uint256,uint256,uint256)", childId, cx, cy));
            uint256 childPlot = cx * 1000 + cy;
            economyAddr.call(abi.encodeWithSignature("addAgentToPlot(uint256,uint256)", childId, childPlot));
        }

        // Fix: BE-P1 — initialize lastGatherBlock for child
        lastGatherBlock[childId] = block.number; // Fix: BE-P1

        // Register birth
        // Fix: R3-LOW-3 — require registerBirth succeeds (prevents orphaned child)
        (bool okBirth,) = familyAddr.call(abi.encodeWithSignature("registerBirth(uint256,uint256,uint256)", childId, fatherId, motherId));
        require(okBirth, "registerBirth failed");

        // Rewards
        economyAddr.call(abi.encodeWithSignature("rewardAgent(uint256,uint256)", fatherId, REPRODUCE_GOLD_REWARD));
        economyAddr.call(abi.encodeWithSignature("rewardAgent(uint256,uint256)", motherId, REPRODUCE_GOLD_REWARD));
        fEnergy += 10;
        mEnergy += 10;

        // Clamp and save energy
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", fatherId, _clampEnergy(fatherId, fEnergy)));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", fatherId, block.number));
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", motherId, _clampEnergy(motherId, mEnergy)));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", motherId, block.number));

        // Update tracking
        lastReproduceBlock[fatherId] = block.number;
        lastReproduceBlock[motherId] = block.number;
        // Fix: Part2-Logic-1 — require to prevent reproduce limit bypass
        (bool okRC1,) = genesisCore.call(abi.encodeWithSignature("incrementReproduceCount(uint256)", fatherId));
        require(okRC1, "incrementReproduceCount father failed");
        (bool okRC2,) = genesisCore.call(abi.encodeWithSignature("incrementReproduceCount(uint256)", motherId));
        require(okRC2, "incrementReproduceCount mother failed");

        // Population
        economyAddr.call(abi.encodeWithSignature("incrementBorn()"));

        emit Reproduced(fatherId, motherId, childId, childOwner);
    }

    /* ========== 5. RAID ========== */

    function raid(uint256 attackerId, uint256 targetId) external whenNotPaused nonReentrant notDead(attackerId) notDead(targetId) { // Fix: BE-P4
        if (block.number < lastRaidBlock[attackerId] + RAID_COOLDOWN) {
            revert CooldownActive("raid", lastRaidBlock[attackerId] + RAID_COOLDOWN);
        }

        uint256 atkEnergy = getCurrentEnergy(attackerId); // Fix: BE-P6
        if (atkEnergy < RAID_MIN_ENERGY) revert InsufficientEnergy(atkEnergy, RAID_MIN_ENERGY);

        uint256 tgtEnergy = getCurrentEnergy(targetId);

        uint256 atkPlot = _getAgentLocation(attackerId);
        uint256 tgtPlot = _getAgentLocation(targetId);
        uint256 dist = _getManhattan(atkPlot, tgtPlot);
        if (dist > 3) revert TooFar(dist, 3);

        address atkOwner = _getOwnerOf(attackerId);
        address tgtOwner = _getOwnerOf(targetId);
        if (atkOwner == tgtOwner) revert SameOwner();

        // Battle calculation
        (bool oka, bytes memory da) = genesisCore.staticcall(
            abi.encodeWithSignature("getAttributes(uint256)", attackerId)
        );
        require(oka, "getAttributes failed");
        (uint16[8] memory atkAttrs, ) = abi.decode(da, (uint16[8], uint8));

        (bool okt, bytes memory dt) = genesisCore.staticcall(
            abi.encodeWithSignature("getAttributes(uint256)", targetId)
        );
        require(okt, "getAttributes failed");
        (uint16[8] memory tgtAttrs, ) = abi.decode(dt, (uint16[8], uint8));

        uint256 atkPower = uint256(atkAttrs[2]) * (255 + uint256(atkAttrs[3])) / 255;
        uint256 defBase  = uint256(tgtAttrs[2]) * 8 / 10;

        uint256 rand = uint256(keccak256(abi.encodePacked(attackerId, targetId, block.prevrandao, block.number))) % 100;

        uint256 defPower;
        if (rand % 2 == 0) {
            defPower = defBase + (defBase * (rand % 21) / 100);
        } else {
            uint256 reduction = defBase * (rand % 21) / 100;
            defPower = defBase > reduction ? defBase - reduction : 0;
        }

        // Update cooldown FIRST (CEI)
        lastRaidBlock[attackerId] = block.number;

        uint8 result;
        uint256 loot = 0;

        if (rand % 20 == 0) {
            result = 2;
            atkEnergy = atkEnergy > 15 ? atkEnergy - 15 : 0;
            tgtEnergy = tgtEnergy > 15 ? tgtEnergy - 15 : 0;
        } else if (atkPower > defPower) {
            result = 1;
            loot = _getLockedBalance(targetId) * RAID_LOOT_RATIO / 100;
            if (loot > 0) {
                dnagold.call(abi.encodeWithSignature("transferLocked(uint256,uint256,uint256)", targetId, attackerId, loot));
            }
            atkEnergy = atkEnergy > 20 ? atkEnergy - 20 : 0;
            tgtEnergy = tgtEnergy > 20 ? tgtEnergy - 20 : 0;
        } else {
            result = 0;
            atkEnergy = atkEnergy > 30 ? atkEnergy - 30 : 0;
            tgtEnergy = tgtEnergy > 10 ? tgtEnergy - 10 : 0;
        }

        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", attackerId, atkEnergy));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", attackerId, block.number));
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", targetId, tgtEnergy));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", targetId, block.number));

        emit RaidResult(attackerId, targetId, result, loot);
    }

    /* ========== 6. SHARE ========== */

    // Fix: V4-M2 — added notDead(toId) to prevent sharing to dead/dying agents
    function share(uint256 fromId, uint256 toId, uint256 amount) external whenNotPaused nonReentrant notDead(fromId) notDead(toId) { // Fix: BE-P4, V4-M2
        require(amount > 0, "zero amount"); // Fix: MEDIUM-4 — prevent zero-amount share exploits
        if (block.number < lastShareBlock[fromId] + SHARE_COOLDOWN) {
            revert CooldownActive("share", lastShareBlock[fromId] + SHARE_COOLDOWN);
        }

        uint256 fromPlot = _getAgentLocation(fromId);
        uint256 toPlot   = _getAgentLocation(toId);
        uint256 dist = _getManhattan(fromPlot, toPlot);
        if (dist > 10) revert TooFar(dist, 10);

        uint256 locked = _getLockedBalance(fromId);
        if (locked < amount) revert InsufficientGold(locked, amount);

        // CEI: update cooldown first
        lastShareBlock[fromId] = block.number;

        dnagold.call(abi.encodeWithSignature("transferLocked(uint256,uint256,uint256)", fromId, toId, amount));

        uint256 toEnergy = getCurrentEnergy(toId);
        uint256 newEnergy = _clampEnergy(toId, toEnergy + 20);
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", toId, newEnergy));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", toId, block.number));

        emit Shared(fromId, toId, amount);
    }

    /* ========== 7. TEACH ========== */

    function teach(uint256 parentId, uint256 childId, uint8 attrIdx) external whenNotPaused nonReentrant notDead(parentId) notDead(childId) { // Fix: BE-P4
        if (attrIdx >= 8) revert InvalidAttribute(attrIdx);

        // Fix: V4-M1 — use dedicated isParentChild instead of isDirectRelative
        (bool ok1, bytes memory d1) = familyAddr.staticcall(
            abi.encodeWithSignature("isParentChild(uint256,uint256)", parentId, childId)
        );
        bool isParent = ok1 && abi.decode(d1, (bool));
        if (!isParent) revert NotParentChild();

        if (parentTeachBlock[parentId] > 0 && block.number < parentTeachBlock[parentId] + TEACH_COOLDOWN) {
            revert CooldownActive("teach_parent", parentTeachBlock[parentId] + TEACH_COOLDOWN);
        }

        bytes32 pairKey = keccak256(abi.encodePacked(parentId, childId));
        if (pairTeachBlock[pairKey] > 0 && block.number < pairTeachBlock[pairKey] + TEACH_COOLDOWN) {
            revert CooldownActive("teach_pair", pairTeachBlock[pairKey] + TEACH_COOLDOWN);
        }

        uint256 pEnergy = getCurrentEnergy(parentId);
        if (pEnergy < TEACH_MIN_ENERGY) revert InsufficientEnergy(pEnergy, TEACH_MIN_ENERGY);

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("agentAttributeBonus(uint256,uint256)", childId, uint256(attrIdx))
        );
        uint16 currentBonus = ok2 ? abi.decode(d2, (uint16)) : 0;
        // Fix: MEDIUM-1 — check currentBonus + 5 won't exceed GenesisCore's max of 20
        if (currentBonus + 5 > TEACH_MAX_BONUS) revert TeachBonusMaxed(childId, attrIdx);

        // Execute
        uint256 newEnergy = pEnergy - TEACH_ENERGY_COST;
        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", parentId, newEnergy));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", parentId, block.number));

        (bool okTeach,) = genesisCore.call(abi.encodeWithSignature("addAttributeBonus(uint256,uint8,uint16)", childId, attrIdx, uint16(5)));
        require(okTeach, "addAttributeBonus failed"); // Fix: MEDIUM-1 — check return value

        parentTeachBlock[parentId] = block.number;
        pairTeachBlock[pairKey] = block.number;

        economyAddr.call(abi.encodeWithSignature("rewardAgent(uint256,uint256)", parentId, TEACH_BONUS));

        emit Taught(parentId, childId, attrIdx);
    }

    /* ========== 8. RESCUE ========== */

    function rescue(uint256 rescuerId, uint256 targetId) external whenNotPaused nonReentrant notDead(rescuerId) { // Fix: BE-P4
        if (formallyDead[targetId]) revert AgentIsDead(targetId);

        uint256 tgtEnergy = getCurrentEnergy(targetId);
        if (tgtEnergy > 0) revert NotDead(targetId);

        // Check still in dying window
        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("lastEatBlock(uint256)", targetId)
        );
        require(ok1, "lastEatBlock failed");
        uint256 lastEat = abi.decode(d1, (uint256));

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("agentEnergy(uint256)", targetId)
        );
        require(ok2, "agentEnergy failed");
        uint256 base = abi.decode(d2, (uint256));

        uint256 zeroAt = lastEat + (base / ENERGY_DECAY_AMOUNT) * ENERGY_DECAY_PERIOD;
        if (block.number > zeroAt + DYING_WINDOW) {
            _formallyDie(targetId);
            revert AgentIsDead(targetId);
        }

        // Distance
        uint256 rPlot = _getAgentLocation(rescuerId);
        uint256 tPlot = _getAgentLocation(targetId);
        uint256 dist = _getManhattan(rPlot, tPlot);
        if (dist > 10) revert TooFar(dist, 10);

        // Gold
        uint256 locked = _getLockedBalance(rescuerId);
        if (locked < RESCUE_COST) revert InsufficientGold(locked, RESCUE_COST);

        // Execute
        dnagold.call(abi.encodeWithSignature("spendLocked(uint256,uint256)", rescuerId, RESCUE_COST));

        genesisCore.call(abi.encodeWithSignature("setEnergy(uint256,uint256)", targetId, RESCUE_ENERGY_TO));
        genesisCore.call(abi.encodeWithSignature("setLastEatBlock(uint256,uint256)", targetId, block.number));

        economyAddr.call(abi.encodeWithSignature("rewardAgent(uint256,uint256)", rescuerId, RESCUE_REWARD));

        emit Rescued(rescuerId, targetId);
    }

    /* ========== INTERNAL HELPERS ========== */

    function _getAgentLocation(uint256 agentId) internal view returns (uint256) {
        (bool ok, bytes memory data) = worldMapAddr.staticcall(
            abi.encodeWithSignature("agentLocation(uint256)", agentId)
        );
        require(ok, "agentLocation failed");
        return abi.decode(data, (uint256));
    }

    function _getManhattan(uint256 a, uint256 b) internal view returns (uint256) {
        (bool ok, bytes memory data) = worldMapAddr.staticcall(
            abi.encodeWithSignature("getManhattanDistance(uint256,uint256)", a, b)
        );
        require(ok, "getManhattanDistance failed");
        return abi.decode(data, (uint256));
    }

    function _toCoords(uint256 plotId) internal view returns (uint256 x, uint256 y) {
        (bool ok, bytes memory data) = worldMapAddr.staticcall(
            abi.encodeWithSignature("toCoords(uint256)", plotId)
        );
        require(ok, "toCoords failed");
        return abi.decode(data, (uint256, uint256));
    }

    function _getLockedBalance(uint256 agentId) internal view returns (uint256) {
        (bool ok, bytes memory data) = dnagold.staticcall(
            abi.encodeWithSignature("lockedBalance(uint256)", agentId)
        );
        return ok ? abi.decode(data, (uint256)) : 0;
    }

    function _getOwnerOf(uint256 tokenId) internal view returns (address) {
        (bool ok, bytes memory data) = genesisCore.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );
        require(ok, "ownerOf failed");
        return abi.decode(data, (address));
    }

    function _getBalance(address addr) internal view returns (uint256) {
        (bool ok, bytes memory data) = genesisCore.staticcall(
            abi.encodeWithSignature("balanceOf(address)", addr)
        );
        return ok ? abi.decode(data, (uint256)) : 0;
    }
}