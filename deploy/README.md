# Deploy & smoke test

Node 18+ scripts (viem) that deploy `WillModule` to **one address on every chain** and run the full inheritance flow end to end.

```bash
cd deploy
npm install
npm run wallet   # creates a fresh testnet deploy key in ../.env and shows balances + faucets
npm run bridge   # optional: moves Sepolia ETH to Arbitrum Sepolia + Base Sepolia
npm run deploy   # CREATE2 deploy on every chain that has test ETH (safe to re-run)
npm run smoke    # full flow on each chain: Safe → enable → configure → check in → cancel → revoke → confirm → execute → claim
```

- Only some chains: `DEPLOY_CHAINS=sepolia,base_sepolia npm run deploy`
- The key is created locally and stored in `../.env` (git-ignored). **Testnets only.**
- `deployments.json` records the address and deployment transaction per chain; `testnet-smoke-results.json` lists every transaction of the last live smoke run (throwaway keys removed).

## Build

`WillModule.initcode.json` holds the creation code built from `src/WillModule.sol` with solc 0.8.28, `evm_version = cancun`, optimizer 50 runs, constructor args `(minCheckInInterval = 300, minDisputePeriod = 300, isTestnet = true)` and CREATE2 salt `keccak256("0xWills.WillModule.v3")` through the standard deterministic deployer.

Expected address: **`0x3a7dFC0e190C278f6AE0D4B2b37E91F3A015ee7c`**

Mainnet builds use `isTestnet = false` and longer minimums, which gives a different address and the EIP-712 domain version `3`.

`deployments.v2.json` is the previous version (`0xA6B22EB8542C52e3eB2ede5efdcA2DFe20F31862`), kept for reference only.
