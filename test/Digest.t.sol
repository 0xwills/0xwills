// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {WillModule} from "../src/WillModule.sol";

/// Fixed EIP-712 vectors. The expected values were computed independently with viem's hashTypedData
/// (script/eip712-vectors.mjs), so wallet signatures made by the app will match what the contract checks.
contract DigestTest is Test {
    function _hc(address a, uint16 b) internal pure returns (WillModule.HeirConfig memory h) {
        h.account = a;
        h.bps = b;
    }
    function test_Eip712VectorsMatchViem() public {
        WillModule m = new WillModule(1 hours, 1 hours, true);
        WillModule.Plan memory p;
        p.creator = address(0x1111111111111111111111111111111111111111);
        p.salt = bytes32(uint256(42));
        p.nonce = 1;
        p.issuedAt = 1_750_000_000;
        p.checkInInterval = 30 days;
        p.disputePeriod = 7 days;
        p.heirs = new WillModule.HeirConfig[](2);
        p.heirs[0] = _hc(address(0x2222222222222222222222222222222222222222), 6000);
        p.heirs[0].vestBps = new uint16[](2);
        p.heirs[0].vestBps[0] = 2000;
        p.heirs[0].vestBps[1] = 8000;
        p.heirs[0].vestAfter = new uint32[](2);
        p.heirs[0].vestAfter[1] = 90 days;
        p.heirs[0].noteHash = bytes32(uint256(99));
        p.heirs[1] = _hc(address(0x3333333333333333333333333333333333333333), 4000);
        p.verifiers = new address[](2);
        p.verifiers[0] = address(0x4444444444444444444444444444444444444444);
        p.verifiers[1] = address(0x5555555555555555555555555555555555555555);
        p.verifierThreshold = 2;
        p.verifierFallback = 365 days;
        p.chains = new WillModule.ChainConfig[](2);
        address[] memory t = new address[](1);
        t[0] = address(0x6666666666666666666666666666666666666666);
        p.chains[0] = WillModule.ChainConfig(46630, address(0x7777777777777777777777777777777777777777), 1e15, t);
        p.chains[1] = WillModule.ChainConfig(421614, address(0x8888888888888888888888888888888888888888), 2e15, new address[](0));
        bytes32 id = m.planIdOf(p.creator, p.salt);
        assertEq(address(m), 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f);
        assertEq(m.hashPlan(p), 0xe812064c1688e7af6f6c717a6647790d2666eac374cac993f16c3dfa81909b95);
        assertEq(id, 0xc775cb6f4825b8f8a497b9aa584318d60b9cc8cebb7c28af819b1644ac2d56e1);
        assertEq(m.checkInDigest(id, 1_750_000_100), 0x6aaf87a4f2b55282b85bf61e1fa4d78d9a5d3a713b27d7ed00a098bce300c1d0);
        assertEq(m.confirmDigest(id, 1, 1_750_000_000), 0x1b7481e3fc2c7628061c787981699427ad5b27240536a8bc8dc5b6e063c8f9a3);
        assertEq(
            m.cancelDigest(id, 2, address(0x9999999999999999999999999999999999999999), true),
            0xfc479727df661a8bc29f1d3fe2534262ec59c21301520ab7bf088f58409a2755
        );
        assertEq(m.claimDigest(id, 0, 1, 5e14), 0x57f0ee5419b0b3c27920a450356c1651250ec1f46e525f7118529baad4abfe7d);
    }
}
