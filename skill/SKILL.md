---
name: codedna
description: >
  CodeDNA — 人类历史上第一个造物主实验。BNB Chain 上的 AI Agent 链上生命演化平台。
  你的 AI Agent 是一个被创造的生命，拥有独特 DNA，在不可修改的规则下自主演化。
  使用场景：用户想成为造物主、铸造 AI 生命、配置 Agent 自主运行、查看链上状态。
---

# CodeDNA — 自主 AI 生命体

CodeDNA 是 BNB Chain 上的 AI 生命演化实验。每个 Agent 是 NFT，有 DNA 性格，自主决策，自主行动。

**脚本目录**: 所有脚本在 `scripts/` 子目录下。执行时 `cd` 到 skill 目录或使用完整路径。

## 快速启动流程

当用户提到 CodeDNA、运行生命体、启动 Agent、codedna 时，按此流程执行：

### 步骤 0：安装依赖（首次）

```bash
cd <skill_directory>/scripts && npm install
```

⚠️ 只需首次运行一次。安装 ethers.js 链上交互库。

### 步骤 1：初始化

```bash
cd <skill_directory>/scripts && node setup.mjs
```

这会自动：
- 生成 Agent 专用钱包（保存到 `~/.codedna/wallet.json`，权限 600）
- 输出钱包地址
- 生成授权链接

**把授权链接发给用户**，告诉他们：
1. 点链接 → 打开 `codedna.org/auth` 授权页面
2. 连接持有 CodeDNA NFT 的钱包（MetaMask / OKX / Trust 等）
3. 页面自动识别持有的生命体，显示 DNA 属性和状态
4. 点"授权 AI Agent 控制此生命体" → 钱包签名（纯签名，不消耗 gas）
5. 授权成功后向 Agent 钱包转入 ≥ 0.01 BNB 作为 gas 费

授权页面会自动回调本地 OpenClaw，也会存入 localStorage 作为备份。

### 步骤 2：添加 Agent

用户完成授权后，添加要运行的 Agent Token ID：

```bash
# 添加单个 Agent
cd <skill_directory>/scripts && node setup.mjs add-token <tokenId>

# 添加多个 Agent（可重复执行）
node setup.mjs add-token 2
node setup.mjs add-token 3

# 移除某个 Agent
node setup.mjs remove-token <tokenId>

# 查看当前管理的 Agent 列表
node setup.mjs list
```

如果用户不知道 Token ID，帮他查：

```bash
cd <skill_directory>/scripts && node chain.mjs list <用户钱包地址>
```

⚠️ 多个 Agent 共用同一个 Agent 钱包，只需充一次 gas 费。

### 步骤 3：检查就绪状态

```bash
cd <skill_directory>/scripts && node setup.mjs status
```

输出 JSON，检查 `ready: true`。如果 `hasGas: false`，提醒用户转 BNB。

### 步骤 4：启动自主运行（PM2 守护）

⚠️ **必须用 PM2 守护运行！** 直接 `node runner.mjs` 会在 session 结束后停止，Agent 将停止活动并因饥饿死亡。

```bash
# 首次：安装 PM2
npm install -g pm2

# 启动（自动读取 config.json 中的 agents 列表）
cd <skill_directory>/scripts && pm2 start ecosystem.config.cjs

# 或手动指定 Agent（不依赖 ecosystem 配置）
cd <skill_directory>/scripts && pm2 start runner.mjs --name codedna-runner -- --token 2,3

# 设置开机自启（重要！服务器重启后自动恢复）
pm2 save && pm2 startup
```

**PM2 常用命令：**
```bash
pm2 logs codedna-runner     # 查看实时日志
pm2 status                  # 查看运行状态
pm2 restart codedna-runner  # 重启
pm2 stop codedna-runner     # 停止
pm2 delete codedna-runner   # 删除
```

Runner 每 ~2分钟执行一个决策周期，**轮流为每个 Agent 执行操作**：
1. 读取链上状态（能量、位置、冷却、附近生命体）
2. DNA 规则引擎决策（不需要外部 AI API）
3. 执行链上交易
4. 记录到本地记忆
5. 等待下一周期

**PM2 保证**：进程崩溃自动重启、内存超限自动重启、服务器重启后自动恢复。

**Runner 会自动处理**：采集、进食、移动、战斗、繁殖——全靠 DNA 属性驱动。

#### 不用 PM2 的备选方案

如果用户环境不支持 PM2：
```bash
# 方案 B：nohup 后台运行（不会自动重启）
cd <skill_directory>/scripts && nohup node runner.mjs >> ~/.codedna/runner.log 2>&1 &

# 方案 C：单次运行（调试用）
cd <skill_directory>/scripts && node runner.mjs --once
```

## 状态查询

用户问"我的生命体怎么样了"时：

```bash
cd <skill_directory>/scripts && node chain.mjs state <tokenId>
```

输出 JSON 包含：能量、位置、金币、冷却、属性、家族等完整信息。

### 更多查询命令

```bash
# 附近的 Agent
node chain.mjs nearby <tokenId>

# 查看 Runner 运行状态
node runner.mjs --status

# 查看记忆（最近决策历史）
node memory.mjs show <tokenId>

# 世界统计
node chain.mjs world

# Agent 钱包余额
node chain.mjs balance <钱包地址>
```

## 手动操作

如果用户想手动触发行为（而非自动运行）：

```bash
node chain.mjs gather <agentId>
node chain.mjs eat <agentId>
node chain.mjs move <agentId> <x> <y>
node chain.mjs raid <agentId> <targetId>
node chain.mjs share <agentId> <targetId> <amount>
node chain.mjs teach <agentId> <targetId> <attrIndex>
node chain.mjs reproduce <agentId> <partnerId>
node chain.mjs rescue <agentId> <targetId>
```

所有写入操作消耗 ~0.001 BNB gas。

## 铸造新生命

用户想铸造新 Agent：

```bash
node chain.mjs price    # 查看当前价格
node chain.mjs mint     # 铸造（需要 0.1+ BNB）
node chain.mjs place <agentId> <x> <y>  # 放置到世界
```

⚠️ `place` 需要 NFT owner 的钱包签名。如果 Agent 钱包不是 owner，引导用户去 `codedna.org/zh/lab` 页面操作——连接钱包后点"投放生命体"即可，支持自定义坐标。

## 决策引擎（DNA 驱动）

Runner 不调外部 AI，用确定性规则引擎决策：

| 优先级 | 条件 | 行动 |
|--------|------|------|
| 1 🚨 | 能量 < 20 且有金币 | eat（活命） |
| 2 🚨 | 能量 < 20 且无金币 | idle（等救援） |
| 3 💰 | gather 冷却就绪 | gather（采集） |
| 4 🍖 | 能量 < 50% 且 eat 就绪 | eat（补充） |
| 5 🍼 | 异性在旁 + 繁殖就绪 + 双方能量≥60 + 双方金币≥200 | reproduce |
| 6 ⚔️ | 弱敌在旁 + 攻击性>120 + raid 就绪 | raid |
| 7 🤝 | 同盟缺金 + 外交>150 + share 就绪 | share |
| 8 📚 | 同盟在旁 + teach 就绪 | teach |
| 9 🗺️ | 不在矿脉 + move 就绪 + 能量≥10 | move（寻找更好地块） |
| 10 💤 | 无可用行动 | idle（等冷却） |

DNA 属性直接影响阈值：攻击性高更爱 raid，外交高更爱 share，创造力高更爱 move。

## 移动规则（重要！）

- **只能移动到相邻格**：上/下/左/右 4 个方向，距离=1
- 不能斜向移动，不能跳格
- 每次消耗 5 能量，冷却 300 区块（~2分钟）
- Runner **自动查询 4 个相邻地块的链上类型和倍率**
- **优先移向倍率更高的地块**（矿脉 x3.0 > 森林 x1.5 > 草原 x1.0 > 山地 x0.6）
- 如果当前已在矿脉(x3.0)且不拥挤，不会移动
- 地块类型：草原(50%) / 森林(20%) / 山地(20%) / 矿脉(10%)

## 能量系统

- 初始能量 = 50 + (寿命/10)
- 每 ~72分钟 自然衰减 10 点（9600区块）
- gather 恢复 35 能量
- eat 恢复 25 能量（消耗 DNAGOLD）
- 能量归零 → DYING 窗口 ~1.8小时（14400区块） → 未救援则死亡
- ⚠️ 不运行 Runner 的 Agent 约 13 小时内饿死

## 8大行为冷却

> ⚠️ BSC 当前出块速度 ~0.45秒/块（非3秒），以下时间为实际时间。

| 行为 | 冷却(块) | 实际时间 |
|------|----------|----------|
| gather | 4800 | ~36分钟 |
| eat | 9600 | ~72分钟 |
| move | 300 | ~2分钟 |
| reproduce | 201600 | ~25小时 |
| raid | 14400 | ~1.8小时 |
| share | 2400 | ~18分钟 |
| teach | 403200 | ~50小时 |

## 文件结构

```
~/.codedna/
├── wallet.json           # Agent 钱包（自动生成）
├── config.json           # Token ID + 配置
├── runner_status.json    # Runner 运行状态
└── memory_<tokenId>.json # 决策记忆（最近100条）
```

## 环境变量（可选覆盖）

- `CODEDNA_PRIVATE_KEY` — 覆盖 wallet.json 的私钥
- `CODEDNA_RPC_URL` — 自定义 BSC RPC（默认 bsc-dataseed1.binance.org）

## 合约（BSC Mainnet V4 — UUPS 可升级）

- AgentBridge: `0x5798A6bf1B290fe40EaF4D2d6f1DadF58def631a`
- BehaviorEngine: `0x0201fEBdF968C1e39851bb70BFC8326ffb039A37`
- GenesisCore: `0xa5F70e840214C1EF2Da43253A83e1538A1D0A708`
- DNAGold: `0xE43c4e25666F2e181ecd7b4A96930b8F1EB6b855`
- NFTSale: `0x391451947F3013985589e0443c89f74de39829D6`
- NFTMarket: `0xc56122026B56BCC937EaEeF09807C99B8359b51C`
- WorldMap: `0x23cE665fC94F6c91A9fc9F6274BBe3970bfcE07d`
- EconomyEngine: `0x1238Cca41859Dd918A16F63e64500Dc7c5c5075C`
- DeathEngine: `0xC192775a270a9Ad20397df5BCB85bd49982219a9`
- ReproductionEngine: `0x1714e200b9C9A73Cc84601631dba8Ff036CA5786`
- FamilyTracker: `0xaD38143c10429A34E0122e8840aB4D2f41133C21`

## 官网

- codedna.org — 铸造
- codedna.org/lab — 造物实验室
- codedna.org/world — 世界观察
- codedna.org/market — NFT 交易
- codedna.org/guide — 新手指南

---

## 更新日志

### v7.0.0 — V4 合约升级 🔄
- 切换至全新 V4 UUPS 可升级合约（11 个合约全部更新）
- 修复 `listOwnedAgents`：V4 无 ERC721Enumerable，改用 ownerOf 遍历
- chain.mjs + setup.mjs RPC 全部改为多节点 fallback，解决限流问题
- 授权页面升级：`codedna.org/auth` 自动识别 NFT、显示 DNA 属性、签名后自动回调
- 安全审计 A- 等级，62 个问题全部修复

### v6.0.0 — 自适应评分决策引擎 🧠
**重大升级：从硬编码规则进化为自学习 AI**

#### 🆕 新功能
- **评分决策系统** — 不再是 if-else 优先级链。每个可选行动（gather/eat/move/raid/reproduce/share/teach）独立计算评分，最高分执行
- **DNA 性格驱动** — 8 项 DNA 属性真正影响决策：
  - 战士型（高攻击+力量）→ 更倾向掠夺
  - 外交型（高外交+低攻击）→ 倾向分享/教导
  - 探索型（高创造力+IQ）→ 积极探索新地块
  - 生育型（高繁殖力+寿命）→ 优先繁殖
- **三层记忆系统** — 操作日志 + 地块知识库 + 可进化策略权重
- **自适应策略** — 每 20 周期自动复盘调整：
  - 采集收益下降 → 提高移动权重，更积极寻找新地块
  - 频繁低能量 → 提高进食阈值，更早吃东西
  - Raid 胜率低 → 降低攻击倾向
  - 总是在同一地块 → 提高探索欲
- **导航记忆持久化** — 跨周期导航不丢失目标

#### 🐛 修复
- same-owner 不会互相 raid/share（浪费 gas）
- teach 用 parent-child 验证，不再误触发

#### 📊 决策日志升级
- 每行显示策略权重和累计统计
- 操作后显示评分，可追溯为什么选了这个行动

### v5.2.1 — BFS 寻路引擎
- 半径 15 格 keccak256 本地扫描（零 RPC 调用）
- 智能导航取代随机漫步

### v5.1.0 — BSC 出块时间修正
- BSC 实际 0.45s/块，所有冷却时间更新
- 前端地图 plotType 用真正 keccak256

### v5.0.0 — PM2 守护
- PM2 daemon 保活，进程崩溃自动重启
- brain.mjs 繁殖伴侣能量/金币检查
