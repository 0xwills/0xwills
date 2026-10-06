// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WillModule} from "../src/WillModule.sol";

/// Fixed EIP-712 vectors. The expected values were computed independently with viem's hashTypedData
/// (script/eip712-vectors.mjs), so wallet signatures made by the app will match what the contract checks.
contract DigestTest is Test {
    function test_Eip712VectorsMatchViem() public {
        WillModule m = new WillModule(1 hours, 1 hours, true);
        WillModule.Plan memory p;
        p.creator = address(0x1111111111111111111111111111111111111111);
        p.salt = bytes32(uint256(42));
        p.nonce = 1;
        p.issuedAt = 1_750_000_000;
        p.checkInInterval = 30 days;
        p.disputePeriod = 7 days;
        p.heirs = new WillModule.Heir[](2);
        p.heirs[0] = WillModule.Heir(address(0x2222222222222222222222222222222222222222), 6000);
        p.heirs[1] = WillModule.Heir(address(0x3333333333333333333333333333333333333333), 4000);
        p.verifiers = new address[](2);
        p.verifiers[0] = address(0x4444444444444444444444444444444444444444);
        p.verifiers[1] = address(0x5555555555555555555555555555555555555555);
        p.verifierThreshold = 2;
        p.chains = new WillModule.ChainConfig[](2);
        address[] memory t = new address[](1);
        t[0] = address(0x6666666666666666666666666666666666666666);
        p.chains[0] = WillModule.ChainConfig(46630, address(0x7777777777777777777777777777777777777777), 1e15, t);
        p.chains[1] = WillModule.ChainConfig(421614, address(0x8888888888888888888888888888888888888888), 2e15, new address[](0));
        bytes32 id = m.planIdOf(p.creator, p.salt);
        assertEq(address(m), 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);
        assertEq(m.hashPlan(p), 0x7592ab6f75be55cae91a8cf4cb63c7b71d6c4ea1294737aad5dba4881f031c5c);
        assertEq(id, 0xc775cb6f4825b8f8a497b9aa584318d60b9cc8cebb7c28af819b1644ac2d56e1);
        assertEq(m.checkInDigest(id, 1_750_000_100), 0x8996785f74463681a3a197967132951ddf4e4bdcf7c94f7e3fbbdbd1f83f55cc);
        assertEq(m.confirmDigest(id, 1, 1_750_000_000), 0xace61bc8739be9087e207ce7a06d319b0ac2895e14c3d40539c026b3a867690c);
        assertEq(
            m.cancelDigest(id, 2, address(0x9999999999999999999999999999999999999999), true),
            0x77920658c337f7175cf15a06bc3170d82ee1505c76ddfc9909de6b3a90b00057
        );
        assertEq(m.claimDigest(id, 0, 1, 5e14), 0x42a40b35739160243b563629baa27a156cd3f95520e260e632c75ceeea5c87a0);
    }
}
