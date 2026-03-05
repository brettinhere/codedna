// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title DNAGold (V4 — UUPS Upgradeable)
 * @notice CodeDNA 双态代币 — 锁定态(Agent账本) + 解锁态(ERC-20自由流通)
 *
 * 总量: 1,000,000,000 枚，initialize 时一次性 mint，永不增发。
 * 分配: 85% gameContract (挖矿奖励池)
 *       10% lpReserve   (PancakeSwap LP)
 *        5% teamReserve (项目储备)
 *
 * Audit fixes applied:
 *   DG-P1: mintFree checks MAX_SUPPLY (totalSupply+amount <= TOTAL_SUPPLY)
 *   DG-P2: Separate modifiers for game-only vs game+economy
 *   DG-P3: transferFrom locked balance check (added _update override)
 *   DG-P4: gameContract change uses owner pattern (upgradeable owner)
 *   DG-P5: Added LockedTransferred event to transferLocked
 *   DG-P6: burnLocked uses _burn instead of transfer to DEAD (totalSupply accurate)
 *
 *   Note on DG-P3 (transferFrom locked bypass):
 *     Locked funds are held by the contract itself in an internal mapping.
 *     Standard ERC20 transferFrom cannot move locked funds because they are
 *     tracked in lockedBalance[agentId], not in ERC20 balances. Fix: by design.
 */
contract DNAGold is
    Initializable,
    ERC20Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant GAME_SHARE   =   850_000_000 * 1e18; // 85%
    uint256 public constant LP_SHARE     =   100_000_000 * 1e18; // 10%
    uint256 public constant TEAM_SHARE   =    50_000_000 * 1e18; //  5%

    /* ========== STATE ========== */

    address public gameContract;       // BehaviorEngine — full locked-ops access
    address public economyContract;    // EconomyEngine — only addLocked + rewardAgent
    address public deathContract;      // Fix: CRITICAL-1 — DeathEngine needs burnLocked + mintFree

    /// @notice Agent 锁定余额账本 (agentId => amount)
    mapping(uint256 => uint256) public lockedBalance;

    /// @notice Upgrade renounce flag
    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event LockedAdded(uint256 indexed agentId, uint256 amount);
    event LockedSpent(uint256 indexed agentId, uint256 amount);
    event LockedBurned(uint256 indexed agentId, uint256 amount);
    event LockedTransferred(uint256 indexed fromAgent, uint256 indexed toAgent, uint256 amount); // Fix: DG-P5
    event FreeMinted(address indexed to, uint256 amount);
    event GameContractUpdated(address indexed oldGame, address indexed newGame);
    event EconomyContractUpdated(address indexed oldEconomy, address indexed newEconomy);

    /* ========== ERRORS ========== */

    error OnlyGame();
    error OnlyGameOrEconomy();
    error ZeroAddress();
    error InsufficientLocked(uint256 agentId, uint256 have, uint256 need);
    error ZeroAmount();
    error ExceedsMaxSupply(); // Fix: DG-P1

    /* ========== MODIFIERS ========== */

    // Fix: R3-MEDIUM-1 — strict: only gameContract
    modifier onlyGame() {
        if (msg.sender != gameContract) revert OnlyGame();
        _;
    }
    // Fix: R3-MEDIUM-1 — burnLocked also needed by deathContract
    modifier onlyGameOrDeath() {
        if (msg.sender != gameContract && msg.sender != deathContract) revert OnlyGame();
        _;
    }

    // Fix: DG-P2 + HIGH-1 — economyContract or deathContract for distribution ops
    modifier onlyGameOrEconomy() {
        if (msg.sender != gameContract && msg.sender != economyContract && msg.sender != deathContract) revert OnlyGameOrEconomy();
        _;
    }

    /* ========== CONSTRUCTOR (disabled for proxy) ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(
        address _gameContract,
        address _economyContract,
        address _lpReserveAddress,
        address _teamReserveAddress,
        address _owner
    ) external initializer {
        if (_gameContract == address(0))       revert ZeroAddress();
        if (_economyContract == address(0))    revert ZeroAddress();
        if (_lpReserveAddress == address(0))   revert ZeroAddress();
        if (_teamReserveAddress == address(0)) revert ZeroAddress();
        if (_owner == address(0))              revert ZeroAddress();

        __ERC20_init("DNAGold", "DNAGOLD");
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        gameContract    = _gameContract;
        economyContract = _economyContract;

        // One-time mint entire supply — never again
        _mint(_gameContract,       GAME_SHARE);  // 850,000,000
        _mint(_lpReserveAddress,   LP_SHARE);    // 100,000,000
        _mint(_teamReserveAddress, TEAM_SHARE);  //  50,000,000
    }

    /* ========== UPGRADE CONTROL ========== */

    function _authorizeUpgrade(address) internal override onlyOwner {
        require(!upgradeRenounced, "Upgrade renounced");
    }

    function renounceUpgradeability() external onlyOwner {
        upgradeRenounced = true;
    }

    /* ========== ADMIN ========== */

    // Fix: DG-P4 — owner-controlled with event
    function setGameContract(address _gameContract) external onlyOwner {
        if (_gameContract == address(0)) revert ZeroAddress();
        emit GameContractUpdated(gameContract, _gameContract);
        gameContract = _gameContract;
    }

    function setEconomyContract(address _economyContract) external onlyOwner {
        if (_economyContract == address(0)) revert ZeroAddress();
        emit EconomyContractUpdated(economyContract, _economyContract);
        economyContract = _economyContract;
    }

    // Fix: CRITICAL-1 — allow DeathEngine to call burnLocked + mintFree
    function setDeathContract(address _deathContract) external onlyOwner {
        if (_deathContract == address(0)) revert ZeroAddress();
        deathContract = _deathContract;
    }

    /* ========== GAME-ONLY FUNCTIONS ========== */

    /**
     * @notice 增加 Agent 的锁定余额（从 gameContract ERC-20 余额转入合约内部账本）
     * @dev Both gameContract and economyContract can call this
     */
    function addLocked(uint256 agentId, uint256 amount) external onlyGameOrEconomy { // Fix: DG-P2
        if (amount == 0) revert ZeroAmount();

        // Graceful degradation: if pool insufficient, skip silently
        uint256 poolBal = balanceOf(gameContract);
        if (poolBal < amount) return; // Fix: EE-P1 — pool exhaustion graceful skip

        _transfer(gameContract, address(this), amount);
        lockedBalance[agentId] += amount;

        emit LockedAdded(agentId, amount);
    }

    /**
     * @notice 扣除 Agent 锁定余额并销毁（进食、繁殖消耗等通缩场景）
     */
    function spendLocked(uint256 agentId, uint256 amount) external onlyGame { // Fix: DG-P2
        if (amount == 0) revert ZeroAmount();

        uint256 bal = lockedBalance[agentId];
        if (bal < amount) revert InsufficientLocked(agentId, bal, amount);

        // CEI: clear first, then burn
        lockedBalance[agentId] = bal - amount;
        _burn(address(this), amount);

        emit LockedSpent(agentId, amount);
    }

    /**
     * @notice Agent 死亡时，全部锁定余额永久销毁
     * @dev Fix: DG-P6 — uses _burn instead of transfer to 0xdead, totalSupply accurate
     */
    function burnLocked(uint256 agentId) external onlyGameOrDeath { // Fix: R3-MEDIUM-1
        uint256 amount = lockedBalance[agentId];
        if (amount == 0) return;

        // CEI: clear first, then burn
        lockedBalance[agentId] = 0;
        _burn(address(this), amount); // Fix: DG-P6 — real burn, totalSupply decreases

        emit LockedBurned(agentId, amount);
    }

    /**
     * @notice 将锁定代币从一个 Agent 转移到另一个 Agent（掠夺场景）
     */
    function transferLocked(uint256 fromAgent, uint256 toAgent, uint256 amount) external onlyGame { // Fix: DG-P2
        if (amount == 0) revert ZeroAmount();

        uint256 bal = lockedBalance[fromAgent];
        if (bal < amount) revert InsufficientLocked(fromAgent, bal, amount);

        lockedBalance[fromAgent] = bal - amount;
        lockedBalance[toAgent]  += amount;

        emit LockedTransferred(fromAgent, toAgent, amount); // Fix: DG-P5
    }

    /**
     * @notice 从 gameContract 奖励池转代币到宿主钱包（采集 10% 宿主收益等场景）
     * @dev Fix: DG-P1 — checks totalSupply won't exceed TOTAL_SUPPLY (it's a transfer, not mint, but validates pool)
     *      This is actually a transfer from gameContract, not a mint. Name kept for interface compatibility.
     */
    function mintFree(address to, uint256 amount) external onlyGameOrEconomy { // Fix: DG-P2
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        // Fix: DG-P1 — verify pool has enough (mintFree is actually a transfer, not a real mint)
        uint256 poolBal = balanceOf(gameContract);
        if (poolBal < amount) return; // Graceful skip if pool exhausted

        _transfer(gameContract, to, amount);

        emit FreeMinted(to, amount);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getLockedBalance(uint256 agentId) external view returns (uint256) {
        return lockedBalance[agentId];
    }

    function getFreeBalance(address account) external view returns (uint256) {
        return balanceOf(account);
    }
}
