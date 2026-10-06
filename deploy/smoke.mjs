// End-to-end test of the deployed WillModule on real testnets.
//   npm run smoke                                   (every chain where WillModule is deployed)
//   DEPLOY_CHAINS=robinhood_testnet npm run smoke
//
// On each chain, in parallel:
//   A. Full inheritance: new 1-of-1 Safe (owner = deploy wallet) holding 0.001 ETH -> enable module ->
//      signed plan (1 heir, 1 verifier, 5 min check-in, 5 min dispute) -> check-in -> signed check-in ->
//      wait until overdue -> verifier's signed confirmation (relayed) -> wait out the dispute window ->
//      execute -> heir claims -> heir received the Safe's ETH.
//   B. Cancel: second Safe with 0.001 ETH and a plan -> owner cancels with sweep -> ETH back in the
//      owner's wallet, plan gone, module switched off.
// Takes about 12 minutes (the contract's testnet minimums are 5 min + 5 min). Costs ~0.003 test ETH per chain,
// most of which goes to a throwaway heir wallet.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import {
  parseAbi, parseEther, encodeFunctionData, decodeEventLog, keccak256, toHex, concat, pad,
  getContractAddress, encodeAbiParameters,
} from 'viem';
import { generatePrivateKey, privateKeyToAccount } from 'viem/accounts';
import { HERE, loadAccount, clients, fmt } from './lib.mjs';
import { selectedChains } from './chains.mjs';

const ABI = JSON.parse(readFileSync(join(HERE, 'WillModule.abi.json'), 'utf8'));
const art = JSON.parse(readFileSync(join(HERE, 'WillModule.initcode.json'), 'utf8'));
const safeArt = JSON.parse(readFileSync(join(HERE, 'safe.initcode.json'), 'utf8'));
const MODULE = getContractAddress({
  opcode: 'CREATE2', from: art.create2Deployer, salt: art.salt,
  bytecode: concat([art.creationCode, encodeAbiParameters([{ type: 'uint64' }, { type: 'uint64' }, { type: 'bool' }],
    [BigInt(art.minCheckInInterval), BigInt(art.minDisputePeriod), !!art.isTestnet])]),
});

// Canonical Safe v1.4.1 deployment (same address on every chain where Safe is deployed).
const CANON = { factory: '0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67', singleton: '0x29fcB43b46531BcA003ddC8FCB67FFE91900C762' };
const SAFE_SALT = keccak256(toHex('0xwills-smoke-safe-v1.4.1'));

const SAFE_ABI = parseAbi([
  'function setup(address[] _owners, uint256 _threshold, address to, bytes data, address fallbackHandler, address paymentToken, uint256 payment, address paymentReceiver)',
  'function execTransaction(address to, uint256 value, bytes data, uint8 operation, uint256 safeTxGas, uint256 baseGas, uint256 gasPrice, address gasToken, address refundReceiver, bytes signatures) payable returns (bool)',
  'function enableModule(address module)',
  'function isModuleEnabled(address module) view returns (bool)',
  'function getOwners() view returns (address[])',
]);
const FACTORY_ABI = parseAbi([
  'function createProxyWithNonce(address _singleton, bytes initializer, uint256 saltNonce) returns (address proxy)',
  'event ProxyCreation(address indexed proxy, address singleton)',
]);
const STATUS = ['None', 'Active', 'Triggered', 'Executed', 'Closed'];
const ETH_IN_SAFE = parseEther(process.env.SMOKE_AMOUNT || '0.001');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const owner = loadAccount();
const results = {};

async function runChain(chain) {
  const tag = `[${chain.name}]`.padEnd(26);
  const log = (...a) => console.log(tag, ...a);
  const { pub, wallet } = clients(chain, owner);
  const local = chain.key === 'local';
  const out = (results[chain.id] = { name: chain.name, module: MODULE, steps: [] });
  const step = (name, extra = {}) => { out.steps.push({ step: name, ...extra }); };

  async function send(label, to, data, value = 0n) {
    const hash = await wallet.sendTransaction({ to, data, value });
    const rcpt = await pub.waitForTransactionReceipt({ hash, timeout: 240_000 });
    if (rcpt.status !== 'success') throw new Error(`${label} reverted: ${hash}`);
    step(label, { tx: hash });
    // Public RPCs are load-balanced: the node answering the next read can lag the one that gave the receipt.
    // Wait until a few reads in a row see the receipt's block before checking state.
    for (let seen = 0, tries = 0; seen < 3 && tries < 40; tries++) {
      seen = (await pub.getBlockNumber()) >= rcpt.blockNumber ? seen + 1 : 0;
      if (seen < 3) await sleep(local ? 0 : 750);
    }
    return rcpt;
  }
  // Read until `ok(value)` holds (covers RPC nodes that are a block behind), then return the value.
  async function settle(fn, ok, tries = 12) {
    let v;
    for (let i = 0; i < tries; i++) { v = await fn(); if (ok(v)) return v; await sleep(local ? 0 : 2500); }
    return v;
  }
  const read = (functionName, args) => pub.readContract({ address: MODULE, abi: ABI, functionName, args });
  const write = (label, functionName, args) => send(label, MODULE, encodeFunctionData({ abi: ABI, functionName, args }));
  async function now() { return (await pub.getBlock()).timestamp; }
  async function waitUntil(label, cond, maxSec) {
    if (local) {
      // anvil: jump the clock instead of waiting
      await pub.request({ method: 'evm_increaseTime', params: [maxSec] });
      await pub.request({ method: 'evm_mine', params: [] });
      if (!(await cond())) throw new Error(`still not ${label} after time travel`);
      return;
    }
    const until = Date.now() + (maxSec + 240) * 1000;
    let shown = 0;
    while (!(await cond())) {
      if (Date.now() > until) throw new Error(`timed out waiting for ${label}`);
      if (Date.now() - shown > 60_000) { log(`waiting for ${label}...`); shown = Date.now(); }
      await sleep(15_000);
    }
  }

  // ---- preflight
  const code = await pub.getCode({ address: MODULE });
  if (!code || code === '0x') throw new Error(`WillModule is not deployed at ${MODULE} on this chain`);
  const bal = await pub.getBalance({ address: owner.address });
  if (bal < ETH_IN_SAFE * 3n) throw new Error(`deploy wallet has ${fmt(bal)}, need at least ~${fmt(ETH_IN_SAFE * 3n)} plus gas`);

  // ---- Safe contracts: canonical if present, else our own copy via CREATE2
  let factory = CANON.factory, singleton = CANON.singleton;
  const canon = (await pub.getCode({ address: factory })) && (await pub.getCode({ address: singleton }));
  if (!canon || canon === '0x') {
    const deployer = art.create2Deployer;
    factory = getContractAddress({ opcode: 'CREATE2', from: deployer, salt: SAFE_SALT, bytecode: safeArt.proxyFactory });
    singleton = getContractAddress({ opcode: 'CREATE2', from: deployer, salt: SAFE_SALT, bytecode: safeArt.safeL2 });
    for (const [name, addr, bc] of [['SafeL2', singleton, safeArt.safeL2], ['SafeProxyFactory', factory, safeArt.proxyFactory]]) {
      const c = await pub.getCode({ address: addr });
      if (!c || c === '0x') { await send(`deploy ${name} (no canonical Safe here)`, deployer, concat([SAFE_SALT, bc])); }
    }
    log(`canonical Safe not found; using Safe v1.4.1 copy at ${singleton}`);
  } else {
    log('using the canonical Safe v1.4.1 deployment');
  }

  async function newSafe(label) {
    const initializer = encodeFunctionData({
      abi: SAFE_ABI, functionName: 'setup',
      args: [[owner.address], 1n, '0x0000000000000000000000000000000000000000', '0x', '0x0000000000000000000000000000000000000000', '0x0000000000000000000000000000000000000000', 0n, '0x0000000000000000000000000000000000000000'],
    });
    const saltNonce = BigInt(keccak256(toHex(`${label}-${Date.now()}-${Math.random()}`)));
    const rcpt = await send(`create Safe ${label}`, factory, encodeFunctionData({ abi: FACTORY_ABI, functionName: 'createProxyWithNonce', args: [singleton, initializer, saltNonce] }));
    let safe;
    for (const l of rcpt.logs) {
      if (l.address.toLowerCase() !== factory.toLowerCase()) continue;
      try { const ev = decodeEventLog({ abi: FACTORY_ABI, data: l.data, topics: l.topics }); if (ev.eventName === 'ProxyCreation') safe = ev.args.proxy; } catch {}
    }
    if (!safe) throw new Error('could not find the new Safe address in the factory logs');
    await send(`fund Safe ${label}`, safe, '0x', ETH_IN_SAFE);
    // 1-of-1 Safe, owner sends the tx itself: "pre-validated" signature (r = owner, s = 0, v = 1).
    const sig = concat([pad(owner.address, { size: 32 }), pad('0x00', { size: 32 }), '0x01']);
    const execData = (to, data) => encodeFunctionData({
      abi: SAFE_ABI, functionName: 'execTransaction',
      args: [to, 0n, data, 0, 0n, 0n, 0n, '0x0000000000000000000000000000000000000000', '0x0000000000000000000000000000000000000000', sig],
    });
    await send(`enable module on Safe ${label}`, safe, execData(safe, encodeFunctionData({ abi: SAFE_ABI, functionName: 'enableModule', args: [MODULE] })));
    const on = await settle(() => pub.readContract({ address: safe, abi: SAFE_ABI, functionName: 'isModuleEnabled', args: [MODULE] }), (x) => x === true);
    if (!on) throw new Error('module not enabled after the Safe transaction');
    return { safe, exec: (label2, to, data) => send(label2, safe, execData(to, data)) };
  }

  async function makePlan(safe, heir, verifier) {
    const salt = keccak256(toHex(`plan-${safe}-${Date.now()}`));
    const plan = {
      creator: owner.address, salt, nonce: 1n, issuedAt: (await now()) - 60n, // a minute back, so the next check-in is strictly later
      checkInInterval: BigInt(art.minCheckInInterval), disputePeriod: BigInt(art.minDisputePeriod),
      heirs: [{ account: heir, bps: 10000 }], verifiers: [verifier], verifierThreshold: 1,
      chains: [{ chainId: BigInt(chain.id), safe, relayFeeCap: 0n, tokens: [] }],
    };
    const digest = await read('hashPlan', [plan]);
    const sig = await owner.sign({ hash: digest });
    await write('configure plan (owner-signed)', 'configure', [plan, [owner.address], [sig]]);
    const planId = await read('planIdOf', [owner.address, salt]);
    return { plan, planId };
  }

  // ---- A + B setup
  const heirKey = generatePrivateKey(), heir = privateKeyToAccount(heirKey).address;
  const verifierAcct = privateKeyToAccount(generatePrivateKey());
  out.heir = heir; out.heirKey = heirKey; out.verifier = verifierAcct.address;

  const A = await newSafe('A');
  out.safeA = A.safe;
  const { planId } = await makePlan(A.safe, heir, verifierAcct.address);
  out.planId = planId;
  let st = await settle(() => read('getState', [planId]), (x) => STATUS[x.status] === 'Active');
  if (STATUS[st.status] !== 'Active') throw new Error(`plan status ${STATUS[st.status]}, expected Active`);
  log(`Safe A ${A.safe} has an active plan`);

  const before = st.lastCheckIn;
  await write('check-in (direct)', 'checkIn', [planId]);
  st = await settle(() => read('getState', [planId]), (x) => x.lastCheckIn > before);
  let signedAt = await now();
  if (signedAt <= st.lastCheckIn) signedAt = st.lastCheckIn + 1n;
  const ciSig = await owner.sign({ hash: await read('checkInDigest', [planId, signedAt]) });
  await write('check-in (signed, relayed)', 'checkInBySig', [planId, signedAt, owner.address, ciSig]);
  st = await settle(() => read('getState', [planId]), (x) => x.lastCheckIn === signedAt);
  if (st.lastCheckIn !== signedAt) throw new Error('signed check-in was not recorded');
  log('check-ins OK (direct + signed)');

  // ---- B: cancel with sweep while A's clock runs
  const B = await newSafe('B');
  const pb = await makePlan(B.safe, heir, verifierAcct.address);
  const ownerBefore = await pub.getBalance({ address: owner.address });
  const cancelRcpt = await B.exec('cancel plan B (Safe tx, sweep to owner, disable module)', MODULE,
    encodeFunctionData({ abi: ABI, functionName: 'cancel', args: [2n, owner.address, true] }));
  const stB = await settle(() => read('getState', [pb.planId]), (x) => STATUS[x.status] === 'None');
  const safeBBal = await settle(() => pub.getBalance({ address: B.safe }), (x) => x === 0n);
  const modOn = await settle(() => pub.readContract({ address: B.safe, abi: SAFE_ABI, functionName: 'isModuleEnabled', args: [MODULE] }), (x) => x === false);
  const ownerAfter = await pub.getBalance({ address: owner.address });
  const gasPaid = cancelRcpt.gasUsed * cancelRcpt.effectiveGasPrice;
  if (STATUS[stB.status] !== 'None') throw new Error(`cancelled plan status ${STATUS[stB.status]}`);
  if (safeBBal !== 0n) throw new Error(`Safe B still holds ${fmt(safeBBal)} after the sweep`);
  if (modOn) throw new Error('module still enabled on Safe B after cancel');
  if (ownerAfter + gasPaid - ownerBefore !== ETH_IN_SAFE) log(`note: owner balance moved by ${fmt(ownerAfter + gasPaid - ownerBefore)} (L2 fees can blur this)`);
  out.cancel = { safe: B.safe, planId: pb.planId, swept: fmt(ETH_IN_SAFE), moduleDisabled: true };
  log(`cancel OK: Safe B swept ${fmt(ETH_IN_SAFE)} back to the owner, module switched off`);

  // ---- v3: a cancel recorded for a plan that never reached this chain (creator-signed revoke)
  const ghostSalt = keccak256(toHex(`ghost-${chain.id}-${Date.now()}`));
  const ghostId = await read('planIdOf', [owner.address, ghostSalt]);
  const rvSig = await owner.sign({ hash: await read('cancelDigest', [ghostId, 5n, '0x0000000000000000000000000000000000000000', false]) });
  await write('revoke a plan that never arrived (creator-signed)', 'revokeBySig', [owner.address, ghostSalt, 5n, '0x0000000000000000000000000000000000000000', false, rvSig]);
  const gst = await settle(() => read('getState', [ghostId]), (x) => x.nonce === 5n);
  if (gst.nonce !== 5n) throw new Error('revoke did not record the nonce');
  out.revoke = { planId: ghostId, nonce: '5' };
  log('revoke OK: the undelivered plan can never be configured here');

  // ---- A: overdue -> verifier confirms -> dispute window -> execute -> claim
  const left = Number(await read('timeUntilOverdue', [planId]));
  log(`owner goes overdue in ~${left}s`);
  await waitUntil('overdue', () => read('isOverdue', [planId]), left + 5);
  st = await read('getState', [planId]);
  const cSig = await verifierAcct.sign({ hash: await read('confirmDigest', [planId, st.nonce, st.lastCheckIn]) });
  await write('verifier confirms (signed, relayed)', 'confirmDeathBySig', [planId, st.lastCheckIn, verifierAcct.address, cSig]);
  st = await settle(() => read('getState', [planId]), (x) => STATUS[x.status] === 'Triggered');
  if (STATUS[st.status] !== 'Triggered') throw new Error(`status ${STATUS[st.status]} after confirmation, expected Triggered`);
  const execAt = st.triggeredAt + st.disputePeriod;
  log(`triggered; dispute window ends in ~${Number(execAt - (await now()))}s`);
  await waitUntil('dispute window', async () => (await now()) >= execAt, Number(execAt - (await now())) + 5);
  await write('execute', 'execute', [planId]);
  const owed = await settle(() => read('claimable', [planId, 0n, '0x0000000000000000000000000000000000000000']), (x) => x === ETH_IN_SAFE);
  if (owed !== ETH_IN_SAFE) throw new Error(`claimable ${fmt(owed)}, expected ${fmt(ETH_IN_SAFE)}`);
  const heirBefore = await pub.getBalance({ address: heir });
  await write('heir claims', 'claim', [planId, 0n]);
  const heirGot = (await settle(() => pub.getBalance({ address: heir }), (x) => x - heirBefore === ETH_IN_SAFE)) - heirBefore;
  const safeLeft = await settle(() => pub.getBalance({ address: A.safe }), (x) => x === 0n);
  if (heirGot !== ETH_IN_SAFE) throw new Error(`heir received ${fmt(heirGot)}, expected ${fmt(ETH_IN_SAFE)}`);
  if (safeLeft !== 0n) throw new Error(`Safe A still holds ${fmt(safeLeft)}`);
  out.inheritance = { safe: A.safe, heir, received: fmt(heirGot) };
  out.passed = true;
  log(`inheritance OK: heir ${heir} received ${fmt(heirGot)}`);
}

console.log(`Owner / relayer: ${owner.address}`);
console.log(`WillModule:      ${MODULE}\n`);
let chains = selectedChains();
if (!process.env.DEPLOY_CHAINS) {
  // default: only chains where deploy.mjs recorded a deployment
  let done = {};
  try { done = JSON.parse(readFileSync(join(HERE, 'deployments.json'), 'utf8')).WillModule?.chains || {}; } catch {}
  chains = chains.filter((c) => done[c.id]);
  if (!chains.length) { console.log('No deployments recorded yet. Run deploy first.'); process.exit(1); }
}
const settled = await Promise.allSettled(chains.map(runChain));
console.log('\nResults');
let failed = 0;
settled.forEach((r, i) => {
  const c = chains[i];
  if (r.status === 'fulfilled') console.log(`  ${c.name.padEnd(26)} PASS`);
  else {
    failed++;
    results[c.id] = { ...(results[c.id] || { name: c.name }), passed: false, error: r.reason?.shortMessage || r.reason?.message };
    console.log(`  ${c.name.padEnd(26)} FAIL: ${r.reason?.shortMessage || r.reason?.message}`);
  }
});
const file = join(HERE, 'smoke-results.json');
// keep earlier chains' results; this run's chains replace their old entries
let prev = {};
try { prev = JSON.parse(readFileSync(file, 'utf8')); } catch {}
Object.assign(prev, results);
Object.keys(results).forEach((k) => delete results[k]);
Object.assign(results, prev);
writeFileSync(file, JSON.stringify(results, (k, v) => (typeof v === 'bigint' ? v.toString() : v), 2) + '\n');
console.log(`\nSaved ${file} (includes the throwaway heir key; testnet only)`);
process.exit(failed ? 1 : 0);
