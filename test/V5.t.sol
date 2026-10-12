// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WillModuleTest} from "./WillModule.t.sol";
import {WillModule} from "../src/WillModule.sol";

/// v5: staged payouts (per-heir vesting schedule measured from execution) + per-heir note hash.
contract V5Test is WillModuleTest {
    uint16 constant ALL = 10_000;

    // ------------------------------------------------------------------ helpers

    function _sched(uint16[] memory bps, uint32[] memory after_) internal pure returns (uint16[] memory, uint32[] memory) {
        return (bps, after_);
    }

    function _u16(uint16 a) internal pure returns (uint16[] memory r) {
        r = new uint16[](1);
        r[0] = a;
    }

    function _u16(uint16 a, uint16 b) internal pure returns (uint16[] memory r) {
        r = new uint16[](2);
        r[0] = a;
        r[1] = b;
    }

    function _u32(uint32 a) internal pure returns (uint32[] memory r) {
        r = new uint32[](1);
        r[0] = a;
    }

    function _u32(uint32 a, uint32 b) internal pure returns (uint32[] memory r) {
        r = new uint32[](2);
        r[0] = a;
        r[1] = b;
    }

    /// Plan where heir A (60%) vests `bps` after `after_` and heir B (40%) is paid all at once.
    function _planVest(uint64 nonce, uint16[] memory bps, uint32[] memory after_)
        internal
        view
        returns (WillModule.Plan memory p)
    {
        p = _plan(nonce, 2, 0);
        p.heirs[0].vestBps = bps;
        p.heirs[0].vestAfter = after_;
        p.heirs[0].noteHash = keccak256("note for A");
    }

    function _executeNow() internal {
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
    }

    function _expectCfg(WillModule.Plan memory p, uint8 code) internal {
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, code));
        module.configure(p, signers, sigs);
    }

    // ------------------------------------------------------------------ config

    function test_V5_ScheduleStoredAndReadable() public {
        _configureBySig(_planVest(1, _u16(2000, 8000), _u32(0, 90 days)));
        (uint16[] memory b, uint32[] memory a) = module.getVesting(planId, 0);
        assertEq(b.length, 2);
        assertEq(b[0], 2000);
        assertEq(b[1], 8000);
        assertEq(a[0], 0);
        assertEq(a[1], 90 days);
        (b, a) = module.getVesting(planId, 1);
        assertEq(b.length, 0);
        assertEq(module.noteHash(planId, 0), keccak256("note for A"));
        assertEq(module.noteHash(planId, 1), bytes32(0));
        // before execution a scheduled heir shows 0 vested, an unscheduled one 100%
        assertEq(module.vestedBps(planId, 0), 0);
        assertEq(module.vestedBps(planId, 1), ALL);
        assertEq(module.nextUnlockAt(planId, 0), 0);
    }

    function test_V5_ScheduleIsPartOfTheSignedPlan() public {
        WillModule.Plan memory a = _planVest(1, _u16(2000, 8000), _u32(0, 90 days));
        WillModule.Plan memory b = _planVest(1, _u16(2000, 8000), _u32(0, 91 days));
        WillModule.Plan memory c = _planVest(1, _u16(2000, 8000), _u32(0, 90 days));
        c.heirs[0].noteHash = keccak256("other note");
        assertTrue(module.hashPlan(a) != module.hashPlan(b));
        assertTrue(module.hashPlan(a) != module.hashPlan(c));
        assertTrue(module.hashPlan(_plan(1, 2, 0)) != module.hashPlan(a));
        // owners signed a 90-day schedule: a relayer can't submit it as "all at once"
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(a));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.configure(_plan(1, 2, 0), signers, sigs);
    }

    function test_V5_ScheduleValidation() public {
        // 25: lengths differ
        _expectCfg(_planVest(1, _u16(5000, 5000), _u32(0)), 25);
        // 25: too many tranches
        uint16[] memory b = new uint16[](13);
        uint32[] memory a = new uint32[](13);
        for (uint256 i; i < 13; ++i) {
            b[i] = i == 0 ? 400 : 800;
            a[i] = uint32(i * 30 days);
        }
        _expectCfg(_planVest(1, b, a), 25);
        // 26: does not sum to 100% of the share
        _expectCfg(_planVest(1, _u16(2000, 7000), _u32(0, 90 days)), 26);
        _expectCfg(_planVest(1, _u16(2000, 9000), _u32(0, 90 days)), 26);
        // 27: unlock times must strictly increase
        _expectCfg(_planVest(1, _u16(5000, 5000), _u32(90 days, 90 days)), 27);
        _expectCfg(_planVest(1, _u16(5000, 5000), _u32(90 days, 30 days)), 27);
        // 28: last unlock beyond five years
        _expectCfg(_planVest(1, _u16(5000, 5000), _u32(0, 1825 days + 1)), 28);
        // the maximum is fine, and 12 tranches is fine
        _configureBySig(_planVest(1, _u16(5000, 5000), _u32(0, 1825 days)));
        b = new uint16[](12);
        a = new uint32[](12);
        for (uint256 i; i < 12; ++i) {
            b[i] = i == 0 ? 1200 : 800;
            a[i] = uint32(i * 30 days);
        }
        _configureBySig(_planVest(2, b, a));
        (uint16[] memory sb,) = module.getVesting(planId, 0);
        assertEq(sb.length, 12);
    }

    function test_V5_ReconfigureReplacesSchedule() public {
        _configureBySig(_planVest(1, _u16(2000, 8000), _u32(0, 90 days)));
        // the update drops the schedule and the note
        WillModule.Plan memory p = _plan(2, 2, 0);
        _configureBySig(p);
        (uint16[] memory b,) = module.getVesting(planId, 0);
        assertEq(b.length, 0);
        assertEq(module.noteHash(planId, 0), bytes32(0));
        assertEq(module.vestedBps(planId, 0), ALL);
        // a plan with fewer heirs leaves no stale schedule behind for the dropped index
        _configureBySig(_planVest(3, _u16(5000, 5000), _u32(0, 30 days)));
        p = _plan(4, 2, 0);
        p.heirs = new WillModule.HeirConfig[](1);
        p.heirs[0] = _hc(heirA, 10_000);
        _configureBySig(p);
        (b,) = module.getVesting(planId, 0);
        assertEq(b.length, 0);
        (b,) = module.getVesting(planId, 1);
        assertEq(b.length, 0);
        assertEq(module.noteHash(planId, 1), bytes32(0));
    }

    // ------------------------------------------------------------------ payout maths

    function test_V5_TwoTranches_HalfOnClaimHalfLater() public {
        _configureBySig(_planVest(1, _u16(5000, 5000), _u32(0, 90 days)));
        _executeNow();
        uint64 x = module.getState(planId).executedAt;
        assertEq(module.vestedBps(planId, 0), 5000);
        assertEq(module.nextUnlockAt(planId, 0), x + 90 days);
        assertEq(module.claimable(planId, 0, address(0)), 3 ether); // 60% of 10 ETH, half vested
        assertEq(module.claimable(planId, 0, address(usdA)), 300_000e18);
        assertEq(module.claimable(planId, 1, address(0)), 4 ether); // B is all at once

        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 3 ether);
        assertEq(usdA.balanceOf(heirA), 300_000e18);
        // a second claim before the unlock pays nothing
        assertEq(module.claimable(planId, 0, address(0)), 0);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 3 ether);

        vm.prank(heirB);
        module.claim(planId, 1);
        assertEq(heirB.balance, 4 ether);
        assertEq(address(safeA).balance, 3 ether); // A's locked half stays in the Safe

        vm.warp(x + 90 days - 1);
        assertEq(module.claimable(planId, 0, address(0)), 0);
        vm.warp(x + 90 days);
        assertEq(module.vestedBps(planId, 0), ALL);
        assertEq(module.nextUnlockAt(planId, 0), 0);
        assertEq(module.claimable(planId, 0, address(0)), 3 ether);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 6 ether);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(address(safeA).balance, 0);
        assertEq(usdA.balanceOf(address(safeA)), 0);
    }

    function test_V5_NothingOnClaim_FirstUnlockLater() public {
        _configureBySig(_planVest(1, _u16(ALL), _u32(180 days)));
        _executeNow();
        uint64 x = module.getState(planId).executedAt;
        assertEq(module.vestedBps(planId, 0), 0);
        assertEq(module.nextUnlockAt(planId, 0), x + 180 days);
        assertEq(module.claimable(planId, 0, address(0)), 0);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 0);
        vm.warp(x + 180 days);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 6 ether);
    }

    function test_V5_FiveTranches_SkippedUnlocksAccumulate() public {
        uint16[] memory b = new uint16[](5);
        uint32[] memory a = new uint32[](5);
        for (uint256 i; i < 5; ++i) {
            b[i] = 2000;
            a[i] = uint32(i * 90 days);
        }
        _configureBySig(_planVest(1, b, a));
        _executeNow();
        uint64 x = module.getState(planId).executedAt;
        // heir A does nothing for a year: three tranches (0, 90, 180, 270 days) have unlocked
        vm.warp(x + 300 days);
        assertEq(module.vestedBps(planId, 0), 8000);
        assertEq(module.nextUnlockAt(planId, 0), x + 360 days);
        assertEq(module.claimable(planId, 0, address(0)), 4.8 ether);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 4.8 ether);
        vm.warp(x + 360 days);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 6 ether);
    }

    function test_V5_TwelveTranches_NoDustLeftBehind() public {
        uint16[] memory b = new uint16[](12);
        uint32[] memory a = new uint32[](12);
        for (uint256 i; i < 12; ++i) {
            b[i] = i == 0 ? 1200 : 800; // 1200 + 11*800 = 10000
            a[i] = uint32(i * 30 days);
        }
        WillModule.Plan memory p = _planVest(1, b, a);
        // odd amounts so rounding would show
        vm.deal(address(safeA), 7 ether + 1 wei);
        _configureBySig(p);
        _executeNow();
        uint64 x = module.getState(planId).executedAt;
        vm.prank(heirB);
        module.claim(planId, 1);
        for (uint256 i; i < 12; ++i) {
            vm.warp(x + i * 30 days);
            vm.prank(heirA);
            module.claim(planId, 0);
        }
        uint256 total = 7 ether + 1 wei;
        uint256 shareA = total * 6000 / 10_000;
        assertEq(heirA.balance, shareA);
        assertEq(heirB.balance, total * 4000 / 10_000);
        assertLe(address(safeA).balance, 1); // at most 1 wei of rounding
    }

    function test_V5_UnscheduledHeirUnaffectedByOthersSchedule() public {
        _configureBySig(_planVest(1, _u16(ALL), _u32(365 days)));
        _executeNow();
        vm.prank(heirB);
        module.claim(planId, 1);
        assertEq(heirB.balance, 4 ether);
        assertEq(usdA.balanceOf(heirB), 400_000e18);
        // A's whole share stays locked in the Safe for a year
        assertEq(address(safeA).balance, 6 ether);
        assertEq(usdA.balanceOf(address(safeA)), 600_000e18);
    }

    function test_V5_FundsArrivingLaterFollowTheSchedule() public {
        _configureBySig(_planVest(1, _u16(5000, 5000), _u32(0, 90 days)));
        _executeNow();
        uint64 x = module.getState(planId).executedAt;
        vm.prank(heirA);
        module.claim(planId, 0);
        vm.prank(heirB);
        module.claim(planId, 1);
        // 10 more ETH lands in the Safe after execution
        vm.deal(address(safeA), address(safeA).balance + 10 ether);
        // B gets 40% of the new money at once; A only the vested half of its 60%
        assertEq(module.claimable(planId, 1, address(0)), 4 ether);
        assertEq(module.claimable(planId, 0, address(0)), 3 ether);
        vm.warp(x + 90 days);
        assertEq(module.claimable(planId, 0, address(0)), 9 ether);
        vm.prank(heirA);
        module.claim(planId, 0);
        vm.prank(heirB);
        module.claim(planId, 1);
        assertEq(heirA.balance, 12 ether);
        assertEq(heirB.balance, 8 ether);
        assertEq(address(safeA).balance, 0);
    }

    // ------------------------------------------------------------------ relayed claims + fallback

    function test_V5_RelayedClaimFeeOnlyFromVestedEth() public {
        WillModule.Plan memory p = _planVest(1, _u16(5000, 5000), _u32(0, 90 days));
        p.chains[0].relayFeeCap = CAP;
        p.chains[1].relayFeeCap = CAP;
        _configureBySig(p);
        _executeNow(); // execute() with a fee cap pays this caller's gas from the Safe first
        uint256 snap = address(safeA).balance;
        uint256 before = relayer.balance;
        vm.fee(1_000 gwei);
        vm.txGasPrice(1_000 gwei);
        bytes memory hsig = _sign(kHeirA, module.claimDigest(planId, 0, 0, CAP));
        vm.prank(relayer, relayer);
        module.claimBySig(planId, 0, CAP, hsig);
        uint256 fee = relayer.balance - before;
        assertEq(fee, CAP);
        uint256 half = snap * 6000 / 10_000 / 2;
        assertEq(heirA.balance, half - fee);
        // nothing vested yet: a relayed claim pays no fee and takes nothing
        hsig = _sign(kHeirA, module.claimDigest(planId, 0, 1, CAP));
        before = relayer.balance;
        vm.prank(relayer, relayer);
        module.claimBySig(planId, 0, CAP, hsig);
        assertEq(relayer.balance, before);
        assertEq(heirA.balance, half - fee);
        assertEq(address(safeA).balance, snap - half);
    }

    function test_V5_ScheduleCountsFromFallbackExecutionToo() public {
        WillModule.Plan memory p = _planVest(1, _u16(5000, 5000), _u32(0, 90 days));
        p.verifierFallback = 90 days;
        _configureBySig(p);
        WillModule.State memory s = module.getState(planId);
        vm.warp(uint256(s.lastCheckIn) + s.checkInInterval + 90 days);
        module.trigger(planId);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        uint64 x = module.getState(planId).executedAt;
        assertEq(x, uint64(block.timestamp));
        assertEq(module.nextUnlockAt(planId, 0), x + 90 days);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 3 ether);
    }

    function test_V5_ClaimAssetsRespectsSchedule() public {
        _configureBySig(_planVest(1, _u16(5000, 5000), _u32(0, 90 days)));
        _executeNow();
        address[] memory only = new address[](1);
        only[0] = address(usdA);
        vm.prank(heirA);
        module.claimAssets(planId, 0, only);
        assertEq(usdA.balanceOf(heirA), 300_000e18);
        assertEq(heirA.balance, 0);
    }

    function test_V5_CancelBeforeExecutionIgnoresSchedule() public {
        _configureBySig(_planVest(1, _u16(ALL), _u32(365 days)));
        _execSafe(safeA, address(module), abi.encodeCall(module.cancel, (2, address(0), false)));
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        (uint16[] memory b,) = module.getVesting(planId, 0);
        assertEq(b.length, 0);
        assertEq(module.noteHash(planId, 0), bytes32(0));
        // reviving the plan without a schedule must not inherit the old one
        _configureBySig(_plan(3, 2, 0));
        _executeNow();
        assertEq(module.claimable(planId, 0, address(0)), 6 ether);
    }
}
