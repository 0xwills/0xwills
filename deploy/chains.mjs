// Testnets the 0xWills demo runs on. Same WillModule address on all of them.
export const CHAINS = [
  {
    key: 'robinhood_testnet',
    name: 'Robinhood Chain testnet',
    id: 46630,
    rpc: 'https://rpc.testnet.chain.robinhood.com',
    explorer: 'https://explorer.testnet.chain.robinhood.com',
    faucet: 'https://faucet.testnet.chain.robinhood.com',
  },
  {
    key: 'sepolia',
    name: 'Ethereum Sepolia',
    id: 11155111,
    rpc: 'https://ethereum-sepolia-rpc.publicnode.com',
    explorer: 'https://sepolia.etherscan.io',
    faucet: 'https://cloud.google.com/application/web3/faucet/ethereum/sepolia',
  },
  {
    key: 'arbitrum_sepolia',
    name: 'Arbitrum Sepolia',
    id: 421614,
    rpc: 'https://sepolia-rollup.arbitrum.io/rpc',
    explorer: 'https://sepolia.arbiscan.io',
    faucet: 'run  .\\scripts\\deploy-testnets.ps1 bridge  (sends Sepolia ETH over)',
  },
  {
    key: 'base_sepolia',
    name: 'Base Sepolia',
    id: 84532,
    rpc: 'https://sepolia.base.org',
    explorer: 'https://sepolia.basescan.org',
    faucet: 'run  .\\scripts\\deploy-testnets.ps1 bridge  (sends Sepolia ETH over)',
  },
];

// For a local dry run: DEPLOY_CHAINS=local (needs `anvil` running on :8545).
export const LOCAL = { key: 'local', name: 'Local anvil', id: 31337, rpc: 'http://127.0.0.1:8545', explorer: '', faucet: '' };

export function selectedChains() {
  const want = (process.env.DEPLOY_CHAINS || '').split(',').map((s) => s.trim()).filter(Boolean);
  if (want.includes('local')) return [LOCAL];
  return want.length ? CHAINS.filter((c) => want.includes(c.key)) : CHAINS;
}
