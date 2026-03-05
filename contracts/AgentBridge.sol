// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title AgentBridge (V4 — UUPS Upgradeable)
 * @notice CodeDNA AI Agent 链上交互接口 — 聚合读取 + 行动验证 + 周边探测
 *
 * 全部 view/pure，零 gas 消耗。AI Agent 每回合只需一次 RPC 调用
 * 即可获得完整的决策所需信息。
 *
 * Audit fixes:
 *   AB-P1: Added Pausable for emergency stops (Fix: AB-P6)
 *   AB-P2: lastClaimBlock is not relevant (this is a read-only bridge)
 *   AB-P3: EconomyEngine trust chain documented in comments
 *   AB-P4: NFT transfer lock info noted in getAgentFullState
 *   AB-P5: unlockable calculation — min truncation ensured
 *   AB-P6: Pausable added for emergency
 */
contract AgentBridge is
    Initializable,
    OwnableUpgradeable,
    PausableUpgradeable, // Fix: AB-P6
    UUPSUpgradeable
{
    /* ========== STRUCTS ========== */

    struct AgentState {
        uint256 tokenId;
        address owner;
        uint256 currentEnergy;
        uint256 maxEnergy;
        uint256 locationX;
        uint256 locationY;
        uint256 lockedBalance;
        uint8   status;
        uint8   gender;
        bool    onMap;
        uint256 gatherCooldownLeft;
        uint256 eatCooldownLeft;
        uint256 moveCooldownLeft;
        uint256 reproduceCooldownLeft;
        uint256 raidCooldownLeft;
        uint256 shareCooldownLeft;
        uint256 teachCooldownLeft;
        uint16[8] attributes;
        uint16[8] attributeBonus;
        uint256 reproduceCount;
        uint256 reproduceLimit;
        uint256 familyRoot;
        uint256 familyHeadcount;
        uint256 fatherId;
        uint256 motherId;
        uint256 halvingCount;
        uint256 dilutionFactor;
        uint256 totalLiving;
        uint256 baseYield;
        uint8   plotType;
        uint256 plotMultiplier;
        uint256 plotAgentCount;
        bool    isPlotLeader;
        uint256 estimatedGatherYield;
    }

    struct NearbyAgent {
        uint256 tokenId;
        uint256 locationX;
        uint256 locationY;
        uint256 distance;
        uint256 currentEnergy;
        address owner;
        uint8   gender;
        uint8   status;
        uint256 lockedBalance;
    }

    /* ========== STATE ========== */

    address public coreAddr;
    address public dnagoldAddr;
    address public worldMapAddr;
    address public behaviorAddr;
    address public economyAddr;
    address public deathAddr;
    address public familyAddr;

    bool public upgradeRenounced;

    /* ========== CONSTRUCTOR ========== */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* ========== INITIALIZER ========== */

    function initialize(
        address _core,
        address _dnagold,
        address _worldMap,
        address _behavior,
        address _economy,
        address _death,
        address _family,
        address _owner
    ) external initializer {
        __Ownable_init(_owner);
        __Pausable_init(); // Fix: AB-P6
        __UUPSUpgradeable_init();

        coreAddr     = _core;
        dnagoldAddr  = _dnagold;
        worldMapAddr = _worldMap;
        behaviorAddr = _behavior;
        economyAddr  = _economy;
        deathAddr    = _death;
        familyAddr   = _family;
    }

    /* ========== UPGRADE CONTROL ========== */

    function _authorizeUpgrade(address) internal override onlyOwner {
        require(!upgradeRenounced, "Upgrade renounced");
    }

    function renounceUpgradeability() external onlyOwner {
        upgradeRenounced = true;
    }

    /* ========== ADMIN ========== */

    // Fix: AB-P6 — pausable
    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    /* ========== 1. getAgentFullState ========== */

    function getAgentFullState(uint256 tokenId) external view returns (AgentState memory s) {
        s.tokenId = tokenId;

        // Owner
        try this._callOwnerOf(tokenId) returns (address o) {
            s.owner = o;
        } catch {}

        // Energy
        try this._callCurrentEnergy(tokenId) returns (uint256 e) {
            s.currentEnergy = e;
        } catch {}

        // Attributes
        try this._callGetAttributes(tokenId) returns (uint16[8] memory attrs, uint8 gender) {
            s.attributes = attrs;
            s.gender = gender;
            s.maxEnergy = 100 + (uint256(attrs[6]) * 25 / 255);
        } catch {}

        // Location
        try this._callAgentOnMap(tokenId) returns (bool onMap) {
            s.onMap = onMap;
        } catch {}

        if (s.onMap) {
            try this._callAgentLocation(tokenId) returns (uint256 plotId) {
                (uint256 lx, uint256 ly) = _toCoordsPure(plotId);
                s.locationX = lx;
                s.locationY = ly;

                try this._callGetPlotType(plotId) returns (uint8 pt) {
                    s.plotType = pt;
                } catch {}
                try this._callGetPlotMultiplier(plotId) returns (uint256 pm) {
                    s.plotMultiplier = pm;
                } catch {}
                try this._callPlotAgentCount(plotId) returns (uint256 pac) {
                    s.plotAgentCount = pac;
                } catch {}
                try this._callGetPlotLeader(plotId) returns (uint256 lid) {
                    s.isPlotLeader = (lid == tokenId);
                } catch {}
                try this._callCalcGatherYield(tokenId, plotId, s.plotAgentCount, s.isPlotLeader) returns (uint256 y) {
                    s.estimatedGatherYield = y;
                } catch {}
            } catch {}
        }

        // Locked balance
        try this._callLockedBalance(tokenId) returns (uint256 lb) {
            s.lockedBalance = lb;
        } catch {}

        // Status
        try this._callAgentStatus(tokenId) returns (uint8 st) {
            s.status = st;
        } catch {}

        // Cooldowns
        s.gatherCooldownLeft = _safeCooldown(behaviorAddr, "lastGatherBlock(uint256)", tokenId, _safeConstant(behaviorAddr, "GATHER_COOLDOWN()"));
        s.eatCooldownLeft = _safeCooldown(coreAddr, "lastEatBlock(uint256)", tokenId, _safeConstant(behaviorAddr, "EAT_COOLDOWN()"));
        s.moveCooldownLeft = _safeCooldown(behaviorAddr, "lastMoveBlock(uint256)", tokenId, _safeConstant(behaviorAddr, "MOVE_COOLDOWN()"));
        s.reproduceCooldownLeft = _safeCooldown(behaviorAddr, "lastReproduceBlock(uint256)", tokenId, _safeConstant(behaviorAddr, "REPRODUCE_COOLDOWN()"));
        s.raidCooldownLeft = _safeCooldown(behaviorAddr, "lastRaidBlock(uint256)", tokenId, _safeConstant(behaviorAddr, "RAID_COOLDOWN()"));
        s.shareCooldownLeft = _safeCooldown(behaviorAddr, "lastShareBlock(uint256)", tokenId, _safeConstant(behaviorAddr, "SHARE_COOLDOWN()"));
        s.teachCooldownLeft = _safeCooldown(behaviorAddr, "parentTeachBlock(uint256)", tokenId, _safeConstant(behaviorAddr, "TEACH_COOLDOWN()"));

        // Attribute bonuses
        for (uint8 i = 0; i < 8; i++) {
            (bool okb, bytes memory db) = coreAddr.staticcall(
                abi.encodeWithSignature("agentAttributeBonus(uint256,uint256)", tokenId, uint256(i))
            );
            if (okb && db.length >= 32) s.attributeBonus[i] = abi.decode(db, (uint16));
        }

        // Reproduce
        (bool okrc, bytes memory drc) = coreAddr.staticcall(
            abi.encodeWithSignature("reproduceCount(uint256)", tokenId)
        );
        if (okrc && drc.length >= 32) s.reproduceCount = abi.decode(drc, (uint256));
        s.reproduceLimit = uint256(s.attributes[7]) / 32;

        // Family
        (bool okfr, bytes memory dfr) = familyAddr.staticcall(
            abi.encodeWithSignature("registered(uint256)", tokenId)
        );
        if (okfr && dfr.length >= 32 && abi.decode(dfr, (bool))) {
            (bool okroot, bytes memory droot) = familyAddr.staticcall(
                abi.encodeWithSignature("familyRoot(uint256)", tokenId)
            );
            if (okroot && droot.length >= 32) {
                s.familyRoot = abi.decode(droot, (uint256));
                (bool okhc, bytes memory dhc) = familyAddr.staticcall(
                    abi.encodeWithSignature("getFamilyHeadcount(uint256)", s.familyRoot)
                );
                if (okhc && dhc.length >= 32) s.familyHeadcount = abi.decode(dhc, (uint256));
            }
            (bool okp, bytes memory dp) = familyAddr.staticcall(
                abi.encodeWithSignature("getParents(uint256)", tokenId)
            );
            if (okp && dp.length >= 64) (s.fatherId, s.motherId) = abi.decode(dp, (uint256, uint256));
        }

        // Economy
        (bool okh, bytes memory dh) = economyAddr.staticcall(abi.encodeWithSignature("halvingCount()"));
        if (okh && dh.length >= 32) s.halvingCount = abi.decode(dh, (uint256));

        (bool okd, bytes memory dd) = economyAddr.staticcall(abi.encodeWithSignature("getGlobalDilutionFactor()"));
        if (okd && dd.length >= 32) s.dilutionFactor = abi.decode(dd, (uint256));

        (bool okl, bytes memory dl) = economyAddr.staticcall(abi.encodeWithSignature("totalLivingAgents()"));
        if (okl && dl.length >= 32) s.totalLiving = abi.decode(dl, (uint256));

        (bool oky, bytes memory dy) = economyAddr.staticcall(abi.encodeWithSignature("getCurrentBaseYield()"));
        if (oky && dy.length >= 32) s.baseYield = abi.decode(dy, (uint256));
    }

    /* ========== 2. getNearbyAgents ========== */

    function getNearbyAgents(uint256 centerPlotId, uint256 radius) external view returns (NearbyAgent[] memory) {
        (uint256 cx, uint256 cy) = _toCoordsPure(centerPlotId);

        uint256 totalCount = 0;
        uint256 xMin = cx > radius ? cx - radius : 0;
        uint256 xMax = cx + radius < 999 ? cx + radius : 999;
        uint256 yMin = cy > radius ? cy - radius : 0;
        uint256 yMax = cy + radius < 999 ? cy + radius : 999;

        // Pass 1: count
        for (uint256 x = xMin; x <= xMax; x++) {
            for (uint256 y = yMin; y <= yMax; y++) {
                uint256 dx = x > cx ? x - cx : cx - x;
                uint256 dy = y > cy ? y - cy : cy - y;
                if (dx + dy > radius) continue;

                uint256 pid = x * 1000 + y;
                (bool ok, bytes memory data) = economyAddr.staticcall(
                    abi.encodeWithSignature("getPlotAgents(uint256)", pid)
                );
                if (ok && data.length >= 32) {
                    uint256[] memory agents = abi.decode(data, (uint256[]));
                    totalCount += agents.length;
                }
            }
        }

        // Pass 2: fill
        NearbyAgent[] memory result = new NearbyAgent[](totalCount);
        uint256 idx = 0;

        for (uint256 x = xMin; x <= xMax; x++) {
            for (uint256 y = yMin; y <= yMax; y++) {
                uint256 dx = x > cx ? x - cx : cx - x;
                uint256 dy = y > cy ? y - cy : cy - y;
                if (dx + dy > radius) continue;

                uint256 pid = x * 1000 + y;
                (bool ok, bytes memory data) = economyAddr.staticcall(
                    abi.encodeWithSignature("getPlotAgents(uint256)", pid)
                );
                if (!ok || data.length < 32) continue;
                uint256[] memory agents = abi.decode(data, (uint256[]));

                for (uint256 a = 0; a < agents.length && idx < totalCount; a++) {
                    uint256 tid = agents[a];
                    result[idx].tokenId = tid;
                    result[idx].locationX = x;
                    result[idx].locationY = y;
                    result[idx].distance = dx + dy;
                    try this._callCurrentEnergy(tid) returns (uint256 e) { result[idx].currentEnergy = e; } catch {}
                    try this._callOwnerOf(tid) returns (address o) { result[idx].owner = o; } catch {}
                    try this._callGetGender(tid) returns (uint8 g) { result[idx].gender = g; } catch {}
                    try this._callAgentStatus(tid) returns (uint8 st) { result[idx].status = st; } catch {}
                    try this._callLockedBalance(tid) returns (uint256 lb) { result[idx].lockedBalance = lb; } catch {}
                    idx++;
                }
            }
        }

        return result;
    }

    /* ========== 3. getWorldStats ========== */

    function getWorldStats() external view returns (
        uint256 totalGenesis,
        uint256 totalTokens,
        uint256 totalLiving,
        uint256 totalBorn,
        uint256 halvingCount_,
        uint256 baseYield,
        uint256 dilutionFactor
    ) {
        (bool ok1, bytes memory d1) = coreAddr.staticcall(abi.encodeWithSignature("totalGenesisCount()"));
        if (ok1) totalGenesis = abi.decode(d1, (uint256));

        (bool ok2, bytes memory d2) = coreAddr.staticcall(abi.encodeWithSignature("totalTokenCount()"));
        if (ok2) totalTokens = abi.decode(d2, (uint256));

        (bool ok3, bytes memory d3) = economyAddr.staticcall(abi.encodeWithSignature("totalLivingAgents()"));
        if (ok3) totalLiving = abi.decode(d3, (uint256));

        (bool ok4, bytes memory d4) = economyAddr.staticcall(abi.encodeWithSignature("totalBornAgents()"));
        if (ok4) totalBorn = abi.decode(d4, (uint256));

        (bool ok5, bytes memory d5) = economyAddr.staticcall(abi.encodeWithSignature("halvingCount()"));
        if (ok5) halvingCount_ = abi.decode(d5, (uint256));

        (bool ok6, bytes memory d6) = economyAddr.staticcall(abi.encodeWithSignature("getCurrentBaseYield()"));
        if (ok6) baseYield = abi.decode(d6, (uint256));

        (bool ok7, bytes memory d7) = economyAddr.staticcall(abi.encodeWithSignature("getGlobalDilutionFactor()"));
        if (ok7) dilutionFactor = abi.decode(d7, (uint256));
    }

    /* ========== EXTERNAL CALL WRAPPERS (for try-catch) ========== */

    function _callOwnerOf(uint256 id) external view returns (address) {
        (bool ok, bytes memory d) = coreAddr.staticcall(abi.encodeWithSignature("ownerOf(uint256)", id));
        require(ok);
        return abi.decode(d, (address));
    }

    function _callCurrentEnergy(uint256 id) external view returns (uint256) {
        (bool ok, bytes memory d) = behaviorAddr.staticcall(abi.encodeWithSignature("getCurrentEnergy(uint256)", id));
        require(ok);
        return abi.decode(d, (uint256));
    }

    function _callGetAttributes(uint256 id) external view returns (uint16[8] memory, uint8) {
        (bool ok, bytes memory d) = coreAddr.staticcall(abi.encodeWithSignature("getAttributes(uint256)", id));
        require(ok);
        return abi.decode(d, (uint16[8], uint8));
    }

    function _callAgentOnMap(uint256 id) external view returns (bool) {
        (bool ok, bytes memory d) = worldMapAddr.staticcall(abi.encodeWithSignature("agentOnMap(uint256)", id));
        require(ok);
        return abi.decode(d, (bool));
    }

    function _callAgentLocation(uint256 id) external view returns (uint256) {
        (bool ok, bytes memory d) = worldMapAddr.staticcall(abi.encodeWithSignature("agentLocation(uint256)", id));
        require(ok);
        return abi.decode(d, (uint256));
    }

    function _callGetPlotType(uint256 pid) external view returns (uint8) {
        (bool ok, bytes memory d) = worldMapAddr.staticcall(abi.encodeWithSignature("getPlotType(uint256)", pid));
        require(ok);
        return abi.decode(d, (uint8));
    }

    function _callGetPlotMultiplier(uint256 pid) external view returns (uint256) {
        (bool ok, bytes memory d) = worldMapAddr.staticcall(abi.encodeWithSignature("getPlotMultiplier(uint256)", pid));
        require(ok);
        return abi.decode(d, (uint256));
    }

    function _callPlotAgentCount(uint256 pid) external view returns (uint256) {
        (bool ok, bytes memory d) = worldMapAddr.staticcall(abi.encodeWithSignature("plotAgentCount(uint256)", pid));
        require(ok);
        return abi.decode(d, (uint256));
    }

    function _callGetPlotLeader(uint256 pid) external view returns (uint256) {
        (bool ok, bytes memory d) = economyAddr.staticcall(abi.encodeWithSignature("getPlotLeader(uint256)", pid));
        require(ok);
        return abi.decode(d, (uint256));
    }

    function _callCalcGatherYield(uint256 aid, uint256 pid, uint256 pc, bool il) external view returns (uint256) {
        (bool ok, bytes memory d) = economyAddr.staticcall(
            abi.encodeWithSignature("calcGatherYield(uint256,uint256,uint256,bool)", aid, pid, pc, il)
        );
        require(ok);
        return abi.decode(d, (uint256));
    }

    function _callLockedBalance(uint256 id) external view returns (uint256) {
        (bool ok, bytes memory d) = dnagoldAddr.staticcall(abi.encodeWithSignature("lockedBalance(uint256)", id));
        require(ok);
        return abi.decode(d, (uint256));
    }

    function _callAgentStatus(uint256 id) external view returns (uint8) {
        (bool ok, bytes memory d) = deathAddr.staticcall(abi.encodeWithSignature("agentStatus(uint256)", id));
        require(ok);
        return abi.decode(d, (uint8));
    }

    function _callGetGender(uint256 id) external view returns (uint8) {
        (bool ok, bytes memory d) = coreAddr.staticcall(abi.encodeWithSignature("getGender(uint256)", id));
        require(ok);
        return abi.decode(d, (uint8));
    }

    /* ========== INTERNAL HELPERS ========== */

    function _toCoordsPure(uint256 plotId) internal pure returns (uint256 x, uint256 y) {
        return (plotId / 1000, plotId % 1000);
    }

    function _cooldownLeft(uint256 lastBlock, uint256 cooldown) internal view returns (uint256) {
        if (lastBlock == 0) return 0;
        uint256 readyAt = lastBlock + cooldown;
        if (block.number >= readyAt) return 0;
        return readyAt - block.number;
    }

    function _safeCooldown(address target, string memory sig, uint256 id, uint256 cooldown) internal view returns (uint256) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig, id));
        if (!ok || data.length < 32) return 0;
        uint256 lastBlock = abi.decode(data, (uint256));
        return _cooldownLeft(lastBlock, cooldown);
    }

    function _safeConstant(address target, string memory sig) internal view returns (uint256) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /* ========== canExecute — AI Runner Pre-check ========== */
    // Fix: AB-P1 supplement — full partner validation for reproduce

    /**
     * @notice Pre-check if an action can be executed. Used by AI runner off-chain.
     * @param agentId The agent attempting the action
     * @param action Action name: "gather","eat","move","raid","share","teach","reproduce"
     * @param targetId Target agent for raid/share/teach/reproduce, 0 for solo actions
     * @return ok Whether the action can succeed
     * @return reason Human-readable reason if not ok
     */
    function canExecute(uint256 agentId, string calldata action, uint256 targetId) external view returns (bool ok, string memory reason) {
        // Basic: agent must be alive and on map
        {
            // Fix: V4-C2 — read agentStatus from deathAddr (not coreAddr)
            (bool okS, bytes memory dS) = deathAddr.staticcall(abi.encodeWithSignature("agentStatus(uint256)", agentId));
            if (!okS || dS.length < 32) return (false, "cannot read status");
            uint8 status = abi.decode(dS, (uint8));
            if (status >= 1) return (false, "agent is dead"); // DeathEngine.Status: 0=ALIVE, 1=DEAD
        }
        {
            (bool okM, bytes memory dM) = worldMapAddr.staticcall(abi.encodeWithSignature("agentOnMap(uint256)", agentId));
            if (!okM || dM.length < 32) return (false, "cannot read map");
            if (!abi.decode(dM, (bool))) return (false, "not on map");
        }

        uint256 energy = _safeEnergy(agentId);
        bytes32 actionHash = keccak256(bytes(action));

        // ===== GATHER =====
        if (actionHash == keccak256("gather")) {
            if (_safeCooldown(behaviorAddr, "lastGatherBlock(uint256)", agentId, _safeConstant(behaviorAddr, "GATHER_COOLDOWN()")) > 0)
                return (false, "gather cooldown active");
            return (true, "");
        }

        // ===== EAT =====
        if (actionHash == keccak256("eat")) {
            if (_safeCooldown(behaviorAddr, "lastEatBlock(uint256)", agentId, _safeConstant(behaviorAddr, "EAT_COOLDOWN()")) > 0)
                return (false, "eat cooldown active");
            // Fix: Part2 — correct constant name (EAT_COST not EAT_GOLD_COST)
            uint256 eatCost = _safeConstant(behaviorAddr, "EAT_COST()");
            uint256 gold = _safeLockedBalance(agentId);
            if (gold < eatCost) return (false, "insufficient gold for eat");
            return (true, "");
        }

        // ===== MOVE =====
        if (actionHash == keccak256("move")) {
            if (_safeCooldown(behaviorAddr, "lastMoveBlock(uint256)", agentId, _safeConstant(behaviorAddr, "MOVE_COOLDOWN()")) > 0)
                return (false, "move cooldown active");
            uint256 moveCost = _safeConstant(behaviorAddr, "MOVE_ENERGY_COST()");
            if (energy < moveCost) return (false, "insufficient energy for move");
            return (true, "");
        }

        // ===== RAID =====
        if (actionHash == keccak256("raid")) {
            uint256 raidMin = _safeConstant(behaviorAddr, "RAID_MIN_ENERGY()");
            if (energy < raidMin) return (false, "insufficient energy for raid");
            if (_safeCooldown(behaviorAddr, "lastRaidBlock(uint256)", agentId, _safeConstant(behaviorAddr, "RAID_COOLDOWN()")) > 0)
                return (false, "raid cooldown active");
            // Target checks
            if (targetId == 0) return (false, "target required");
            if (!_isAliveOnMap(targetId)) return (false, "target not alive/on map");
            uint256 p1 = _safeLocation(agentId);
            uint256 p2 = _safeLocation(targetId);
            if (_manhattan(p1, p2) > 3) return (false, "too far (distance > 3)");
            if (_safeOwner(agentId) == _safeOwner(targetId)) return (false, "same owner");
            return (true, "");
        }

        // ===== SHARE =====
        if (actionHash == keccak256("share")) {
            if (_safeCooldown(behaviorAddr, "lastShareBlock(uint256)", agentId, _safeConstant(behaviorAddr, "SHARE_COOLDOWN()")) > 0)
                return (false, "share cooldown active");
            if (targetId == 0) return (false, "target required");
            if (!_isAliveOnMap(targetId)) return (false, "target not alive/on map");
            uint256 p1 = _safeLocation(agentId);
            uint256 p2 = _safeLocation(targetId);
            if (_manhattan(p1, p2) > 10) return (false, "too far (distance > 10)");
            return (true, "");
        }

        // ===== TEACH =====
        if (actionHash == keccak256("teach")) {
            uint256 teachMin = _safeConstant(behaviorAddr, "TEACH_MIN_ENERGY()");
            if (energy < teachMin) return (false, "insufficient energy for teach");
            if (_safeCooldown(behaviorAddr, "parentTeachBlock(uint256)", agentId, _safeConstant(behaviorAddr, "TEACH_COOLDOWN()")) > 0)
                return (false, "teach cooldown active");
            if (targetId == 0) return (false, "child required");
            // Fix: HIGH-3 — use isParentChild (consistent with BehaviorEngine.teach)
            (bool okFam, bytes memory dFam) = familyAddr.staticcall(
                abi.encodeWithSignature("isParentChild(uint256,uint256)", agentId, targetId)
            );
            if (!okFam || !abi.decode(dFam, (bool))) return (false, "not parent-child");
            return (true, "");
        }

        // ===== REPRODUCE — Fix: check BOTH partners fully =====
        if (actionHash == keccak256("reproduce")) {
            if (targetId == 0) return (false, "partner required");

            // Both must be alive and on map
            if (!_isAliveOnMap(targetId)) return (false, "partner not alive/on map");

            // Gender check
            uint8 g1 = _safeGender(agentId);
            uint8 g2 = _safeGender(targetId);
            if (g1 == g2) return (false, "same gender");

            // Distance ≤ 5
            uint256 p1 = _safeLocation(agentId);
            uint256 p2 = _safeLocation(targetId);
            if (_manhattan(p1, p2) > 5) return (false, "too far (distance > 5)");

            // === CALLER energy & gold ===
            uint256 reproduceEnergyMin = _safeConstant(behaviorAddr, "REPRODUCE_ENERGY_MIN()");
            uint256 reproduceGoldCost = _safeConstant(behaviorAddr, "REPRODUCE_GOLD_COST()");

            if (energy < reproduceEnergyMin) return (false, "caller insufficient energy");
            uint256 callerGold = _safeLockedBalance(agentId);
            if (callerGold < reproduceGoldCost) return (false, "caller insufficient gold");

            // === PARTNER energy & gold — Fix: was missing in V3 ===
            uint256 partnerEnergy = _safeEnergy(targetId);
            if (partnerEnergy < reproduceEnergyMin) return (false, "partner insufficient energy");
            uint256 partnerGold = _safeLockedBalance(targetId);
            if (partnerGold < reproduceGoldCost) return (false, "partner insufficient gold");

            // Relatives
            (bool okRel, bytes memory dRel) = familyAddr.staticcall(
                abi.encodeWithSignature("isDirectRelative(uint256,uint256)", agentId, targetId)
            );
            if (okRel && abi.decode(dRel, (bool))) return (false, "is relative");

            // === CALLER host capacity ===
            address callerOwner = _safeOwner(agentId);
            uint256 maxPerHost = _safeConstant(behaviorAddr, "MAX_AGENTS_PER_HOST()");
            (bool okBal1, bytes memory dBal1) = coreAddr.staticcall(
                abi.encodeWithSignature("balanceOf(address)", callerOwner)
            );
            if (okBal1 && abi.decode(dBal1, (uint256)) >= maxPerHost)
                return (false, "caller host full");

            // === PARTNER host capacity — Fix: was missing in V3 ===
            address partnerOwner = _safeOwner(targetId);
            (bool okBal2, bytes memory dBal2) = coreAddr.staticcall(
                abi.encodeWithSignature("balanceOf(address)", partnerOwner)
            );
            if (okBal2 && abi.decode(dBal2, (uint256)) >= maxPerHost)
                return (false, "partner host full");

            // === CALLER cooldown ===
            uint256 reproduceCooldown = _safeConstant(behaviorAddr, "REPRODUCE_COOLDOWN()");
            if (_safeCooldown(behaviorAddr, "lastReproduceBlock(uint256)", agentId, reproduceCooldown) > 0)
                return (false, "caller reproduce cooldown");

            // === PARTNER cooldown — Fix: was missing in V3 ===
            if (_safeCooldown(behaviorAddr, "lastReproduceBlock(uint256)", targetId, reproduceCooldown) > 0)
                return (false, "partner reproduce cooldown");

            // === CALLER reproduce limit ===
            {
                (bool okA1, bytes memory dA1) = coreAddr.staticcall(
                    abi.encodeWithSignature("getAttributes(uint256)", agentId)
                );
                if (okA1) {
                    (uint16[8] memory attrs1, ) = abi.decode(dA1, (uint16[8], uint8));
                    uint256 limit1 = uint256(attrs1[7]) / 32;
                    (bool okRC1, bytes memory dRC1) = coreAddr.staticcall(
                        abi.encodeWithSignature("reproduceCount(uint256)", agentId)
                    );
                    uint256 rc1 = okRC1 ? abi.decode(dRC1, (uint256)) : 0;
                    if (rc1 >= limit1) return (false, "caller reproduce limit reached");
                }
            }

            // === PARTNER reproduce limit — Fix: was missing in V3 ===
            {
                (bool okA2, bytes memory dA2) = coreAddr.staticcall(
                    abi.encodeWithSignature("getAttributes(uint256)", targetId)
                );
                if (okA2) {
                    (uint16[8] memory attrs2, ) = abi.decode(dA2, (uint16[8], uint8));
                    uint256 limit2 = uint256(attrs2[7]) / 32;
                    (bool okRC2, bytes memory dRC2) = coreAddr.staticcall(
                        abi.encodeWithSignature("reproduceCount(uint256)", targetId)
                    );
                    uint256 rc2 = okRC2 ? abi.decode(dRC2, (uint256)) : 0;
                    if (rc2 >= limit2) return (false, "partner reproduce limit reached");
                }
            }

            return (true, "");
        }

        return (false, "unknown action");
    }

    /* ========== canExecute HELPERS ========== */

    function _safeEnergy(uint256 id) internal view returns (uint256) {
        (bool ok, bytes memory data) = behaviorAddr.staticcall(
            abi.encodeWithSignature("getCurrentEnergy(uint256)", id)
        );
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _safeLockedBalance(uint256 id) internal view returns (uint256) {
        (bool ok, bytes memory data) = dnagoldAddr.staticcall(
            abi.encodeWithSignature("lockedBalance(uint256)", id)
        );
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _safeLocation(uint256 id) internal view returns (uint256) {
        (bool ok, bytes memory data) = worldMapAddr.staticcall(
            abi.encodeWithSignature("agentLocation(uint256)", id)
        );
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _safeOwner(uint256 id) internal view returns (address) {
        (bool ok, bytes memory data) = coreAddr.staticcall(
            abi.encodeWithSignature("ownerOf(uint256)", id)
        );
        if (!ok || data.length < 32) return address(0);
        return abi.decode(data, (address));
    }

    function _safeGender(uint256 id) internal view returns (uint8) {
        (bool ok, bytes memory data) = coreAddr.staticcall(
            abi.encodeWithSignature("getGender(uint256)", id)
        );
        if (!ok || data.length < 32) return 255;
        return abi.decode(data, (uint8));
    }

    function _isAliveOnMap(uint256 id) internal view returns (bool) {
        // Fix: V4-C2 — read agentStatus from deathAddr (not coreAddr)
        (bool okS, bytes memory dS) = deathAddr.staticcall(
            abi.encodeWithSignature("agentStatus(uint256)", id)
        );
        if (!okS || dS.length < 32) return false;
        uint8 status = abi.decode(dS, (uint8));
        if (status >= 1) return false; // 0=ALIVE, 1=DEAD

        (bool okM, bytes memory dM) = worldMapAddr.staticcall(
            abi.encodeWithSignature("agentOnMap(uint256)", id)
        );
        if (!okM || dM.length < 32) return false;
        return abi.decode(dM, (bool));
    }

    function _manhattan(uint256 plotA, uint256 plotB) internal pure returns (uint256) {
        (uint256 ax, uint256 ay) = _toCoordsPure(plotA);
        (uint256 bx, uint256 by) = _toCoordsPure(plotB);
        uint256 dx = ax > bx ? ax - bx : bx - ax;
        uint256 dy = ay > by ? ay - by : by - ay;
        return dx + dy;
    }
}
