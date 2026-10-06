// Creates the testnet deploy wallet on THIS computer (first run), then shows its balance on every chain.
//   npm run wallet
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { readEnv, writeEnv, ENV_FILE, clients, fmt } from './lib.mjs';
import { selectedChains } from './chains.mjs';

const env = readEnv();
if (!env.PRIVATE_KEY) {
  const pk = generatePrivateKey();
  const acct = privateKeyToAccount(pk);
  writeEnv({ ...env, DEPLOYER_ADDRESS: acct.address, PRIVATE_KEY: pk });
  console.log(`New testnet deploy wallet created and saved to ${ENV_FILE}`);
  env.PRIVATE_KEY = pk;
  env.DEPLOYER_ADDRESS = acct.address;
}
const address = privateKeyToAccount(env.PRIVATE_KEY).address;
console.log(`\nDeploy wallet address: ${address}\n`);
console.log('Balances:');
for (const chain of selectedChains()) {
  try {
    const { pub } = clients(chain);
    const bal = await pub.getBalance({ address });
    const need = bal === 0n ? `   <- needs test ETH: ${chain.faucet}` : '';
    console.log(`  ${chain.name.padEnd(26)} ${fmt(bal)}${need}`);
  } catch (e) {
    console.log(`  ${chain.name.padEnd(26)} (couldn't reach the network: ${e.shortMessage || e.message})`);
  }
}
