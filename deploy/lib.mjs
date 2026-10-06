import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createPublicClient, createWalletClient, http, defineChain, formatEther } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

export const HERE = dirname(fileURLToPath(import.meta.url));
// The key lives in contracts/.env on this computer only (never committed, never uploaded).
export const ENV_FILE = join(HERE, '..', '.env');

export function readEnv() {
  const out = {};
  if (!existsSync(ENV_FILE)) return out;
  for (const line of readFileSync(ENV_FILE, 'utf8').split(/\r?\n/)) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)\s*$/);
    if (m) out[m[1]] = m[2];
  }
  return out;
}

export function writeEnv(vars) {
  const body =
    '# 0xWills TESTNET deploy wallet. Testnets only - never send real funds here, never share this file.\n' +
    Object.entries(vars).map(([k, v]) => `${k}=${v}`).join('\n') + '\n';
  writeFileSync(ENV_FILE, body, { mode: 0o600 });
}

export function loadAccount() {
  const env = readEnv();
  const pk = process.env.PRIVATE_KEY || env.PRIVATE_KEY;
  if (!pk) {
    console.error('No deploy wallet yet. Run:  npm run wallet');
    process.exit(1);
  }
  return privateKeyToAccount(pk.startsWith('0x') ? pk : `0x${pk}`);
}

export function clients(chain, account) {
  const c = defineChain({
    id: chain.id,
    name: chain.name,
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    rpcUrls: { default: { http: [chain.rpc] } },
  });
  const transport = http(chain.rpc, { timeout: 30_000, retryCount: 2 });
  return {
    pub: createPublicClient({ chain: c, transport }),
    wallet: account ? createWalletClient({ chain: c, transport, account }) : null,
  };
}

export const fmt = (wei) => `${Number(formatEther(wei)).toFixed(5)} ETH`;
