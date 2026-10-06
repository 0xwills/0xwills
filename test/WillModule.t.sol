// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SafeL2} from "safe-smart-account/SafeL2.sol";
import {Safe} from "safe-smart-account/Safe.sol";
import {SafeProxyFactory} from "safe-smart-account/proxies/SafeProxyFactory.sol";
import {Enum} from "safe-smart-account/common/Enum.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {WillModule} from "../src/WillModule.sol";

contract MockToken is ERC20 {
    constructor() ERC20("Mock USD", "mUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev transfer always reverts — must not block other assets.
contract BrokenToken is MockToken {
    function transfer(address, uint256) public pure override returns (bool) {
        revert("broken");
    }
}

/// @dev USDT-style token: transfer returns nothing.
contract NoReturnToken {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
    }
}

/// @dev balanceOf can be switched to revert (e.g. a paused token).
contract PausableToken is MockToken {
    bool public paused;

    function setPaused(bool p) external {
        paused = p;
    }

    function balanceOf(address a) public view override returns (uint256) {
        require(!paused, "paused");
        return super.balanceOf(a);
    }
}

/// @dev Heir contract that tries to re-enter claim on receiving ETH.
contract Reenterer {
    WillModule public module;
    bytes32 public planId;
    uint256 public calls;

    function arm(WillModule m, bytes32 id) external {
        module = m;
        planId = id;
    }

    receive() external payable {
        calls++;
        if (calls == 1) {
            try module.claim(planId, 0) {} catch {}
        }
    }
}

contract WillModuleTest is Test {
    uint256 constant CHAIN_A = 46630; // Robinhood Chain testnet
    uint256 constant CHAIN_B = 421614; // Arbitrum Sepolia

    WillModule module;
    SafeL2 singleton;
    SafeProxyFactory factory;
    Safe safeA; // "Robinhood" Safe
    Safe safeB; // "Arbitrum" Safe
    MockToken usdA;
    MockToken usdB;

    address o1;
    uint256 k1;
    address o2;
    uint256 k2;
    address o3;
    uint256 k3;
    address v1;
    uint256 kv1;
    address v2;
    uint256 kv2;
    address v3;
    uint256 kv3;

    address heirA;
    uint256 kHeirA;
    address heirB = makeAddr("heirB");
    address relayer = makeAddr("relayer");
    address stranger = makeAddr("stranger");
    address ownerWallet; // the owner's own wallet (an owner of the Safe)

    uint64 constant INTERVAL = 30 days;
    uint64 constant DISPUTE = 7 days;
    bytes32 constant SALT = keccak256("family-plan");
    uint256 constant CAP = 0.01 ether;
    uint64 T0;

    bytes32 planId;

    function setUp() public {
        vm.warp(1_750_000_000);
        T0 = uint64(block.timestamp);
        vm.chainId(CHAIN_A);
        (o1, k1) = makeAddrAndKey("owner1");
        (o2, k2) = makeAddrAndKey("owner2");
        (o3, k3) = makeAddrAndKey("owner3");
        (v1, kv1) = makeAddrAndKey("verifier1");
        (v2, kv2) = makeAddrAndKey("verifier2");
        (v3, kv3) = makeAddrAndKey("verifier3");
        (heirA, kHeirA) = makeAddrAndKey("heirA");
        ownerWallet = o3;

        module = new WillModule(1 hours, 1 hours, true);
        singleton = new SafeL2();
        factory = new SafeProxyFactory();
        usdA = new MockToken();
        usdB = new MockToken();

        safeA = _newSafe(1);
        safeB = _newSafe(2);
        vm.deal(address(safeA), 10 ether);
        vm.deal(address(safeB), 4 ether);
        usdA.mint(address(safeA), 1_000_000e18);
        usdB.mint(address(safeB), 500_000e18);

        _execSafe(safeA, address(safeA), abi.encodeCall(safeA.enableModule, (address(module))));
        _execSafe(safeB, address(safeB), abi.encodeCall(safeB.enableModule, (address(module))));

        planId = module.planIdOf(o1, SALT);
        vm.txGasPrice(1 gwei);
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _newSafe(uint256 nonce) internal returns (Safe) {
        address[] memory owners = new address[](3);
        owners[0] = o1;
        owners[1] = o2;
        owners[2] = o3;
        bytes memory init =
            abi.encodeCall(Safe.setup, (owners, 2, address(0), "", address(0), address(0), 0, payable(address(0))));
        return Safe(payable(address(factory.createProxyWithNonce(address(singleton), init, nonce))));
    }

    /// Execute a Safe transaction signed by owners 1 and 2 (threshold 2).
    function _execSafe(Safe safe, address to, bytes memory data) internal {
        bytes32 h = safe.getTransactionHash(
            to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), address(0), safe.nonce()
        );
        bytes memory sigs = _sortedSigs(h, k1, o1, k2, o2);
        bool ok = safe.execTransaction(to, 0, data, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), sigs);
        require(ok, "safe tx failed");
    }

    function _sortedSigs(bytes32 h, uint256 ka, address a, uint256 kb, address b) internal pure returns (bytes memory) {
        (uint8 va, bytes32 ra, bytes32 sa) = vm.sign(ka, h);
        (uint8 vb, bytes32 rb, bytes32 sb) = vm.sign(kb, h);
        bytes memory A = abi.encodePacked(ra, sa, va);
        bytes memory B = abi.encodePacked(rb, sb, vb);
        return a < b ? abi.encodePacked(A, B) : abi.encodePacked(B, A);
    }

    function _sign(uint256 k, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(k, digest);
        return abi.encodePacked(r, s, v);
    }

    function _plan(uint64 nonce, uint8 threshold, uint256 cap) internal view returns (WillModule.Plan memory p) {
        p.creator = o1;
        p.salt = SALT;
        p.nonce = nonce;
        p.issuedAt = uint64(block.timestamp);
        p.checkInInterval = INTERVAL;
        p.disputePeriod = DISPUTE;
        p.heirs = new WillModule.Heir[](2);
        p.heirs[0] = WillModule.Heir({account: heirA, bps: 6000});
        p.heirs[1] = WillModule.Heir({account: heirB, bps: 4000});
        p.verifiers = new address[](3);
        p.verifiers[0] = v1;
        p.verifiers[1] = v2;
        p.verifiers[2] = v3;
        p.verifierThreshold = threshold;
        p.chains = new WillModule.ChainConfig[](2);
        address[] memory ta = new address[](1);
        ta[0] = address(usdA);
        address[] memory tb = new address[](1);
        tb[0] = address(usdB);
        p.chains[0] = WillModule.ChainConfig({chainId: CHAIN_A, safe: address(safeA), relayFeeCap: cap, tokens: ta});
        p.chains[1] = WillModule.ChainConfig({chainId: CHAIN_B, safe: address(safeB), relayFeeCap: cap, tokens: tb});
    }

    function _ownerSigs(bytes32 digest) internal view returns (address[] memory signers, bytes[] memory sigs) {
        signers = new address[](2);
        sigs = new bytes[](2);
        signers[0] = o1;
        signers[1] = o2;
        sigs[0] = _sign(k1, digest);
        sigs[1] = _sign(k2, digest);
    }

    /// Owners sign once; the relayer submits on the current chain.
    function _configureBySig(WillModule.Plan memory p) internal {
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.prank(relayer, relayer);
        module.configure(p, signers, sigs);
    }

    function _configureViaSafe(Safe safe, WillModule.Plan memory p) internal {
        address[] memory signers = new address[](1);
        bytes[] memory sigs = new bytes[](1);
        signers[0] = p.creator;
        sigs[0] = _sign(k1, module.hashPlan(p));
        _execSafe(safe, address(module), abi.encodeCall(module.configure, (p, signers, sigs)));
    }

    function _confirmBySig(uint256 k, address v) internal {
        WillModule.State memory s = module.getState(planId);
        bytes memory sig = _sign(k, module.confirmDigest(planId, s.nonce, s.lastCheckIn));
        vm.prank(relayer, relayer);
        module.confirmDeathBySig(planId, s.lastCheckIn, v, sig);
    }

    function _toExecuted() internal {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
    }

    // ------------------------------------------------------------------
    // configure
    // ------------------------------------------------------------------

    function test_Configure_ViaSafeTransaction() public {
        _configureViaSafe(safeA, _plan(1, 2, CAP));
        WillModule.State memory s = module.getState(planId);
        assertEq(uint8(s.status), uint8(WillModule.Status.Active));
        assertEq(s.safe, address(safeA));
        assertEq(module.planOf(address(safeA)), planId);
        assertEq(module.getHeirs(planId).length, 2);
        assertEq(module.getVerifiers(planId).length, 3);
        assertEq(module.getTokens(planId)[0], address(usdA)); // only this chain's tokens
        assertEq(s.relayFeeCap, CAP);
    }

    function test_Configure_BySig_PaysRelayerCapped() public {
        uint256 before = relayer.balance;
        vm.fee(1_000 gwei); // very expensive block: refund must stop at the cap
        vm.txGasPrice(1_000 gwei);
        _configureBySig(_plan(1, 2, CAP));
        assertEq(relayer.balance - before, CAP);
        assertEq(address(safeA).balance, 10 ether - CAP);
    }

    function test_Fee_RelayerCannotInflateGasPrice() public {
        uint256 before = relayer.balance;
        vm.fee(1 gwei); // cheap block, but the relayer bids an absurd gas price
        vm.txGasPrice(1_000 gwei);
        _configureBySig(_plan(1, 2, CAP));
        uint256 fee = relayer.balance - before;
        assertGt(fee, 0);
        assertLe(fee, 600_000 * 3 gwei); // priced at basefee + 2 gwei, not at the 1,000 gwei bid
        assertLt(fee, CAP);
    }

    function test_Configure_BySig_NoFeeWhenCapZero() public {
        _configureBySig(_plan(1, 2, 0));
        assertEq(relayer.balance, 0);
        assertEq(address(safeA).balance, 10 ether);
    }

    function test_Configure_SameSignaturesWorkOnEveryChain() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));

        uint256 snap = vm.snapshotState();
        vm.chainId(CHAIN_A);
        vm.prank(relayer, relayer);
        module.configure(p, signers, sigs);
        assertEq(module.getState(planId).safe, address(safeA));
        assertEq(module.getTokens(planId)[0], address(usdA));

        vm.revertToState(snap);
        vm.chainId(CHAIN_B);
        assertEq(module.hashPlan(p), module.hashPlan(p)); // domain has no chainId
        vm.prank(relayer, relayer);
        module.configure(p, signers, sigs);
        assertEq(module.getState(planId).safe, address(safeB));
        assertEq(module.getTokens(planId)[0], address(usdB));
    }

    function test_Configure_DigestIgnoresChainId() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        bytes32 a = module.hashPlan(p);
        vm.chainId(CHAIN_B);
        assertEq(module.hashPlan(p), a);
    }

    function test_Configure_RejectsChainNotInPlan() public {
        vm.chainId(8453);
        WillModule.Plan memory p = _plan(1, 2, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(WillModule.ChainNotInPlan.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_RejectsTooFewSigners() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        bytes32 d = module.hashPlan(p);
        address[] memory signers = new address[](1);
        bytes[] memory sigs = new bytes[](1);
        signers[0] = o1;
        sigs[0] = _sign(k1, d);
        vm.expectRevert(WillModule.NotEnoughSigners.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_RejectsDuplicateSigner() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        bytes32 d = module.hashPlan(p);
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        signers[0] = o1;
        signers[1] = o1;
        sigs[0] = _sign(k1, d);
        sigs[1] = _sign(k1, d);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_RejectsNonOwnerSigner() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        bytes32 d = module.hashPlan(p);
        (address x, uint256 kx) = makeAddrAndKey("outsider");
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        signers[0] = o1;
        signers[1] = x;
        sigs[0] = _sign(k1, d);
        sigs[1] = _sign(kx, d);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_RejectsTamperedPlan() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        p.heirs[0].account = stranger; // relayer swaps an heir
        vm.expectRevert(WillModule.BadSignature.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_RequiresCreatorAmongSigners() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        bytes32 d = module.hashPlan(p);
        address[] memory signers = new address[](2);
        bytes[] memory sigs = new bytes[](2);
        signers[0] = o2;
        signers[1] = o3;
        sigs[0] = _sign(k2, d);
        sigs[1] = _sign(k3, d);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_RequiresModuleEnabled() public {
        Safe other = _newSafe(9);
        WillModule.Plan memory p = _plan(1, 2, CAP);
        p.chains[0].safe = address(other);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(WillModule.ModuleNotEnabled.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_ReplayAndNonce() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        module.configure(p, signers, sigs);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(p, signers, sigs);

        WillModule.Plan memory p2 = _plan(2, 1, CAP);
        _configureBySig(p2);
        assertEq(module.getState(planId).verifierThreshold, 1);
        assertEq(module.getState(planId).nonce, 2);
    }

    function test_Configure_ValidatesShapes() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        p.heirs[1].bps = 3000; // sums to 9000
        (address[] memory s1, bytes[] memory g1) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, "shares must sum to 10000 bps"));
        module.configure(p, s1, g1);

        p = _plan(1, 2, CAP);
        p.verifierThreshold = 4;
        (s1, g1) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, "threshold > verifiers"));
        module.configure(p, s1, g1);

        p = _plan(1, 2, CAP);
        p.checkInInterval = 10 minutes;
        (s1, g1) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, "interval too short"));
        module.configure(p, s1, g1);

        p = _plan(1, 2, CAP);
        p.heirs[1].account = heirA;
        (s1, g1) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, "duplicate heir"));
        module.configure(p, s1, g1);

        p = _plan(1, 2, CAP);
        p.chains[1].chainId = CHAIN_A;
        (s1, g1) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, "duplicate chain"));
        module.configure(p, s1, g1);
    }

    function test_Configure_PlanCannotHijackAnotherSafe() public {
        _configureBySig(_plan(1, 2, CAP));
        // A different plan id cannot be bound to the same Safe while the first is live.
        WillModule.Plan memory p = _plan(1, 2, CAP);
        p.salt = keccak256("second");
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(WillModule.PlanTaken.selector);
        module.configure(p, signers, sigs);
    }

    function test_Configure_BlockedWhileTriggered() public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        WillModule.Plan memory p = _plan(2, 2, 0);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Triggered));
        module.configure(p, signers, sigs);
    }

    function test_Configure_FutureIssuedAtRejected() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        p.issuedAt = uint64(block.timestamp + 1 days);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(WillModule.FromTheFuture.selector);
        module.configure(p, signers, sigs);
    }

    // ------------------------------------------------------------------
    // check-in
    // ------------------------------------------------------------------

    function test_CheckIn_OneSignatureEveryChain() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        vm.warp(block.timestamp + 10 days);
        uint64 at = uint64(block.timestamp);
        bytes memory sig = _sign(k3, module.checkInDigest(planId, at)); // any single owner

        uint256 snap = vm.snapshotState();
        vm.chainId(CHAIN_A);
        module.configure(p, signers, sigs);
        vm.warp(block.timestamp + 2 minutes); // relayed a bit later: time recorded is the signed one
        vm.prank(relayer, relayer);
        module.checkInBySig(planId, at, o3, sig);
        assertEq(module.getState(planId).lastCheckIn, at);

        vm.revertToState(snap);
        vm.chainId(CHAIN_B);
        module.configure(p, signers, sigs);
        vm.warp(block.timestamp + 9 minutes);
        vm.prank(relayer, relayer);
        module.checkInBySig(planId, at, o3, sig);
        assertEq(module.getState(planId).lastCheckIn, at); // identical on both chains
    }

    function test_CheckIn_SignatureCannotBeReplayed() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes memory sig = _sign(k1, module.checkInDigest(planId, at));
        module.checkInBySig(planId, at, o1, sig);
        vm.expectRevert(WillModule.StaleCheckIn.selector);
        module.checkInBySig(planId, at, o1, sig);
    }

    function test_CheckIn_RejectsNonOwnerAndBadSig() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes memory sig = _sign(kv1, module.checkInDigest(planId, at));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.checkInBySig(planId, at, v1, sig);

        bytes memory wrong = _sign(k2, module.checkInDigest(planId, at));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.checkInBySig(planId, at, o1, wrong);
    }

    function test_CheckIn_FutureTimestampRejected() public {
        _configureBySig(_plan(1, 2, CAP));
        uint64 at = uint64(block.timestamp + 1 hours);
        bytes memory sig = _sign(k1, module.checkInDigest(planId, at));
        vm.expectRevert(WillModule.FromTheFuture.selector);
        module.checkInBySig(planId, at, o1, sig);
    }

    function test_CheckIn_DirectByOwner() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + 5 days);
        vm.prank(o2);
        module.checkIn(planId);
        assertEq(module.getState(planId).lastCheckIn, block.timestamp);
        vm.prank(stranger);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.checkIn(planId);
    }

    function test_CheckIn_CancelsTriggerAndVoidsVotes() public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));

        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        module.checkInBySig(planId, at, o1, _sign(k1, module.checkInDigest(planId, at)));
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Active));
        assertEq(module.currentConfirmations(planId), 0);
    }

    // ------------------------------------------------------------------
    // verifiers / trigger
    // ------------------------------------------------------------------

    function test_Confirm_OnlyWhenOverdue() public {
        _configureBySig(_plan(1, 2, 0));
        WillModule.State memory s = module.getState(planId);
        bytes memory sig = _sign(kv1, module.confirmDigest(planId, s.nonce, s.lastCheckIn));
        vm.expectRevert(WillModule.NotOverdue.selector);
        module.confirmDeathBySig(planId, s.lastCheckIn, v1, sig);
    }

    function test_Confirm_OneSignatureEveryChain() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        uint64 epoch = p.issuedAt;
        bytes memory c1 = _sign(kv1, module.confirmDigest(planId, 1, epoch));
        bytes memory c2 = _sign(kv2, module.confirmDigest(planId, 1, epoch));

        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            vm.revertToState(snap);
            vm.chainId(i == 0 ? CHAIN_A : CHAIN_B);
            module.configure(p, signers, sigs);
            vm.warp(epoch + INTERVAL + 1);
            vm.startPrank(relayer, relayer);
            module.confirmDeathBySig(planId, epoch, v1, c1);
            module.confirmDeathBySig(planId, epoch, v2, c2);
            vm.stopPrank();
            assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
        }
    }

    function test_Confirm_OldEpochSignatureUselessAfterCheckIn() public {
        _configureBySig(_plan(1, 2, 0));
        uint64 oldEpoch = module.getState(planId).lastCheckIn;
        bytes memory c1 = _sign(kv1, module.confirmDigest(planId, 1, oldEpoch));
        vm.warp(block.timestamp + 1 days);
        vm.prank(o1);
        module.checkIn(planId);
        vm.warp(block.timestamp + INTERVAL + 1);
        vm.expectRevert(WillModule.WrongEpoch.selector);
        module.confirmDeathBySig(planId, oldEpoch, v1, c1);
    }

    function test_Confirm_DirectAndGuards() public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        vm.prank(stranger);
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.confirmDeath(planId);
        vm.prank(v1);
        module.confirmDeath(planId);
        vm.prank(v1);
        vm.expectRevert(WillModule.AlreadyConfirmed.selector);
        module.confirmDeath(planId);
        assertEq(module.currentConfirmations(planId), 1);
        vm.prank(v3);
        module.confirmDeath(planId);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
    }

    function test_Trigger_TimeOnlyWhenThresholdZero() public {
        _configureBySig(_plan(1, 0, 0));
        vm.expectRevert(WillModule.NotOverdue.selector);
        module.trigger(planId);
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Triggered));
    }

    function test_Trigger_RequiresThreshold() public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        vm.prank(v1);
        module.confirmDeath(planId);
        vm.expectRevert(WillModule.ThresholdNotMet.selector);
        module.trigger(planId);
    }

    // ------------------------------------------------------------------
    // execute / claim
    // ------------------------------------------------------------------

    function test_Execute_RespectsDisputeWindow() public {
        _configureBySig(_plan(1, 2, 0));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.expectRevert();
        module.execute(planId);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.Executed));
        assertEq(module.claimable(planId, 0, address(0)), 6 ether);
        assertEq(module.claimable(planId, 1, address(usdA)), 400_000e18);
        vm.prank(heirB);
        module.claim(planId, 1);
        assertEq(module.totalPaid(planId, address(usdA)), 400_000e18);
        assertEq(module.claimable(planId, 1, address(usdA)), 0);
    }

    function test_Claim_ByHeirPaysFullShareNoFee() public {
        _toExecuted();
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(heirA.balance, 6 ether);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        vm.prank(heirB);
        module.claim(planId, 1);
        assertEq(heirB.balance, 4 ether);
        assertEq(usdA.balanceOf(heirB), 400_000e18);
        assertEq(address(safeA).balance, 0);
    }

    function test_Claim_ByRelayerFeeComesFromThatHeirsEth() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        vm.prank(relayer, relayer);
        module.execute(planId);
        uint256 snapEth = address(safeA).balance;

        uint256 before = relayer.balance;
        vm.fee(1_000 gwei);
        vm.txGasPrice(1_000 gwei);
        bytes memory hsig = _sign(kHeirA, module.claimDigest(planId, 0, 0, CAP));
        vm.prank(relayer, relayer);
        module.claimBySig(planId, 0, CAP, hsig);
        uint256 fee = relayer.balance - before;
        assertEq(fee, CAP);
        assertEq(heirA.balance, snapEth * 6000 / 10_000 - fee);
        // heir B is unaffected
        vm.prank(heirB);
        module.claim(planId, 1);
        assertEq(heirB.balance, snapEth * 4000 / 10_000);
    }

    function test_Claim_SecondCallPaysNothing() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        bytes memory hsig = _sign(kHeirA, module.claimDigest(planId, 0, 0, CAP));
        vm.prank(relayer, relayer);
        module.claimBySig(planId, 0, CAP, hsig);
        uint256 r = relayer.balance;
        uint256 h = heirA.balance;
        // the signature is used up: a relayer can't replay it to collect fees again
        vm.prank(relayer, relayer);
        vm.expectRevert(WillModule.BadSignature.selector);
        module.claimBySig(planId, 0, CAP, hsig);
        // and a plain second claim pays nothing more
        module.claim(planId, 0);
        assertEq(relayer.balance, r);
        assertEq(heirA.balance, h);
    }

    function test_Claim_BrokenTokenDoesNotBlockOthers() public {
        BrokenToken bad = new BrokenToken();
        NoReturnToken nr = new NoReturnToken();
        bad.mint(address(safeA), 100e18);
        nr.mint(address(safeA), 1000);
        WillModule.Plan memory p = _plan(1, 2, 0);
        address[] memory ta = new address[](3);
        ta[0] = address(usdA);
        ta[1] = address(bad);
        ta[2] = address(nr);
        p.chains[0].tokens = ta;
        _configureBySig(p);
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(usdA.balanceOf(heirA), 600_000e18);
        assertEq(nr.balanceOf(heirA), 600);
        assertEq(heirA.balance, 6 ether);
        assertEq(module.paid(planId, 0, address(bad)), 0);
    }

    function test_Claim_ReentrancyBlocked() public {
        Reenterer r = new Reenterer();
        WillModule.Plan memory p = _plan(1, 2, 0);
        p.heirs[0].account = address(r);
        _configureBySig(p);
        r.arm(module, planId);
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        module.claim(planId, 0);
        assertEq(address(r).balance, 6 ether); // paid once
    }

    function test_Claim_BeforeExecutionReverts() public {
        _configureBySig(_plan(1, 2, 0));
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Active));
        module.claim(planId, 0);
    }

    function test_Execute_FeeComesOutBeforeHeirsShare() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        uint256 safeBal = address(safeA).balance;
        uint256 before = relayer.balance;
        vm.prank(relayer, relayer);
        module.execute(planId);
        uint256 fee = relayer.balance - before;
        assertGt(fee, 0);
        assertEq(
            module.claimable(planId, 0, address(0)) + module.claimable(planId, 1, address(0)),
            safeBal - fee - (safeBal - fee) % 2 // at most 1 wei of rounding dust per heir
        );
    }

    // ------------------------------------------------------------------
    // cancel
    // ------------------------------------------------------------------

    function test_Cancel_ViaSafe_SweepsToOwnerAndDisablesModule() public {
        _configureBySig(_plan(1, 2, CAP));
        uint256 eth = address(safeA).balance;
        _execSafe(safeA, address(module), abi.encodeCall(module.cancel, (2, ownerWallet, true)));
        assertEq(ownerWallet.balance, eth);
        assertEq(usdA.balanceOf(ownerWallet), 1_000_000e18);
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(module.planOf(address(safeA)), bytes32(0));
        assertFalse(safeA.isModuleEnabled(address(module)));
        assertEq(module.getHeirs(planId).length, 0);
    }

    function test_Cancel_ViaSafe_KeepFundsInSafe() public {
        _configureBySig(_plan(1, 2, CAP));
        _execSafe(safeA, address(module), abi.encodeCall(module.cancel, (2, address(0), false)));
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertTrue(safeA.isModuleEnabled(address(module)));
        assertGt(address(safeA).balance, 9 ether);
    }

    function test_Cancel_BySig_EveryChainEvenWhileTriggered() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        (address[] memory signers, bytes[] memory sigs) = _ownerSigs(module.hashPlan(p));
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, ownerWallet, true));

        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 2; ++i) {
            vm.revertToState(snap);
            vm.chainId(i == 0 ? CHAIN_A : CHAIN_B);
            Safe safe = i == 0 ? safeA : safeB;
            MockToken usd = i == 0 ? usdA : usdB;
            module.configure(p, signers, sigs);
            vm.warp(p.issuedAt + INTERVAL + 1);
            _confirmBySig(kv1, v1);
            _confirmBySig(kv2, v2); // triggered
            uint256 tokenBal = usd.balanceOf(address(safe));
            vm.prank(relayer, relayer);
            module.cancelBySig(planId, 2, ownerWallet, true, cs, csig);
            assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
            assertEq(usd.balanceOf(ownerWallet), tokenBal);
            assertEq(address(safe).balance, 0);
            assertGt(ownerWallet.balance, 0);
            assertFalse(safe.isModuleEnabled(address(module)));
        }
    }

    function test_Cancel_BySig_ReplayAndNonce() public {
        _configureBySig(_plan(1, 2, CAP));
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 1, address(0), false));
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.cancelBySig(planId, 1, address(0), false, cs, csig); // nonce must exceed the plan's

        (cs, csig) = _ownerSigs(module.cancelDigest(planId, 2, address(0), false));
        module.cancelBySig(planId, 2, address(0), false, cs, csig);
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.cancelBySig(planId, 2, address(0), false, cs, csig);

        // A new plan must use a higher nonce, and the old cancel can't touch it.
        _configureBySig(_plan(3, 2, CAP));
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.cancelBySig(planId, 2, address(0), false, cs, csig);
    }

    function test_Cancel_BySig_RequiresOwnerThreshold() public {
        _configureBySig(_plan(1, 2, CAP));
        bytes32 d = module.cancelDigest(planId, 2, stranger, false);
        address[] memory signers = new address[](1);
        bytes[] memory sigs = new bytes[](1);
        signers[0] = o1;
        sigs[0] = _sign(k1, d);
        vm.expectRevert(WillModule.NotEnoughSigners.selector);
        module.cancelBySig(planId, 2, stranger, false, signers, sigs);
    }

    function test_Cancel_NotAfterExecution() public {
        _toExecuted();
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Executed));
        _execSafeExpectFail();
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, ownerWallet, false));
        vm.expectRevert(abi.encodeWithSelector(WillModule.WrongStatus.selector, WillModule.Status.Executed));
        module.cancelBySig(planId, 2, ownerWallet, false, cs, csig);
    }

    function _execSafeExpectFail() internal {
        // The Safe calls cancel(); the module reverts with WrongStatus(Executed).
        vm.prank(address(safeA));
        module.cancel(2, ownerWallet, false);
    }

    function test_Cancel_SweepOnlyToAnOwner() public {
        _configureBySig(_plan(1, 2, CAP));
        uint256 eth = address(safeA).balance;
        vm.prank(address(safeA));
        module.cancel(2, stranger, false); // not an owner here: cancel still happens, no sweep
        assertEq(uint8(module.getState(planId).status), uint8(WillModule.Status.None));
        assertEq(stranger.balance, 0);
        assertEq(address(safeA).balance, eth);
    }

    // ------------------------------------------------------------------
    // fees never block safety actions
    // ------------------------------------------------------------------

    function test_Fee_SkippedWhenSafeHasNoEth_ActionStillWorks() public {
        _configureBySig(_plan(1, 2, CAP));
        // Owners empty the Safe's ETH.
        vm.deal(address(safeA), 0);
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        uint256 before = relayer.balance;
        vm.prank(relayer, relayer);
        module.checkInBySig(planId, at, o1, _sign(k1, module.checkInDigest(planId, at)));
        assertEq(module.getState(planId).lastCheckIn, at);
        assertEq(relayer.balance, before);
    }

    function test_Fee_OnlyOncePerSignature() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes memory sig = _sign(k1, module.checkInDigest(planId, at));
        vm.prank(relayer, relayer);
        module.checkInBySig(planId, at, o1, sig);
        uint256 r = relayer.balance;
        vm.prank(relayer, relayer);
        vm.expectRevert(WillModule.StaleCheckIn.selector);
        module.checkInBySig(planId, at, o1, sig);
        assertEq(relayer.balance, r);
    }

    // ------------------------------------------------------------------
    // regressions from the security review
    // ------------------------------------------------------------------

    function _evilSafe(address attacker, uint256 ka) internal returns (Safe evil) {
        address[] memory owners = new address[](2);
        owners[0] = attacker;
        owners[1] = o1;
        bytes memory init =
            abi.encodeCall(Safe.setup, (owners, 1, address(0), "", address(0), address(0), 0, payable(address(0))));
        evil = Safe(payable(address(factory.createProxyWithNonce(address(singleton), init, 77))));
        _enableBySingleOwner(evil, ka);
    }

    function _enableBySingleOwner(Safe safe, uint256 key) internal {
        bytes memory en = abi.encodeCall(safe.enableModule, (address(module)));
        bytes32 h = safe.getTransactionHash(address(safe), 0, en, Enum.Operation.Call, 0, 0, 0, address(0), address(0), 0);
        bytes memory sig = _sign(key, h);
        safe.execTransaction(address(safe), 0, en, Enum.Operation.Call, 0, 0, 0, address(0), payable(address(0)), sig);
    }

    function test_Review_PlanIdCannotBeSquatted() public {
        // Attacker builds a Safe that lists the victim (o1) as an owner without consent.
        (address attacker, uint256 ka) = makeAddrAndKey("attacker");
        Safe evil = _evilSafe(attacker, ka);
        WillModule.Plan memory p = _plan(type(uint64).max, 0, 0);
        p.chains[0].safe = address(evil);
        address[] memory signers = new address[](1);
        bytes[] memory sigs = new bytes[](1);
        signers[0] = o1;
        sigs[0] = _sign(ka, module.hashPlan(p)); // attacker can't produce the victim's signature
        vm.prank(address(evil));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.configure(p, signers, sigs);
        vm.prank(address(evil));
        vm.expectRevert(WillModule.NotAuthorized.selector);
        module.configure(p, new address[](0), new bytes[](0));
    }

    function test_Review_CancelBlocksUndeliveredUpdate() public {
        _configureBySig(_plan(1, 0, 0));
        WillModule.Plan memory upd = _plan(2, 0, 0); // signed, never delivered
        (address[] memory us, bytes[] memory usig) = _ownerSigs(module.hashPlan(upd));
        vm.warp(block.timestamp + 20 days);
        _execSafe(safeA, address(module), abi.encodeCall(module.cancel, (3, address(0), false)));
        assertEq(module.getState(planId).lastCheckIn, block.timestamp); // cancel counts as proof of life
        vm.expectRevert(WillModule.StaleNonce.selector);
        module.configure(upd, us, usig);
    }

    function test_Review_OldCheckInsNotReplayableAfterReconfigure() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        bytes memory sig = _sign(k1, module.checkInDigest(planId, at));
        module.checkInBySig(planId, at, o1, sig);
        (address[] memory cs, bytes[] memory csig) = _ownerSigs(module.cancelDigest(planId, 2, address(0), false));
        module.cancelBySig(planId, 2, address(0), false, cs, csig);
        WillModule.Plan memory p = _plan(3, 2, CAP);
        p.issuedAt = at - 1; // older than the earlier check-in
        _configureBySig(p);
        assertGe(module.getState(planId).lastCheckIn, at);
        vm.expectRevert(WillModule.StaleCheckIn.selector);
        module.checkInBySig(planId, at, o1, sig);
    }

    function test_Review_DelegatedEoaOwnerCanStillSign() public {
        _configureBySig(_plan(1, 2, 0));
        vm.etch(o1, hex"600060005260206000f3"); // o1 now has code (EIP-7702 style), no isValidSignature
        vm.warp(block.timestamp + 1 days);
        uint64 at = uint64(block.timestamp);
        module.checkInBySig(planId, at, o1, _sign(k1, module.checkInDigest(planId, at)));
        assertEq(module.getState(planId).lastCheckIn, at);
    }

    function test_Review_TokenUnreadableAtExecuteIsNotLost() public {
        PausableToken pt = new PausableToken();
        pt.mint(address(safeA), 1000e18);
        WillModule.Plan memory p = _plan(1, 0, 0);
        address[] memory ta = new address[](1);
        ta[0] = address(pt);
        p.chains[0].tokens = ta;
        _configureBySig(p);
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        vm.warp(block.timestamp + DISPUTE);
        pt.setPaused(true);
        module.execute(planId);
        vm.prank(heirA);
        module.claim(planId, 0); // token unreadable: skipped, retryable
        assertEq(heirA.balance, 6 ether);
        pt.setPaused(false);
        vm.prank(heirA);
        module.claim(planId, 0);
        assertEq(pt.balanceOf(heirA), 600e18);
    }

    function test_Review_PlainClaimNeverTakesAFee() public {
        _configureBySig(_plan(1, 2, CAP));
        vm.warp(block.timestamp + INTERVAL + 1);
        _confirmBySig(kv1, v1);
        _confirmBySig(kv2, v2);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        uint256 snapEth = address(safeA).balance;
        uint256 r = relayer.balance;
        vm.prank(relayer, relayer); // front-running bot
        module.claim(planId, 0);
        assertEq(relayer.balance, r);
        assertEq(heirA.balance, snapEth * 6000 / 10_000);
    }

    function test_Review_ClaimBySigRejectsWrongSigner() public {
        _toExecuted();
        bytes memory bad = _sign(k1, module.claimDigest(planId, 0, 0, 0));
        vm.expectRevert(WillModule.BadSignature.selector);
        module.claimBySig(planId, 0, 0, bad);
    }

    function test_Review_DurationBounds() public {
        WillModule.Plan memory p = _plan(1, 2, CAP);
        p.disputePeriod = type(uint64).max;
        (address[] memory s1, bytes[] memory g1) = _ownerSigs(module.hashPlan(p));
        vm.expectRevert(abi.encodeWithSelector(WillModule.InvalidConfig.selector, "dispute too long"));
        module.configure(p, s1, g1);
    }

    // ------------------------------------------------------------------
    // fuzz
    // ------------------------------------------------------------------

    function testFuzz_SharesNeverExceedSnapshot(uint16 bpsA, uint96 eth, uint128 tokens) public {
        bpsA = uint16(bound(bpsA, 1, 9999));
        vm.deal(address(safeA), eth);
        deal(address(usdA), address(safeA), tokens);
        WillModule.Plan memory p = _plan(1, 0, 0);
        p.heirs[0].bps = bpsA;
        p.heirs[1].bps = 10_000 - bpsA;
        _configureBySig(p);
        vm.warp(block.timestamp + INTERVAL + 1);
        module.trigger(planId);
        vm.warp(block.timestamp + DISPUTE);
        module.execute(planId);
        vm.prank(heirA);
        module.claim(planId, 0);
        vm.prank(heirB);
        module.claim(planId, 1);
        assertLe(heirA.balance + heirB.balance, uint256(eth));
        assertLe(usdA.balanceOf(heirA) + usdA.balanceOf(heirB), uint256(tokens));
        // rounding dust at most 1 wei per heir
        assertLe(uint256(eth) - (heirA.balance + heirB.balance), 2);
    }
}
