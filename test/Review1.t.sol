// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {WillModuleTest} from "./WillModule.t.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";
import {OwnerManager} from "safe-smart-account/base/OwnerManager.sol";
import {CompatibilityFallbackHandler} from "safe-smart-account/handler/CompatibilityFallbackHandler.sol";
import {WillModule} from "../src/WillModule.sol";

/// Regression tests for review round 1 findings (authorization & signatures), run against v3.
/// Cross-chain state is emulated with snapshots: "chain B" = the state before chain A's actions.
contract Review1Test is WillModuleTest {
    // ------------------------------------------------------------------
    // F1 (Medium in v2): cancel could not reach a chain the plan never reached; the old public
    // plan signatures could be replayed there later and the plan arrived already overdue.
    // ------------------------------------------------------------------

    /// Original v2 PoC scenario: replay 60 days later (interval 30 days) is now rejected as stale.
    function test_Review_RevivedPlan_StaleReplayRejected() public {
        WillModule.Plan memory p = _plan(1, 0, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        uint256 chainB = vm.snapshotState();

        vm.chainId(CHAIN_A);
        vm.prank(relayer, relayer);
        module.configure(p, signers, sigs);
        vm.warp(block.timestamp + 60 days);
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, address(0), true));
        module.cancelBySig(planId, 2, address(0), true, cs, csig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));

        uint256 t = block.timestamp;
        vm.revertToState(chainB);
        vm.warp(t);
        vm.chainId(CHAIN_B);
        vm.prank(stranger, stranger);
        vm.expectRevert(WillModule.StalePlan.selector);
        module.configure(p, signers, sigs);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
    }

    /// Within the interval the stale check does not help; revokeBySig (creator's signature taken from
    /// the same Cancel signature bundle) records the cancel nonce on chain B and blocks the replay.
    function test_Review_RevivedPlan_RevokeBySigBlocksFreshReplay() public {
        WillModule.Plan memory p = _plan(1, 0, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        uint256 chainB = vm.snapshotState();

        vm.chainId(CHAIN_A);
        vm.prank(relayer, relayer);
        module.configure(p, signers, sigs);
        vm.warp(block.timestamp + 5 days);
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, address(0), true));
        module.cancelBySig(planId, 2, address(0), true, cs, csig);

        uint256 t = block.timestamp;
        vm.revertToState(chainB);
        vm.warp(t);
        vm.chainId(CHAIN_B);
        // cancelBySig still can't be used where the plan doesn't exist ...
        vm.expectRevert(WillModule.UnknownPlan.selector);
        module.cancelBySig(planId, 2, address(0), true, cs, csig);
        // ... a non-creator's signature can't revoke ...
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(o1, SALT, 2, address(0), true, csig[1]); // o2's signature
        // ... but the creator's signature from the same bundle can (anyone may relay it).
        assertEq(cs[0], o1);
        vm.prank(stranger, stranger);
        module.revokeBySig(o1, SALT, 2, address(0), true, csig[0]);
        assertEq(module.getState(planId).nonce, 2);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.revokeBySig(o1, SALT, 2, address(0), true, csig[0]); // not replayable

        vm.prank(stranger, stranger);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(p, signers, sigs); // old plan can no longer be revived on B
    }

    /// Same root cause: an update that drops chain B can't be recorded there; a revoke now can.
    function test_Review_DroppedChain_RevokeBlocksSupersededPlan() public {
        WillModule.Plan memory v1 = _plan(1, 0, 0);
        (address[] memory s1, bytes[] memory g1) = _ownerSigs(module.hashPlan(v1));
        WillModule.Plan memory v2 = _plan(2, 0, 0);
        WillModule.ChainConfig[] memory only = new WillModule.ChainConfig[](1);
        only[0] = v2.chains[0];
        v2.chains = only;
        (address[] memory s2, bytes[] memory g2) = _ownerSigs(module.hashPlan(v2));

        vm.chainId(CHAIN_B);
        vm.expectRevert(WillModule.ChainNotInPlan.selector);
        module.configure(v2, s2, g2);
        bytes memory rsig = _sign(k1, module.cancelDigest(planId, 3, address(0), false));
        module.revokeBySig(o1, SALT, 3, address(0), false, rsig);
        vm.prank(stranger, stranger);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(v1, s1, g1);
    }

    /// Helper: owners sign plan v1 (time-based) on chain A, then cancel it there 1 day later.
    /// Returns the plan + its public signatures and the cancel bundle; leaves state = fresh chain B.
    function _cancelledOnAOnly()
        internal
        returns (
            WillModule.Plan memory p,
            address[] memory signers,
            bytes[] memory sigs,
            address[] memory cs,
            bytes[] memory csig
        )
    {
        p = _plan(1, 0, CAP);
        (signers, sigs) = _ownerSigs(module.hashPlan(p));
        uint256 chainB = vm.snapshotState();
        vm.chainId(CHAIN_A);
        vm.prank(relayer, relayer);
        module.configure(p, signers, sigs);
        vm.warp(block.timestamp + 1 days);
        (cs, csig) = _ownerSigs(module.cancelDigest(planId, 2, address(0), true));
        module.cancelBySig(planId, 2, address(0), true, cs, csig);
        vm.revertToState(chainB);
        vm.chainId(CHAIN_B);
    }

    /// App behaviour: revokeBySig is sent to every chain in the plan. The near-stale replay
    /// (last second before StalePlan applies) is then blocked on chain B.
    function test_Review_NearStaleReplay_BlockedOnceRevokeSentEverywhere() public {
        (WillModule.Plan memory p, address[] memory signers, bytes[] memory sigs,, bytes[] memory csig) =
            _cancelledOnAOnly();
        module.revokeBySig(o1, SALT, 2, address(0), true, csig[0]); // the app's revoke on chain B
        vm.warp(uint256(p.issuedAt) + INTERVAL - 1);
        vm.prank(stranger, stranger);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(p, signers, sigs);
    }

    /// An attacker front-runs the app's revoke and delivers the old plan to chain B first. The app's
    /// revoke (signed with disableModule=true) is now refused on a live plan; the owners' cancelBySig
    /// cancels it, and so does a creator-only revoke that asks for no sweep and no disable.
    function test_Review_FrontRunDelivery_CancelledByLaterRevoke() public {
        (WillModule.Plan memory p, address[] memory signers, bytes[] memory sigs, address[] memory cs, bytes[] memory csig)
        = _cancelledOnAOnly();
        vm.warp(uint256(p.issuedAt) + INTERVAL - 1);
        vm.prank(stranger, stranger);
        module.configure(p, signers, sigs); // front-run delivery
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Active));

        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, address(0), true, csig[0]); // app's revoke: refused on a live plan

        uint256 snap = vm.snapshotState();
        // (a) owners' cancelBySig with the same bundle (app's fallback)
        module.cancelBySig(planId, 2, address(0), true, cs, csig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertFalse(safeB.isModuleEnabled(address(module))); // signed disable honoured
        assertEq(module.getState(planId).nonce, 2);
        vm.expectRevert(WillModule.ModuleNotEnabled.selector); // and nonce 2 would also refuse it
        module.configure(p, signers, sigs);

        // (b) creator-only revoke with no sweep and no disable
        vm.revertToState(snap);
        uint256 bal = address(safeB).balance;
        module.revokeBySig(o1, SALT, 2, address(0), false, _sign(k1, module.cancelDigest(planId, 2, address(0), false)));
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(module.planOf(address(safeB)), bytes32(0));
        assertEq(address(safeB).balance, bal);
        assertTrue(safeB.isModuleEnabled(address(module)));
        vm.warp(block.timestamp + 2);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.trigger(planId);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(p, signers, sigs);
    }

    /// Same, but the front-run delivery was already triggered before the cancel arrived.
    function test_Review_FrontRunDelivery_TriggeredThenRevoked() public {
        (WillModule.Plan memory p, address[] memory signers, bytes[] memory sigs, address[] memory cs, bytes[] memory csig)
        = _cancelledOnAOnly();
        vm.warp(uint256(p.issuedAt) + INTERVAL - 1);
        module.configure(p, signers, sigs);
        vm.warp(block.timestamp + 2);
        module.trigger(planId);

        uint256 snap = vm.snapshotState();
        module.cancelBySig(planId, 2, address(0), true, cs, csig); // (a) owners
        vm.warp(block.timestamp + DISPUTE);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.execute(planId);

        vm.revertToState(snap);
        module.revokeBySig(o1, SALT, 2, address(0), false, _sign(k1, module.cancelDigest(planId, 2, address(0), false)));
        vm.warp(block.timestamp + DISPUTE); // (b) creator-only plain revoke
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.None));
        module.execute(planId);
    }

    /// INFO: protection relies on the revoke actually reaching every chain. If it is never sent to
    /// chain B (app/relayer failure), the near-stale replay still revives the cancelled plan there.
    function test_Review_Info_ProtectionReliesOnRevokeReachingEveryChain() public {
        (WillModule.Plan memory p, address[] memory signers, bytes[] memory sigs,,) = _cancelledOnAOnly();
        vm.warp(uint256(p.issuedAt) + INTERVAL - 1);
        module.configure(p, signers, sigs);
        vm.warp(block.timestamp + 2);
        module.trigger(planId); // runs to execution after DISPUTE unless someone revokes/checks in
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
    }

    // ------------------------------------------------------------------
    // revokeBySig signature safety (round 2)
    // ------------------------------------------------------------------

    /// The creator's Cancel signature is bound to planId = (creator, salt): useless for another plan.
    function test_Review_Revoke_SignatureBoundToPlan() public {
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(o1, keccak256("other-salt"), 2, address(0), false, sig);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(o2, SALT, 2, address(0), false, sig); // other creator
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(o1, SALT, 3, address(0), false, sig); // other nonce
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
    }

    /// High-s (malleated) variant of a valid signature is rejected (OZ ECDSA).
    function test_Review_Revoke_MalleatedSignatureRejected() public {
        bytes32 d = module.cancelDigest(planId, 2, address(0), false);
        (uint8 v, bytes32 r, bytes32 s_) = vm.sign(k1, d);
        uint256 n = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
        bytes memory mal = abi.encodePacked(r, bytes32(n - uint256(s_)), v == 27 ? uint8(28) : uint8(27));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, mal);
    }

    /// Round-2 LOW (fixed in round 3): stripping the signed sweep/disable by submitting the creator's
    /// part of the owners' cancel bundle through revokeBySig is refused; the real cancelBySig then
    /// sweeps to the owner and disables the module.
    function test_Review_Revoke_CannotStripSignedSweepAndDisable() public {
        _configureBySig(_plan(1, 0, 0));
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, o3, true));
        uint256 bal = address(safeA).balance;
        uint256 o3Bal = o3.balance;
        vm.prank(stranger, stranger);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, o3, true, csig[0]);
        module.cancelBySig(planId, 2, o3, true, cs, csig);
        assertEq(o3.balance - o3Bal, bal); // swept to the owner
        assertEq(address(safeA).balance, 0);
        assertFalse(safeA.isModuleEnabled(address(module))); // disabled
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
    }

    /// Creator-only plain revoke on a live plan requires the creator to still be a Safe owner.
    function test_Review_Revoke_LivePlanRequiresCreatorStillOwner() public {
        _configureBySig(_plan(1, 0, 0));
        _execSafe(safeA, address(safeA), abi.encodeCall(OwnerManager.removeOwner, (address(0x1), o1, 2)));
        assertFalse(safeA.isOwner(o1));
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
    }

    /// INFO: revoke needs only the creator, not the Safe threshold. A lone creator signature (e.g. a
    /// Cancel the co-owners never countersigned) cancels a Triggered plan. Equivalent in power to the
    /// creator checking in (any single owner can already reset a trigger), and moves no funds.
    function test_Review_Info_Revoke_CreatorAloneCancelsTriggeredPlan() public {
        _configureBySig(_plan(1, 0, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        module.revokeBySig(o1, SALT, 2, address(0), false, _sign(k1, module.cancelDigest(planId, 2, address(0), false)));
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
    }

    /// INFO: a contract creator (nested Safe, EIP-1271) signs in its own chain-bound domain, so one
    /// revoke signature does NOT work on every chain; the app must collect one per chain.
    function test_Review_Info_ContractCreatorRevokeIsChainBound() public {
        CompatibilityFallbackHandler handler = new CompatibilityFallbackHandler();
        address[] memory owners = new address[](1);
        owners[0] = o2;
        bytes memory init = abi.encodeCall(
            Safe.setup, (owners, 1, address(0), "", address(handler), address(0), 0, payable(address(0)))
        );
        Safe nested = Safe(payable(address(factory.createProxyWithNonce(address(singleton), init, 556))));
        _execSafe(safeA, address(safeA), abi.encodeCall(OwnerManager.addOwnerWithThreshold, (address(nested), 2)));

        WillModule.Plan memory p = _plan(1, 0, 0);
        p.creator = address(nested);
        bytes32 id = module.planIdOf(address(nested), SALT);
        bytes32 hp = module.hashPlan(p);
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        signers[0] = address(nested);
        sigs[0] = _sign(k2, handler.getMessageHashForSafe(nested, abi.encode(hp)));
        signers[1] = o1;
        sigs[1] = _sign(k1, hp);
        module.configure(p, signers, sigs);

        bytes32 d = module.cancelDigest(id, 2, address(0), false);
        bytes memory rsig = _sign(k2, handler.getMessageHashForSafe(nested, abi.encode(d)));
        uint256 snap = vm.snapshotState();
        module.revokeBySig(address(nested), SALT, 2, address(0), false, rsig); // works on chain A
        assertEq(uint8(module.getState(id).status), uint8(WillModule.Status.None));
        vm.revertToState(snap);
        vm.chainId(CHAIN_B);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.revokeBySig(address(nested), SALT, 2, address(0), false, rsig); // rejected on chain B
    }

    // ------------------------------------------------------------------
    // F2 (Low in v2): front-running a Safe-tx configure let a third party take the full fee cap
    // with an inflated gas price. Front-running itself is STILL possible in v3 (the relayer address
    // is not signed), but the refund is now priced at <= basefee + 2 gwei, so it is bounded by the
    // real gas cost instead of the cap.
    // ------------------------------------------------------------------
    function test_Review_FrontRunFeeBoundedByGasPriceCap() public {
        address[] memory owners = new address[](1);
        owners[0] = o1;
        bytes memory init =
            abi.encodeCall(Safe.setup, (owners, 1, address(0), "", address(0), address(0), 0, payable(address(0))));
        Safe s1 = Safe(payable(address(factory.createProxyWithNonce(address(singleton), init, 999))));
        vm.deal(address(s1), 1 ether);
        bytes memory en = abi.encodeCall(s1.enableModule, (address(module)));
        bytes32 h = s1.getTransactionHash(address(s1), 0, en, Enum.Operation.Call, 0, 0, 0, address(0), address(0), 0);
        s1.execTransaction(address(s1), 0, en, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), _sign(k1, h));

        WillModule.Plan memory p = _plan(1, 0, CAP);
        p.chains[0].safe = address(s1);
        address[] memory signers = new address[](1);
        bytes[] memory sigs = new bytes[](1);
        signers[0] = o1;
        sigs[0] = _sign(k1, module.hashPlan(p));

        vm.fee(1 gwei); // cheap block
        vm.txGasPrice(1_000 gwei); // front-runner bids an absurd gas price
        uint256 g = gasleft();
        vm.prank(stranger, stranger);
        module.configure(p, signers, sigs); // front-run still succeeds ...
        uint256 used = g - gasleft();

        uint256 fee = stranger.balance;
        assertGt(fee, 0);
        // ... but the refund is priced at basefee + 2 gwei = 3 gwei, not 1,000 gwei:
        assertLe(fee, (used + module.FEE_GAS_OVERHEAD() + 25_000) * 3 gwei);
        assertLt(fee, CAP / 3); // far below the 0.01 ETH cap (v2 paid exactly CAP here)
        assertEq(address(s1).balance, 1 ether - fee);
    }

    // ------------------------------------------------------------------
    // Unproven v2 suspicion: testnet and mainnet deployments at the same address shared one domain.
    // v3 separates them by EIP-712 version even at an identical address.
    // ------------------------------------------------------------------
    function test_Review_TestnetDomainDiffersFromMainnetAtSameAddress() public {
        uint256 snap = vm.snapshotState();
        WillModule test_ = new WillModule(1 hours, 1 hours, true);
        bytes32 dTest = test_.cancelDigest(planId, 2, address(0), false);
        bytes32 sepTest = test_.DOMAIN_SEPARATOR();
        address aTest = address(test_);
        vm.revertToState(snap);
        WillModule main_ = new WillModule(30 days, 7 days, false); // same deployer nonce => same address
        assertEq(address(main_), aTest);
        assertTrue(main_.DOMAIN_SEPARATOR() != sepTest);
        assertTrue(main_.cancelDigest(planId, 2, address(0), false) != dTest);
        assertEq(main_.domainVersion(), "3");
    }

    // ------------------------------------------------------------------
    // F3 (Info, unchanged in v3): a nested Safe owner (EIP-1271 via CompatibilityFallbackHandler)
    // signs inside its own chain-specific domain, so its signatures are NOT portable across chains.
    // ------------------------------------------------------------------
    function test_Review_Info_NestedSafeOwnerSignatureIsChainBound() public {
        CompatibilityFallbackHandler handler = new CompatibilityFallbackHandler();
        address[] memory owners = new address[](1);
        owners[0] = o2;
        bytes memory init = abi.encodeCall(
            Safe.setup, (owners, 1, address(0), "", address(handler), address(0), 0, payable(address(0)))
        );
        Safe nested = Safe(payable(address(factory.createProxyWithNonce(address(singleton), init, 555))));
        _execSafe(safeA, address(safeA), abi.encodeCall(OwnerManager.addOwnerWithThreshold, (address(nested), 2)));
        _configureBySig(_plan(1, 2, 0));

        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes32 d = module.checkInDigest(planId, at);
        bytes memory sig = _sign(k2, handler.getMessageHashForSafe(nested, abi.encode(d)));

        uint256 snap = vm.snapshotState();
        module.checkInBySig(planId, at, address(nested), sig); // valid on chain A
        vm.revertToState(snap);
        vm.chainId(CHAIN_B);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.checkInBySig(planId, at, address(nested), sig); // same signature rejected on chain B
    }
}
