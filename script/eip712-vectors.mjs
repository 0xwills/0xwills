// Computes the EIP-712 test vectors in test/Digest.t.sol with viem (what the app uses to sign).
// Run: npm i viem@2 && node script/eip712-vectors.mjs
import { hashTypedData, keccak256, encodeAbiParameters } from 'viem';
const domain = { name: '0xWills', version: '4-testnet', verifyingContract: '0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f' };
const types = {
  Heir: [{name:'account',type:'address'},{name:'bps',type:'uint16'}],
  ChainConfig: [{name:'chainId',type:'uint256'},{name:'safe',type:'address'},{name:'relayFeeCap',type:'uint256'},{name:'tokens',type:'address[]'}],
  Plan: [{name:'creator',type:'address'},{name:'salt',type:'bytes32'},{name:'nonce',type:'uint64'},{name:'issuedAt',type:'uint64'},{name:'checkInInterval',type:'uint64'},{name:'disputePeriod',type:'uint64'},{name:'heirs',type:'Heir[]'},{name:'verifiers',type:'address[]'},{name:'verifierThreshold',type:'uint8'},{name:'verifierFallback',type:'uint64'},{name:'chains',type:'ChainConfig[]'}],
  CheckIn: [{name:'planId',type:'bytes32'},{name:'signedAt',type:'uint64'}],
  Confirm: [{name:'planId',type:'bytes32'},{name:'nonce',type:'uint64'},{name:'epoch',type:'uint64'}],
  Claim: [{name:'planId',type:'bytes32'},{name:'index',type:'uint256'},{name:'claimNonce',type:'uint256'},{name:'maxFee',type:'uint256'}],
  Cancel: [{name:'planId',type:'bytes32'},{name:'nonce',type:'uint64'},{name:'sweepTo',type:'address'},{name:'disableModule',type:'bool'}],
};
const a = n => '0x' + String(n).repeat(40);
const plan = { creator: a(1), salt: '0x' + (42).toString(16).padStart(64,'0'), nonce: 1n, issuedAt: 1750000000n, checkInInterval: 2592000n, disputePeriod: 604800n,
  heirs: [{account:a(2),bps:6000},{account:a(3),bps:4000}], verifiers:[a(4),a(5)], verifierThreshold:2, verifierFallback:31536000n,
  chains:[{chainId:46630n,safe:a(7),relayFeeCap:10n**15n,tokens:[a(6)]},{chainId:421614n,safe:a(8),relayFeeCap:2n*10n**15n,tokens:[]}] };
const planId = keccak256(encodeAbiParameters([{type:'address'},{type:'bytes32'}],[plan.creator, plan.salt]));
console.log(hashTypedData({domain, types, primaryType:'Plan', message: plan}));
console.log(planId);
console.log(hashTypedData({domain, types, primaryType:'CheckIn', message:{planId, signedAt:1750000100n}}));
console.log(hashTypedData({domain, types, primaryType:'Confirm', message:{planId, nonce:1n, epoch:1750000000n}}));
console.log(hashTypedData({domain, types, primaryType:'Cancel', message:{planId, nonce:2n, sweepTo:a(9), disableModule:true}}));
console.log(hashTypedData({domain, types, primaryType:'Claim', message:{planId, index:0n, claimNonce:1n, maxFee:5n*10n**14n}}));
