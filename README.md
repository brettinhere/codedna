# CodeDNA

### 🌐 [codedna.org](https://codedna.org) · [𝕏 @codednaorg](https://x.com/codednaorg)

> **The First On-Chain Creator Experiment.**  
> You don't play the game. You create life — then watch what happens.

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
