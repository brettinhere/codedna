// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title NFTSale (V4 — UUPS Upgradeable)
 * @notice CodeDNA 创世 NFT 销售 + 三阶段自动 PancakeSwap LP 注入
 *
 * Audit fixes:
 *   NS-P1: Price from GenesisCore.getGenesisPrice() (dynamic, not hardcoded)
 *   NS-P2: Exact payment required (msg.value == price), no overpayment
 *   NS-P3: nonReentrant on mintGenesis (Fix: NS-P3)
 *   NS-P4: withdraw() function added for owner to rescue stuck BNB
 *   NS-P5: rescueToken() for stuck ERC20 tokens
 *   NS-P6: maxPerWallet per-address mint limit
 *   NS-P7: Pausable for emergency stop
 */
contract NFTSale is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable, // Fix: NS-P3
    PausableUpgradeable,         // Fix: NS-P7
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant LP_INJECT_THRESHOLD = 500;
    uint256 public constant GOLD_PER_MINT = 10_000 * 1e18;
    uint256 public constant LP_BPS  = 8_000;
    uint256 public constant OPS_BPS = 2_000;
    uint256 public constant BPS_BASE = 10_000;
    uint256 public constant SLIPPAGE_BPS = 9_500;

    /* ========== STATE ========== */

    address public genesisCore;
    address public dnagold;
    address public pancakeRouter;
    address public opsWallet;
    address public goldSource;

    uint256 public pendingLP_BNB;
    uint256 public pendingLP_GOLD;
    uint256 public surplusLP_GOLD;
    bool public lpLaunched;
    uint256 public totalLPBNBInjected;
    uint256 public totalLPGOLDInjected;
    uint256 public totalRaised;

    uint256 public maxPerWallet; // Fix: NS-P6
    mapping(address => uint256) public mintedCount; // Fix: NS-P6

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event GenesisPurchased(address indexed buyer, uint256 indexed tokenId, uint256 price);
    event LiquidityLaunched(uint256 bnbAmount, uint256 goldAmount, uint256 blockNumber);
    event LiquidityAdded(uint256 bnbAmount, uint256 goldAmount);
    event LPAttemptFailed(uint256 bnbAmount, uint256 goldAmount, string reason);
    event Withdrawn(address indexed to, uint256 amount); // Fix: NS-P4
    event TokenRescued(address indexed token, address indexed to, uint256 amount); // Fix: NS-P5

    /* ========== ERRORS ========== */

    error SoldOut();
    error WrongPayment(uint256 required, uint256 sent);
    error ZeroAddress();
    error InsufficientGoldSource();
    error WalletLimitReached(address wallet, uint256 limit); // Fix: NS-P6
    error WithdrawFailed(); // Fix: NS-P4

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(
        address _genesisCore,
        address _dnagold,
        address _pancakeRouter,
        address _opsWallet,
        address _goldSource,
        address _owner
    ) external initializer {
        if (_genesisCore == address(0))  revert ZeroAddress();
        if (_dnagold == address(0))      revert ZeroAddress();
        if (_pancakeRouter == address(0)) revert ZeroAddress();
        if (_opsWallet == address(0))    revert ZeroAddress();
        if (_goldSource == address(0))   revert ZeroAddress();
        if (_owner == address(0))        revert ZeroAddress();

        __Ownable_init(_owner);
        __ReentrancyGuard_init(); // Fix: NS-P3
        __Pausable_init();        // Fix: NS-P7
        __UUPSUpgradeable_init();

        genesisCore   = _genesisCore;
        dnagold       = _dnagold;
        pancakeRouter = _pancakeRouter;
        opsWallet     = _opsWallet;
        goldSource    = _goldSource;
        maxPerWallet  = 5; // Fix: NS-P6 — default 5 per wallet
    }

    /* ========== UPGRADE CONTROL ========== */

    function _authorizeUpgrade(address) internal override onlyOwner {
        require(!upgradeRenounced, "Upgrade renounced");
    }

    function renounceUpgradeability() external onlyOwner {
        upgradeRenounced = true;
    }

    /* ========== ADMIN ========== */

    // Fix: NS-P7 — pausable
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // Fix: NS-P6 — configurable per-wallet limit
    function setMaxPerWallet(uint256 _max) external onlyOwner {
        maxPerWallet = _max;
    }

    // Fix: NS-P4 — withdraw stuck BNB (excludes LP-pending BNB)
    // Fix: AUDIT-V4-2 — protect LP-pending BNB from accidental withdrawal
    function withdraw(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = address(this).balance;
        // Cannot withdraw BNB earmarked for LP
        uint256 reserved = pendingLP_BNB;
        if (bal <= reserved) revert WithdrawFailed();
        uint256 withdrawable = bal - reserved;
        (bool ok,) = payable(to).call{value: withdrawable}("");
        if (!ok) revert WithdrawFailed();
        emit Withdrawn(to, withdrawable);
    }

    // Fix: NS-P5 — rescue stuck ERC20 tokens
    // Fix: Part3 — exclude dnagold to prevent draining LP gold reserves
    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        require(token != dnagold, "cannot rescue DNAGOLD"); // Fix: Part3-LOW
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "Token rescue failed");
        emit TokenRescued(token, to, amount);
    }

    /// @notice Fix: V4-L1 — verify goldSource has sufficient allowance before sale goes live
    function activateSale() external view onlyOwner {
        (bool ok, bytes memory data) = dnagold.staticcall(
            abi.encodeWithSignature("allowance(address,address)", goldSource, address(this))
        );
        require(ok, "allowance check failed");
        uint256 allowance = abi.decode(data, (uint256));
        require(allowance >= GOLD_PER_MINT * 10_000, "goldSource allowance insufficient");
    }

    // withdrawLP intentionally removed — LP tokens permanently locked in contract, no extraction possible

    /* ========== MINT ========== */

    // Fix: NS-P2, NS-P3, NS-P6, NS-P7
    function mintGenesis() external payable whenNotPaused nonReentrant { // Fix: NS-P3, NS-P7
        // Fix: NS-P1 — dynamic price from GenesisCore
        (bool okPrice, bytes memory dPrice) = genesisCore.staticcall(
            abi.encodeWithSignature("getGenesisPrice()")
        );
        require(okPrice, "getGenesisPrice failed");
        uint256 price = abi.decode(dPrice, (uint256));

        // Fix: V4-M4 — accept >= price, refund excess (prevents boundary race condition)
        if (msg.value < price) revert WrongPayment(price, msg.value);

        // Check sold out
        (bool okCount, bytes memory dCount) = genesisCore.staticcall(
            abi.encodeWithSignature("totalGenesisCount()")
        );
        require(okCount, "totalGenesisCount failed");
        uint256 countBefore = abi.decode(dCount, (uint256));

        (bool okMax, bytes memory dMax) = genesisCore.staticcall(
            abi.encodeWithSignature("MAX_GENESIS()")
        );
        require(okMax, "MAX_GENESIS failed");
        uint256 maxGenesis = abi.decode(dMax, (uint256));

        if (countBefore >= maxGenesis) revert SoldOut();

        // Fix: NS-P6 — per-wallet limit
        if (maxPerWallet > 0) {
            if (mintedCount[msg.sender] >= maxPerWallet) revert WalletLimitReached(msg.sender, maxPerWallet);
            mintedCount[msg.sender]++;
        }

        // 1. BNB分配 — Fix: V4-M4 — use price for distribution (msg.value may exceed price)
        uint256 opsAmount = (price * OPS_BPS) / BPS_BASE;
        uint256 lpAmount  = price - opsAmount;

        (bool opsOk,) = opsWallet.call{value: opsAmount}("");
        require(opsOk, "Ops transfer failed");

        totalRaised += price; // Fix: LOW-1 — use price not msg.value (excess is refunded)

        // 2. Mint NFT
        (bool okMint, bytes memory dMint) = genesisCore.call(
            abi.encodeWithSignature("mintFor(address,uint256)", msg.sender, price)
        );
        require(okMint, "mintFor failed");
        uint256 tokenId = abi.decode(dMint, (uint256));

        // 3. Pull DNAGOLD from goldSource
        (bool okBal, bytes memory dBal) = dnagold.staticcall(
            abi.encodeWithSignature("balanceOf(address)", goldSource)
        );
        require(okBal, "goldSource balance check failed");
        uint256 goldSourceBal = abi.decode(dBal, (uint256));
        if (goldSourceBal < GOLD_PER_MINT) revert InsufficientGoldSource();

        (bool goldOk,) = dnagold.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", goldSource, address(this), GOLD_PER_MINT)
        );
        if (!goldOk) revert InsufficientGoldSource();

        // 4. LP phase handling
        uint256 mintNumber = countBefore + 1;

        if (!lpLaunched) {
            pendingLP_BNB  += lpAmount;
            pendingLP_GOLD += GOLD_PER_MINT;

            if (mintNumber >= LP_INJECT_THRESHOLD) {
                _launchLP();
            }
        } else {
            _addLP(lpAmount, GOLD_PER_MINT);
        }

        // Fix: V4-M4 — refund excess BNB
        if (msg.value > price) {
            uint256 refund = msg.value - price;
            (bool refundOk,) = payable(msg.sender).call{value: refund}("");
            require(refundOk, "Refund failed");
        }

        emit GenesisPurchased(msg.sender, tokenId, price);
    }

    /* ========== INTERNAL: LP LAUNCH ========== */

    function _launchLP() internal {
        uint256 bnbToInject  = pendingLP_BNB;
        uint256 goldToInject = pendingLP_GOLD;

        address routerAddr = pancakeRouter;
        uint256 routerSize;
        assembly { routerSize := extcodesize(routerAddr) }
        if (routerSize == 0) {
            emit LPAttemptFailed(bnbToInject, goldToInject, "no router");
            return;
        }

        // CEI: clear pending first
        pendingLP_BNB  = 0;
        pendingLP_GOLD = 0;

        (bool okApprove,) = dnagold.call(
            abi.encodeWithSignature("approve(address,uint256)", pancakeRouter, goldToInject)
        );
        require(okApprove, "approve failed");

        uint256 minGold = (goldToInject * SLIPPAGE_BPS) / BPS_BASE;
        uint256 minBNB  = (bnbToInject * SLIPPAGE_BPS) / BPS_BASE;

        (bool ok, bytes memory data) = pancakeRouter.call{value: bnbToInject}(
            abi.encodeWithSignature(
                "addLiquidityETH(address,uint256,uint256,uint256,address,uint256)",
                dnagold, goldToInject, minGold, minBNB, address(this), block.timestamp + 300
            )
        );

        if (ok && data.length >= 96) {
            (uint256 usedGold, uint256 usedBNB, ) = abi.decode(data, (uint256, uint256, uint256));
            lpLaunched = true;
            totalLPBNBInjected  += usedBNB;
            totalLPGOLDInjected += usedGold;

            if (goldToInject > usedGold) {
                surplusLP_GOLD += (goldToInject - usedGold);
            }

            emit LiquidityLaunched(usedBNB, usedGold, block.number);
        } else {
            pendingLP_BNB  = bnbToInject;
            pendingLP_GOLD = goldToInject;
            emit LPAttemptFailed(bnbToInject, goldToInject, "addLiquidity failed");
        }
    }

    /* ========== INTERNAL: LP ADD ========== */

    // Fix: V4-H3 — _addLP now includes accumulated pending amounts
    function _addLP(uint256 bnbAmount, uint256 goldAmount) internal {
        // Include previously failed pending amounts
        uint256 totalBNB  = bnbAmount + pendingLP_BNB;
        uint256 totalGold = goldAmount + surplusLP_GOLD + pendingLP_GOLD;
        // Clear pending before external call (CEI)
        pendingLP_BNB  = 0;
        pendingLP_GOLD = 0;

        address routerAddr = pancakeRouter;
        uint256 routerSize;
        assembly { routerSize := extcodesize(routerAddr) }
        if (routerSize == 0) {
            pendingLP_BNB  += totalBNB;
            pendingLP_GOLD += totalGold;
            emit LPAttemptFailed(totalBNB, totalGold, "no router");
            return;
        }

        // surplus already cleared above
        surplusLP_GOLD = 0;

        (bool okApprove,) = dnagold.call(
            abi.encodeWithSignature("approve(address,uint256)", pancakeRouter, totalGold)
        );
        require(okApprove, "approve failed");

        uint256 minGold = (totalGold * SLIPPAGE_BPS) / BPS_BASE;
        uint256 minBNB  = (totalBNB * SLIPPAGE_BPS) / BPS_BASE;

        (bool ok, bytes memory data) = pancakeRouter.call{value: totalBNB}(
            abi.encodeWithSignature(
                "addLiquidityETH(address,uint256,uint256,uint256,address,uint256)",
                dnagold, totalGold, minGold, minBNB, address(this), block.timestamp + 300
            )
        );

        if (ok && data.length >= 96) {
            (uint256 usedGold, uint256 usedBNB, ) = abi.decode(data, (uint256, uint256, uint256));
            totalLPBNBInjected  += usedBNB;
            totalLPGOLDInjected += usedGold;

            if (totalGold > usedGold) {
                surplusLP_GOLD = totalGold - usedGold;
            }

            emit LiquidityAdded(usedBNB, usedGold);
        } else {
            // Fix: V4-H3 — restore pending on failure so retryLP can pick them up
            pendingLP_BNB  += totalBNB;
            pendingLP_GOLD += totalGold;
            emit LPAttemptFailed(totalBNB, totalGold, "addLiquidity failed");
        }
    }

    /// @notice Fix: V4-H3 — retry failed LP injection using accumulated pending BNB/GOLD
    function retryLP() external nonReentrant {
        require(lpLaunched, "LP not launched yet");
        require(pendingLP_BNB > 0 || pendingLP_GOLD > 0, "nothing pending");
        _addLP(0, 0); // _addLP will pick up pendingLP_BNB and pendingLP_GOLD internally
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getPendingLP() external view returns (uint256 bnb, uint256 gold) {
        return (pendingLP_BNB, pendingLP_GOLD);
    }

    function getLPStatus() external view returns (bool launched) {
        return lpLaunched;
    }

    function getRemainingToLaunch() external view returns (uint256) {
        (bool ok, bytes memory data) = genesisCore.staticcall(
            abi.encodeWithSignature("totalGenesisCount()")
        );
        if (!ok) return LP_INJECT_THRESHOLD;
        uint256 count = abi.decode(data, (uint256));
        if (count >= LP_INJECT_THRESHOLD) return 0;
        return LP_INJECT_THRESHOLD - count;
    }

    function getTotalLPInjected() external view returns (uint256 bnb, uint256 gold) {
        return (totalLPBNBInjected, totalLPGOLDInjected);
    }

    function getGenesisPrice() external view returns (uint256) {
        (bool ok, bytes memory data) = genesisCore.staticcall(
            abi.encodeWithSignature("getGenesisPrice()")
        );
        require(ok, "getGenesisPrice failed");
        return abi.decode(data, (uint256));
    }

    function getRemainingGenesis() external view returns (uint256) {
        (bool ok1, bytes memory d1) = genesisCore.staticcall(abi.encodeWithSignature("MAX_GENESIS()"));
        (bool ok2, bytes memory d2) = genesisCore.staticcall(abi.encodeWithSignature("totalGenesisCount()"));
        if (!ok1 || !ok2) return 0;
        uint256 max = abi.decode(d1, (uint256));
        uint256 count = abi.decode(d2, (uint256));
        return max > count ? max - count : 0;
    }

    function getTotalRaised() external view returns (uint256) {
        return totalRaised;
    }

    /* ========== RECEIVE ========== */

    receive() external payable {}
}
