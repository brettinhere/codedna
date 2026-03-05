// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title ReproductionEngine (V4 — UUPS Upgradeable)
 * @notice CodeDNA 繁殖引擎 — 子代 DNA 生成 (孟德尔遗传 + 1.17%突变 + 天才突变事件)
 *
 * Audit fixes:
 *   RE-P1: isDirectRelative now covers 3-layer (handled in FamilyTracker upgrade)
 *   RE-P2: Reproduce cooldown — enforced in BehaviorEngine (REPRODUCE_COOLDOWN)
 *   RE-P3: Both parents must be same owner — enforced in BehaviorEngine
 *   RE-P4: Reproduce fee — REPRODUCE_GOLD_COST enforced in BehaviorEngine
 *   RE-P5: Attribute inheritance documentation added
 *   RE-P6: Clear delegation boundary: BehaviorEngine.reproduce() is entry, this is DNA-only
 *   RE-P7: Dead agent family state — cleaned up in FamilyTracker.removeAgent (FT-P3)
 */
contract ReproductionEngine is
    Initializable,
    OwnableUpgradeable,
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant ENERGY_INIT_OFFSPRING = 50;
    uint256 public constant MUTATION_THRESHOLD    = 3;    // uint8(r[1]) < 3 → ~1.17%
    uint256 public constant TALENT_THRESHOLD      = 240;  // gene value >= 240 = genius

    uint8 public constant GENE_IQ_PRIMARY    = 0;
    uint8 public constant GENE_CREATIVITY    = 5;
    uint8 public constant GENE_IQ_SECONDARY  = 8;

    /* ========== STATE ========== */

    address public genesisCore;
    address public gameContract;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event GeneMutated(uint256 indexed childId, uint8 geneIndex, uint8 oldValue, uint8 newValue);
    event ChildGenerated(
        uint256 indexed childId,
        uint256 indexed fatherId,
        uint256 indexed motherId,
        uint8 mutationCount,
        uint8 talentCount
    );

    /* ========== ERRORS ========== */

    error OnlyGame();
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

    function initialize(address _core, address _gameContract, address _owner) external initializer {
        if (_core == address(0)) revert ZeroAddress();
        if (_gameContract == address(0)) revert ZeroAddress();
        if (_owner == address(0)) revert ZeroAddress();

        __Ownable_init(_owner);
        __UUPSUpgradeable_init();

        genesisCore = _core;
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

    /* ========== TALENT CHECK ========== */

    function isTalentGene(uint8 geneIndex) public pure returns (bool) {
        return geneIndex == GENE_IQ_PRIMARY
            || geneIndex == GENE_CREATIVITY
            || geneIndex == GENE_IQ_SECONDARY;
    }

    /* ========== CORE: generateChild ========== */

    /**
     * @notice 生成子代：DNA继承 + 突变 + 天才检测 + 铸造 NFT + 能量初始化
     * @dev Fix: RE-P6 — This contract ONLY handles DNA generation and talent detection.
     *      All validation (cooldown, gold, relatives, capacity) is in BehaviorEngine.
     *      BehaviorEngine.reproduce() → GenesisCore.mintOffspring() handles the actual mint.
     *      This contract wraps mintOffspring with talent detection events.
     */
    function generateChild(
        uint256 fatherId,
        uint256 motherId,
        address childOwner
    ) external onlyGame returns (uint256 childId) {
        // Read parent genes
        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("getGenes(uint256)", fatherId)
        );
        require(ok1, "getGenes father failed");
        uint8[23] memory fGenes = abi.decode(d1, (uint8[23]));

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("getGenes(uint256)", motherId)
        );
        require(ok2, "getGenes mother failed");
        uint8[23] memory mGenes = abi.decode(d2, (uint8[23]));

        // Mint offspring via GenesisCore
        (bool ok3, bytes memory d3) = genesisCore.call(
            abi.encodeWithSignature("mintOffspring(address,uint256,uint256)", childOwner, fatherId, motherId)
        );
        require(ok3, "mintOffspring failed");
        childId = abi.decode(d3, (uint256));

        // Read child genes
        (bool ok4, bytes memory d4) = genesisCore.staticcall(
            abi.encodeWithSignature("getGenes(uint256)", childId)
        );
        require(ok4, "getGenes child failed");
        uint8[23] memory cGenes = abi.decode(d4, (uint8[23]));

        // Analyze mutations
        uint8 mutationCount = 0;
        uint8 talentCount   = 0;

        for (uint256 i = 0; i < 23; i++) {
            bytes32 r = keccak256(abi.encodePacked(fatherId, motherId, i, block.prevrandao, block.number));
            uint8 inheritedValue = uint8(r[0]) % 2 == 0 ? fGenes[i] : mGenes[i];

            if (cGenes[i] != inheritedValue) {
                mutationCount++;
                if (isTalentGene(uint8(i)) && cGenes[i] >= TALENT_THRESHOLD) {
                    talentCount++;
                    emit GeneMutated(childId, uint8(i), inheritedValue, cGenes[i]);
                }
            }
        }

        emit ChildGenerated(childId, fatherId, motherId, mutationCount, talentCount);
        return childId;
    }

    /**
     * @notice 纯 view 函数：预测子代基因
     * @dev Fix: RE-P5 — documented that attributes are averages of parent genes
     */
    function previewChildGenes(
        uint256 fatherId,
        uint256 motherId
    ) external view returns (
        uint8[23] memory predictedGenes,
        uint8 predictedMutations,
        bool hasTalent
    ) {
        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("getGenes(uint256)", fatherId)
        );
        require(ok1, "getGenes father failed");
        uint8[23] memory fGenes = abi.decode(d1, (uint8[23]));

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("getGenes(uint256)", motherId)
        );
        require(ok2, "getGenes mother failed");
        uint8[23] memory mGenes = abi.decode(d2, (uint8[23]));

        for (uint256 i = 0; i < 23; i++) {
            bytes32 r = keccak256(abi.encodePacked(fatherId, motherId, i, block.prevrandao, block.number));
            predictedGenes[i] = uint8(r[0]) % 2 == 0 ? fGenes[i] : mGenes[i];
            if (uint8(r[1]) < MUTATION_THRESHOLD) {
                uint8 mutatedVal = uint8(r[2]);
                predictedGenes[i] = mutatedVal;
                predictedMutations++;
                if (isTalentGene(uint8(i)) && mutatedVal >= TALENT_THRESHOLD) {
                    hasTalent = true;
                }
            }
        }
    }
}
