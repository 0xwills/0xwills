// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WillModuleTest} from "./WillModule.t.sol";
import {WillModule} from "../src/WillModule.sol";

/// v4: owner-chosen verifier fallback + acknowledge() ("I'm here / my wallet works").
contract V4Test is WillModuleTest {
    event Acknowledged(bytes32 indexed planId, address indexed who, bool asVerifier, bool asHeir, uint64 at);
    event FallbackTriggered(bytes32 indexed planId, uint8 confirmations);

    uint64 constant FALLBACK = 90 days;

    function _planFb(uint64 nonce, uint8 threshold, uint64 fb) internal view returns (WillModule.Plan memory p) {
        p = _plan(nonce, threshold, 0);
        p.verifierFallback = fb;
    }

    function _deadline() internal view returns (uint256) {
        WillModule.State memory s = module.getState(planId);
        return uint256(s.lastCheckIn) + s.checkInInterval;
    }

    // ------------------------------------------------------------------ fallback: config

    function test_V4_FallbackStoredAndCleared() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        assertEq(module.getState(planId).verifierFallback, FALLBACK);
        assertEq(module.fallbackAt(planId), _deadline() + FALLBACK);
        // an update can change it
        _configureBySig(_planFb(2, 2, 180 days));
        assertEq(module.getState(planId).verifierFallback, 180 days);
        // cancel clears it
        _execSafe(safeA, address(module), abi.encodeCall(module.cancel, (3, address(0), false)));
        assertEq(module.getState(planId).verifierFallback, 0);
        assertEq(module.fallbackAt(planId), 0);
    }

    function test_V4_FallbackValidation() public {
        WillModule.Plan memory p = _planFb(1, 0, FALLBACK); // fallback without verifiers makes no sense
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, _cfg("fallback without verifiers")));
        module.configure(p, signers, sigs);

        p = _planFb(1, 2, 30 minutes); // below the deployment minimum (1 hour here)
        (signers, sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, _cfg("fallback too short")));
        module.configure(p, signers, sigs);

        p = _planFb(1, 2, 3651 days);
        (signers, sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, _cfg("fallback too long")));
        module.configure(p, signers, sigs);

        _configureBySig(_planFb(1, 2, 3650 days)); // the maximum is fine
        assertEq(module.getState(planId).verifierFallback, 3650 days);
    }

    function test_V4_FallbackIsPartOfTheSignedPlan() public {
        WillModule.Plan memory a = _planFb(1, 2, FALLBACK);
        WillModule.Plan memory b = _planFb(1, 2, FALLBACK + 1);
        assertTrue(module.hashPlan(a) != module.hashPlan(b));
        // owners signed a 90-day fallback: a relayer can't submit it with a shorter one
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(a));
        WillModule.Plan memory tampered = _planFb(1, 2, 1 hours);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.configure(tampered, signers, sigs);
    }

    // ------------------------------------------------------------------ fallback: trigger

    function test_V4_FallbackTriggersWithoutVerifiers() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        uint256 d = _deadline();

        vm.warp(d + 1); // overdue, but no confirmations and fallback not open yet
        vm.expectRevert(WillModule.ThresholdNotMet.selector);
        module.trigger(planId);

        vm.warp(d + FALLBACK - 1);
        vm.expectRevert(WillModule.ThresholdNotMet.selector);
        module.trigger(planId);

        vm.warp(d + FALLBACK);
        vm.expectEmit(true, false, false, true);
        emit FallbackTriggered(planId, 0);
        vm.prank(stranger);
        module.trigger(planId);
        WillModule.State memory s = module.getState(planId);
        assertEq(uint8(s.status), uint8(WillModule.Status.Triggered));

        // the dispute window still applies
        vm.expectRevert(abi.encodeWithSelector(WillModule.DisputeWindowOpen.selector, s.triggeredAt + DISPUTE));
        module.execute(planId);
        vm.warp(s.triggeredAt + DISPUTE);
        module.execute(planId);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Executed));
    }

    function test_V4_OwnerCheckInCancelsAFallbackTrigger() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        vm.warp(_deadline() + FALLBACK);
        module.trigger(planId);
        vm.prank(ownerWallet);
        module.checkIn(planId);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Active));
        // and the fallback clock restarts from the new check-in
        assertEq(module.fallbackAt(planId), _deadline() + FALLBACK);
        vm.warp(_deadline() + 1);
        vm.expectRevert(WillModule.ThresholdNotMet.selector);
        module.trigger(planId);
    }

    function test_V4_NoFallbackMeansVerifiersAreRequiredForever() public {
        _configureBySig(_planFb(1, 2, 0));
        assertEq(module.fallbackAt(planId), 0);
        vm.warp(_deadline() + 3650 days);
        vm.expectRevert(WillModule.ThresholdNotMet.selector);
        module.trigger(planId);
    }

    function test_V4_VerifiersStillWorkBeforeTheFallback() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        vm.warp(_deadline() + 1);
        vm.prank(v1);
        module.confirmDeath(planId);
        vm.prank(v2);
        module.confirmDeath(planId); // threshold met: triggers normally, no fallback event
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
    }

    function test_V4_PartialConfirmationsPlusFallback() public {
        _configureBySig(_planFb(1, 3, FALLBACK));
        vm.warp(_deadline() + 1);
        vm.prank(v1);
        module.confirmDeath(planId); // 1 of 3: not enough
        vm.warp(_deadline() + FALLBACK);
        vm.expectEmit(true, false, false, true);
        emit FallbackTriggered(planId, 1);
        module.trigger(planId);
    }

    function testFuzz_V4_FallbackBoundary(uint64 fb, uint64 extra) public {
        fb = uint64(bound(fb, 1 hours, 3650 days));
        _configureBySig(_planFb(1, 2, fb));
        uint256 open = _deadline() + fb;
        assertEq(module.fallbackAt(planId), open);
        uint256 t = bound(extra, _deadline() + 1, open + 30 days);
        vm.warp(t);
        if (t < open) {
            vm.expectRevert(WillModule.ThresholdNotMet.selector);
            module.trigger(planId);
        } else {
            module.trigger(planId);
            assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
        }
    }

    // ------------------------------------------------------------------ acknowledge

    function test_V4_VerifierAndHeirAcknowledge() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        uint64 before = module.getState(planId).lastCheckIn;
        vm.warp(block.timestamp + 5 days);

        vm.expectEmit(true, true, false, true);
        emit Acknowledged(planId, v1, true, false, uint64(block.timestamp));
        vm.prank(v1);
        module.acknowledge(planId);
        assertEq(module.lastSeen(planId, v1), uint64(block.timestamp));

        vm.expectEmit(true, true, false, true);
        emit Acknowledged(planId, heirA, false, true, uint64(block.timestamp));
        vm.prank(heirA);
        module.acknowledge(planId);
        assertEq(module.lastSeen(planId, heirA), uint64(block.timestamp));

        // acknowledging changes nothing in the plan (it is not a check-in, not a vote)
        WillModule.State memory s = module.getState(planId);
        assertEq(s.lastCheckIn, before);
        assertEq(module.currentConfirmations(planId), 0);
    }

    function test_V4_AcknowledgeOnlyForPlanPeople() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        vm.prank(stranger);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.acknowledge(planId);
        vm.prank(ownerWallet); // an owner who is neither verifier nor heir
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.acknowledge(planId);
        vm.prank(v1);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.acknowledge(keccak256("no such plan"));
    }

    function test_V4_AcknowledgeWhileTriggeredButNotAfterExecution() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        vm.warp(_deadline() + FALLBACK);
        module.trigger(planId);
        vm.prank(v2);
        module.acknowledge(planId); // still useful: "I'm alive and can act"
        vm.warp(module.getState(planId).triggeredAt + DISPUTE);
        module.execute(planId);
        vm.prank(v2);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Executed));
        module.acknowledge(planId);
    }

    function test_V4_RemovedVerifierCanNoLongerAcknowledge() public {
        _configureBySig(_planFb(1, 2, FALLBACK));
        WillModule.Plan memory p = _planFb(2, 1, FALLBACK);
        p.verifiers = new address[](1);
        p.verifiers[0] = v1;
        _configureBySig(p);
        vm.prank(v3);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.acknowledge(planId);
        vm.prank(v1);
        module.acknowledge(planId);
    }

    function test_V4_StateLayoutKeepsV3Words() public {
        // Off-chain readers (the reminder bot) decode getState() by word position; v4 only appends.
        _configureBySig(_planFb(1, 2, FALLBACK));
        (bool ok, bytes memory raw) = address(module).staticcall(abi.encodeCall(module.getState, (planId)));
        assertTrue(ok);
        assertEq(raw.length, 11 * 32);
        WillModule.State memory s = module.getState(planId);
        (, uint8 status,, uint64 interval,, uint64 last,,, uint8 thr,, uint64 fb) =
            abi.decode(raw, (address, uint8, uint64, uint64, uint64, uint64, uint64, uint64, uint8, uint256, uint64));
        assertEq(status, uint8(WillModule.Status.Active));
        assertEq(interval, s.checkInInterval);
        assertEq(last, s.lastCheckIn);
        assertEq(thr, 2);
        assertEq(fb, FALLBACK);
    }

    function test_V4_FitsTheContractSizeLimit() public view {
        // EIP-170: Ethereum, Arbitrum, Base (and Robinhood Chain) reject runtime code over 24,576 bytes.
        assertLe(address(module).code.length, 24_576);
    }
}
