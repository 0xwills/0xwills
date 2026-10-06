// Moves test ETH from Ethereum Sepolia to Arbitrum Sepolia and Base Sepolia through their official bridges,
// so one Sepolia faucet claim can fund three chains.
//   npm run bridge                         (0.01 ETH to each)
//   BRIDGE_AMOUNT=0.02 npm run bridge
//   DEPLOY_CHAINS=base_sepolia npm run bridge
// Deposits arrive at the same address on the other chain, usually within 10-20 minutes.
import { parseEther, parseAbi, encodeFunctionData } from 'viem';
import { loadAccount, clients, fmt } from './lib.mjs';
import { CHAINS } from './chains.mjs';

const amount = parseEther(process.env.BRIDGE_AMOUNT || '0.01');
const KEEP_ON_SEPOLIA = parseEther('0.01'); // left behind for the Sepolia deploy itself

// Official bridge contracts on Sepolia (docs.arbitrum.io contract addresses; docs.base.org base contracts).
const ROUTES = [
  {
    to: 'arbitrum_sepolia',
    via: 'Arbitrum bridge (Inbox.depositEth)',
    target: '0xaAe29B0366299461418F5324a79Afc425BE5ae21',
    data: encodeFunctionData({
      abi: parseAbi(['function depositEth() payable returns (uint256)']),
      functionName: 'depositEth',
    }),
  },
  {
    to: 'base_sepolia',
    via: 'Base bridge (L1StandardBridge.depositETH)',
    target: '0xfd0Bf71F60660E2f608ed56e1659C450eB113120',
    data: encodeFunctionData({
      abi: parseAbi(['function depositETH(uint32 _minGasLimit, bytes _extraData) payable']),
      functionName: 'depositETH',
      args: [200000, '0x'],
    }),
  },
];

const want = (process.env.DEPLOY_CHAINS || '').split(',').map((s) => s.trim()).filter(Boolean);
const sepolia = CHAINS.find((c) => c.key === 'sepolia');
const account = loadAccount();
const { pub, wallet } = clients(sepolia, account);

console.log(`Deploy wallet: ${account.address}`);
console.log(`Bridging ${fmt(amount)} from Ethereum Sepolia to each chain that needs it\n`);

let failures = 0;
for (const route of ROUTES) {
  if (want.length && !want.includes(route.to)) continue;
  const dest = CHAINS.find((c) => c.key === route.to);
  const label = dest.name.padEnd(20);
  try {
    const destBal = await clients(dest).pub.getBalance({ address: account.address });
    if (destBal >= amount / 2n) {
      console.log(`${label} already has ${fmt(destBal)}, skipping`);
      continue;
    }
    const bal = await pub.getBalance({ address: account.address });
    const gas = await pub.estimateGas({ account, to: route.target, data: route.data, value: amount });
    const gasPrice = await pub.getGasPrice();
    const cost = amount + (gas * 12n / 10n) * gasPrice;
    if (bal < cost + KEEP_ON_SEPOLIA) {
      throw new Error(`not enough Sepolia ETH: have ${fmt(bal)}, need about ${fmt(cost + KEEP_ON_SEPOLIA)} (incl. ${fmt(KEEP_ON_SEPOLIA)} kept for the Sepolia deploy)`);
    }
    const hash = await wallet.sendTransaction({ to: route.target, data: route.data, value: amount, gas: gas * 12n / 10n });
    const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 180_000 });
    if (rcpt.status !== 'success') throw new Error(`transaction reverted: ${hash}`);
    console.log(`${label} sent via ${route.via}   ${sepolia.explorer}/tx/${hash}`);
  } catch (e) {
    failures++;
    console.log(`${label} FAILED: ${e.shortMessage || e.message}`);
  }
}

console.log('\nDeposits usually arrive in 10-20 minutes. Check with:  .\\scripts\\deploy-testnets.ps1 wallet');
process.exit(failures ? 1 : 0);
