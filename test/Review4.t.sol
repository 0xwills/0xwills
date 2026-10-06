// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WillModuleTest, MockToken} from "./WillModule.t.sol";
import {WillModule} from "../src/WillModule.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {CompatibilityFallbackHandler} from "safe-smart-account/handler/CompatibilityFallbackHandler.sol";

/// @dev A covered token whose transfer burns all forwarded gas before failing
///      (malicious / upgraded token, or one that hits INVALID / an unbounded loop).
contract GasBurnToken is MockToken {
    function transfer(address, uint256) public view override returns (bool) {
        while (gasleft() > 3000) {}
        revert();
    }
}

/// @dev balanceOf burns all gas and returns a huge payload (return-data bomb).
contract BalanceBombToken is MockToken {
    function balanceOf(address) public view override returns (uint256) {
        while (gasleft() > 3000) {}
        assembly {
            return(0, 100000)
        }
    }
}

/// @dev balanceOf burns ~95k (just under the 100k cap) but still answers; transfer burns everything.
contract MaxGriefToken is MockToken {
    function balanceOf(address a) public view override returns (uint256) {
        while (gasleft() > 6000) {}
        return super.balanceOf(a);
    }

    function transfer(address, uint256) public view override returns (bool) {
        while (gasleft() > 3000) {}
        revert();
    }
}

/// @dev Regression tests for the v2 review findings (A4: Safe integration / config validation),
///      asserting the fixed v3 behaviour.
contract Review4Test is WillModuleTest {
    uint256 constant BLOCK_GAS = 30_000_000;

    function _toExecutedWith(WillModule.Plan memory p) internal {
        _configureBySig(p);
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
    }

    function _disableModuleDirectly() internal {
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.disableModule, (address(0x1), address(module))));
        assertFalse(safeA.isModuleEnabled(address(module)));
    }

    function _expectConfigRevert(WillModule.Plan memory p, string memory reason) internal {
        (address[] memory s, bytes[] memory g) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, reason));
        module.configure(p, s, g);
    }

    // ------------------------------------------------------------------
    // F1: gas-burning tokens no longer brick claims
    // ------------------------------------------------------------------

    function _burnerPlan(uint256 burners, uint256 good) internal returns (WillModule.Plan memory p, address[] memory ta) {
        p = _plan(1, 2, 0);
        ta = new address[](burners + good);
        for (uint256 i; i < burners; ++i) {
            GasBurnToken b = new GasBurnToken();
            b.mint(address(safeA), 1e18);
            ta[i] = address(b);
        }
        for (uint256 i = burners; i < burners + good; ++i) {
            MockToken t = new MockToken();
            t.mint(address(safeA), 1e18);
            ta[i] = address(t);
        }
        p.chains[0].tokens = ta;
    }

    /// One burner followed by 19 good tokens (v2: claim OOG at 30M). v3: the Safe call is capped at
    /// TOKEN_CALL_GAS, so one claim() pays ETH and all 19 good tokens.
    function test_A4_SingleGasBurningTokenNoLongerBricksClaim() public {
        (WillModule.Plan memory p, address[] memory ta) = _burnerPlan(1, 19);
        _toExecutedWith(p);
        module.claim{gas: BLOCK_GAS}(planId, 0);
        assertEq(heirA.balance, 6 ether, "ETH paid despite burner");
        for (uint256 i = 1; i < 20; ++i) {
            assertEq(MockToken(ta[i]).balanceOf(heirA), 0.6e18);
        }
        assertEq(GasBurnToken(ta[0]).balanceOf(heirA), 0);
        assertEq(module.paid(planId, 0, ta[0]), 0); // burner stays owed, retryable
    }

    /// Two or three burners (v3 round 1: plain claim() still OOG). Now a plain claim() succeeds and
    /// pays ETH plus every good token, for every heir.
    function test_A4_TwoGasBurningTokens_ClaimSucceeds() public {
        (WillModule.Plan memory p, address[] memory ta) = _burnerPlan(2, 1);
        _toExecutedWith(p);
        for (uint256 i; i < 2; ++i) {
            module.claim{gas: BLOCK_GAS}(planId, i);
        }
        assertEq(heirA.balance, 6 ether);
        assertEq(heirB.balance, 4 ether);
        assertEq(MockToken(ta[2]).balanceOf(heirA), 0.6e18);
        assertEq(MockToken(ta[2]).balanceOf(heirB), 0.4e18);
        assertEq(address(safeA).balance, 0);
    }

    function test_A4_ThreeGasBurningTokens_ClaimSucceeds() public {
        (WillModule.Plan memory p, address[] memory ta) = _burnerPlan(3, 2);
        _toExecutedWith(p);
        uint256 g = gasleft();
        module.claim{gas: BLOCK_GAS}(planId, 0);
        emit log_named_uint("claim gas (3 burners + 2 good)", g - gasleft());
        assertEq(heirA.balance, 6 ether);
        assertEq(MockToken(ta[3]).balanceOf(heirA), 0.6e18);
        assertEq(MockToken(ta[4]).balanceOf(heirA), 0.6e18);
    }

    /// Worst case per token: balanceOf burns ~95k (twice) and transfer burns its whole 250k.
    /// 20 such tokens still fit easily in one 30M claim; ETH is paid.
    function test_A4_TwentyMaxGriefTokens_ClaimBounded() public {
        WillModule.Plan memory p = _plan(1, 2, 0);
        address[] memory ta = new address[](20);
        for (uint256 i; i < 20; ++i) {
            MaxGriefToken t = new MaxGriefToken();
            t.mint(address(safeA), 1e18);
            ta[i] = address(t);
        }
        p.chains[0].tokens = ta;
        _toExecutedWith(p);
        uint256 g = gasleft();
        module.claim{gas: BLOCK_GAS}(planId, 0);
        uint256 used = g - gasleft();
        emit log_named_uint("claim gas (20 max-grief tokens)", used);
        assertEq(heirA.balance, 6 ether);
        assertLt(used, 12_000_000);
    }

    /// balanceOf is gas-capped and copies at most 32 bytes: a balanceOf gas/return bomb is skipped.
    function test_A4_BalanceOfBombIsBounded() public {
        BalanceBombToken bomb = new BalanceBombToken();
        WillModule.Plan memory p = _plan(1, 2, 0);
        address[] memory ta = new address[](2);
        ta[0] = address(bomb);
        ta[1] = address(usdA);
        p.chains[0].tokens = ta;
        _toExecutedWith(p);
        uint256 g = gasleft();
        module.claim{gas: BLOCK_GAS}(planId, 0);
        assertLt(g - gasleft(), 1_000_000, "bomb consumed at most ~100k");
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(heirA.balance, 6 ether);
        assertEq(module.claimable(planId, 0, address(bomb)), 0);
    }

    /// cancel with a sweep is not bricked by a burner; good tokens and ETH are swept.
    function test_A4_GasBurningTokenDoesNotBlockCancelSweep() public {
        (WillModule.Plan memory p, address[] memory ta) = _burnerPlan(1, 1);
        _configureBySig(p);
        uint256 eth = address(safeA).balance;
        vm.prank(address(safeA));
        module.cancel{gas: BLOCK_GAS}(2, o3, true);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(o3.balance, eth);
        assertEq(MockToken(ta[1]).balanceOf(o3), 1e18);
        assertFalse(safeA.isModuleEnabled(address(module)));
    }

    function test_A4_ThreeGasBurningTokens_CancelSweepStillWorks() public {
        (WillModule.Plan memory p, address[] memory ta) = _burnerPlan(3, 1);
        _configureBySig(p);
        uint256 eth = address(safeA).balance;
        vm.prank(address(safeA));
        module.cancel{gas: BLOCK_GAS}(2, o3, true);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(o3.balance, eth);
        assertEq(MockToken(ta[3]).balanceOf(o3), 1e18);
        assertFalse(safeA.isModuleEnabled(address(module)));
    }

    // ------------------------------------------------------------------
    // Round 3: the gas guard reverts NotEnoughGas, so success is monotonic in gas and a
    // gas-estimated claim either pays every token or reverts.
    // ------------------------------------------------------------------

    /// An estimated-gas claim either pays every token or reverts NotEnoughGas: the optimistic
    /// gasUsed*64/63 guess reverts, and the minimal succeeding gas (binary search, as estimators do)
    /// pays all 20 tokens; anything below reverts.
    function test_A4_EstimatedGasSkipsLastTokens() public {
        (WillModule.Plan memory p, address[] memory ta) = _burnerPlan(0, 20);
        _toExecutedWith(p);
        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        module.claim{gas: BLOCK_GAS}(planId, 0);
        uint256 used = g - gasleft();
        vm.revertToState(snap);

        // geth's optimistic first guess: either pays every token or reverts (here: reverts, since the
        // guard wants 400k of headroom; the estimator then falls back to binary search below).
        (bool ok, bytes memory ret) =
            address(module).call{gas: used * 64 / 63 + 2300}(abi.encodeCall(module.claim, (planId, 0)));
        if (ok) {
            for (uint256 i; i < 20; ++i) {
                assertEq(MockToken(ta[i]).balanceOf(heirA), 0.6e18, "every token paid");
            }
        } else {
            assertEq(bytes4(ret), WillModule.NotEnoughGas.selector);
        }
        vm.revertToState(snap);

        // Binary search for the minimal succeeding gas (what an estimator converges to).
        uint256 lo = 21_000;
        uint256 hi = BLOCK_GAS;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 s2 = vm.snapshotState();
            (bool okm,) = address(module).call{gas: mid}(abi.encodeCall(module.claim, (planId, 0)));
            vm.revertToState(s2);
            if (okm) hi = mid;
            else lo = mid;
        }
        emit log_named_uint("minimal succeeding gas", hi);
        (ok,) = address(module).call{gas: hi}(abi.encodeCall(module.claim, (planId, 0)));
        assertTrue(ok);
        for (uint256 i; i < 20; ++i) {
            assertEq(MockToken(ta[i]).balanceOf(heirA), 0.6e18, "minimal gas still pays every token");
        }
        assertEq(heirA.balance, 6 ether);
        vm.revertToState(snap);
        vm.expectRevert(WillModule.NotEnoughGas.selector);
        module.claim{gas: hi - 300_000}(planId, 0);
    }

    /// With a griefing token, scanning gas upward: once a call succeeds, every higher gas succeeds.
    function test_A4_GasJustAboveGuardRevertsButLessSucceeds() public {
        WillModule.Plan memory p = _plan(1, 2, 0);
        address[] memory ta = new address[](2);
        MaxGriefToken mg = new MaxGriefToken();
        mg.mint(address(safeA), 1e18);
        ta[0] = address(mg);
        ta[1] = address(usdA);
        p.chains[0].tokens = ta;
        _toExecutedWith(p);
        bool seenSuccess;
        uint256 firstSuccess;
        for (uint256 gl = 200_000; gl < 2_000_000; gl += 5_000) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(module).call{gas: gl}(abi.encodeCall(module.claim, (planId, 0)));
            if (ok) {
                assertEq(usdA.balanceOf(heirA), 600_000e18, "success always pays every good token");
                assertEq(heirA.balance, 6 ether);
            }
            vm.revertToState(snap);
            if (ok && !seenSuccess) {
                seenSuccess = true;
                firstSuccess = gl;
            }
            assertTrue(!seenSuccess || ok, "monotonic: no failure above a success");
        }
        emit log_named_uint("first succeeding gas", firstSuccess);
        assertTrue(seenSuccess);
    }

    // ------------------------------------------------------------------
    // Cancel sweep vs hostile tokens (round 3: sweep can't be skipped, but can't be blocked either)
    // ------------------------------------------------------------------
    function test_A4_HostileTokensCannotBlockCancel() public {
        WillModule.Plan memory p = _plan(1, 2, 0);
        address[] memory ta = new address[](20);
        for (uint256 i; i < 19; ++i) {
            MaxGriefToken t = new MaxGriefToken();
            t.mint(address(safeA), 1e18);
            ta[i] = address(t);
        }
        ta[19] = address(usdA);
        p.chains[0].tokens = ta;
        _configureBySig(p);
        uint256 eth = address(safeA).balance;

        uint256 snap = vm.snapshotState();
        // Low gas: the sweep reverts instead of being silently skipped.
        vm.prank(address(safeA));
        vm.expectRevert(WillModule.NotEnoughGas.selector);
        module.cancel{gas: 1_000_000}(2, o3, true);
        // Enough gas (bounded per token): the full sweep completes within a block.
        uint256 g = gasleft();
        vm.prank(address(safeA));
        module.cancel{gas: BLOCK_GAS}(2, o3, true);
        emit log_named_uint("cancel+sweep gas, 19 grief tokens", g - gasleft());
        assertLt(g - gasleft(), 12_000_000);
        assertEq(usdA.balanceOf(o3), 1_000_000e18);
        assertEq(o3.balance, eth);
        assertFalse(safeA.isModuleEnabled(address(module)));
        vm.revertToState(snap);

        // Without a sweep no token is touched: cheap, always works.
        g = gasleft();
        vm.prank(address(safeA));
        module.cancel{gas: 300_000}(2, address(0), true);
        assertLt(g - gasleft(), 300_000);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertFalse(safeA.isModuleEnabled(address(module)));
    }

    // ------------------------------------------------------------------
    // Round 3: revokeBySig on a live plan needs a creator who is still an owner, and no sweep/disable
    // ------------------------------------------------------------------
    function test_A4_RevokeByRemovedCreatorStillCancels() public {
        _configureBySig(_plan(1, 2, CAP));
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.removeOwner, (address(0x1), o1, 2)));
        assertFalse(safeA.isOwner(o1));
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.prank(stranger);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Active));
    }

    function test_A4_RevokeLivePlanRequiresNoSweepNoDisable() public {
        _configureBySig(_plan(1, 2, CAP));
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, o3, false));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, o3, false, sig);
        sig = _sign(k1, module.cancelDigest(planId, 2, address(0), true));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, address(0), true, sig);
        // Owner creator, plain cancel: allowed.
        sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertTrue(safeA.isModuleEnabled(address(module)));
    }

    // ------------------------------------------------------------------
    // claimAssets input handling
    // ------------------------------------------------------------------
    function test_A4_ClaimAssetsInputValidation() public {
        _toExecuted();
        address[] memory a = new address[](2);
        a[0] = address(usdA);
        a[1] = address(usdA);
        vm.expectRevert(WillModule.BadAsset.selector);
        module.claimAssets(planId, 0, a);

        a[1] = address(0);
        a[0] = address(0);
        vm.expectRevert(WillModule.BadAsset.selector);
        module.claimAssets(planId, 0, a); // duplicate ETH

        a[0] = address(usdB); // covered on chain B only
        vm.expectRevert(WillModule.BadAsset.selector);
        module.claimAssets(planId, 0, a);

        a[0] = address(safeA);
        vm.expectRevert(WillModule.BadAsset.selector);
        module.claimAssets(planId, 0, a);

        vm.expectRevert(WillModule.BadIndex.selector);
        module.claimAssets(planId, 2, new address[](0));

        // Empty list is a harmless no-op.
        module.claimAssets(planId, 0, new address[](0));
        assertEq(heirA.balance, 0);

        // ETH only, then token only; second call of the same asset pays nothing more.
        address[] memory e = new address[](1);
        module.claimAssets(planId, 0, e);
        assertEq(heirA.balance, 6 ether);
        assertEq(usdA.balanceOf(heirA), 0);
        e[0] = address(usdA);
        module.claimAssets(planId, 0, e);
        module.claimAssets(planId, 0, e);
        assertEq(usdA.balanceOf(heirA), 600_000e18);

        // Unknown plan: tokens are "not covered"; ETH-only hits the status check.
        bytes32 other = module.planIdOf(o1, keccak256("x"));
        vm.expectRevert(WillModule.BadAsset.selector);
        module.claimAssets(other, 0, e);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.claimAssets(other, 0, new address[](1));
    }

    // ------------------------------------------------------------------
    // F2: a disabled module no longer breaks relayed actions; a stale plan can't execute while disabled
    // ------------------------------------------------------------------
    function test_A4_DisabledModule_RelayedActionsWork() public {
        _configureBySig(_plan(1, 2, CAP));
        _disableModuleDirectly();
        uint256 safeEth = address(safeA).balance;

        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes memory sig = _sign(k1, module.checkInDigest(planId, at));
        vm.prank(relayer, relayer);
        module.checkInBySig(planId, at, o1, sig); // no GS104; fee skipped
        assertEq(module.getState(planId).lastCheckIn, at);
        assertEq(address(safeA).balance, safeEth, "no fee while disabled");

        // Relayed cancel with a sweep: cancels, sweep and disable skipped, nothing moves.
        bytes32 cd = module.cancelDigest(planId, 2, o3, true);
        (address[] memory s, bytes[] memory sg) = _ownerSigs(cd);
        vm.prank(relayer, relayer);
        module.cancelBySig(planId, 2, o3, true, s, sg);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(module.planOf(address(safeA)), bytes32(0));
        assertEq(address(safeA).balance, safeEth);
        assertEq(o3.balance, 0);
        assertEq(usdA.balanceOf(o3), 0);
    }

    function test_A4_DisabledModule_DirectCancelWithSweepWorks() public {
        _configureBySig(_plan(1, 2, CAP));
        _disableModuleDirectly();
        vm.prank(address(safeA));
        module.cancel(2, o3, true);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(o3.balance, 0); // sweep skipped
    }

    /// While disabled nothing can advance the plan. After re-enabling, an overdue Active plan needs
    /// confirmations AND a full dispute window, during which the owner can still check in.
    function test_A4_DisabledModule_StaleActivePlanAfterReEnable() public {
        _configureBySig(_plan(1, 2, CAP));
        _disableModuleDirectly();
        vm.warp(block.timestamp + INTERVAL + 1);

        vm.prank(v1);
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.confirmDeath(planId);
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.trigger(planId);

        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.enableModule, (address(module))));
        // Can't execute straight away.
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Active));
        module.execute(planId);
        vm.prank(v1);
        module.confirmDeath(planId);
        vm.prank(v2);
        module.confirmDeath(planId); // triggers now
        vm.expectRevert(
            abi.encodeWithSelector(WillModule.DisputeWindowOpen.selector, uint64(block.timestamp) + DISPUTE)
        );
        module.execute(planId);
        vm.prank(o1);
        module.checkIn(planId); // owner can still stop it
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Active));
    }

    /// Documented residual: a plan already Triggered before the disable, whose dispute window
    /// expires while disabled, is executable as soon as the module is re-enabled - unless an owner
    /// checks in (which works while disabled).
    function test_A4_DisabledModule_TriggeredPlanAfterReEnable() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        _disableModuleDirectly();
        vm.warp(block.timestamp + DISPUTE);
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.execute(planId);

        uint256 snap = vm.snapshotState();
        // (a) owner checks in while disabled -> plan back to Active, safe after re-enable
        vm.prank(o1);
        module.checkIn(planId);
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.enableModule, (address(module))));
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Active));
        module.execute(planId);

        // (b) no check-in -> executable right after re-enable
        vm.revertToState(snap);
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.enableModule, (address(module))));
        vm.prank(stranger);
        module.execute(planId);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Executed));
    }

    function test_A4_DisabledModule_ClaimsRevert() public {
        _toExecuted();
        _disableModuleDirectly();
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.claim(planId, 0);
    }

    // ------------------------------------------------------------------
    // F3: an executed plan no longer binds the Safe forever
    // ------------------------------------------------------------------
    function test_A4_ExecutedPlanIsClosedByNewPlan() public {
        _toExecuted();
        bytes32 oldId = planId;
        WillModule.Plan memory p = _plan(1, 2, 0);
        p.salt = keccak256("new-plan");
        _configureBySig(p);
        bytes32 newId = module.planIdOf(o1, p.salt);
        assertEq(module.planOf(address(safeA)), newId);
        assertEq(uint8(module.getState(newId).status), uint8(WillModule.Status.Active));
        assertEq(uint8(module.getState(oldId).status), uint8(WillModule.Status.Closed));
        // The closed plan can no longer pay out or be reconfigured.
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Closed));
        module.claim(oldId, 0);
        WillModule.Plan memory again = _plan(5, 2, 0);
        (address[] memory s, bytes[] memory g) = _ownerSigs(module.hashPlan(again));
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Closed));
        module.configure(again, s, g);
    }

    /// A non-executed plan still blocks another plan id on the same Safe.
    function test_A4_ActivePlanStillBlocksOtherPlanId() public {
        _configureBySig(_plan(1, 2, 0));
        WillModule.Plan memory p = _plan(1, 2, 0);
        p.salt = keccak256("new-plan");
        (address[] memory s, bytes[] memory g) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(WillModule.PlanTaken.selector);
        module.configure(p, s, g);
    }

    // ------------------------------------------------------------------
    // F4: heir / verifier / token == module (and token == Safe) rejected
    // ------------------------------------------------------------------
    function test_A4_ModuleAndSafeAddressesRejected() public {
        WillModule.Plan memory p = _plan(1, 2, 0);
        p.heirs[1].account = address(module);
        _expectConfigRevert(p, "bad heir");

        p = _plan(1, 2, 0);
        p.verifiers[2] = address(module);
        _expectConfigRevert(p, "bad verifier");

        p = _plan(1, 2, 0);
        p.chains[0].tokens[0] = address(module);
        _expectConfigRevert(p, "bad token");

        p = _plan(1, 2, 0);
        p.chains[0].tokens[0] = address(safeA);
        _expectConfigRevert(p, "bad token");
    }

    /// The Safe's fallback handler (still allowed as a "token") stays harmless: no Safe state changes.
    function test_A4_FallbackHandlerAsTokenHarmless() public {
        CompatibilityFallbackHandler fh = new CompatibilityFallbackHandler();
        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.setFallbackHandler, (address(fh))));
        WillModule.Plan memory p = _plan(1, 2, 0);
        address[] memory ta = new address[](2);
        ta[0] = address(fh);
        ta[1] = address(usdA);
        p.chains[0].tokens = ta;
        _toExecutedWith(p);
        uint256 nonceBefore = safeA.nonce();
        module.claim(planId, 0);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(heirA.balance, 6 ether);
        assertTrue(safeA.isModuleEnabled(address(module)));
        assertEq(safeA.getThreshold(), 2);
        assertEq(safeA.getOwners().length, 3);
        assertEq(safeA.nonce(), nonceBefore);
        assertEq(module.paid(planId, 0, address(fh)), 0);
    }

    // ------------------------------------------------------------------
    // _disableSelf pagination: module at the tail of a 120-module list
    // ------------------------------------------------------------------
    function test_A4_DisableSelfPaginates() public {
        _configureBySig(_plan(1, 2, 0));
        for (uint256 i; i < 120; ++i) {
            _execSafe(safeA, address(safeA), abi.encodeCall(safeA.enableModule, (address(uint160(0x1000 + i)))));
        }
        vm.prank(address(safeA));
        module.cancel(2, address(0), true);
        assertFalse(safeA.isModuleEnabled(address(module)));
        assertTrue(safeA.isModuleEnabled(address(uint160(0x1000))));
        assertTrue(safeA.isModuleEnabled(address(uint160(0x1000 + 119))));
    }

    // ------------------------------------------------------------------
    // Views: timeUntilOverdue agrees with isOverdue
    // ------------------------------------------------------------------
    function test_A4_ViewBoundaryConsistent() public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(T0 + INTERVAL);
        assertFalse(module.isOverdue(planId));
        assertEq(module.timeUntilOverdue(planId), 1);
        vm.warp(T0 + INTERVAL + 1);
        assertTrue(module.isOverdue(planId));
        assertEq(module.timeUntilOverdue(planId), 0);
        vm.prank(v1);
        module.confirmDeath(planId);
    }

    function testFuzz_A4_ViewsAgree(uint32 dt) public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(T0 + dt);
        assertEq(module.isOverdue(planId), module.timeUntilOverdue(planId) == 0);
    }

    // ------------------------------------------------------------------
    // Gas: max heirs/tokens/verifiers stays well under block limits
    // ------------------------------------------------------------------
    function test_A4_MaxSizeGas() public {
        WillModule.Plan memory p = _plan(1, 0, CAP);
        p.heirs = new WillModule.Heir[](20);
        for (uint256 i; i < 20; ++i) {
            p.heirs[i] = WillModule.Heir(address(uint160(0xA000 + i)), 500);
        }
        p.verifiers = new address[](10);
        for (uint256 i; i < 10; ++i) {
            p.verifiers[i] = address(uint160(0xB000 + i));
        }
        address[] memory ta = new address[](20);
        for (uint256 i; i < 20; ++i) {
            MockToken t = new MockToken();
            t.mint(address(safeA), 1e18);
            ta[i] = address(t);
        }
        p.chains[0].tokens = ta;
        uint256 g = gasleft();
        _configureBySig(p);
        uint256 cfg = g - gasleft();
        emit log_named_uint("configure gas", cfg);
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        g = gasleft();
        module.claim(planId, 0);
        uint256 cl = g - gasleft();
        emit log_named_uint("claim gas (20 tokens)", cl);
        assertEq(MockToken(ta[19]).balanceOf(address(uint160(0xA000))), 0.05e18, "all 20 tokens paid in one claim");
        assertLt(cfg, 5_000_000);
        assertLt(cl, 5_000_000);
    }

    function test_A4_MaxSizeCancelSweepGas() public {
        WillModule.Plan memory p = _plan(1, 0, CAP);
        address[] memory ta = new address[](20);
        for (uint256 i; i < 20; ++i) {
            MockToken t = new MockToken();
            t.mint(address(safeA), 1e18);
            ta[i] = address(t);
        }
        p.chains[0].tokens = ta;
        _configureBySig(p);
        uint256 g = gasleft();
        vm.prank(address(safeA));
        module.cancel(2, o3, true);
        uint256 used = g - gasleft();
        emit log_named_uint("cancel+sweep+disable gas", used);
        assertEq(MockToken(ta[19]).balanceOf(o3), 1e18);
        assertLt(used, 3_000_000);
    }
}
