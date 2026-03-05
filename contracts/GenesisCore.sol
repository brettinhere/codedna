// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title GenesisCore (V4 — UUPS Upgradeable)
 * @notice CodeDNA 创世 Agent NFT — ERC-721 + 链上 DNA 生成 + 阶梯价格
 *
 * Audit fixes:
 *   GC-P1: DNA random uses msg.sender for extra entropy (mitigation)
 *   GC-P2: getAttributes boundary — use cumulative then divide for precision
 *   GC-P3: agentEnergy cap enforced in setEnergy
 *   GC-P4: block.prevrandao acknowledged; commit-reveal deferred to future
 *   GC-P5: offspringCount independent counter for clarity
 *   GC-P6: Pausable deferred (not in TASK.md scope for GenesisCore)
 */
contract GenesisCore is
    Initializable,
    ERC721Upgradeable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant MAX_GENESIS         = 10_000;
    uint256 public constant GENESIS_BASE_PRICE  = 0.1 ether;
    uint256 public constant PRICE_STEP_SIZE     = 1_000;
    uint256 public constant PRICE_MULTIPLIER    = 112;
    uint256 public constant PRICE_DIVISOR       = 100;
    uint256 public constant ENERGY_INIT_GENESIS = 80;

    /* ========== STATE ========== */

    address public gameContract;        // BehaviorEngine
    address public lpManager;           // NFTSale contract
    address public reproductionEngine;  // Fix: CRITICAL-2 — ReproductionEngine needs mintOffspring
    address public deathContract;       // Fix: CRITICAL-1 — DeathEngine needs markDead

    uint256 public totalGenesisCount;
    uint256 public totalTokenCount;
    uint256 public offspringCount; // Fix: GC-P5 — independent offspring counter

    mapping(uint256 => uint8[23]) public agentGenes;
    mapping(uint256 => uint256) public lastEatBlock;
    mapping(uint256 => uint256) public agentEnergy;
    mapping(uint256 => uint16[8]) public agentAttributeBonus;
    mapping(uint256 => uint256) public reproduceCount;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event GenesisMinted(uint256 indexed tokenId, address indexed host, uint256 price, uint8 gender);
    event OffspringMinted(uint256 indexed tokenId, uint256 fatherId, uint256 motherId, address indexed host);
    event GameContractSet(address indexed gameContract);
    event LPManagerSet(address indexed lpManager); // Fix: GC-P7 (from audit)

    /* ========== ERRORS ========== */

    error SoldOut();
    error ZeroAddress();
    error OnlyGame();
    error OnlyOwner();
    error OnlyLPManager();
    error AttributeOverflow(uint256 tokenId, uint8 attrIdx);

    /* ========== MODIFIERS ========== */

    // Fix: R3-MEDIUM-1 — fine-grained permissions per function
    modifier onlyGame() {
        if (msg.sender != gameContract) revert OnlyGame();
        _;
    }
    modifier onlyGameOrRepro() {
        if (msg.sender != gameContract && msg.sender != reproductionEngine) revert OnlyGame();
        _;
    }
    modifier onlyGameOrDeath() {
        if (msg.sender != gameContract && msg.sender != deathContract) revert OnlyGame();
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(address _owner) external initializer {
        if (_owner == address(0)) revert ZeroAddress();
        __ERC721_init("CodeDNA Agent", "CDNA");
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
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
        emit GameContractSet(_gameContract);
    }

    function setLPManager(address _lpManager) external onlyOwner {
        if (_lpManager == address(0)) revert ZeroAddress();
        lpManager = _lpManager;
        emit LPManagerSet(_lpManager); // Fix: GC-P7
    }

    // Fix: CRITICAL-2 — allow ReproductionEngine to call mintOffspring
    function setReproductionEngine(address _reproEngine) external onlyOwner {
        require(_reproEngine != address(0), "zero addr");
        reproductionEngine = _reproEngine;
    }

    // Fix: CRITICAL-1 — allow DeathEngine to call markDead
    function setDeathContract(address _deathContract) external onlyOwner {
        require(_deathContract != address(0), "zero addr");
        deathContract = _deathContract;
    }

    /* ========== MINTING ========== */

    function mintFor(address to, uint256 price) external returns (uint256 tokenId) {
        if (msg.sender != lpManager) revert OnlyLPManager();
        if (totalGenesisCount >= MAX_GENESIS) revert SoldOut();

        tokenId = totalGenesisCount;
        totalGenesisCount++;
        totalTokenCount++;

        // Fix: GC-P1 — add msg.sender for extra entropy
        bytes32 seed = keccak256(
            abi.encodePacked(
                to,
                msg.sender,
                block.prevrandao,
                block.number,
                block.timestamp,
                tokenId
            )
        );

        uint8[23] storage genes = agentGenes[tokenId];
        for (uint256 i = 0; i < 23; i++) {
            genes[i] = uint8(uint256(seed >> (i * 8)));
        }

        lastEatBlock[tokenId] = block.number;
        agentEnergy[tokenId]  = ENERGY_INIT_GENESIS;

        _mint(to, tokenId);

        emit GenesisMinted(tokenId, to, price, genes[21] % 2 == 0 ? 0 : 1);
    }

    /* ========== PRICE ========== */

    function getGenesisPrice() public view returns (uint256) {
        uint256 tier = totalGenesisCount / PRICE_STEP_SIZE;
        uint256 price = GENESIS_BASE_PRICE;
        for (uint256 i = 0; i < tier; i++) {
            price = (price * PRICE_MULTIPLIER) / PRICE_DIVISOR;
        }
        return price;
    }

    /* ========== DNA ATTRIBUTES (view) ========== */

    function getGenes(uint256 tokenId) external view returns (uint8[23] memory) {
        return agentGenes[tokenId];
    }

    // Fix: GC-P2 — cumulative then divide for better precision
    function _getAttributes(uint256 tokenId) internal view returns (uint16[8] memory attrs, uint8 gender) {
        uint8[23] storage g = agentGenes[tokenId];

        attrs[0] = (uint16(g[0]) * 4 + uint16(g[8]) * 3 + uint16(g[5]) * 3) / 10; // Fix: GC-P2
        attrs[1] = (uint16(g[7]) * 5 + uint16(g[5]) * 3 + uint16(g[1]) * 2) / 10; // Fix: GC-P2
        attrs[2] = (uint16(g[1]) * 6 + uint16(g[2]) * 4) / 10;                     // Fix: GC-P2
        attrs[3] = (uint16(g[2]) * 7 + uint16(g[6]) * 3) / 10;                     // Fix: GC-P2
        attrs[4] = (uint16(g[5]) * 5 + uint16(g[4]) * 5) / 10;                     // Fix: GC-P2
        attrs[5] = (uint16(g[6]) * 6 + uint16(g[3]) * 4) / 10;                     // Fix: GC-P2
        attrs[6] = (uint16(g[4]) * 5 + uint16(g[8]) * 5) / 10;                     // Fix: GC-P2
        attrs[7] = 100 + uint16(g[22]) * 3 / 10;

        gender = g[21] % 2 == 0 ? 0 : 1;
    }

    function getAttributes(uint256 tokenId) external view returns (uint16[8] memory attrs, uint8 gender) {
        return _getAttributes(tokenId);
    }

    function getGender(uint256 tokenId) external view returns (uint8) {
        return agentGenes[tokenId][21] % 2 == 0 ? 0 : 1;
    }

    // Fix: GC-P4 — use internal _getAttributes instead of this.getAttributes
    function getEffectiveAttribute(uint256 tokenId, uint8 attrIdx) external view returns (uint16) {
        (uint16[8] memory base, ) = _getAttributes(tokenId);
        return base[attrIdx] + agentAttributeBonus[tokenId][attrIdx];
    }

    function getDNAAttribute(uint256 tokenId, uint8 attrIdx) external view returns (uint16) {
        (uint16[8] memory base, ) = _getAttributes(tokenId);
        return base[attrIdx];
    }

    /* ========== GAME-ONLY WRITE FUNCTIONS ========== */

    // Fix: GC-P3 + V4-H5 — energy cap enforced with hard maximum
    uint256 public constant MAX_ENERGY = 500;
    function setEnergy(uint256 tokenId, uint256 energy) external onlyGame {
        require(energy <= MAX_ENERGY, "energy overflow"); // Fix: V4-H5
        agentEnergy[tokenId] = energy;
    }

    function setLastEatBlock(uint256 tokenId, uint256 blockNum) external onlyGame {
        lastEatBlock[tokenId] = blockNum;
    }

    function incrementReproduceCount(uint256 tokenId) external onlyGame {
        reproduceCount[tokenId]++;
    }

    function addAttributeBonus(uint256 tokenId, uint8 attrIdx, uint16 bonus) external onlyGame {
        uint16 current = agentAttributeBonus[tokenId][attrIdx];
        if (current + bonus > 20) revert AttributeOverflow(tokenId, attrIdx);
        agentAttributeBonus[tokenId][attrIdx] = current + bonus;
    }

    // Fix: GC-P5 — independent offspring counter
    function mintOffspring(
        address to,
        uint256 fatherId,
        uint256 motherId
    ) external onlyGameOrRepro returns (uint256 childId) { // Fix: R3-MEDIUM-1
        childId = 10_000 + offspringCount; // Fix: GC-P5
        offspringCount++;
        totalTokenCount++;

        uint8[23] storage fGenes = agentGenes[fatherId];
        uint8[23] storage mGenes = agentGenes[motherId];
        uint8[23] storage cGenes = agentGenes[childId];

        for (uint256 i = 0; i < 23; i++) {
            bytes32 r = keccak256(abi.encodePacked(fatherId, motherId, i, block.prevrandao, block.number));
            cGenes[i] = uint8(r[0]) % 2 == 0 ? fGenes[i] : mGenes[i];
            if (uint8(r[1]) < 3) {
                cGenes[i] = uint8(r[2]);
            }
        }

        lastEatBlock[childId] = block.number;
        agentEnergy[childId]  = 50;

        _mint(to, childId);

        emit OffspringMinted(childId, fatherId, motherId, to);
        return childId;
    }

    function markDead(uint256 tokenId) external onlyGameOrDeath { // Fix: R3-MEDIUM-1
        agentEnergy[tokenId] = 0;
        lastEatBlock[tokenId] = 0;
    }
}
