// Deploys WillModule at the same address on every testnet via the standard CREATE2 deployer.
//   npm run deploy            (all four testnets)
//   DEPLOY_CHAINS=sepolia,base_sepolia npm run deploy
// Safe to re-run: chains where it's already deployed are skipped.
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { encodeAbiParameters, concat, getContractAddress, keccak256 } from 'viem';
import { HERE, loadAccount, clients, fmt } from './lib.mjs';
import { selectedChains } from './chains.mjs';

const art = JSON.parse(readFileSync(join(HERE, 'WillModule.initcode.json'), 'utf8'));
const initCode = concat([
  art.creationCode,
  encodeAbiParameters([{ type: 'uint64' }, { type: 'uint64' }, { type: 'bool' }], [BigInt(art.minCheckInInterval), BigInt(art.minDisputePeriod), !!art.isTestnet]),
]);
const expected = getContractAddress({ opcode: 'CREATE2', from: art.create2Deployer, salt: art.salt, bytecode: initCode });
const account = loadAccount();

const outFile = join(HERE, 'deployments.json');
const record = existsSync(outFile) ? JSON.parse(readFileSync(outFile, 'utf8')) : {};
record.WillModule = record.WillModule || { address: expected, initCodeHash: keccak256(initCode), chains: {} };
if (record.WillModule.address !== expected) record.WillModule = { address: expected, initCodeHash: keccak256(initCode), chains: {} };

console.log(`Deployer: ${account.address}`);
console.log(`WillModule will live at ${expected} on every chain\n`);

let failures = 0;
for (const chain of selectedChains()) {
  const label = chain.name.padEnd(26);
  try {
    const { pub, wallet } = clients(chain, account);
    const id = await pub.getChainId();
    if (id !== chain.id) throw new Error(`RPC reports chain ${id}, expected ${chain.id}`);

    const existing = await pub.getCode({ address: expected });
    if (existing && existing !== '0x') {
      console.log(`${label} already deployed`);
      record.WillModule.chains[chain.id] = { ...(record.WillModule.chains[chain.id] || {}), name: chain.name, explorer: chain.explorer };
      continue;
    }
    const deployerCode = await pub.getCode({ address: art.create2Deployer });
    if (!deployerCode || deployerCode === '0x') throw new Error('the standard CREATE2 deployer is not on this chain');

    const data = concat([art.salt, initCode]);
    const gas = await pub.estimateGas({ account, to: art.create2Deployer, data });
    const gasPrice = await pub.getGasPrice();
    const bal = await pub.getBalance({ address: account.address });
    const cost = (gas * 12n / 10n) * gasPrice;
    if (bal < cost) throw new Error(`not enough test ETH: have ${fmt(bal)}, need about ${fmt(cost)}`);

    const hash = await wallet.sendTransaction({ to: art.create2Deployer, data, gas: gas * 12n / 10n });
    const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    if (rcpt.status !== 'success') throw new Error(`transaction reverted: ${hash}`);
    // public RPCs (e.g. Base) can answer from a node that hasn't seen the new block yet: retry for ~60s
    let code;
    for (let i = 0; i < 20; i++) {
      code = await pub.getCode({ address: expected });
      if (code && code !== '0x') break;
      await new Promise((r) => setTimeout(r, 3000));
    }
    if (!code || code === '0x') throw new Error(`no code at ${expected} after ${hash}`);

    record.WillModule.chains[chain.id] = { name: chain.name, tx: hash, block: Number(rcpt.blockNumber), explorer: chain.explorer };
    console.log(`${label} deployed   ${chain.explorer ? `${chain.explorer}/tx/${hash}` : hash}`);
  } catch (e) {
    failures++;
    console.log(`${label} FAILED: ${e.shortMessage || e.message}`);
  }
}

writeFileSync(outFile, JSON.stringify(record, null, 2) + '\n');
console.log(`\nSaved ${outFile}`);
process.exit(failures ? 1 : 0);
