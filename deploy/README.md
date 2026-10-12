# Deploy WillModule to the demo testnets

Deploys the contract at **one address on all four testnets** (Robinhood Chain testnet, Ethereum Sepolia, Arbitrum Sepolia, Base Sepolia). Needs Node.js 18+ (https://nodejs.org).

From the `0xwills` folder in PowerShell:

```powershell
.\scripts\deploy-testnets.ps1 wallet   # first time: creates the deploy wallet, shows its address and balances
.\scripts\deploy-testnets.ps1 bridge   # sends Sepolia test ETH to Arbitrum Sepolia + Base Sepolia (0.01 each)
.\scripts\deploy-testnets.ps1 deploy   # deploys to every chain that has test ETH; safe to re-run
```

- The deploy wallet's key is created **on this computer** and saved in `contracts/.env`. It's ignored by git and never uploaded. Use it for testnets only.
- Each chain needs a little test ETH in the deploy wallet (one deploy costs well under 0.01 test ETH). `wallet` lists a faucet for each chain that's empty.
- Getting test ETH: Robinhood Chain testnet from the official faucet (https://faucet.testnet.chain.robinhood.com, address only). Sepolia from Google's faucet (Google login) or https://sepolia-faucet.pk910.de (browser mining, no requirements). Then `bridge` moves 0.01 Sepolia ETH each to Arbitrum Sepolia and Base Sepolia through their official bridges (arrives in 10-20 min). Amount: `$env:BRIDGE_AMOUNT="0.02"`.
- Results go to `contracts/deploy/deployments.json` (the address plus the transaction on each chain).
- Deploy only some chains: `$env:DEPLOY_CHAINS="sepolia,base_sepolia"; .\scripts\deploy-testnets.ps1 deploy`

The contract bytecode is in `WillModule.initcode.json` (v5: built from `src/WillModule.sol` with solc 0.8.28 via-IR, optimizer 50 runs, minimum interval and dispute window 5 minutes). Expected address: `0x7F0307cF3A5779cdA232003158adfCEc6F410971`. Earlier deployments are kept in `deployments.v2.json`, `deployments.v3.json` and `deployments.v4.json`.
