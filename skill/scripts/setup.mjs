#!/usr/bin/env node
/**
 * CodeDNA Setup — Agent Wallet & Multi-Agent Config
 * 
 * Creates:
 *   ~/.codedna/wallet.json   — Agent wallet (auto-generated, chmod 600)
 *   ~/.codedna/config.json   — Agent list + auth state
 * 
 * Usage:
 *   node setup.mjs                    — Full setup (generate wallet, show auth link)
 *   node setup.mjs status             — Show current setup state
 *   node setup.mjs add-token <id>     — Add an agent to manage (can add multiple)
 *   node setup.mjs remove-token <id>  — Remove an agent
 *   node setup.mjs set-token <id>     — Legacy: set single agent (auto-upgrades to agents[])
 *   node setup.mjs wallet             — Show wallet address only
 *   node setup.mjs list               — List all managed agents
 */

import { ethers } from "ethers";
import { readFileSync, writeFileSync, existsSync, mkdirSync, chmodSync } from "fs";
import { join } from "path";
import { homedir } from "os";

const CONFIG_DIR = join(homedir(), ".codedna");
const WALLET_PATH = join(CONFIG_DIR, "wallet.json");
const CONFIG_PATH = join(CONFIG_DIR, "config.json");

// ========== Helpers ==========

function ensureDir() {
  if (!existsSync(CONFIG_DIR)) mkdirSync(CONFIG_DIR, { recursive: true });
}

function loadWallet() {
  if (!existsSync(WALLET_PATH)) return null;
  try { return JSON.parse(readFileSync(WALLET_PATH, "utf-8")); } catch { return null; }
}

function loadConfig() {
  if (!existsSync(CONFIG_PATH)) return { agents: [] };
  try {
    const c = JSON.parse(readFileSync(CONFIG_PATH, "utf-8"));
    // Auto-upgrade legacy format
    if (!c.agents) {
      c.agents = c.tokenId ? [c.tokenId] : [];
    }
    return c;
  } catch { return { agents: [] }; }
}

function saveConfig(config) {
  ensureDir();
  config.updatedAt = new Date().toISOString();
  writeFileSync(CONFIG_PATH, JSON.stringify(config, null, 2));
  try { chmodSync(CONFIG_PATH, 0o600); } catch {}
}

// ========== Commands ==========

async function setup() {
  ensureDir();

  // 1. Wallet
  let walletData = loadWallet();
  if (walletData) {
    console.log(`✅ 钱包已存在: ${walletData.address}`);
  } else {
    const w = ethers.Wallet.createRandom();
    walletData = {
      address: w.address,
      privateKey: w.privateKey,
      createdAt: new Date().toISOString(),
    };
    writeFileSync(WALLET_PATH, JSON.stringify(walletData, null, 2));
    try { chmodSync(WALLET_PATH, 0o600); } catch {}
    try { chmodSync(CONFIG_DIR, 0o700); } catch {}
    console.log(`🔑 新钱包已生成: ${walletData.address}`);
    console.log(`   私钥已安全保存到 ${WALLET_PATH}`);
  }

  // 2. Config
  const config = loadConfig();
  if (config.agents.length > 0) {
    console.log(`✅ 管理的 Agent: ${config.agents.map(id => "#" + id).join(", ")}`);
  } else {
    console.log(`⏳ 尚未添加 Agent — 运行: node setup.mjs add-token <tokenId>`);
  }

  // 3. Auth link
  const nonce = Math.floor(Math.random() * 1e9);
  const timestamp = Math.floor(Date.now() / 1000);
  const request = `${walletData.address}:${nonce}:${timestamp}`;

  if (config.agents.length > 0) {
    console.log(`\n🔗 授权链接 (为每个 Agent 分别打开):`);
    for (const id of config.agents) {
      console.log(`   Agent #${id}: https://codedna.org/auth?agent=${id}&request=${encodeURIComponent(request)}`);
    }
  } else {
    console.log(`\n🔗 授权链接 (选择 Agent): https://codedna.org/auth?request=${encodeURIComponent(request)}`);
  }

  console.log(`\n📋 步骤:`);
  console.log(`   1. 打开授权链接 → 连接持有 NFT 的钱包 → 签名授权`);
  console.log(`   2. 向 Agent 钱包转入 ≥ 0.01 BNB 作为 gas 费`);
  console.log(`      Agent 钱包: ${walletData.address}`);
  console.log(`   3. 启动 Runner: node runner.mjs`);

  // 4. BNB balance
  const rpcs = ["https://bsc-rpc.publicnode.com","https://bsc-dataseed1.binance.org","https://bsc-dataseed2.binance.org"];
  for (const rpc of rpcs) {
    try {
      const provider = new ethers.JsonRpcProvider(rpc);
      const bal = await provider.getBalance(walletData.address);
      const bnb = ethers.formatEther(bal);
      console.log(parseFloat(bnb) >= 0.005 ? `\n✅ Gas 余额: ${bnb} BNB` : `\n⚠️  Gas 余额: ${bnb} BNB (需要 ≥ 0.005 BNB)`);
      break;
    } catch {}
  }
}

function addToken(tokenId) {
  const parsed = parseInt(tokenId);
  if (isNaN(parsed) || parsed < 0) {
    console.error("❌ Token ID 无效，必须是非负整数");
    process.exit(1);
  }
  const config = loadConfig();
  if (config.agents.includes(parsed)) {
    console.log(`ℹ️  Agent #${parsed} 已在列表中`);
    return;
  }
  config.agents.push(parsed);
  saveConfig(config);
  console.log(`✅ 已添加 Agent #${parsed}`);
  console.log(`   当前管理: ${config.agents.map(id => "#" + id).join(", ")}`);
}

function removeToken(tokenId) {
  const parsed = parseInt(tokenId);
  const config = loadConfig();
  const idx = config.agents.indexOf(parsed);
  if (idx === -1) {
    console.log(`ℹ️  Agent #${parsed} 不在列表中`);
    return;
  }
  config.agents.splice(idx, 1);
  saveConfig(config);
  console.log(`✅ 已移除 Agent #${parsed}`);
  console.log(`   当前管理: ${config.agents.length > 0 ? config.agents.map(id => "#" + id).join(", ") : "(空)"}`);
}

function setToken(tokenId) {
  // Legacy compatibility — converts to agents[]
  const parsed = parseInt(tokenId);
  if (isNaN(parsed) || parsed < 0) {
    console.error("❌ Token ID 无效");
    process.exit(1);
  }
  const config = loadConfig();
  if (!config.agents.includes(parsed)) {
    config.agents.push(parsed);
  }
  config.tokenId = parsed;  // Keep legacy field for backward compat
  saveConfig(config);
  console.log(`✅ Token ID 设为 #${parsed} (agents: ${config.agents.map(id => "#" + id).join(", ")})`);
}

function listTokens() {
  const config = loadConfig();
  const wallet = loadWallet();
  console.log(`钱包: ${wallet ? wallet.address : "(未创建)"}`);
  if (config.agents.length === 0) {
    console.log("Agent 列表: (空)");
    console.log("添加: node setup.mjs add-token <tokenId>");
  } else {
    console.log(`Agent 列表 (${config.agents.length} 个):`);
    for (const id of config.agents) {
      console.log(`  - #${id}`);
    }
  }
}

async function showStatus() {
  const walletData = loadWallet();
  const config = loadConfig();
  
  const status = {
    wallet: walletData ? { address: walletData.address } : null,
    agents: config.agents,
    ready: false,
  };

  if (walletData) {
    try {
      const rpcs3 = ["https://bsc-rpc.publicnode.com","https://bsc-dataseed1.binance.org","https://bsc-dataseed2.binance.org"];
      let fetched = false;
      for (const rpc of rpcs3) {
        try {
          const provider = new ethers.JsonRpcProvider(rpc);
          const bal = await provider.getBalance(walletData.address);
          status.bnbBalance = ethers.formatEther(bal);
          status.hasGas = parseFloat(status.bnbBalance) >= 0.005;
          fetched = true; break;
        } catch {}
      }
      if (!fetched) { status.bnbBalance = "check_failed"; status.hasGas = false; }
    } catch {
      status.bnbBalance = "check_failed";
      status.hasGas = false;
    }
  }

  status.ready = !!(walletData && config.agents.length > 0 && status.hasGas);
  console.log(JSON.stringify(status, null, 2));
}

function showWallet() {
  const walletData = loadWallet();
  if (walletData) { console.log(walletData.address); } else {
    console.error("No wallet found. Run: node setup.mjs");
    process.exit(1);
  }
}

// ========== CLI ==========
const [cmd, ...args] = process.argv.slice(2);

switch (cmd) {
  case "status":       await showStatus(); break;
  case "add-token":    if (!args[0]) { console.error("Usage: node setup.mjs add-token <tokenId>"); process.exit(1); } addToken(args[0]); break;
  case "remove-token": if (!args[0]) { console.error("Usage: node setup.mjs remove-token <tokenId>"); process.exit(1); } removeToken(args[0]); break;
  case "set-token":    if (!args[0]) { console.error("Usage: node setup.mjs set-token <tokenId>"); process.exit(1); } setToken(args[0]); break;
  case "list":         listTokens(); break;
  case "wallet":       showWallet(); break;
  default:             await setup(); break;
}
