// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WillModuleTest} from "./WillModule.t.sol";
import {WillModule} from "../src/WillModule.sol";

/// Lifecycle / state-machine / timing review (reviewer A2): regression tests for v3.
/// Multi-chain is modelled with vm.snapshotState / vm.revertToState (each chain has its own state).
contract Review2Test is WillModuleTest {
    address attacker = makeAddr("attacker");

    function _sigs(WillModule.Plan memory p) internal view returns (address[] memory s, bytes[] memory g) {
        return _ownerSigs(module.hashPlan(p));
    }

    function _status() internal view returns (uint8) {
        return uint8(module.getState(planId).status);
    }

    // ------------------------------------------------------------------
    // F1: a cancelled plan can't be revived on a chain it never reached
    // ------------------------------------------------------------------

    /// Fix 1 (StalePlan): once issuedAt + interval has passed, the old plan can't be replayed anywhere.
    function test_A2_RevivedPlanBlocked_StalePlan() public {
        WillModule.Plan memory p1 = _plan(1, 0, 0); // threshold 0, lists chains A and B
        (address[] memory s1, bytes[] memory g1) = _sigs(p1);
        (address[] memory cs, bytes[] memory cg) = _ownerSigs(module.cancelDigest(planId, 2, address(0), false));
        uint256 snap = vm.snapshotState();
        // chain A: configured, then cancelled
        _configureBySig(p1);
        module.cancelBySig(planId, 2, address(0), false, cs, cg);
        assertEq(_status(), uint8(WillModule.Status.None));
        // chain B: never reached; cancelBySig can't apply there
        vm.revertToState(snap);
        vm.chainId(CHAIN_B);
        vm.expectRevert(WillModule.UnknownPlan.selector);
        module.cancelBySig(planId, 2, address(0), false, cs, cg);
        // months later: replay is rejected
        vm.warp(block.timestamp + INTERVAL);
        vm.prank(attacker);
        vm.expectRevert(WillModule.StalePlan.selector);
        module.configure(p1, s1, g1);
        assertEq(_status(), uint8(WillModule.Status.None));
    }

    /// Fix 2 (revokeBySig): the creator's cancel signature records the nonce on chain B, so the old
    /// plan can't be configured there even inside its freshness window.
    function test_A2_RevivedPlanBlocked_RevokeBySig() public {
        WillModule.Plan memory p1 = _plan(1, 0, 0);
        (address[] memory s1, bytes[] memory g1) = _sigs(p1);
        bytes memory creatorCancel = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.chainId(CHAIN_B); // plan never delivered here
        vm.prank(relayer);
        module.revokeBySig(o1, SALT, 2, address(0), false, creatorCancel);
        assertEq(module.getState(planId).nonce, 2);
        vm.warp(block.timestamp + 1 hours); // still fresh, so only the revoke protects
        vm.prank(attacker);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(p1, s1, g1);
        // replaying the revoke, or a forged one, fails
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, creatorCancel);
        bytes memory forged = _sign(k2, module.cancelDigest(planId, 3, address(0), false));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(o1, SALT, 3, address(0), false, forged);
        // a genuinely newer plan from the owners still works
        WillModule.Plan memory p3 = _plan(3, 0, 0);
        (address[] memory s3, bytes[] memory g3) = _sigs(p3);
        module.configure(p3, s3, g3);
        assertEq(_status(), uint8(WillModule.Status.Active));
    }

    /// Round 2: a front-run delivery of the cancelled plan no longer dodges the creator's revoke.
    function test_A2_RevokeWinsAfterFrontRunDelivery() public {
        WillModule.Plan memory p1 = _plan(1, 0, 0);
        (address[] memory s1, bytes[] memory g1) = _sigs(p1);
        bytes memory creatorCancel = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.chainId(CHAIN_B);
        vm.warp(block.timestamp + 1 days); // owner cancelled on A; relayer now sends the revoke to B
        vm.prank(attacker); // front-runs with the old plan (still fresh: 1 day < 30 days)
        module.configure(p1, s1, g1);
        assertEq(_status(), uint8(WillModule.Status.Active));
        uint256 eth = address(safeB).balance;
        uint256 tok = usdB.balanceOf(address(safeB));

        vm.prank(relayer);
        module.revokeBySig(o1, SALT, 2, address(0), false, creatorCancel);
        WillModule.State memory st = module.getState(planId);
        assertEq(uint8(st.status), uint8(WillModule.Status.None));
        assertEq(st.nonce, 2);
        assertEq(module.planOf(address(safeB)), bytes32(0));
        assertEq(address(safeB).balance, eth);
        assertEq(usdB.balanceOf(address(safeB)), tok);
        assertTrue(safeB.isModuleEnabled(address(module)));

        // the old signature can't bring it back, now or after it would have been overdue
        vm.prank(attacker);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(p1, s1, g1);
        vm.warp(uint256(p1.issuedAt) + INTERVAL + 1);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.trigger(planId);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, creatorCancel); // revoke itself not replayable
    }

    /// Round 2: the creator's revoke also stops a plan that is already Triggered.
    function test_A2_CreatorRevokeWorksWhileTriggered() public {
        _configureBySig(_plan(1, 0, CAP));
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        assertEq(_status(), uint8(WillModule.Status.Triggered));
        vm.warp(block.timestamp + DISPUTE); // even with the window already over
        uint256 eth = address(safeA).balance;
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.prank(relayer, relayer);
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
        assertEq(_status(), uint8(WillModule.Status.None));
        assertEq(module.getState(planId).nonce, 2);
        assertEq(module.getState(planId).lastCheckIn, block.timestamp);
        assertEq(address(safeA).balance, eth); // no relayer fee, nothing moved
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.execute(planId);
    }

    /// Executed plans can't be revoked by the creator signature.
    function test_A2_RevokeRefusedOnExecutedPlan() public {
        _toExecuted();
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Executed));
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
    }

    /// INFO (by design): on a 2-of-3 Safe, the creator's signature alone cancels a live plan via
    /// revokeBySig, but only a no-sweep / no-disable cancel, and only while the creator is an owner.
    /// It fails safe: nothing moves. A sweep (or disable) cancel through the revoke path reverts.
    function test_A2_INFO_SingleCreatorSigCancelsMultiOwnerPlan() public {
        _configureBySig(_plan(1, 2, 0));
        assertEq(safeA.getThreshold(), 2);
        uint256 eth = address(safeA).balance;
        uint256 tok = usdA.balanceOf(address(safeA));

        // sweep or disable requested: refused on a live plan
        bytes memory sweepSig = _sign(k1, module.cancelDigest(planId, 2, o3, false));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, o3, false, sweepSig);
        bytes memory disableSig = _sign(k1, module.cancelDigest(planId, 2, address(0), true));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, address(0), true, disableSig);
        // a non-creator owner's signature alone is rejected
        bytes memory notCreator = _sign(k2, module.cancelDigest(planId, 2, address(0), false));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, notCreator);

        bytes memory creatorOnly = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        // as a multi-sig cancel it is insufficient...
        address[] memory one = new address[](1);
        bytes[] memory oneSig = new bytes[](1);
        one[0] = o1;
        oneSig[0] = creatorOnly;
        vm.expectRevert(WillModule.NotEnoughSigners.selector);
        module.cancelBySig(planId, 2, address(0), false, one, oneSig);
        // ...but anyone holding it can submit it as a revoke
        vm.prank(stranger);
        module.revokeBySig(o1, SALT, 2, address(0), false, creatorOnly);
        assertEq(_status(), uint8(WillModule.Status.None));
        assertEq(address(safeA).balance, eth);
        assertEq(usdA.balanceOf(address(safeA)), tok);
        assertTrue(safeA.isModuleEnabled(address(module)));
    }

    /// Round 3: a creator who is no longer a Safe owner can't revoke a live plan alone.
    function test_A2_RevokeRefusedWhenCreatorNoLongerOwner() public {
        _configureBySig(_plan(1, 0, 0));
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        address[] memory owners = safeA.getOwners();
        address prev = address(1);
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i] == o1) break;
            prev = owners[i];
        }
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.removeOwner, (prev, o1, 2)));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
        assertEq(_status(), uint8(WillModule.Status.Active));
    }

    /// Round 3 side effect: the front-run fix only holds for a no-sweep cancel. If the owners'
    /// cancel asked for a sweep, a front-run delivery on chain B makes the creator revoke revert;
    /// the relayer must fall back to cancelBySig with the owners' threshold signatures (which then
    /// works, sweeping to an owner on B).
    function test_A2_SweepCancelFrontRunNeedsCancelBySigFallback() public {
        WillModule.Plan memory p1 = _plan(1, 0, 0);
        (address[] memory s1, bytes[] memory g1) = _sigs(p1);
        bytes32 d = module.cancelDigest(planId, 2, o3, false);
        bytes memory creatorPart = _sign(k1, d);
        vm.chainId(CHAIN_B);
        // without front-run, the same signature records the nonce on B
        uint256 snap = vm.snapshotState();
        module.revokeBySig(o1, SALT, 2, o3, false, creatorPart);
        assertEq(module.getState(planId).nonce, 2);
        vm.revertToState(snap);
        // with front-run, the revoke path is refused...
        vm.warp(block.timestamp + 1 days);
        vm.prank(attacker);
        module.configure(p1, s1, g1);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, o3, false, creatorPart);
        // ...and only the owners' threshold cancel stops it
        (address[] memory cs, bytes[] memory cg) = _ownerSigs(d);
        uint256 eth = address(safeB).balance;
        module.cancelBySig(planId, 2, o3, false, cs, cg);
        assertEq(_status(), uint8(WillModule.Status.None));
        assertEq(o3.balance, eth);
    }

    /// INFO: a creator cancel signature has no expiry. One the co-owners never countersigned (so it
    /// never executed) stays a standing revoke: months of check-ins later, anyone can still use it.
    function test_A2_INFO_UnusedCreatorCancelIsAStandingRevoke() public {
        _configureBySig(_plan(1, 2, 0));
        bytes memory proposal = _sign(k1, module.cancelDigest(planId, 2, address(0), false)); // never countersigned
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 20 days);
            vm.prank(o2);
            module.checkIn(planId);
        }
        vm.prank(stranger);
        module.revokeBySig(o1, SALT, 2, address(0), false, proposal);
        assertEq(_status(), uint8(WillModule.Status.None));
    }

    /// INFO: why nonces come from max(on-chain nonce + 1, unix time). An old standing creator cancel
    /// (nonce 2) can't touch a later plan whose nonce is a timestamp, and can't block configuring it.
    function test_A2_INFO_TimestampNonceDefeatsStandingCancel() public {
        _configureBySig(_plan(1, 2, 0));
        bytes memory standing = _sign(k1, module.cancelDigest(planId, 2, address(0), false)); // never used
        vm.warp(block.timestamp + 40 days);
        uint64 n = uint64(block.timestamp); // max(1 + 1, now)
        WillModule.Plan memory upd = _plan(n, 2, 0);
        (address[] memory s, bytes[] memory g) = _sigs(upd);
        module.configure(upd, s, g);
        vm.prank(stranger);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, standing);
        assertEq(_status(), uint8(WillModule.Status.Active));
        // contrast: an "on-chain nonce + 1" plan (nonce 2) would have been revocable by it
    }

    /// INFO: revokeBySig accepts nonce type(uint64).max (configure doesn't), retiring the plan id on
    /// that chain for good. Only the creator can sign it; other plan ids for the Safe are unaffected.
    function test_A2_INFO_RevokeWithMaxNonceRetiresPlanId() public {
        _configureBySig(_plan(1, 2, 0));
        bytes memory sig = _sign(k1, module.cancelDigest(planId, type(uint64).max, address(0), false));
        module.revokeBySig(o1, SALT, type(uint64).max, address(0), false, sig);
        WillModule.Plan memory p = _plan(2, 2, 0);
        (address[] memory s, bytes[] memory g) = _sigs(p);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(p, s, g);
        WillModule.Plan memory other = _plan(1, 2, 0);
        other.salt = keccak256("other");
        (s, g) = _sigs(other);
        module.configure(other, s, g); // the Safe itself is free
    }

    /// Stale replay can no longer pre-empt the owner's fresh configure.
    function test_A2_StaleReplayCannotBlockFreshConfigure() public {
        WillModule.Plan memory p1 = _plan(1, 0, 0);
        (address[] memory s1, bytes[] memory g1) = _sigs(p1);
        vm.warp(block.timestamp + INTERVAL + 5 days);
        vm.chainId(CHAIN_B);
        WillModule.Plan memory p2 = _plan(2, 0, 0);
        (address[] memory s2, bytes[] memory g2) = _sigs(p2);
        vm.startPrank(attacker);
        vm.expectRevert(WillModule.StalePlan.selector);
        module.configure(p1, s1, g1);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.trigger(planId);
        vm.stopPrank();
        module.configure(p2, s2, g2);
        assertEq(_status(), uint8(WillModule.Status.Active));
        assertFalse(module.isOverdue(planId));
    }

    /// A fresh-but-older plan delivered first can't be triggered and doesn't block the newer one.
    function test_A2_FreshOlderReplayDoesNotBlockNewerConfigure() public {
        WillModule.Plan memory p1 = _plan(1, 0, 0);
        (address[] memory s1, bytes[] memory g1) = _sigs(p1);
        vm.warp(block.timestamp + 10 days);
        vm.chainId(CHAIN_B);
        WillModule.Plan memory p2 = _plan(2, 0, 0);
        (address[] memory s2, bytes[] memory g2) = _sigs(p2);
        vm.prank(attacker);
        module.configure(p1, s1, g1);
        vm.expectRevert(WillModule.NotOverdue.selector);
        module.trigger(planId);
        module.configure(p2, s2, g2);
        assertEq(module.getState(planId).nonce, 2);
        assertEq(module.getState(planId).lastCheckIn, block.timestamp);
    }

    // ------------------------------------------------------------------
    // F2: an executed plan no longer locks the Safe
    // ------------------------------------------------------------------

    function test_A2_ExecutedPlanNoLongerLocksSafe() public {
        _toExecuted();
        bytes32 oldId = planId;
        // heirs can claim while Executed
        vm.prank(heirA);
        module.claim(oldId, 0);
        assertGt(heirA.balance, 0);
        // same plan id stays terminal
        WillModule.Plan memory same = _plan(2, 0, 0);
        (address[] memory s, bytes[] memory g) = _sigs(same);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Executed));
        module.configure(same, s, g);
        // a new plan signed before the execution can't close it (round 2)
        uint64 execAt = module.getState(oldId).executedAt;
        WillModule.Plan memory pre = _plan(1, 0, 0);
        pre.salt = keccak256("pre-signed");
        pre.issuedAt = execAt - 1;
        (s, g) = _sigs(pre);
        vm.expectRevert(WillModule.PlanTaken.selector);
        module.configure(pre, s, g);
        // a new plan for the same Safe works and closes the old one
        WillModule.Plan memory np = _plan(1, 0, 0);
        np.salt = keccak256("new-plan");
        (s, g) = _sigs(np);
        module.configure(np, s, g);
        bytes32 newId = module.planIdOf(o1, np.salt);
        assertEq(module.planOf(address(safeA)), newId);
        assertEq(uint8(module.getState(newId).status), uint8(WillModule.Status.Active));
        assertEq(uint8(module.getState(oldId).status), uint8(WillModule.Status.Closed));
        // closed plan: claims, check-in, revoke, reconfigure all refused
        vm.prank(heirB);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Closed));
        module.claim(oldId, 1);
        vm.prank(o1);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Closed));
        module.checkIn(oldId);
        bytes memory rv = _sign(k1, module.cancelDigest(oldId, 9, address(0), false));
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Closed));
        module.revokeBySig(o1, SALT, 9, address(0), false, rv);
        WillModule.Plan memory again = _plan(3, 0, 0);
        (s, g) = _sigs(again);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Closed));
        module.configure(again, s, g);
    }

    /// Only an Executed plan can be displaced; an Active/Triggered one still blocks a second plan.
    function test_A2_NonExecutedPlanStillBlocksSafe() public {
        _configureBySig(_plan(1, 0, 0));
        WillModule.Plan memory np = _plan(1, 0, 0);
        np.salt = keccak256("new-plan");
        (address[] memory s, bytes[] memory g) = _sigs(np);
        vm.expectRevert(WillModule.PlanTaken.selector);
        module.configure(np, s, g);
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        np.issuedAt = uint64(block.timestamp);
        (s, g) = _sigs(np);
        vm.expectRevert(WillModule.PlanTaken.selector);
        module.configure(np, s, g);
    }

    // ------------------------------------------------------------------
    // F3: a disabled module pauses the lifecycle; relayed safety actions still work
    // ------------------------------------------------------------------

    function _disable() internal {
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.disableModule, (address(1), address(module))));
        assertFalse(safeA.isModuleEnabled(address(module)));
    }

    function test_A2_DisabledModuleStopsLifecycle() public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1); // one vote before the owner disables
        _disable();
        vm.prank(v2);
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.confirmDeath(planId);
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.trigger(planId);
        assertEq(_status(), uint8(WillModule.Status.Active));
    }

    function test_A2_DisabledModuleBlocksExecuteAndClaims() public {
        _configureBySig(_plan(1, 0, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        vm.warp(block.timestamp + DISPUTE);
        uint256 snap = vm.snapshotState();
        _disable();
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.execute(planId);
        // owner can still stop it while disabled
        vm.prank(o2);
        module.checkIn(planId);
        assertEq(_status(), uint8(WillModule.Status.Active));
        // executed first, then disabled: claims refuse rather than silently doing nothing
        vm.revertToState(snap);
        module.execute(planId);
        _disable();
        vm.prank(heirA);
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.claim(planId, 0);
    }

    function test_A2_DisabledModuleRelayedActionsDoNotRevert() public {
        _configureBySig(_plan(1, 2, CAP));
        _disable();
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes memory sig = _sign(k1, module.checkInDigest(planId, at));
        uint256 r = relayer.balance;
        vm.prank(relayer, relayer);
        module.checkInBySig(planId, at, o1, sig);
        assertEq(module.getState(planId).lastCheckIn, at);
        assertEq(relayer.balance, r); // no fee while disabled
        // relayed cancel (with sweep + disable request) also works while disabled; sweep is skipped
        (address[] memory cs, bytes[] memory cg) = _ownerSigs(module.cancelDigest(planId, 2, o3, true));
        uint256 eth = address(safeA).balance;
        vm.prank(relayer, relayer);
        module.cancelBySig(planId, 2, o3, true, cs, cg);
        assertEq(_status(), uint8(WillModule.Status.None));
        assertEq(address(safeA).balance, eth);
        assertEq(relayer.balance, r);
    }

    /// Info: re-enabling after a long disable resumes an overdue plan. Anyone can trigger at once
    /// (threshold 0), but the owner keeps the full dispute window to check in.
    function test_A2_ReEnableResumesPlanOwnerKeepsDisputeWindow() public {
        _configureBySig(_plan(1, 0, 0));
        _disable();
        vm.warp(block.timestamp + INTERVAL * 3);
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.enableModule, (address(module))));
        module.trigger(planId);
        vm.warp(block.timestamp + DISPUTE - 1);
        vm.expectRevert(
            abi.encodeWithSelector(WillModule.DisputeWindowOpen.selector, uint64(block.timestamp + 1))
        );
        module.execute(planId);
        vm.prank(o2);
        module.checkIn(planId);
        assertEq(_status(), uint8(WillModule.Status.Active));
    }

    // ------------------------------------------------------------------
    // F4: max nonce rejected; every plan stays cancellable
    // ------------------------------------------------------------------

    function test_A2_MaxNonceRejected() public {
        WillModule.Plan memory p = _plan(type(uint64).max, 2, 0);
        (address[] memory s, bytes[] memory g) = _sigs(p);
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, _cfg("nonce too high")));
        module.configure(p, s, g);
        // the highest allowed nonce still leaves room to cancel
        _configureBySig(_plan(type(uint64).max - 1, 2, 0));
        vm.prank(address(safeA));
        module.cancel(type(uint64).max, address(0), false);
        assertEq(_status(), uint8(WillModule.Status.None));
        assertEq(module.planOf(address(safeA)), bytes32(0));
    }

    // ------------------------------------------------------------------
    // F5: future-dated issuedAt no longer blocks a direct check-in
    // ------------------------------------------------------------------

    function test_A2_FutureIssuedAtDoesNotBlockDirectCheckIn() public {
        WillModule.Plan memory p = _plan(1, 2, 0);
        uint64 future = uint64(block.timestamp + 15 minutes);
        p.issuedAt = future;
        _configureBySig(p);
        vm.prank(o1);
        module.checkIn(planId); // no-op, no revert
        assertEq(module.getState(planId).lastCheckIn, future); // never moves backwards
        vm.warp(future + 1);
        vm.prank(o1);
        module.checkIn(planId);
        assertEq(module.getState(planId).lastCheckIn, future + 1);
    }

    // ------------------------------------------------------------------
    // Regression of behaviour already safe in v2
    // ------------------------------------------------------------------

    /// A check-in withheld by a relayer and delivered during Triggered only restarts the window.
    function test_A2_StaleCheckInDuringTriggeredOnlyExtends() public {
        _configureBySig(_plan(1, 0, 0));
        uint64 at = uint64(block.timestamp + 1 days);
        vm.warp(at);
        bytes memory sig = _sign(k1, module.checkInDigest(planId, at));
        vm.warp(block.timestamp + INTERVAL + 1 days);
        module.trigger(planId);
        uint64 firstTrigger = module.getState(planId).triggeredAt;
        module.checkInBySig(planId, at, o1, sig);
        assertTrue(module.isOverdue(planId));
        vm.warp(block.timestamp + 1);
        module.trigger(planId);
        assertGt(module.getState(planId).triggeredAt, firstTrigger);
    }

    /// I4 (informational, by design): removing the creator from the Safe doesn't end the plan; the
    /// creator can no longer check in, remaining owners can (and must cancel if unwanted).
    function test_A2_INFO_CreatorRemovedPlanContinues() public {
        _configureBySig(_plan(1, 0, 0));
        address[] memory owners = safeA.getOwners();
        address prev = address(1);
        for (uint256 i; i < owners.length; ++i) {
            if (owners[i] == o1) break;
            prev = owners[i];
        }
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.removeOwner, (prev, o1, 2)));
        vm.warp(block.timestamp + 1 days);
        vm.prank(o1);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.checkIn(planId);
        assertEq(_status(), uint8(WillModule.Status.Active));
        vm.prank(o2);
        module.checkIn(planId);
    }
}
