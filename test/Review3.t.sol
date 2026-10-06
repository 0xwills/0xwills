// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./WillModule.t.sol";

/// @dev transfer succeeds (moves funds) but returns a 32-byte word that is not a valid bool (2).
contract NonBoolReturnToken is MockToken {
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        assembly {
            mstore(0, 2)
            return(0, 32)
        }
    }
}

/// @dev transfer "fails" by returning a huge blob (return bomb) — e.g. a malicious/upgraded token.
contract ReturnBombToken is MockToken {
    function transfer(address, uint256) public pure override returns (bool) {
        assembly {
            return(0, 1500000)
        }
    }
}

/// @dev transfer fails by burning all gas (e.g. pre-0.8 `assert`/invalid opcode on pause).
contract GasBurnToken is MockToken {
    function transfer(address, uint256) public pure override returns (bool) {
        assembly {
            invalid()
        }
    }
}

/// @dev transfer succeeds but returns 64 bytes (true, extra word) -> misread as failure.
contract LongReturnToken is MockToken {
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        assembly {
            mstore(0, 1)
            mstore(32, 1)
            return(0, 64)
        }
    }
}

/// @dev Rebasing token: balances are shares * index / 1e18.
contract RebaseToken {
    mapping(address => uint256) public shares;
    uint256 public index = 1e18;

    function mint(address to, uint256 amount) external {
        shares[to] += amount * 1e18 / index;
    }

    function rebase(uint256 newIndex) external {
        index = newIndex;
    }

    function balanceOf(address a) external view returns (uint256) {
        return shares[a] * index / 1e18;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 s = amount * 1e18 / index;
        require(shares[msg.sender] >= s, "insufficient");
        shares[msg.sender] -= s;
        shares[to] += s;
        return true;
    }
}

/// @dev Charges a 10% fee on top, taken from the sender (sender loses amount + fee).
contract SenderFeeToken is MockToken {
    function transfer(address to, uint256 amount) public override returns (bool) {
        _transfer(msg.sender, to, amount);
        _burn(msg.sender, amount / 10);
        return true;
    }
}

/// @dev A legitimate but gas-heavy token: transfer costs ~300k gas (e.g. reflection/auto-swap tokens).
contract HeavyToken is MockToken {
    function transfer(address to, uint256 amount) public override returns (bool) {
        uint256 g = gasleft();
        while (g - gasleft() < 300_000) {}
        return super.transfer(to, amount);
    }
}

/// @dev Heir wallet that rejects ETH.
contract EthRejecter {
    receive() external payable {
        revert("no eth");
    }
}

contract Review3Test is WillModuleTest {
    function _executeWith(WillModule.Plan memory p) internal {
        _configureBySig(p);
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
    }

    function _executeWithTokens(address[] memory ta, uint256 cap) internal {
        WillModule.Plan memory p = _plan(1, 2, cap);
        p.chains[0].tokens = ta;
        _executeWith(p);
    }

    function _two(address a, address b) internal pure returns (address[] memory r) {
        r = new address[](2);
        r[0] = a;
        r[1] = b;
    }

    function _three(address a, address b, address c) internal pure returns (address[] memory r) {
        r = new address[](3);
        r[0] = a;
        r[1] = b;
        r[2] = c;
    }

    // ------------------------------------------------------------------
    // F1 regressions: a bad token can't block ETH or other tokens
    // ------------------------------------------------------------------

    function test_A3_NonBoolToken_DoesNotBlockClaims() public {
        NonBoolReturnToken t = new NonBoolReturnToken();
        t.mint(address(safeA), 100e18);
        _executeWithTokens(_two(address(t), address(usdA)), 0);
        module.claim(planId, 0);
        module.claim(planId, 1);
        assertEq(heirA.balance, 6 ether);
        assertEq(heirB.balance, 4 ether);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(usdA.balanceOf(heirB), 400_000e18);
        // the odd token is paid correctly too (success measured by balance change)
        assertEq(t.balanceOf(heirA), 60e18);
        assertEq(t.balanceOf(heirB), 40e18);
        // repeated claims pay nothing more
        module.claim(planId, 0);
        assertEq(t.balanceOf(heirA), 60e18);
        assertEq(heirA.balance, 6 ether);
    }

    function test_A3_NonBoolToken_SweepingCancelWorks() public {
        NonBoolReturnToken t = new NonBoolReturnToken();
        t.mint(address(safeA), 100e18);
        WillModule.Plan memory p = _plan(1, 2, 0);
        p.chains[0].tokens = _two(address(t), address(usdA));
        _configureBySig(p);
        vm.prank(address(safeA));
        module.cancel(2, ownerWallet, false);
        assertEq(t.balanceOf(ownerWallet), 100e18);
        assertEq(usdA.balanceOf(ownerWallet), 1_000_000e18);
        assertEq(ownerWallet.balance, 10 ether);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
    }

    function test_A3_ReturnBombToken_DoesNotBlockClaims() public {
        ReturnBombToken t = new ReturnBombToken();
        t.mint(address(safeA), 100e18);
        _executeWithTokens(_two(address(usdA), address(t)), 0);
        module.claim{gas: 30_000_000}(planId, 0);
        module.claim{gas: 30_000_000}(planId, 1);
        assertEq(heirA.balance, 6 ether);
        assertEq(heirB.balance, 4 ether);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(usdA.balanceOf(heirB), 400_000e18);
        assertEq(module.paid(planId, 0, address(t)), 0); // nothing recorded for the bomb
    }

    function test_A3_GasBurnTokens_ClaimAssetsSkipsThem() public {
        GasBurnToken g1 = new GasBurnToken();
        GasBurnToken g2 = new GasBurnToken();
        g1.mint(address(safeA), 1e18);
        g2.mint(address(safeA), 1e18);
        _executeWithTokens(_three(address(g1), address(g2), address(usdA)), 0);
        module.claimAssets{gas: 30_000_000}(planId, 0, _two(address(usdA), address(0)));
        module.claimAssets{gas: 30_000_000}(planId, 1, _two(address(usdA), address(0)));
        assertEq(heirA.balance, 6 ether);
        assertEq(heirB.balance, 4 ether);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(usdA.balanceOf(heirB), 400_000e18);
    }

    function test_A3_OneGasBurnToken_FullClaimStillPaysEth() public {
        GasBurnToken g1 = new GasBurnToken();
        g1.mint(address(safeA), 1e18);
        _executeWithTokens(_two(address(g1), address(usdA)), 0);
        module.claim{gas: 30_000_000}(planId, 0);
        assertEq(heirA.balance, 6 ether);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
    }

    /// Round-2 fix: token calls get bounded gas, so two burners no longer starve the full claim.
    function test_A3_TwoGasBurnTokens_FullClaimPaysEthAndGoodTokens() public {
        GasBurnToken g1 = new GasBurnToken();
        GasBurnToken g2 = new GasBurnToken();
        g1.mint(address(safeA), 1e18);
        g2.mint(address(safeA), 1e18);
        _executeWithTokens(_three(address(g1), address(g2), address(usdA)), 0);
        module.claim{gas: 30_000_000}(planId, 0);
        module.claim{gas: 5_000_000}(planId, 1);
        assertEq(heirA.balance, 6 ether);
        assertEq(heirB.balance, 4 ether);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(usdA.balanceOf(heirB), 400_000e18);
        assertEq(module.paid(planId, 0, address(g1)), 0);
        assertEq(module.paid(planId, 0, address(g2)), 0);
    }

    /// Round-2 fix: relayed claims work despite burners; fee still bounded by the heir's maxFee.
    function test_A3_GasBurnTokens_ClaimBySigWorks() public {
        GasBurnToken g1 = new GasBurnToken();
        GasBurnToken g2 = new GasBurnToken();
        g1.mint(address(safeA), 1e18);
        g2.mint(address(safeA), 1e18);
        _executeWithTokens(_three(address(g1), address(g2), address(usdA)), CAP);
        uint256 share = module.claimable(planId, 0, address(0));
        uint256 maxFee = 0.001 ether;
        bytes memory hsig = _sign(kHeirA, module.claimDigest(planId, 0, 0, maxFee));
        uint256 r0 = relayer.balance;
        vm.prank(relayer, relayer);
        module.claimBySig{gas: 30_000_000}(planId, 0, maxFee, hsig);
        uint256 fee = relayer.balance - r0;
        assertGt(fee, 0);
        assertLe(fee, maxFee);
        assertEq(heirA.balance, share - fee);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(module.claimNonce(planId, 0), 1);
    }

    // ------------------------------------------------------------------
    // F2 regression: late arrivals are shared
    // ------------------------------------------------------------------

    function test_A3_LateArrivalsAreShared() public {
        _toExecuted();
        vm.prank(stranger);
        module.claim(planId, 1); // anyone claims early
        module.claim(planId, 0);
        assertEq(heirA.balance, 6 ether);
        assertEq(heirB.balance, 4 ether);
        // ETH refund / airdrop / yield arrive after everyone claimed
        vm.deal(address(safeA), 5 ether);
        usdA.mint(address(safeA), 1_000_000e18);
        assertEq(module.claimable(planId, 0, address(0)), 3 ether);
        module.claim(planId, 0);
        module.claim(planId, 1);
        assertEq(heirA.balance, 9 ether);
        assertEq(heirB.balance, 6 ether);
        assertEq(usdA.balanceOf(heirA), 1_200_000e18);
        assertEq(usdA.balanceOf(heirB), 800_000e18);
        assertEq(address(safeA).balance, 0);
        assertEq(usdA.balanceOf(address(safeA)), 0);
    }

    // ------------------------------------------------------------------
    // F3 regressions: negative balance changes
    // ------------------------------------------------------------------

    function test_A3_NegativeRebase_LastHeirGetsFairRemainder() public {
        RebaseToken r = new RebaseToken();
        r.mint(address(safeA), 1000e18);
        address[] memory ta = new address[](1);
        ta[0] = address(r);
        _executeWithTokens(ta, 0);
        module.claim(planId, 0);
        assertEq(r.balanceOf(heirA), 600e18);
        r.rebase(0.8e18); // -20%: A holds 480, Safe 320
        module.claim(planId, 1);
        assertEq(r.balanceOf(heirB), 320e18); // = 40% of 800: fair, and paid (not stuck)
        assertEq(r.balanceOf(address(safeA)), 0);
    }

    /// KNOWN (accepted): nominal totalPaid, so after a negative rebase the 2nd claimer is overpaid and the last short-changed.
    function test_A3_KNOWN_NegativeRebase_ThreeHeirs_MiddleHeirOverpaid() public {
        address heirC = makeAddr("heirC");
        RebaseToken r = new RebaseToken();
        r.mint(address(safeA), 1000e18);
        WillModule.Plan memory p = _plan(1, 2, 0);
        p.heirs = new WillModule.Heir[](3);
        p.heirs[0] = WillModule.Heir({account: heirA, bps: 5000});
        p.heirs[1] = WillModule.Heir({account: heirB, bps: 3000});
        p.heirs[2] = WillModule.Heir({account: heirC, bps: 2000});
        address[] memory ta = new address[](1);
        ta[0] = address(r);
        p.chains[0].tokens = ta;
        _executeWith(p);
        module.claim(planId, 0); // A: 500
        r.rebase(0.8e18); // A now 400, Safe 400; fair: B 240, C 160
        module.claim(planId, 1);
        module.claim(planId, 2);
        assertEq(r.balanceOf(heirB), 270e18); // fair is 240: +30
        assertEq(r.balanceOf(heirC), 130e18); // fair is 160: -30
    }

    /// KNOWN (accepted): yield on an unclaimed share is split by bps, so an early claimer takes part of it (wrap rebasing tokens).
    function test_A3_KNOWN_PositiveRebase_EarlyClaimerTakesOthersYield() public {
        RebaseToken r = new RebaseToken();
        r.mint(address(safeA), 1000e18);
        address[] memory ta = new address[](1);
        ta[0] = address(r);
        _executeWithTokens(ta, 0);
        module.claim(planId, 0); // A: 600, Safe 400 (B's)
        r.rebase(1.5e18); // A 900, Safe 600 -> fair: B should get all 600
        module.claim(planId, 1);
        module.claim(planId, 0);
        assertEq(r.balanceOf(heirB), 480e18); // fair 600
        assertEq(r.balanceOf(heirA), 1020e18); // fair 900
    }

    /// KNOWN (accepted): a token that burns an extra fee from the sender leaves the last heir's remainder untransferable.
    function test_A3_KNOWN_SenderFeeToken_LastHeirStuck() public {
        SenderFeeToken t = new SenderFeeToken();
        t.mint(address(safeA), 1000e18);
        address[] memory ta = new address[](1);
        ta[0] = address(t);
        _executeWithTokens(ta, 0);
        module.claim(planId, 0); // A: 600, Safe pays 660 -> 340 left
        module.claim(planId, 1);
        module.claim(planId, 1);
        assertEq(t.balanceOf(heirB), 0);
        assertEq(t.balanceOf(address(safeA)), 340e18);
    }

    // ------------------------------------------------------------------
    // F4 regression: a misreported transfer can't overpay
    // ------------------------------------------------------------------

    function test_A3_LongReturnToken_CannotOverpay() public {
        LongReturnToken t = new LongReturnToken();
        t.mint(address(safeA), 1000e18);
        address[] memory ta = new address[](1);
        ta[0] = address(t);
        _executeWithTokens(ta, 0);
        module.claim(planId, 1);
        module.claim(planId, 1);
        module.claim(planId, 1);
        assertEq(t.balanceOf(heirB), 400e18);
        module.claim(planId, 0);
        assertEq(t.balanceOf(heirA), 600e18);
        assertEq(t.balanceOf(address(safeA)), 0);
    }

    // ------------------------------------------------------------------
    // ETH-rejecting heir
    // ------------------------------------------------------------------

    function test_A3_EthRejectingHeir_DoesNotBlockOthers() public {
        EthRejecter rej = new EthRejecter();
        WillModule.Plan memory p = _plan(1, 2, 0);
        p.heirs[0].account = address(rej);
        _executeWith(p);
        module.claim(planId, 0);
        assertEq(usdA.balanceOf(address(rej)), 600_000e18);
        assertEq(module.paid(planId, 0, address(0)), 0);
        assertEq(module.claimable(planId, 0, address(0)), 6 ether); // still owed, retryable
        module.claim(planId, 1);
        assertEq(heirB.balance, 4 ether);
        assertEq(address(safeA).balance, 6 ether);
        assertEq(module.claimable(planId, 1, address(0)), 0);
    }

    // ------------------------------------------------------------------
    // F5 regression: disabled module
    // ------------------------------------------------------------------

    function test_A3_DisabledModule_RelayedCancelAndCheckInWork() public {
        _configureBySig(_plan(1, 2, CAP));
        _execSafe(
            safeA, address(safeA), abi.encodeWithSignature("disableModule(address,address)", address(1), address(module))
        );
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes memory csg = _sign(k1, module.checkInDigest(planId, at));
        uint256 r0 = relayer.balance;
        vm.prank(relayer, relayer);
        module.checkInBySig(planId, at, o1, csg);
        assertEq(module.getState(planId).lastCheckIn, at);

        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, ownerWallet, true));
        uint256 eth = address(safeA).balance;
        vm.prank(relayer, relayer);
        module.cancelBySig(planId, 2, ownerWallet, true, cs, csig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(relayer.balance, r0); // no fees while disabled
        assertEq(address(safeA).balance, eth); // sweep skipped, nothing moved
        assertEq(module.planOf(address(safeA)), bytes32(0));
    }

    // ------------------------------------------------------------------
    // F6 regressions: fee bounds
    // ------------------------------------------------------------------

    function test_A3_Fee_BoundedByGasPriceCeiling() public {
        _configureBySig(_plan(1, 2, 1 ether));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        vm.fee(1 gwei);
        vm.txGasPrice(1_000_000 gwei); // builder-relayer bids absurdly
        uint256 r0 = relayer.balance;
        vm.prank(relayer, relayer);
        module.execute(planId);
        uint256 fee = relayer.balance - r0;
        assertGt(fee, 0);
        assertLe(fee, 200_000 * 3 gwei); // priced at <= basefee + 2 gwei
    }

    function test_A3_Fee_BoundedByHeirSignedMaxFee() public {
        vm.deal(address(safeA), 0.02 ether);
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        vm.fee(50 gwei);
        vm.txGasPrice(1_000_000 gwei);
        vm.prank(relayer, relayer);
        module.execute(planId);
        uint256 share = module.claimable(planId, 0, address(0));
        assertGt(share, 0);

        uint256 maxFee = 1e12;
        bytes memory hsig = _sign(kHeirA, module.claimDigest(planId, 0, 0, maxFee));
        uint256 r0 = relayer.balance;
        vm.prank(relayer, relayer);
        module.claimBySig(planId, 0, maxFee, hsig);
        assertEq(relayer.balance - r0, maxFee); // never more than the heir signed
        assertEq(heirA.balance, share - maxFee);
        // the signature is single-use
        vm.prank(relayer, relayer);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.claimBySig(planId, 0, maxFee, hsig);
        // and a relayer can't raise the fee above what was signed
        bytes memory hsig1 = _sign(kHeirA, module.claimDigest(planId, 0, 1, maxFee));
        vm.prank(relayer, relayer);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.claimBySig(planId, 0, CAP, hsig1);
    }

    // ------------------------------------------------------------------
    // New accounting: repeated / third-party claims with arrivals never overpay
    // ------------------------------------------------------------------

    function testFuzz_A3_RepeatedClaimsWithArrivalsNeverOverpay(uint256 seed) public {
        _toExecuted();
        uint256 totalEth = address(safeA).balance;
        uint256 totalTok = usdA.balanceOf(address(safeA));
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 3;
            if (op == 0) {
                uint256 addEth = (r >> 8) % 3 ether;
                vm.deal(address(safeA), address(safeA).balance + addEth);
                totalEth += addEth;
                uint256 addTok = (r >> 80) % 1000e18;
                usdA.mint(address(safeA), addTok);
                totalTok += addTok;
            } else {
                vm.prank(address(uint160(r >> 96))); // anyone
                module.claim(planId, op - 1);
            }
            assertLe(heirA.balance, totalEth * 6000 / 10_000);
            assertLe(heirB.balance, totalEth * 4000 / 10_000);
            assertLe(usdA.balanceOf(heirA), totalTok * 6000 / 10_000);
            assertLe(usdA.balanceOf(heirB), totalTok * 4000 / 10_000);
        }
        module.claim(planId, 0);
        module.claim(planId, 1);
        assertEq(heirA.balance, totalEth * 6000 / 10_000);
        assertEq(usdA.balanceOf(heirA), totalTok * 6000 / 10_000);
        assertLe(address(safeA).balance, 1); // only rounding dust
        assertLe(usdA.balanceOf(address(safeA)), 1);
    }

    /// KNOWN (accepted): funds leaving the Safe after execution are borne by whoever claims later (heirs should claim together).
    function test_A3_KNOWN_CoOwnerWithdrawal_FirstClaimerKeepsFullShare() public {
        _toExecuted();
        module.claim(planId, 0); // A: 6 ETH
        // co-owners (2-of-3 still alive) move 2 ETH out
        vm.prank(address(safeA));
        payable(ownerWallet).transfer(2 ether);
        module.claim(planId, 1);
        assertEq(heirA.balance, 6 ether);
        assertEq(heirB.balance, 2 ether); // bears the whole 2 ETH loss (fair split would be 60/40 of 8)
    }

    /// Round-2 fix: an old, never-delivered plan for the same Safe can't close an executed plan...
    function test_A3_StaleSignedPlanCannotCloseExecutedPlan() public {
        WillModule.Plan memory q = _plan(1, 0, 0);
        q.salt = keccak256("draft");
        q.checkInInterval = 3650 days;
        q.heirs[0].account = stranger;
        (address[] memory qs, bytes[] memory qsig) = _ownerSigs(module.hashPlan(q)); // signed at T0, never sent

        _toExecuted();
        module.claim(planId, 0);

        vm.prank(stranger);
        vm.expectRevert(WillModule.PlanTaken.selector);
        module.configure(q, qs, qsig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Executed));
        module.claim(planId, 1);
        assertEq(heirB.balance, 4 ether);
    }

    /// ...but a plan the owners sign after execution (same block allowed) still closes it.
    function test_A3_PlanSignedAfterExecutionClosesExecutedPlan() public {
        _toExecuted();
        WillModule.Plan memory q = _plan(1, 0, 0);
        q.salt = keccak256("next");
        q.issuedAt = module.getState(planId).executedAt; // same block as execution
        bytes32 qId = module.planIdOf(o1, q.salt);
        _configureBySig(q);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Closed));
        assertEq(module.planOf(address(safeA)), qId);
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Closed));
        module.claim(planId, 0);
    }

    // ------------------------------------------------------------------
    // Round-2/3 review
    // ------------------------------------------------------------------

    /// Round-3 fix: the creator's signature lifted from a sweeping/disabling cancelBySig bundle can't be
    /// used via revokeBySig to strip the sweep; the owners' cancel then goes through intact.
    function test_A3_RevokeCannotFrontRunSweepingCancel() public {
        _configureBySig(_plan(1, 2, CAP));
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, ownerWallet, true));
        vm.prank(stranger);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, ownerWallet, true, csig[0]);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Active));
        vm.prank(relayer, relayer);
        module.cancelBySig(planId, 2, ownerWallet, true, cs, csig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(usdA.balanceOf(ownerWallet), 1_000_000e18); // swept
        assertGt(ownerWallet.balance, 9 ether);
        assertFalse(safeA.isModuleEnabled(address(module))); // disabled as signed
    }

    /// Round-3 fix: a creator key the owners removed can no longer cancel a live plan via revokeBySig.
    function test_A3_RemovedCreatorCannotCancelTriggeredPlan() public {
        _configureBySig(_plan(1, 2, 0));
        _execSafe(
            safeA,
            address(safeA),
            abi.encodeWithSignature("removeOwner(address,address,uint256)", address(1), o1, uint256(2))
        );
        assertFalse(safeA.isOwner(o1));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
        // the plan still executes and pays heirs
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        module.claim(planId, 0);
        assertEq(heirA.balance, 6 ether);
    }

    /// Round-3: a creator who is still an owner can revoke a live plan with a plain (no sweep/disable) cancel.
    function test_A3_CreatorOwnerCanRevokeLivePlanWithPlainCancel() public {
        _configureBySig(_plan(1, 2, 0));
        bytes memory sig = _sign(k1, module.cancelDigest(planId, 2, address(0), false));
        module.revokeBySig(o1, SALT, 2, address(0), false, sig);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(module.getState(planId).nonce, 2);
        assertTrue(safeA.isModuleEnabled(address(module)));
    }

    /// Round-3: a caller can't skip tokens by under-supplying gas; the claim reverts NotEnoughGas instead.
    function test_A3_LowGasClaimRevertsInsteadOfSkippingTokens() public {
        _toExecuted();
        vm.expectRevert(WillModule.NotEnoughGas.selector);
        module.claim{gas: 300_000}(planId, 0);
        assertEq(module.paid(planId, 0, address(usdA)), 0);
        assertEq(module.paid(planId, 0, address(0)), 0);
        module.claim(planId, 0);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(heirA.balance, 6 ether);
    }

    /// KNOWN (accepted): a token whose transfer needs more than the bounded token-call gas is never claimable via the module.
    function test_A3_KNOWN_HeavyTokenNeverClaimable() public {
        HeavyToken t = new HeavyToken();
        t.mint(address(safeA), 100e18);
        address[] memory ta = new address[](1);
        ta[0] = address(t);
        _executeWithTokens(ta, 0);
        address[] memory only = new address[](1);
        only[0] = address(t);
        module.claimAssets{gas: 30_000_000}(planId, 0, only);
        module.claimAssets{gas: 30_000_000}(planId, 1, only);
        assertEq(t.balanceOf(heirA), 0);
        assertEq(t.balanceOf(heirB), 0);
        assertEq(t.balanceOf(address(safeA)), 100e18);
    }
}
