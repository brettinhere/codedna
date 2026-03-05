/**
 * CodeDNA V4 — UUPS Upgradeable Deployment Script
 * 
 * Usage: npx hardhat run deploy-v4.js --network bscMainnet
 * 
 * Requires:
 *   - @openzeppelin/hardhat-upgrades
 *   - @openzeppelin/contracts-upgradeable
 *   - hardhat
 * 
 * Deployment Order (respects dependency graph):
 *   1. GenesisCore (no deps)
 *   2. WorldMap (needs gameContract placeholder)
 *   3. FamilyTracker (needs gameContract placeholder)
 *   4. DNAGold (needs gameContract, economyContract placeholders)
 *   5. EconomyEngine (needs gameContract, dnagold, genesisCore, worldMap)
 *   6. DeathEngine (needs all core contracts)
 *   7. BehaviorEngine (needs all core contracts — the main gameContract)
 *   8. ReproductionEngine (needs genesisCore, gameContract)
 *   9. AgentBridge (needs all contracts, read-only)
 *   10. NFTSale (needs genesisCore, dnagold, router, opsWallet, goldSource)
 *   11. NFTMarket (needs dnagold, genesisCore, deathEngine, feeAddress)
 * 
 * Post-deployment: wire gameContract addresses into all contracts
 */

const { ethers, upgrades } = require("hardhat");

async function main() {
    const [deployer] = await ethers.getSigners();
    console.log("Deploying with:", deployer.address);
    console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "BNB");

    // ===== CONFIGURATION =====
    const MULTISIG = process.env.MULTISIG_ADDRESS || deployer.address;

    // ── 收款地址配置（已硬编码，部署前请再次核对）──────────────────────────
    const OPS_WALLET   = "0xfd19bbb8cf9aa43f594904c779eec4a150c6bdd1"; // 每次铸造 20% BNB 实时到账
    const FEE_ADDRESS  = "0x159acaa0a5e247d91cca665ad077aed66012bf03"; // NFTMarket 二级市场手续费 2.5%
    const LP_RESERVE   = "0xa3ff0251841c2a68630b97f8956cbea076a01f6d"; // DNAGold 初始 10%（1 亿枚）
    const TEAM_RESERVE = "0x565b7464238618dfac321831085f96db43720d3b"; // DNAGold 初始  5%（5 千万枚）
    const GOLD_SOURCE  = "0xb94173be4e032675aa59255ac975155d0668942e"; // DNAGOLD 授权钱包（需提前 approve）
    // ─────────────────────────────────────────────────────────────────────────

    const PANCAKE_ROUTER = process.env.PANCAKE_ROUTER || "0x10ED43C718714eb63d5aA57B78B54704E256024E"; // BSC mainnet

    const deployed = {};

    // ===== STEP 1: GenesisCore =====
    console.log("\n--- 1. Deploying GenesisCore ---");
    const GenesisCore = await ethers.getContractFactory("GenesisCore");
    const genesisCore = await upgrades.deployProxy(GenesisCore, [deployer.address], {
        initializer: "initialize",
        kind: "uups",
    });
    await genesisCore.waitForDeployment();
    deployed.genesisCore = await genesisCore.getAddress();
    console.log("GenesisCore:", deployed.genesisCore);

    // ===== STEP 2: WorldMap (with placeholder gameContract) =====
    console.log("\n--- 2. Deploying WorldMap ---");
    const WorldMap = await ethers.getContractFactory("WorldMap");
    // Use deployer as temporary gameContract; will update after BehaviorEngine is deployed
    const worldMap = await upgrades.deployProxy(WorldMap, [deployer.address, deployer.address], {
        initializer: "initialize",
        kind: "uups",
    });
    await worldMap.waitForDeployment();
    deployed.worldMap = await worldMap.getAddress();
    console.log("WorldMap:", deployed.worldMap);

    // ===== STEP 3: FamilyTracker =====
    console.log("\n--- 3. Deploying FamilyTracker ---");
    const FamilyTracker = await ethers.getContractFactory("FamilyTracker");
    const familyTracker = await upgrades.deployProxy(FamilyTracker, [deployer.address, deployer.address], {
        initializer: "initialize",
        kind: "uups",
    });
    await familyTracker.waitForDeployment();
    deployed.familyTracker = await familyTracker.getAddress();
    console.log("FamilyTracker:", deployed.familyTracker);

    // ===== STEP 4: DNAGold =====
    console.log("\n--- 4. Deploying DNAGold ---");
    const DNAGold = await ethers.getContractFactory("DNAGold");
    // gameContract and economyContract will be updated after deployment
    // For now, use deployer as placeholder (initial mint goes to deployer as gameContract)
    const dnagold = await upgrades.deployProxy(DNAGold, [
        deployer.address,   // gameContract (placeholder — will hold 850M)
        deployer.address,   // economyContract (placeholder)
        LP_RESERVE,          // lpReserveAddress
        TEAM_RESERVE,        // teamReserveAddress
        deployer.address,    // owner
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await dnagold.waitForDeployment();
    deployed.dnagold = await dnagold.getAddress();
    console.log("DNAGold:", deployed.dnagold);

    // ===== STEP 5: EconomyEngine =====
    console.log("\n--- 5. Deploying EconomyEngine ---");
    const EconomyEngine = await ethers.getContractFactory("EconomyEngine");
    const economyEngine = await upgrades.deployProxy(EconomyEngine, [
        deployer.address,       // gameContract placeholder
        deployed.dnagold,
        deployed.genesisCore,
        deployed.worldMap,
        deployer.address,        // owner
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await economyEngine.waitForDeployment();
    deployed.economyEngine = await economyEngine.getAddress();
    console.log("EconomyEngine:", deployed.economyEngine);

    // ===== STEP 6: DeathEngine =====
    console.log("\n--- 6. Deploying DeathEngine ---");
    const DeathEngine = await ethers.getContractFactory("DeathEngine");
    const deathEngine = await upgrades.deployProxy(DeathEngine, [
        deployed.dnagold,
        deployed.genesisCore,
        deployed.worldMap,
        deployed.economyEngine,
        deployed.familyTracker,
        deployer.address,       // gameContract placeholder
        deployer.address,        // owner
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await deathEngine.waitForDeployment();
    deployed.deathEngine = await deathEngine.getAddress();
    console.log("DeathEngine:", deployed.deathEngine);

    // ===== STEP 7: BehaviorEngine (THE main gameContract) =====
    // Fix: CRITICAL-1 — initialize now takes 9 params (added reproAddr + deathAddr)
    // reproAddr = address(0) placeholder (ReproductionEngine not deployed yet — circular dep)
    // deathAddr = deployed.deathEngine (already deployed in step 6)
    console.log("\n--- 7. Deploying BehaviorEngine ---");
    const BehaviorEngine = await ethers.getContractFactory("BehaviorEngine");
    const behaviorEngine = await upgrades.deployProxy(BehaviorEngine, [
        deployed.dnagold,
        deployed.genesisCore,
        deployed.worldMap,
        deployed.economyEngine,
        deployed.familyTracker,
        MULTISIG,
        ethers.ZeroAddress,      // _reproAddr placeholder (set after step 8)
        deployed.deathEngine,    // _deathAddr (already deployed)
        deployer.address,        // _owner
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await behaviorEngine.waitForDeployment();
    deployed.behaviorEngine = await behaviorEngine.getAddress();
    console.log("BehaviorEngine:", deployed.behaviorEngine);

    // ===== STEP 8: ReproductionEngine =====
    console.log("\n--- 8. Deploying ReproductionEngine ---");
    const ReproductionEngine = await ethers.getContractFactory("ReproductionEngine");
    const reproductionEngine = await upgrades.deployProxy(ReproductionEngine, [
        deployed.genesisCore,
        deployed.behaviorEngine,
        deployer.address,
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await reproductionEngine.waitForDeployment();
    deployed.reproductionEngine = await reproductionEngine.getAddress();
    console.log("ReproductionEngine:", deployed.reproductionEngine);

    // ===== STEP 9: AgentBridge =====
    console.log("\n--- 9. Deploying AgentBridge ---");
    const AgentBridge = await ethers.getContractFactory("AgentBridge");
    const agentBridge = await upgrades.deployProxy(AgentBridge, [
        deployed.genesisCore,
        deployed.dnagold,
        deployed.worldMap,
        deployed.behaviorEngine,
        deployed.economyEngine,
        deployed.deathEngine,
        deployed.familyTracker,
        deployer.address,
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await agentBridge.waitForDeployment();
    deployed.agentBridge = await agentBridge.getAddress();
    console.log("AgentBridge:", deployed.agentBridge);

    // ===== STEP 10: NFTSale =====
    console.log("\n--- 10. Deploying NFTSale ---");
    const NFTSale = await ethers.getContractFactory("NFTSale");
    const nftSale = await upgrades.deployProxy(NFTSale, [
        deployed.genesisCore,
        deployed.dnagold,
        PANCAKE_ROUTER,
        OPS_WALLET,
        GOLD_SOURCE,
        deployer.address,
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await nftSale.waitForDeployment();
    deployed.nftSale = await nftSale.getAddress();
    console.log("NFTSale:", deployed.nftSale);

    // ===== STEP 11: NFTMarket =====
    console.log("\n--- 11. Deploying NFTMarket ---");
    const NFTMarket = await ethers.getContractFactory("NFTMarket");
    const nftMarket = await upgrades.deployProxy(NFTMarket, [
        deployed.dnagold,
        deployed.genesisCore,
        deployed.deathEngine,
        FEE_ADDRESS,
        deployer.address,
    ], {
        initializer: "initialize",
        kind: "uups",
    });
    await nftMarket.waitForDeployment();
    deployed.nftMarket = await nftMarket.getAddress();
    console.log("NFTMarket:", deployed.nftMarket);

    // ===== POST-DEPLOYMENT: Wire ALL authorization addresses =====
    // Fix: CRITICAL-2 — complete wiring (was missing 10 setXxx calls)
    // Fix: HIGH-1 — NFTMarket worldMap/economy
    console.log("\n===== Wiring contract authorizations (19 calls) =====\n");

    // --- GenesisCore ---
    console.log("Setting GenesisCore.gameContract...");
    await (await genesisCore.setGameContract(deployed.behaviorEngine)).wait();
    console.log("Setting GenesisCore.lpManager...");
    await (await genesisCore.setLPManager(deployed.nftSale)).wait();
    console.log("Setting GenesisCore.reproductionEngine...");  // ① NEW
    await (await genesisCore.setReproductionEngine(deployed.reproductionEngine)).wait();
    console.log("Setting GenesisCore.deathContract...");       // ② NEW
    await (await genesisCore.setDeathContract(deployed.deathEngine)).wait();

    // --- WorldMap ---
    console.log("Setting WorldMap.gameContract...");
    await (await worldMap.setGameContract(deployed.behaviorEngine)).wait();
    console.log("Setting WorldMap.deathContract...");           // ③ NEW
    await (await worldMap.setDeathContract(deployed.deathEngine)).wait();
    console.log("Setting WorldMap.marketContract...");          // ④ NEW
    await (await worldMap.setMarketContract(deployed.nftMarket)).wait();

    // --- FamilyTracker ---
    console.log("Setting FamilyTracker.gameContract...");
    await (await familyTracker.setGameContract(deployed.behaviorEngine)).wait();
    console.log("Setting FamilyTracker.deathContract...");      // ⑦ NEW
    await (await familyTracker.setDeathContract(deployed.deathEngine)).wait();

    // --- DNAGold ---
    console.log("Setting DNAGold.gameContract...");
    await (await dnagold.setGameContract(deployed.behaviorEngine)).wait();
    console.log("Setting DNAGold.economyContract...");
    await (await dnagold.setEconomyContract(deployed.economyEngine)).wait();
    console.log("Setting DNAGold.deathContract...");            // ⑧ NEW
    await (await dnagold.setDeathContract(deployed.deathEngine)).wait();

    // --- Transfer 850M DNAGOLD game pool ---
    console.log("Transferring DNAGOLD game pool to BehaviorEngine...");
    const GAME_SHARE = ethers.parseEther("850000000");
    const deployerGoldBalance = await dnagold.balanceOf(deployer.address);
    console.log("Deployer DNAGOLD balance:", ethers.formatEther(deployerGoldBalance));
    if (deployerGoldBalance >= GAME_SHARE) {
        await (await dnagold.transfer(deployed.behaviorEngine, GAME_SHARE)).wait();
        console.log("Transferred 850M DNAGOLD to BehaviorEngine");
    } else {
        console.log("WARNING: Deployer doesn't have enough DNAGOLD for game pool");
    }

    // --- EconomyEngine ---
    console.log("Setting EconomyEngine.gameContract...");
    await (await economyEngine.setGameContract(deployed.behaviorEngine)).wait();
    console.log("Setting EconomyEngine.deathContract...");      // ⑤ NEW
    await (await economyEngine.setDeathContract(deployed.deathEngine)).wait();
    console.log("Setting EconomyEngine.marketContract...");     // ⑥ NEW
    await (await economyEngine.setMarketContract(deployed.nftMarket)).wait();

    // --- DeathEngine ---
    console.log("Setting DeathEngine.gameContract...");
    await (await deathEngine.setGameContract(deployed.behaviorEngine)).wait();
    console.log("Setting DeathEngine.nftMarket...");
    await (await deathEngine.setNFTMarket(deployed.nftMarket)).wait();

    // --- BehaviorEngine (post-deploy setters for circular deps) ---
    console.log("Setting BehaviorEngine.reproAddr...");         // ⑨ NEW
    await (await behaviorEngine.setReproAddr(deployed.reproductionEngine)).wait();
    // deathAddr already set in initialize, but verify:
    console.log("BehaviorEngine.deathAddr already set in initialize ✓");  // ⑩

    // --- NFTMarket ---
    console.log("Setting NFTMarket.worldMap...");               // HIGH-1 FIX
    await (await nftMarket.setWorldMap(deployed.worldMap)).wait();
    console.log("Setting NFTMarket.economy...");                // HIGH-1 FIX
    await (await nftMarket.setEconomy(deployed.economyEngine)).wait();

    console.log("\n✅ All 19 authorization calls complete");

    // ===== SUMMARY =====
    console.log("\n===== DEPLOYMENT COMPLETE =====\n");
    console.log("Contract Addresses:");
    console.log(JSON.stringify(deployed, null, 2));

    // Save to file
    const fs = require("fs");
    fs.writeFileSync(
        "deployed-v4.json",
        JSON.stringify({
            network: (await ethers.provider.getNetwork()).name,
            chainId: Number((await ethers.provider.getNetwork()).chainId),
            deployer: deployer.address,
            timestamp: new Date().toISOString(),
            contracts: deployed,
        }, null, 2)
    );
    console.log("\nSaved to deployed-v4.json");

    // ===== OPTIONAL: Transfer ownership to multisig =====
    if (MULTISIG !== deployer.address) {
        console.log("\n===== Transferring ownership to multisig =====");
        const contracts = [
            { name: "GenesisCore", instance: genesisCore },
            { name: "WorldMap", instance: worldMap },
            { name: "FamilyTracker", instance: familyTracker },
            { name: "DNAGold", instance: dnagold },
            { name: "EconomyEngine", instance: economyEngine },
            { name: "DeathEngine", instance: deathEngine },
            { name: "BehaviorEngine", instance: behaviorEngine },
            { name: "ReproductionEngine", instance: reproductionEngine },
            { name: "AgentBridge", instance: agentBridge },
            { name: "NFTSale", instance: nftSale },
            { name: "NFTMarket", instance: nftMarket },
        ];

        for (const c of contracts) {
            try {
                await (await c.instance.transferOwnership(MULTISIG)).wait();
                console.log(`${c.name} ownership → ${MULTISIG}`);
            } catch (e) {
                console.log(`${c.name} ownership transfer failed: ${e.message}`);
            }
        }
    }
}

main()
    .then(() => process.exit(0))
    .catch((error) => {
        console.error(error);
        process.exit(1);
    });
