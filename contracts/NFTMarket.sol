// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title NFTMarket (V4 — UUPS Upgradeable)
 * @notice CodeDNA Agent 二级交易市场 — 用解锁态 DNAGOLD 买卖 Agent NFT
 *
 * Audit fixes:
 *   NM-P1: Escrow mode (NFT transferred to contract on listing) — already correct
 *   NM-P2: nonReentrant on buyAgent + CEI pattern (delete listing before transfers)
 *   NM-P3: Agent death check on buyAgent (isDead check)
 *   NM-P4: MAX_FEE cap on platformFee (max 10%)
 *   NM-P5: Exact payment via ERC20 — overpayment N/A for ERC20
 *   NM-P6: MIN_PRICE for listings (prevent zero-price front-running)
 *   NM-P7: Pausable for emergency stop
 *   NM-P8: listAgent checks agent not on map (force remove before listing)
 */
contract NFTMarket is
    Initializable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable, // Fix: NM-P2
    PausableUpgradeable,         // Fix: NM-P7
    UUPSUpgradeable
{
    /* ========== CONSTANTS ========== */

    uint256 public constant FEE_BPS  = 25;    // 2.5% default
    uint256 public constant BPS_BASE = 1000;
    uint256 public constant MAX_FEE  = 100;   // Fix: NM-P4 — max 10%
    uint256 public constant MIN_PRICE = 1 * 1e18; // Fix: NM-P6 — minimum 1 DNAGOLD

    /* ========== STRUCTS ========== */

    struct Listing {
        address seller;
        uint256 price;     // DNAGOLD (18 decimals)
        uint256 listedAt;  // block.number
    }

    /* ========== STATE ========== */

    address public dnagold;
    address public genesisCore;
    address public deathEngine;
    address public feeAddress;
    address public worldMapAddr;   // Fix: V4-H2 — for map removal on listing
    address public economyAddr;    // Fix: V4-H2 — for plot cleanup on listing

    uint256 public platformFee; // Fix: NM-P4 — configurable within MAX_FEE

    mapping(uint256 => Listing) public listings;
    uint256[] public activeListingIds;
    mapping(uint256 => uint256) internal _listingIndex;

    uint256 public totalFeesCollected;
    uint256 public totalVolume;

    bool public upgradeRenounced;

    /* ========== EVENTS ========== */

    event AgentListed(uint256 indexed tokenId, address indexed seller, uint256 price);
    event AgentDelisted(uint256 indexed tokenId, address indexed seller);
    event AgentSold(uint256 indexed tokenId, address indexed seller, address indexed buyer, uint256 price, uint256 fee);
    event DeadListingCleaned(uint256 indexed tokenId, address indexed seller);
    event PlatformFeeUpdated(uint256 oldFee, uint256 newFee); // Fix: NM-P4

    /* ========== ERRORS ========== */

    error NotOwner(uint256 tokenId, address caller);
    error NotSeller(uint256 tokenId, address caller);
    error NotListed(uint256 tokenId);
    error AlreadyListed(uint256 tokenId);
    error AgentIsDead(uint256 tokenId);
    error InsufficientBalance(uint256 have, uint256 need);
    error InsufficientAllowance(uint256 have, uint256 need);
    error PriceTooLow(uint256 price, uint256 minPrice); // Fix: NM-P6
    error ZeroAddress();
    error TransferFailed();
    error BuyOwnListing();
    error AgentNotDead(uint256 tokenId);
    error FeeTooHigh(uint256 fee, uint256 maxFee); // Fix: NM-P4

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(
        address _dnagold,
        address _genesisCore,
        address _deathEngine,
        address _feeAddress,
        address _owner
    ) external initializer {
        if (_dnagold == address(0))     revert ZeroAddress();
        if (_genesisCore == address(0)) revert ZeroAddress();
        if (_deathEngine == address(0)) revert ZeroAddress();
        if (_feeAddress == address(0))  revert ZeroAddress();
        if (_owner == address(0))       revert ZeroAddress();

        __Ownable_init(_owner);
        __ReentrancyGuard_init(); // Fix: NM-P2
        __Pausable_init();        // Fix: NM-P7
        __UUPSUpgradeable_init();

        dnagold       = _dnagold;
        genesisCore   = _genesisCore;
        deathEngine   = _deathEngine;
        feeAddress    = _feeAddress;
        platformFee   = FEE_BPS; // Fix: NM-P4 — default 2.5%
    }

    /* ========== UPGRADE CONTROL ========== */

    function _authorizeUpgrade(address) internal override onlyOwner {
        require(!upgradeRenounced, "Upgrade renounced");
    }

    function renounceUpgradeability() external onlyOwner {
        upgradeRenounced = true;
    }

    /* ========== ADMIN ========== */

    // Fix: NM-P7 — pausable
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    // Fix: NM-P4 — fee cap enforced
    function setPlatformFee(uint256 newFee) external onlyOwner {
        if (newFee > MAX_FEE) revert FeeTooHigh(newFee, MAX_FEE);
        emit PlatformFeeUpdated(platformFee, newFee);
        platformFee = newFee;
    }

    function setFeeAddress(address _feeAddress) external onlyOwner {
        if (_feeAddress == address(0)) revert ZeroAddress();
        feeAddress = _feeAddress;
    }

    // Fix: V4-H2 — setters for map/economy addresses
    function setWorldMap(address _worldMap) external onlyOwner {
        require(_worldMap != address(0), "zero addr");
        worldMapAddr = _worldMap;
    }
    function setEconomy(address _economy) external onlyOwner {
        require(_economy != address(0), "zero addr");
        economyAddr = _economy;
    }

    /* ========== LIST ========== */

    // Fix: NM-P1 (Escrow), NM-P6 (MIN_PRICE), NM-P7 (Pausable), NM-P8 (map check)
    function listAgent(uint256 tokenId, uint256 price) external whenNotPaused nonReentrant {
        // Fix: R3-MEDIUM-2 — ensure map/economy addresses are configured
        require(worldMapAddr != address(0) && economyAddr != address(0), "map/economy not configured");
        // Fix: NM-P6 — minimum price
        if (price < MIN_PRICE) revert PriceTooLow(price, MIN_PRICE);
        if (listings[tokenId].seller != address(0)) revert AlreadyListed(tokenId);

        // Ownership check
        (bool ok1, bytes memory d1) = genesisCore.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", tokenId)
        );
        require(ok1, "ownerOf failed");
        address nftOwner = abi.decode(d1, (address));
        if (nftOwner != msg.sender) revert NotOwner(tokenId, msg.sender);

        // Fix: NM-P3 — death check
        if (_isAgentDead(tokenId)) revert AgentIsDead(tokenId);

        // Fix: V4-H2 — force remove agent from map before listing
        {
            (bool okMap, bytes memory dMap) = worldMapAddr.staticcall(
                abi.encodeWithSignature("agentOnMap(uint256)", tokenId)
            );
            if (okMap && dMap.length >= 32 && abi.decode(dMap, (bool))) {
                // Get current location for economy cleanup
                (bool okLoc, bytes memory dLoc) = worldMapAddr.staticcall(
                    abi.encodeWithSignature("agentLocation(uint256)", tokenId)
                );
                uint256 plotId = (okLoc && dLoc.length >= 32) ? abi.decode(dLoc, (uint256)) : 0;

                worldMapAddr.call(abi.encodeWithSignature("removeAgent(uint256)", tokenId));
                economyAddr.call(abi.encodeWithSignature("removeAgentFromPlot(uint256,uint256)", tokenId, plotId));
                // Fix: MEDIUM-2 — decrement living count when agent leaves map
                economyAddr.call(abi.encodeWithSignature("decrementLiving()"));
            }
        }

        // Fix: NM-P1 — Escrow mode: transfer NFT to this contract
        (bool ok2,) = genesisCore.call(
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", msg.sender, address(this), tokenId)
        );
        require(ok2, "NFT transfer failed");

        // Record listing
        listings[tokenId] = Listing({
            seller: msg.sender,
            price: price,
            listedAt: block.number
        });

        _listingIndex[tokenId] = activeListingIds.length;
        activeListingIds.push(tokenId);

        emit AgentListed(tokenId, msg.sender, price);
    }

    /* ========== CANCEL ========== */

    function cancelListing(uint256 tokenId) external whenNotPaused nonReentrant {
        Listing storage lst = listings[tokenId];
        if (lst.seller == address(0)) revert NotListed(tokenId);
        if (lst.seller != msg.sender) revert NotSeller(tokenId, msg.sender);

        address seller = lst.seller;

        // CEI: remove listing first
        _removeListing(tokenId);

        // Return NFT
        (bool ok,) = genesisCore.call(
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(this), seller, tokenId)
        );
        require(ok, "NFT return failed");

        emit AgentDelisted(tokenId, seller);
    }

    /* ========== BUY ========== */

    // Fix: NM-P2 (nonReentrant + CEI), NM-P3 (death check)
    function buyAgent(uint256 tokenId) external whenNotPaused nonReentrant { // Fix: NM-P2
        Listing storage lst = listings[tokenId];
        if (lst.seller == address(0)) revert NotListed(tokenId);
        if (lst.seller == msg.sender) revert BuyOwnListing();

        // Fix: NM-P3 — death check
        if (_isAgentDead(tokenId)) revert AgentIsDead(tokenId);

        address seller = lst.seller;
        uint256 price  = lst.price;

        // Fee calculation
        uint256 fee      = (price * platformFee) / BPS_BASE;
        uint256 sellerAmt = price - fee;

        // Check buyer balance + allowance
        (bool okBal, bytes memory dBal) = dnagold.staticcall(
            abi.encodeWithSignature("balanceOf(address)", msg.sender)
        );
        require(okBal, "balanceOf failed");
        uint256 buyerBal = abi.decode(dBal, (uint256));
        if (buyerBal < price) revert InsufficientBalance(buyerBal, price);

        (bool okAllow, bytes memory dAllow) = dnagold.staticcall(
            abi.encodeWithSignature("allowance(address,address)", msg.sender, address(this))
        );
        require(okAllow, "allowance failed");
        uint256 buyerAllowance = abi.decode(dAllow, (uint256));
        if (buyerAllowance < price) revert InsufficientAllowance(buyerAllowance, price);

        // Fix: NM-P2 — CEI: delete listing BEFORE any external calls
        _removeListing(tokenId);

        // DNAGOLD transfers
        (bool ok1,) = dnagold.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, seller, sellerAmt)
        );
        if (!ok1) revert TransferFailed();

        if (fee > 0) {
            (bool ok2,) = dnagold.call(
                abi.encodeWithSignature("transferFrom(address,address,uint256)", msg.sender, feeAddress, fee)
            );
            if (!ok2) revert TransferFailed();
        }

        // NFT transfer to buyer
        (bool ok3,) = genesisCore.call(
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(this), msg.sender, tokenId)
        );
        require(ok3, "NFT transfer to buyer failed");

        totalFeesCollected += fee;
        totalVolume += price;

        emit AgentSold(tokenId, seller, msg.sender, price, fee);
    }

    /* ========== DEAD LISTING CLEANUP ========== */

    function cleanDeadListing(uint256 tokenId) external whenNotPaused nonReentrant {
        Listing storage lst = listings[tokenId];
        if (lst.seller == address(0)) revert NotListed(tokenId);
        if (!_isAgentDead(tokenId)) revert AgentNotDead(tokenId);

        address seller = lst.seller;

        _removeListing(tokenId);

        // Trigger formal death
        try this._callCheckDeath(tokenId) {} catch {}

        // Return NFT to seller
        (bool ok,) = genesisCore.call(
            abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", address(this), seller, tokenId)
        );
        require(ok, "NFT return failed");

        emit DeadListingCleaned(tokenId, seller);
    }

    /* ========== VIEW FUNCTIONS ========== */

    function getActiveListingCount() external view returns (uint256) {
        return activeListingIds.length;
    }

    function getActiveListings(uint256 offset, uint256 limit) external view returns (
        uint256[] memory tokenIds,
        address[] memory sellers,
        uint256[] memory prices,
        uint256[] memory lockedBalances
    ) {
        uint256 total = activeListingIds.length;
        if (offset >= total) {
            return (new uint256[](0), new address[](0), new uint256[](0), new uint256[](0));
        }

        uint256 end = offset + limit;
        if (end > total) end = total;
        uint256 count = end - offset;

        tokenIds       = new uint256[](count);
        sellers        = new address[](count);
        prices         = new uint256[](count);
        lockedBalances = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            uint256 tid = activeListingIds[offset + i];
            Listing storage lst = listings[tid];
            tokenIds[i] = tid;
            sellers[i]  = lst.seller;
            prices[i]   = lst.price;

            (bool ok, bytes memory data) = dnagold.staticcall(
                abi.encodeWithSignature("lockedBalance(uint256)", tid)
            );
            if (ok && data.length >= 32) lockedBalances[i] = abi.decode(data, (uint256));
        }
    }

    function getListingDetail(uint256 tokenId) external view returns (
        address seller,
        uint256 price,
        uint256 listedAt,
        uint256 locked,
        uint16[8] memory attrs,
        uint8 gender
    ) {
        Listing storage lst = listings[tokenId];
        seller   = lst.seller;
        price    = lst.price;
        listedAt = lst.listedAt;

        (bool ok1, bytes memory d1) = dnagold.staticcall(
            abi.encodeWithSignature("lockedBalance(uint256)", tokenId)
        );
        if (ok1 && d1.length >= 32) locked = abi.decode(d1, (uint256));

        (bool ok2, bytes memory d2) = genesisCore.staticcall(
            abi.encodeWithSignature("getAttributes(uint256)", tokenId)
        );
        if (ok2 && d2.length >= 288) (attrs, gender) = abi.decode(d2, (uint16[8], uint8));
    }

    /* ========== INTERNAL ========== */

    function _removeListing(uint256 tokenId) internal {
        delete listings[tokenId];

        uint256 index = _listingIndex[tokenId];
        uint256 lastIndex = activeListingIds.length - 1;
        if (index != lastIndex) {
            uint256 lastId = activeListingIds[lastIndex];
            activeListingIds[index] = lastId;
            _listingIndex[lastId] = index;
        }
        activeListingIds.pop();
        delete _listingIndex[tokenId];
    }

    // Fix: NM-P3 — death check
    function _isAgentDead(uint256 tokenId) internal view returns (bool) {
        (bool ok1, bytes memory d1) = deathEngine.staticcall(
            abi.encodeWithSignature("isDead(uint256)", tokenId)
        );
        if (ok1 && d1.length >= 32 && abi.decode(d1, (bool))) return true;

        (bool ok2, bytes memory d2) = deathEngine.staticcall(
            abi.encodeWithSignature("isEffectivelyDead(uint256)", tokenId)
        );
        if (ok2 && d2.length >= 32) return abi.decode(d2, (bool));
        return false;
    }

    function _callCheckDeath(uint256 tokenId) external {
        (bool ok,) = deathEngine.call(abi.encodeWithSignature("checkDeath(uint256)", tokenId));
        ok; // suppress warning
    }

    /* ========== ERC721 RECEIVER ========== */

    // Fix: Part3 — only accept NFTs from GenesisCore
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        require(msg.sender == genesisCore, "only GenesisCore NFTs");
        return this.onERC721Received.selector;
    }
}
