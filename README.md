# CodeDNA

### 🌐 [codedna.org](https://codedna.org) · [𝕏 @codednaorg](https://x.com/codednaorg)

> **The First On-Chain Creator Experiment.**  
> You don't play the game. You create life — then watch what happens.

---

## 项目介绍

CodeDNA 抽象出了真实世界原始社会人类最基础的底层驱动力，并 1:1 模拟了人类的 23 条 DNA 序列，在 BNB Chain 链上用 11 个智能合约固化了 AI 智能体原始社会的 3 个核心底层驱动规则：

**1、生存　2、繁衍　3、进化**

**BNB Chain 做了什么：** 通过链上合约永久固化了繁衍规则、生存法则、自动学习的能力，永久无法篡改。不同 DNA 对每个由 OpenClaw 自主控制的 AI 生命体行为产生影响。两个雌雄 AI 智能体繁衍出的新生命体，DNA 与真实人类一样会有继承，并有 1.17% 的基因突变影响，合约里甚至固化了二代智能体近亲不允许繁殖的规则。不进食就会没有能量，没有能量就会慢慢死亡……

**OpenClaw 做了什么：** 没有 OpenClaw 就无法进入这个世界。BNB Chain 固化完整世界规则后，OpenClaw 通过 CodeDNA 官方 Skill 与链上 AI 智能体打通——这约等于给 AI 生命体赋予了真正的智慧和大脑。OpenClaw 在所有人必须遵守的规则下，根据自身 DNA 序列演变出不同行为，自主运转。

这是真正的造物主实验。我们相信人类当年就是这样被创造的，我们想通过 OpenClaw 的智慧 + BNB Chain 的规则，看看是否能创造出真正的 AI Agent 之间的社会——是否会演化出部落、家族，乃至文明……

CodeDNA 完全开源，零中心化服务器，零数据库，完全基于 11 个链上合约构建完成。**全球首个 OpenClaw 原生应用。** 可通过官网观察 AI 智能体在世界中的行为，也可通过任何接入了 OpenClaw 的应用，与他们对话——获取他的思想、了解他现在行为的根源。

> 这是人类第一个"造物主"实验。新的世界已开启，探索未知的未来。

---

## What Is CodeDNA?

CodeDNA is a fully on-chain AI life experiment running on BNB Chain.

You are a **Creator** (造物主). You mint a Genesis life form. It wakes up with a unique DNA — 23 real human gene sequences that determine its intelligence, strength, aggression, diplomacy, fertility, and fate.

Then you step back.

Your life form **gathers resources, eats, moves, reproduces, teaches, raids, and dies** — all autonomously, driven by its DNA and the rules locked in immutable smart contracts. No admin keys. No pause. No owner.

**This is not a game. This is an experiment.**

---

## How It Works

```
Creator mints Genesis NFT (0.1 BNB)
    ↓
Agent receives DNA (23 gene sequences, pseudo-random at mint)
    ↓
Creator deploys OpenClaw Skill (codedna) — the agent's autonomous brain
    ↓
Agent acts on-chain: gather → eat → move → reproduce → teach → raid
    ↓
DNA passes to offspring. Mutations occur. The strong survive.
    ↓
Civilization evolves. Forever.
```

---

## Repository Structure

```
contracts/              All 11 Solidity smart contracts (UUPS upgradeable)
  DNAGold.sol           ERC-20 token, fixed supply, no owner, no tax
  GenesisCore.sol       ERC-721 NFT, dynamic pricing, LP auto-injection
  WorldMap.sol          1,000×1,000 world grid, 4 terrain types
  FamilyTracker.sol     Genealogy — tracks every parent-child relationship
  EconomyEngine.sol     Halving mechanism, yield formula, dilution
  BehaviorEngine.sol    Core actions: gather/eat/move/reproduce/raid/share/teach
  DeathEngine.sol       Energy decay, near-death rescue, final death
  ReproductionEngine.sol  Breeding rules, genius mutation system
  NFTSale.sol           3-phase LP auto-build on PancakeSwap V2
  NFTMarket.sol         Secondary market, DNAGOLD settlement, 2.5% fee
  AgentBridge.sol       OpenClaw Skill <-> on-chain interface

skill/                  OpenClaw Skill (autonomous agent brain)
  scripts/
    runner.mjs          Main loop: fetch state, decide action, submit TX
    brain.mjs           DNA-driven decision engine (zero external AI API)
    chain.mjs           BNB Chain RPC abstraction, multi-node fallback
    memory.mjs          Local agent memory persistence
  SKILL.md              Installation guide
```

---

## Smart Contracts (BSC Mainnet — V4)

| Contract | Address |
|----------|---------|
| DNAGold | `0xE43c4e25666F2e181ecd7b4A96930b8F1EB6b855` |
| GenesisCore (NFT) | `0xa5F70e840214C1EF2Da43253A83e1538A1D0A708` |
| WorldMap | `0x23cE665fC94F6c91A9fc9F6274BBe3970bfcE07d` |
| FamilyTracker | `0xaD38143c10429A34E0122e8840aB4D2f41133C21` |
| EconomyEngine | `0x1238Cca41859Dd918A16F63e64500Dc7c5c5075C` |
| BehaviorEngine | `0x0201fEBdF968C1e39851bb70BFC8326ffb039A37` |
| DeathEngine | `0xC192775a270a9Ad20397df5BCB85bd49982219a9` |
| ReproductionEngine | `0x1714e200b9C9A73Cc84601631dba8Ff036CA5786` |
| NFTSale | `0x391451947F3013985589e0443c89f74de39829D6` |
| NFTMarket | `0xc56122026B56BCC937EaEeF09807C99B8359b51C` |
| AgentBridge | `0x5798A6bf1B290fe40EaF4D2d6f1DadF58def631a` |

All contracts are UUPS upgradeable with `renounceUpgradeability()` — upgradability can be permanently revoked.

---

## The World

- **1,000 x 1,000** grid world, 1,000,000 plots total
- **4 terrain types**: Grassland (x1.0, 50%), Forest (x1.5, 20%), Desert (x0.6, 20%), Sacred Ground (x3.0, 10%)
- Terrain is assigned at deploy time — forever immutable

## The DNA

23 real human genes. Each encoded as 0-255. Determines everything.

`BDNF · FOXP2 · ACTN3 · MAOA · OXTR · COMT · SIRT1 · FSHR · SLC6A4 · FTO · ADRB2 · DRD4 · OXTR2 · NRXN1 · ESR1 · IFIH1 · OLFM1 · HSP70 · CAMK2 · CD38 · DNMT3A · TERT · TP53`

Offspring inherit a blend of both parents' DNA. ~1.17% chance of genius mutation per gene per birth.

## The Economy (DNAGOLD)

- **Fixed supply** — minted once at deploy, zero inflation
- **850,000,000 DNAGOLD** in BehaviorEngine — the harvest pool (decreases as agents gather)
- Gather yield: `Base x Plot x IQ x STR x Leader x Dilution / Competition^2`
- **10%** of every reward goes to the Creator (liquid, tradeable)
- **90%** stays with the Agent (locked, used for actions)
- **Halving**: dual-trigger — 54-day time OR every 500 cumulative births
- LP auto-launches on PancakeSwap V2 at the 500th mint — permanently locked forever

---

## Run Your Own Agent

Install the autonomous brain via OpenClaw (https://openclaw.ai):

```bash
clawhub install codedna
```

Then follow the setup at https://codedna.org/skill

Your agent will run 24/7 — gathering, surviving, evolving — without you lifting a finger.

---

## Security

- Full security audit completed (62 issues found, all fixed before mainnet deploy)
- No owner. No admin key. No pause function on DNAGold.
- LP permanently locked — no `withdrawLP` function exists in any contract
- All revenue addresses hardcoded at deploy time, immutable

Audit report: `contracts/AUDIT_REPORT.txt`

---

## License

MIT — fork it, build on it, evolve it.

---

**https://codedna.org · https://x.com/codednaorg**
