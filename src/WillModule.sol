// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {SignatureChecker} from "openzeppelin-contracts/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/// @notice Minimal subset of the Safe interface the module relies on.
interface ISafe {
    /// @dev Used instead of the ReturnData variant so a callee can never make us copy unbounded return data.
    function execTransactionFromModule(address to, uint256 value, bytes calldata data, uint8 operation)
        external
        returns (bool success);
    function isOwner(address owner) external view returns (bool);
    function getThreshold() external view returns (uint256);
    function isModuleEnabled(address module) external view returns (bool);
    function getModulesPaginated(address start, uint256 pageSize)
        external
        view
        returns (address[] memory array, address next);
}

interface IERC20Balance {
    function balanceOf(address account) external view returns (uint256);
}

/// @title 0xWills WillModule (v4, multi-chain)
/// @notice Non-custodial inheritance for Safe smart accounts — one plan across many EVM chains.
///
/// The same contract is deployed at the same address on every supported chain (CREATE2).
/// Its EIP-712 domain deliberately has NO chainId, so one signature is valid on every chain:
///   - the owner(s) sign the plan once; it carries one entry per chain (that chain's Safe,
///     the tokens covered there, and the relayer fee cap there);
///   - an owner signs each check-in once; a verifier signs each confirmation once;
///   - the owner(s) sign a cancel once.
/// A relayer (or anyone) submits those signatures to every chain. Each chain verifies them
/// against its own Safe's owners, so a relayer can delay but never forge or alter anything.
/// The relayer is reimbursed for gas from the Safe, capped per chain by the plan.
///
/// Assets never leave the Safe until an heir claims. Lifecycle per chain:
///   Active --(interval missed + verifier threshold)--> Triggered
///   Triggered --(owner checks in)--> Active
///   Active/Triggered --(owner cancels)--> None (optionally sweeping assets to the owner)
///   Triggered --(dispute window passes, anyone calls execute)--> Executed
///   Executed --> each heir claims its share of whatever the Safe holds (now or later), per asset
///   Executed --(the Safe's owners configure a new plan for the Safe)--> Closed
///
/// v3 changes (from the v2 security review): cross-chain revoke for chains a plan never reached,
/// stale plans rejected, running-total payouts with per-asset claims and balance-checked token
/// transfers, lifecycle paused while the module is disabled, executed plans can be closed,
/// capped relayer gas price + heir-signed max fee, network-specific EIP-712 domain.
///
/// v4 changes: (1) owner-chosen verifier fallback: if verifiers never confirm, anyone may start the
/// dispute window once the owner has been overdue for `verifierFallback` seconds (0 = off);
/// (2) acknowledge(): verifiers and heirs can confirm on-chain that their wallet works ("I'm here"),
/// recorded as lastSeen + an event, so owners know their people can still act.
contract WillModule is ReentrancyGuard {
    // ------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------

    enum Status {
        None,
        Active,
        Triggered,
        Executed,
        Closed
    }

    struct Heir {
        address account;
        uint16 bps;
    }

    /// @notice One entry per chain the plan covers.
    struct ChainConfig {
        uint256 chainId;
        address safe;
        uint256 relayFeeCap; // max wei paid to a relayer per action on this chain (0 = no fees)
        address[] tokens; // ERC-20s covered on this chain (native ETH is always covered)
    }

    /// @notice The plan the owner(s) sign once. planId = keccak256(abi.encode(creator, salt)).
    struct Plan {
        address creator;
        bytes32 salt;
        uint64 nonce; // must increase with every update or cancel
        uint64 issuedAt; // counts as a check-in at this time
        uint64 checkInInterval;
        uint64 disputePeriod;
        Heir[] heirs;
        address[] verifiers;
        uint8 verifierThreshold; // 0 = purely time-based
        uint64 verifierFallback; // seconds overdue after which anyone may trigger without verifiers (0 = off)
        ChainConfig[] chains;
    }

    /// @notice Per-chain state of a plan.
    struct State {
        address safe;
        Status status;
        uint64 nonce;
        uint64 checkInInterval;
        uint64 disputePeriod;
        uint64 lastCheckIn; // also the "epoch" verifiers confirm against
        uint64 triggeredAt;
        uint64 executedAt;
        uint8 verifierThreshold;
        uint256 relayFeeCap;
        uint64 verifierFallback; // v4 (kept last so older readers of the layout still work)
    }

    // ------------------------------------------------------------------
    // Constants / immutables
    // ------------------------------------------------------------------

    address public constant NATIVE = address(0);
    address internal constant SENTINEL_MODULES = address(0x1);
    uint16 internal constant TOTAL_BPS = 10_000;
    uint256 internal constant MAX_HEIRS = 20;
    uint256 internal constant MAX_VERIFIERS = 10;
    uint256 internal constant MAX_TOKENS = 20;
    uint256 internal constant MAX_CHAINS = 16;
    /// @notice How far in the future a signed timestamp may be (clock skew between chains).
    uint64 internal constant MAX_CLOCK_DRIFT = 15 minutes;
    uint64 internal constant MAX_INTERVAL = 3650 days;
    uint64 internal constant MAX_DISPUTE = 365 days;
    uint64 internal constant MAX_FALLBACK = 3650 days;
    /// @notice Gas not visible to gasleft() (base tx cost + calldata), added to relayer refunds.
    uint256 public constant FEE_GAS_OVERHEAD = 45_000;
    /// @notice Relayer refunds use at most basefee + this tip, whatever gas price the relayer chose.
    uint256 internal constant MAX_PRIORITY_FEE = 2 gwei;
    /// @notice Gas given to a token's balanceOf (bounded, so a hostile token can't eat the claim's gas).
    uint256 internal constant BALANCE_GAS = 100_000;
    /// @notice Gas given to each token transfer (through the Safe), so a hostile token can't eat the claim's gas.
    uint256 internal constant TOKEN_CALL_GAS = 250_000;
    /// @notice A claim stops paying further tokens when less than this gas is left (ETH is still paid).
    uint256 internal constant MIN_GAS_PER_ASSET = 400_000;

    bytes32 internal constant HEIR_TYPEHASH = keccak256("Heir(address account,uint16 bps)");
    bytes32 internal constant CHAIN_TYPEHASH =
        keccak256("ChainConfig(uint256 chainId,address safe,uint256 relayFeeCap,address[] tokens)");
    bytes32 internal constant PLAN_TYPEHASH = keccak256(
        "Plan(address creator,bytes32 salt,uint64 nonce,uint64 issuedAt,uint64 checkInInterval,uint64 disputePeriod,Heir[] heirs,address[] verifiers,uint8 verifierThreshold,uint64 verifierFallback,ChainConfig[] chains)"
        "ChainConfig(uint256 chainId,address safe,uint256 relayFeeCap,address[] tokens)"
        "Heir(address account,uint16 bps)"
    );
    bytes32 internal constant CHECKIN_TYPEHASH = keccak256("CheckIn(bytes32 planId,uint64 signedAt)");
    bytes32 internal constant CONFIRM_TYPEHASH = keccak256("Confirm(bytes32 planId,uint64 nonce,uint64 epoch)");
    bytes32 internal constant CANCEL_TYPEHASH =
        keccak256("Cancel(bytes32 planId,uint64 nonce,address sweepTo,bool disableModule)");
    bytes32 internal constant CLAIM_TYPEHASH =
        keccak256("Claim(bytes32 planId,uint256 index,uint256 claimNonce,uint256 maxFee)");

    /// @notice EIP-712 domain separator without chainId: signatures are valid on every chain
    ///         where this contract lives at this same address.
    bytes32 public immutable DOMAIN_SEPARATOR;

    /// @notice Lower bounds, set per deployment (short on testnets for demos, long on mainnets).
    uint64 public immutable minCheckInInterval;
    uint64 public immutable minDisputePeriod;
    /// @notice Testnet deployments use a different EIP-712 version, so their signatures never work on mainnet.
    bool public immutable isTestnet;

    // ------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------

    mapping(bytes32 planId => State) internal _plans;
    mapping(bytes32 planId => Heir[]) internal _heirs;
    mapping(bytes32 planId => address[]) internal _verifiers;
    mapping(bytes32 planId => address[]) internal _tokens;
    mapping(address safe => bytes32 planId) public planOf;

    mapping(bytes32 planId => mapping(address verifier => bool)) public isVerifier;
    /// @dev votes are keyed by (nonce, epoch): any check-in or plan update voids old votes.
    mapping(bytes32 planId => mapping(bytes32 voteKey => mapping(address verifier => bool))) public hasConfirmed;
    mapping(bytes32 planId => mapping(bytes32 voteKey => uint8)) internal confirmationCount;

    /// @notice Running payout totals. Heir i is owed bps_i of (Safe balance + everything already paid),
    ///         minus what it already received, so assets arriving after execution are shared too.
    mapping(bytes32 planId => mapping(address asset => uint256)) public totalPaid;
    mapping(bytes32 planId => mapping(uint256 index => mapping(address asset => uint256))) public paid;
    /// @notice Per-heir counter for relayed claims: each relayed claim needs a fresh heir signature.
    mapping(bytes32 planId => mapping(uint256 index => uint256)) public claimNonce;
    /// @notice Last time a verifier or heir confirmed on-chain that their wallet works (acknowledge()).
    mapping(bytes32 planId => mapping(address who => uint64)) public lastSeen;

    // ------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------

    event PlanConfigured(bytes32 indexed planId, address indexed safe, uint64 nonce);
    event PlanCancelled(bytes32 indexed planId, address indexed safe, uint64 nonce, address sweepTo, bool moduleDisabled);
    event PlanRevoked(bytes32 indexed planId, uint64 nonce);
    event PlanClosed(bytes32 indexed planId, address indexed safe);
    event CheckedIn(bytes32 indexed planId, address indexed owner, uint64 at, bool cancelledTrigger);
    event DeathConfirmed(bytes32 indexed planId, address indexed verifier, uint64 epoch, uint8 count);
    event Triggered(bytes32 indexed planId, uint64 executableAt);
    event Executed(bytes32 indexed planId);
    event ShareClaimed(bytes32 indexed planId, uint256 indexed index, address indexed asset, address to, uint256 amount);
    event ShareTransferFailed(
        bytes32 indexed planId, uint256 indexed index, address indexed asset, address to, uint256 amount
    );
    event Swept(bytes32 indexed planId, address indexed asset, address to, uint256 amount, bool ok);
    event SweepSkipped(bytes32 indexed planId, address sweepTo);
    event RelayerPaid(bytes32 indexed planId, address indexed relayer, uint256 amount);
    event Acknowledged(bytes32 indexed planId, address indexed who, bool asVerifier, bool asHeir, uint64 at);
    event FallbackTriggered(bytes32 indexed planId, uint8 confirmations);

    // ------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------

    error ModuleNotEnabled();
    /// @dev Codes (kept numeric to stay under the 24 KB contract size limit):
    ///      1 = zero minimums
    ///      2 = nonce too high
    ///      3 = chain count
    ///      4 = duplicate chain
    ///      5 = zero safe
    ///      6 = interval too short
    ///      7 = dispute too short
    ///      8 = interval too long
    ///      9 = dispute too long
    ///      10 = fallback without verifiers
    ///      11 = fallback too short
    ///      12 = fallback too long
    ///      13 = heir count
    ///      14 = bad heir
    ///      15 = zero share
    ///      16 = duplicate heir
    ///      17 = shares must sum to 10000 bps
    ///      18 = verifier count
    ///      19 = threshold > verifiers
    ///      20 = bad verifier
    ///      21 = duplicate verifier
    ///      22 = token count
    ///      23 = bad token
    ///      24 = duplicate token
    error InvalidConfig(uint8 code);
    error WrongStatus(Status actual);
    error NotAuthorized();
    error BadSignature();
    error NotEnoughSigners();
    error StaleNonce();
    error StaleCheckIn();
    error FromTheFuture();
    error ChainNotInPlan();
    error PlanTaken();
    error NotOverdue();
    error AlreadyConfirmed();
    error WrongEpoch();
    error ThresholdNotMet();
    error DisputeWindowOpen(uint64 executableAt);
    error BadIndex();
    error UnknownPlan();
    error StalePlan();
    error NotEnoughGas();
    error BadAsset();

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------

    constructor(uint64 _minCheckInInterval, uint64 _minDisputePeriod, bool _isTestnet) {
        if (_minCheckInInterval == 0 || _minDisputePeriod == 0) revert InvalidConfig(1);
        minCheckInInterval = _minCheckInInterval;
        minDisputePeriod = _minDisputePeriod;
        isTestnet = _isTestnet;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256("0xWills"),
                keccak256(bytes(_isTestnet ? "4-testnet" : "4")),
                address(this)
            )
        );
    }

    // ------------------------------------------------------------------
    // Plan: create / update
    // ------------------------------------------------------------------

    /// @notice Create or update a plan on this chain.
    ///         Either called by the Safe itself (a Safe transaction), or by anyone (e.g. a relayer)
    ///         with signatures from enough Safe owners to meet the Safe's threshold.
    function configure(Plan calldata plan, address[] calldata signers, bytes[] calldata signatures)
        external
        nonReentrant
    {
        uint256 gasStart = gasleft();
        ChainConfig calldata cc = plan.chains[_localChain(plan.chains)];
        address safe = cc.safe;
        bytes32 planId = planIdOf(plan.creator, plan.salt);

        // The plan id belongs to its creator: the creator's own signature is always required,
        // so nobody can squat or pre-empt someone else's plan id on any chain.
        bytes32 digest = hashPlan(plan);
        bool viaSignatures = msg.sender != safe;
        if (viaSignatures) {
            _checkOwnerSignatures(safe, digest, signers, signatures);
        } else if (!ISafe(safe).isOwner(plan.creator)) {
            revert NotAuthorized();
        }
        _requireSignedBy(plan.creator, digest, signers, signatures);
        if (!ISafe(safe).isModuleEnabled(address(this))) revert ModuleNotEnabled();

        State storage s = _plans[planId];
        if (s.status == Status.Triggered || s.status == Status.Executed || s.status == Status.Closed) {
            revert WrongStatus(s.status);
        }
        if (plan.nonce <= s.nonce) revert StaleNonce();
        // Leave room for a higher cancel nonce, so every plan can always be cancelled or updated.
        if (plan.nonce == type(uint64).max) revert InvalidConfig(2);
        if (s.status == Status.Active && s.safe != safe) revert PlanTaken();
        bytes32 existing = planOf[safe];
        if (existing != bytes32(0) && existing != planId) {
            // An executed plan no longer blocks the Safe: its owners may start a new plan, which
            // closes the old one (they control the Safe's funds anyway).
            State storage old = _plans[existing];
            // Only a plan signed after the execution may close it (an old, never-delivered plan can't).
            if (old.status != Status.Executed || plan.issuedAt < old.executedAt) revert PlanTaken();
            old.status = Status.Closed;
            emit PlanClosed(existing, safe);
        }
        if (plan.issuedAt > block.timestamp + MAX_CLOCK_DRIFT) revert FromTheFuture();
        // A plan must not arrive already overdue: an old signed plan (e.g. one never delivered to this
        // chain) can't be replayed months later and triggered on the spot.
        if (uint256(plan.issuedAt) + plan.checkInInterval <= block.timestamp) revert StalePlan();

        _validateAndStore(planId, plan, cc);

        // lastCheckIn never moves backwards for a plan id (old check-ins can't be replayed).
        if (plan.issuedAt > s.lastCheckIn) s.lastCheckIn = plan.issuedAt;
        s.safe = safe;
        s.status = Status.Active;
        s.nonce = plan.nonce;
        s.checkInInterval = plan.checkInInterval;
        s.disputePeriod = plan.disputePeriod;
        s.verifierThreshold = plan.verifierThreshold;
        s.verifierFallback = plan.verifierFallback;
        s.relayFeeCap = cc.relayFeeCap;
        s.triggeredAt = 0;
        planOf[safe] = planId;

        emit PlanConfigured(planId, safe, plan.nonce);
        if (viaSignatures) _payRelayerFromSafe(planId, s, gasStart);
    }

    // ------------------------------------------------------------------
    // Cancel
    // ------------------------------------------------------------------

    /// @notice Cancel the calling Safe's plan (a Safe transaction). Works until execution.
    /// @param nonce must be higher than the plan's nonce and than any plan update you signed but
    ///        that may not have been delivered yet, so such an update can never revive the plan
    /// @param sweepTo if non-zero, every covered asset in the Safe is sent there; must be an owner of the Safe
    /// @param disableModule also switch this module off for the Safe
    function cancel(uint64 nonce, address sweepTo, bool disableModule) external nonReentrant {
        bytes32 planId = planOf[msg.sender];
        if (planId == bytes32(0)) revert UnknownPlan();
        State storage s = _plans[planId];
        if (nonce <= s.nonce) revert StaleNonce();
        _cancel(planId, s, nonce, sweepTo, disableModule);
    }

    /// @notice Cancel with owner signatures (relayable to every chain with one set of signatures).
    function cancelBySig(
        bytes32 planId,
        uint64 nonce,
        address sweepTo,
        bool disableModule,
        address[] calldata signers,
        bytes[] calldata signatures
    ) external nonReentrant {
        uint256 gasStart = gasleft();
        State storage s = _plans[planId];
        if (s.safe == address(0)) revert UnknownPlan();
        if (nonce <= s.nonce) revert StaleNonce();
        _checkOwnerSignatures(s.safe, cancelDigest(planId, nonce, sweepTo, disableModule), signers, signatures);
        // Fee first: after cancelling, the Safe may be swept empty and the module disabled.
        _payRelayerFromSafe(planId, s, gasStart);
        _cancel(planId, s, nonce, sweepTo, disableModule);
    }

    /// @notice The creator's cancel, valid on every chain in the plan whatever its state there:
    ///         where the plan is active it is cancelled (no sweep, module left on); where it never
    ///         arrived (or was already cancelled) the nonce is recorded, so the old signed plan can
    ///         never be configured there later. Uses the same Cancel signature as cancelBySig, by the
    ///         plan's creator (whose signature every configure requires). It can't move funds.
    ///         On a live plan it only accepts a cancel without sweep/disable, from a current owner.
    function revokeBySig(
        address creator,
        bytes32 salt,
        uint64 nonce,
        address sweepTo,
        bool disableModule,
        bytes calldata creatorSignature
    ) external nonReentrant {
        bytes32 planId = planIdOf(creator, salt);
        State storage s = _plans[planId];
        if (s.status == Status.Executed || s.status == Status.Closed) revert WrongStatus(s.status);
        if (nonce <= s.nonce) revert StaleNonce();
        if (!_isValidSig(creator, cancelDigest(planId, nonce, sweepTo, disableModule), creatorSignature)) {
            revert BadSignature();
        }
        if (s.status == Status.None) {
            s.nonce = nonce;
        } else {
            // Cancelling a live plan alone: only a creator who is still an owner, and only a cancel
            // that asked for no sweep and no disable (those must go through cancelBySig, so nobody can
            // strip them from the owners' signed cancel).
            if (sweepTo != address(0) || disableModule || !ISafe(s.safe).isOwner(creator)) revert NotAuthorized();
            _cancel(planId, s, nonce, address(0), false); // e.g. a front-run delivery of the old plan
        }
        emit PlanRevoked(planId, nonce);
    }

    // ------------------------------------------------------------------
    // Check-in
    // ------------------------------------------------------------------

    /// @notice Proof of life on this chain, sent directly by any owner of the Safe (or the Safe).
    function checkIn(bytes32 planId) external nonReentrant {
        State storage s = _plans[planId];
        if (s.safe == address(0)) revert UnknownPlan();
        if (msg.sender != s.safe && !ISafe(s.safe).isOwner(msg.sender)) revert NotAuthorized();
        if (s.status == Status.Active && s.lastCheckIn >= block.timestamp) {
            // Already checked in up to a (slightly future) signed time: nothing to do, never revert.
            emit CheckedIn(planId, msg.sender, s.lastCheckIn, false);
            return;
        }
        _checkIn(planId, s, msg.sender, uint64(block.timestamp));
    }

    /// @notice Proof of life signed once by any Safe owner, relayable to every chain.
    function checkInBySig(bytes32 planId, uint64 signedAt, address owner, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 gasStart = gasleft();
        State storage s = _plans[planId];
        if (s.safe == address(0)) revert UnknownPlan();
        if (signedAt > block.timestamp + MAX_CLOCK_DRIFT) revert FromTheFuture();
        if (!ISafe(s.safe).isOwner(owner)) revert NotAuthorized();
        if (!_isValidSig(owner, checkInDigest(planId, signedAt), signature)) revert BadSignature();
        // Store the signed time as-is so every chain records the same value.
        _checkIn(planId, s, owner, signedAt);
        _payRelayerFromSafe(planId, s, gasStart);
    }

    // ------------------------------------------------------------------
    // Verifiers / trigger / execute
    // ------------------------------------------------------------------

    /// @notice A verifier confirms directly on this chain (only once the owner is overdue).
    function confirmDeath(bytes32 planId) external nonReentrant {
        State storage s = _plans[planId];
        _confirm(planId, s, msg.sender);
    }

    /// @notice A verifier's confirmation signed once, relayable to every chain.
    ///         `epoch` is the last check-in time being confirmed after; it must match this chain.
    function confirmDeathBySig(bytes32 planId, uint64 epoch, address verifier, bytes calldata signature)
        external
        nonReentrant
    {
        uint256 gasStart = gasleft();
        State storage s = _plans[planId];
        if (epoch != s.lastCheckIn) revert WrongEpoch();
        if (!_isValidSig(verifier, confirmDigest(planId, s.nonce, epoch), signature)) revert BadSignature();
        _confirm(planId, s, verifier);
        _payRelayerFromSafe(planId, s, gasStart);
    }

    /// @notice Start the dispute window. Anyone may call once overdue and the verifier threshold
    ///         is met (with threshold 0 the switch is purely time-based). If the plan has a verifier
    ///         fallback and the owner has been overdue for that long, the threshold is not required
    ///         (e.g. every verifier lost their wallet). The dispute window still applies either way.
    function trigger(bytes32 planId) external nonReentrant {
        uint256 gasStart = gasleft();
        State storage s = _plans[planId];
        if (s.status != Status.Active) revert WrongStatus(s.status);
        _requireModuleEnabled(s.safe);
        if (!isOverdue(planId)) revert NotOverdue();
        uint8 count = confirmationCount[planId][_voteKey(s)];
        if (count < s.verifierThreshold) {
            uint64 at = fallbackAt(planId);
            if (at == 0 || block.timestamp < at) revert ThresholdNotMet();
            emit FallbackTriggered(planId, count);
        }
        _trigger(planId, s);
        _payRelayerFromSafe(planId, s, gasStart);
    }

    /// @notice When the verifier fallback opens (0 = no fallback / no plan / no verifiers needed).
    function fallbackAt(bytes32 planId) public view returns (uint64) {
        State storage s = _plans[planId];
        if (s.status == Status.None || s.verifierFallback == 0 || s.verifierThreshold == 0) return 0;
        return s.lastCheckIn + s.checkInInterval + s.verifierFallback;
    }

    // ------------------------------------------------------------------
    // Acknowledge ("I'm here / my wallet works")
    // ------------------------------------------------------------------

    /// @notice A verifier or heir confirms that they still control their wallet. Changes nothing in
    ///         the plan; it only records when they were last seen, so the owner knows they can act.
    function acknowledge(bytes32 planId) external {
        State storage s = _plans[planId];
        if (s.status != Status.Active && s.status != Status.Triggered) revert WrongStatus(s.status);
        bool asVerifier = isVerifier[planId][msg.sender];
        bool asHeir;
        Heir[] storage hs = _heirs[planId];
        for (uint256 i; i < hs.length; ++i) {
            if (hs[i].account == msg.sender) {
                asHeir = true;
                break;
            }
        }
        if (!asVerifier && !asHeir) revert NotAuthorized();
        uint64 at = uint64(block.timestamp);
        lastSeen[planId][msg.sender] = at;
        emit Acknowledged(planId, msg.sender, asVerifier, asHeir, at);
    }

    /// @notice After the dispute window, open claims. Anyone may call.
    function execute(bytes32 planId) external nonReentrant {
        uint256 gasStart = gasleft();
        State storage s = _plans[planId];
        if (s.status != Status.Triggered) revert WrongStatus(s.status);
        _requireModuleEnabled(s.safe);
        uint64 executableAt = s.triggeredAt + s.disputePeriod;
        if (block.timestamp < executableAt) revert DisputeWindowOpen(executableAt);

        _payRelayerFromSafe(planId, s, gasStart);

        s.status = Status.Executed;
        s.executedAt = uint64(block.timestamp);
        emit Executed(planId);
    }

    // ------------------------------------------------------------------
    // Claims
    // ------------------------------------------------------------------

    /// @notice Pay heir `index` what it is owed of every covered asset (tokens first, then ETH).
    ///         Anyone may call; funds only ever go to the heir's registered wallet, no fee is taken.
    ///         Can be called again later: assets that reach the Safe after execution are shared too.
    function claim(bytes32 planId, uint256 index) external nonReentrant {
        _claim(planId, index, _tokens[planId], true, 0, 0);
    }

    /// @notice Like claim, but only for the listed assets (address(0) = ETH). Lets heirs skip a
    ///         token that misbehaves so it can never block the rest of the inheritance.
    function claimAssets(bytes32 planId, uint256 index, address[] calldata assets) external nonReentrant {
        bool eth;
        address[] memory tokens = new address[](assets.length);
        uint256 n;
        for (uint256 i; i < assets.length; ++i) {
            address a = assets[i];
            for (uint256 j; j < i; ++j) {
                if (assets[j] == a) revert BadAsset();
            }
            if (a == NATIVE) {
                eth = true;
            } else {
                if (!_isCovered(planId, a)) revert BadAsset();
                tokens[n++] = a;
            }
        }
        assembly ("memory-safe") {
            mstore(tokens, n)
        }
        _claim(planId, index, tokens, eth, 0, 0);
    }

    /// @notice Claim relayed on the heir's behalf. The heir signs each relayed claim (valid on every
    ///         chain) with a max fee; the relayer's gas refund comes out of this heir's ETH only and
    ///         never exceeds that max or the plan's cap.
    function claimBySig(bytes32 planId, uint256 index, uint256 maxFee, bytes calldata heirSignature)
        external
        nonReentrant
    {
        uint256 gasStart = gasleft();
        if (index >= _heirs[planId].length) revert BadIndex();
        uint256 cn = claimNonce[planId][index];
        if (!_isValidSig(_heirs[planId][index].account, claimDigest(planId, index, cn, maxFee), heirSignature)) {
            revert BadSignature();
        }
        claimNonce[planId][index] = cn + 1;
        uint256 cap = _plans[planId].relayFeeCap;
        _claim(planId, index, _tokens[planId], true, gasStart, maxFee < cap ? maxFee : cap);
    }

    function _claim(
        bytes32 planId,
        uint256 index,
        address[] memory tokens,
        bool withEth,
        uint256 gasStart,
        uint256 feeCap
    ) internal {
        State storage s = _plans[planId];
        if (s.status != Status.Executed) revert WrongStatus(s.status);
        if (index >= _heirs[planId].length) revert BadIndex();
        address safe = s.safe;
        _requireModuleEnabled(safe);
        Heir memory h = _heirs[planId][index];

        bool paidSomething;
        for (uint256 i; i < tokens.length; ++i) {
            // Each token costs bounded gas, so require enough for it: a claim never silently skips
            // tokens because the caller sent too little gas (use claimAssets to skip a bad token).
            if (gasleft() < MIN_GAS_PER_ASSET) revert NotEnoughGas();
            if (_payToken(planId, safe, index, h, tokens[i])) paidSomething = true;
        }
        if (!withEth) return;

        // Native ETH last, so the relayer fee can be taken from it.
        uint256 amount = _owed(planId, index, h.bps, NATIVE, safe.balance);
        uint256 fee;
        if (feeCap != 0 && (paidSomething || amount != 0)) {
            fee = _gasCost(gasStart, 30_000);
            if (fee > feeCap) fee = feeCap;
            if (fee > amount) fee = amount;
        }
        if (amount == 0) return;
        uint256 toHeir = amount - fee;
        if (toHeir != 0 && !ISafe(safe).execTransactionFromModule(h.account, toHeir, "", 0)) {
            emit ShareTransferFailed(planId, index, NATIVE, h.account, toHeir); // nothing recorded: retryable
            return;
        }
        if (fee != 0) {
            if (ISafe(safe).execTransactionFromModule(msg.sender, fee, "", 0)) {
                emit RelayerPaid(planId, msg.sender, fee);
            } else if (ISafe(safe).execTransactionFromModule(h.account, fee, "", 0)) {
                toHeir += fee; // refund couldn't be delivered: the heir gets it instead
            } else {
                amount -= fee; // neither went out: it stays in the Safe and stays owed
            }
        }
        paid[planId][index][NATIVE] += amount;
        totalPaid[planId][NATIVE] += amount;
        emit ShareClaimed(planId, index, NATIVE, h.account, toHeir);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function planIdOf(address creator, bytes32 salt) public pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    function getState(bytes32 planId) external view returns (State memory) {
        return _plans[planId];
    }

    function getHeirs(bytes32 planId) external view returns (Heir[] memory) {
        return _heirs[planId];
    }

    function getVerifiers(bytes32 planId) external view returns (address[] memory) {
        return _verifiers[planId];
    }

    function getTokens(bytes32 planId) external view returns (address[] memory) {
        return _tokens[planId];
    }

    function isOverdue(bytes32 planId) public view returns (bool) {
        State storage s = _plans[planId];
        return s.status != Status.None && block.timestamp > uint256(s.lastCheckIn) + s.checkInInterval;
    }

    function currentConfirmations(bytes32 planId) external view returns (uint8) {
        return confirmationCount[planId][_voteKey(_plans[planId])];
    }

    /// @notice What heir `index` could claim of `asset` right now (0 unless executed).
    function claimable(bytes32 planId, uint256 index, address asset) external view returns (uint256) {
        State storage s = _plans[planId];
        if (s.status != Status.Executed || index >= _heirs[planId].length) return 0;
        uint256 bal;
        if (asset == NATIVE) {
            bal = s.safe.balance;
        } else {
            if (!_isCovered(planId, asset)) return 0;
            (, bal) = _tryBalanceOf(asset, s.safe);
        }
        return _owed(planId, index, _heirs[planId][index].bps, asset, bal);
    }

    // --- EIP-712 digests (what wallets sign) ---

    function hashPlan(Plan calldata plan) public view returns (bytes32) {
        return _digest(_hashPlanStruct(plan));
    }

    function checkInDigest(bytes32 planId, uint64 signedAt) public view returns (bytes32) {
        return _digest(keccak256(abi.encode(CHECKIN_TYPEHASH, planId, signedAt)));
    }

    function confirmDigest(bytes32 planId, uint64 nonce, uint64 epoch) public view returns (bytes32) {
        return _digest(keccak256(abi.encode(CONFIRM_TYPEHASH, planId, nonce, epoch)));
    }

    function claimDigest(bytes32 planId, uint256 index, uint256 nonce, uint256 maxFee) public view returns (bytes32) {
        return _digest(keccak256(abi.encode(CLAIM_TYPEHASH, planId, index, nonce, maxFee)));
    }

    function cancelDigest(bytes32 planId, uint64 nonce, address sweepTo, bool disableModule)
        public
        view
        returns (bytes32)
    {
        return _digest(keccak256(abi.encode(CANCEL_TYPEHASH, planId, nonce, sweepTo, disableModule)));
    }

    // ------------------------------------------------------------------
    // Internals: lifecycle
    // ------------------------------------------------------------------

    function _checkIn(bytes32 planId, State storage s, address owner, uint64 at) internal {
        if (s.status != Status.Active && s.status != Status.Triggered) revert WrongStatus(s.status);
        if (at <= s.lastCheckIn) revert StaleCheckIn();
        bool wasTriggered = s.status == Status.Triggered;
        s.status = Status.Active;
        s.lastCheckIn = at; // new epoch: every earlier verifier vote is void
        s.triggeredAt = 0;
        emit CheckedIn(planId, owner, at, wasTriggered);
    }

    function _confirm(bytes32 planId, State storage s, address verifier) internal {
        if (s.status != Status.Active) revert WrongStatus(s.status);
        _requireModuleEnabled(s.safe);
        if (!isVerifier[planId][verifier]) revert NotAuthorized();
        if (!isOverdue(planId)) revert NotOverdue();
        bytes32 key = _voteKey(s);
        if (hasConfirmed[planId][key][verifier]) revert AlreadyConfirmed();
        hasConfirmed[planId][key][verifier] = true;
        uint8 count = ++confirmationCount[planId][key];
        emit DeathConfirmed(planId, verifier, s.lastCheckIn, count);
        if (count >= s.verifierThreshold) _trigger(planId, s);
    }

    function _trigger(bytes32 planId, State storage s) internal {
        s.status = Status.Triggered;
        s.triggeredAt = uint64(block.timestamp);
        emit Triggered(planId, s.triggeredAt + s.disputePeriod);
    }

    function _cancel(bytes32 planId, State storage s, uint64 nonce, address sweepTo, bool disableModule) internal {
        if (s.status != Status.Active && s.status != Status.Triggered) revert WrongStatus(s.status);
        address safe = s.safe;

        // Sweep only to an owner of this chain's Safe: the same address on another chain could belong
        // to someone else (e.g. a smart wallet not deployed there). Otherwise skip the sweep but still
        // cancel, so one cancel signature works on every chain.
        // A disabled module can't move anything: still cancel, just skip the sweep.
        bool enabled = ISafe(safe).isModuleEnabled(address(this));
        if (sweepTo != address(0) && (!enabled || !ISafe(safe).isOwner(sweepTo))) {
            emit SweepSkipped(planId, sweepTo);
        } else if (sweepTo != address(0)) {
            address[] storage tokens = _tokens[planId];
            for (uint256 i; i < tokens.length; ++i) {
                if (gasleft() < MIN_GAS_PER_ASSET) revert NotEnoughGas(); // the sweep can't be skipped
                (bool okBal, uint256 bal) = _tryBalanceOf(tokens[i], safe);
                if (okBal && bal != 0) {
                    uint256 moved = _transferToken(safe, tokens[i], sweepTo, bal);
                    emit Swept(planId, tokens[i], sweepTo, moved, moved != 0);
                }
            }
            uint256 eth = safe.balance;
            if (eth != 0) {
                bool ok = ISafe(safe).execTransactionFromModule(sweepTo, eth, "", 0);
                emit Swept(planId, NATIVE, sweepTo, eth, ok);
            }
        }

        _clearVerifiers(planId);
        delete _heirs[planId];
        delete _tokens[planId];
        delete planOf[safe];
        // Keep the nonce (and the Safe binding) so old signatures can never be replayed.
        s.status = Status.None;
        s.nonce = nonce;
        s.triggeredAt = 0;
        // A cancel is an owner action: count it as proof of life so nothing revived later starts overdue.
        if (block.timestamp > s.lastCheckIn) s.lastCheckIn = uint64(block.timestamp);
        s.checkInInterval = 0;
        s.disputePeriod = 0;
        s.verifierThreshold = 0;
        s.verifierFallback = 0;
        s.relayFeeCap = 0;

        bool disabled;
        if (disableModule && enabled) disabled = _disableSelf(safe);
        emit PlanCancelled(planId, safe, nonce, sweepTo, disabled);
    }

    // ------------------------------------------------------------------
    // Internals: payments
    // ------------------------------------------------------------------

    /// @dev Heir `index` is owed bps of everything this asset ever held for the plan
    ///      (current balance + all paid out), minus what it already got; never more than the balance.
    function _owed(bytes32 planId, uint256 index, uint16 bps, address asset, uint256 bal)
        internal
        view
        returns (uint256 due)
    {
        uint256 entitled = (bal + totalPaid[planId][asset]) * bps / TOTAL_BPS;
        uint256 got = paid[planId][index][asset];
        if (entitled <= got) return 0;
        due = entitled - got;
        if (due > bal) due = bal;
    }

    function _payToken(bytes32 planId, address safe, uint256 index, Heir memory h, address token)
        internal
        returns (bool)
    {
        (bool okBal, uint256 bal) = _tryBalanceOf(token, safe);
        if (!okBal) {
            emit ShareTransferFailed(planId, index, token, h.account, 0); // retry when readable
            return false;
        }
        uint256 amount = _owed(planId, index, h.bps, token, bal);
        if (amount == 0) return false;
        uint256 moved = _transferToken(safe, token, h.account, amount);
        if (moved == 0) {
            emit ShareTransferFailed(planId, index, token, h.account, amount); // retryable
            return false;
        }
        // Record what actually left the Safe, so a misreported transfer can't be paid twice.
        paid[planId][index][token] += moved;
        totalPaid[planId][token] += moved;
        emit ShareClaimed(planId, index, token, h.account, moved);
        return true;
    }

    /// @dev Transfer via the Safe and measure the Safe's balance before/after, instead of trusting the
    ///      token's return value (handles no-return, false-returning, oddly-returning and hostile tokens).
    ///      Returns how much actually left the Safe (capped at `amount`).
    function _transferToken(address safe, address token, address to, uint256 amount) internal returns (uint256) {
        (bool okBefore, uint256 before) = _tryBalanceOf(token, safe);
        if (!okBefore) return 0;
        bytes memory data = abi.encodeCall(
            ISafe.execTransactionFromModule, (token, 0, abi.encodeWithSelector(0xa9059cbb, to, amount), 0)
        );
        uint256 g = TOKEN_CALL_GAS;
        bool ok;
        assembly ("memory-safe") {
            // Bounded gas, and only the Safe's 32-byte bool is read back.
            ok := call(g, safe, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            if ok { ok := iszero(iszero(mload(0x00))) }
        }
        if (!ok) return 0;
        (bool okAfter, uint256 afterBal) = _tryBalanceOf(token, safe);
        if (!okAfter) return amount; // the call succeeded; assume it did what it said
        if (afterBal >= before) return 0;
        uint256 moved = before - afterBal;
        return moved > amount ? amount : moved;
    }

    /// @dev Refund the caller's gas from the Safe's ETH, capped by the plan. Never reverts.
    function _payRelayerFromSafe(bytes32 planId, State storage s, uint256 gasStart) internal {
        uint256 cap = s.relayFeeCap;
        if (cap == 0) return;
        uint256 fee = _gasCost(gasStart, 25_000);
        if (fee > cap) fee = cap;
        address safe = s.safe;
        if (fee == 0 || fee > safe.balance) return;
        if (!ISafe(safe).isModuleEnabled(address(this))) return;
        if (ISafe(safe).execTransactionFromModule(msg.sender, fee, "", 0)) emit RelayerPaid(planId, msg.sender, fee);
    }

    /// @dev Gas used times a gas price the relayer can't inflate (at most basefee + MAX_PRIORITY_FEE).
    function _gasCost(uint256 gasStart, uint256 extra) internal view returns (uint256) {
        uint256 price = tx.gasprice;
        uint256 ceiling = block.basefee + MAX_PRIORITY_FEE;
        if (price > ceiling) price = ceiling;
        return (gasStart - gasleft() + FEE_GAS_OVERHEAD + extra) * price;
    }

    function _requireModuleEnabled(address safe) internal view {
        if (!ISafe(safe).isModuleEnabled(address(this))) revert ModuleNotEnabled();
    }

    function _isCovered(bytes32 planId, address token) internal view returns (bool) {
        address[] storage t = _tokens[planId];
        for (uint256 i; i < t.length; ++i) {
            if (t[i] == token) return true;
        }
        return false;
    }

    function _disableSelf(address safe) internal returns (bool) {
        address prev = SENTINEL_MODULES;
        address start = SENTINEL_MODULES;
        for (uint256 page; page < 20; ++page) {
            (address[] memory mods, address next) = ISafe(safe).getModulesPaginated(start, 50);
            for (uint256 i; i < mods.length; ++i) {
                if (mods[i] == address(this)) {
                    // The Safe calling itself is allowed to disable a module.
                    return ISafe(safe).execTransactionFromModule(
                        safe, 0, abi.encodeWithSignature("disableModule(address,address)", prev, address(this)), 0
                    );
                }
                prev = mods[i];
            }
            if (next == SENTINEL_MODULES || next == address(0)) break;
            start = next;
        }
        return false;
    }

    /// @dev balanceOf with bounded gas and at most 32 bytes of return data copied.
    function _tryBalanceOf(address token, address account) internal view returns (bool ok, uint256 bal) {
        bytes memory data = abi.encodeCall(IERC20Balance.balanceOf, (account));
        uint256 g = BALANCE_GAS;
        assembly ("memory-safe") {
            ok := staticcall(g, token, add(data, 0x20), mload(data), 0x00, 0x20)
            if lt(returndatasize(), 0x20) { ok := 0 }
            bal := mload(0x00)
        }
        if (!ok) bal = 0;
    }

    // ------------------------------------------------------------------
    // Internals: config + signatures
    // ------------------------------------------------------------------

    function _localChain(ChainConfig[] calldata chains) internal view returns (uint256 idx) {
        uint256 n = chains.length;
        if (n == 0 || n > MAX_CHAINS) revert InvalidConfig(3);
        bool found;
        for (uint256 i; i < n; ++i) {
            for (uint256 j; j < i; ++j) {
                if (chains[j].chainId == chains[i].chainId) revert InvalidConfig(4);
            }
            if (chains[i].safe == address(0)) revert InvalidConfig(5);
            if (chains[i].chainId == block.chainid) {
                idx = i;
                found = true;
            }
        }
        if (!found) revert ChainNotInPlan();
    }

    function _validateAndStore(bytes32 planId, Plan calldata plan, ChainConfig calldata cc) internal {
        if (plan.checkInInterval < minCheckInInterval) revert InvalidConfig(6);
        if (plan.disputePeriod < minDisputePeriod) revert InvalidConfig(7);
        if (plan.checkInInterval > MAX_INTERVAL) revert InvalidConfig(8);
        if (plan.disputePeriod > MAX_DISPUTE) revert InvalidConfig(9);
        if (plan.verifierFallback != 0) {
            if (plan.verifierThreshold == 0) revert InvalidConfig(10);
            if (plan.verifierFallback < minDisputePeriod) revert InvalidConfig(11);
            if (plan.verifierFallback > MAX_FALLBACK) revert InvalidConfig(12);
        }

        // heirs
        uint256 n = plan.heirs.length;
        if (n == 0 || n > MAX_HEIRS) revert InvalidConfig(13);
        delete _heirs[planId];
        uint256 total;
        for (uint256 i; i < n; ++i) {
            Heir calldata h = plan.heirs[i];
            if (h.account == address(0) || h.account == cc.safe || h.account == address(this)) {
                revert InvalidConfig(14);
            }
            if (h.bps == 0) revert InvalidConfig(15);
            for (uint256 j; j < i; ++j) {
                if (plan.heirs[j].account == h.account) revert InvalidConfig(16);
            }
            total += h.bps;
            _heirs[planId].push(h);
        }
        if (total != TOTAL_BPS) revert InvalidConfig(17);

        // verifiers
        uint256 vn = plan.verifiers.length;
        if (vn > MAX_VERIFIERS) revert InvalidConfig(18);
        if (plan.verifierThreshold > vn) revert InvalidConfig(19);
        _clearVerifiers(planId);
        for (uint256 i; i < vn; ++i) {
            address v = plan.verifiers[i];
            if (v == address(0) || v == cc.safe || v == address(this)) revert InvalidConfig(20);
            if (isVerifier[planId][v]) revert InvalidConfig(21);
            isVerifier[planId][v] = true;
            _verifiers[planId].push(v);
        }

        // tokens on this chain
        uint256 tn = cc.tokens.length;
        if (tn > MAX_TOKENS) revert InvalidConfig(22);
        delete _tokens[planId];
        for (uint256 i; i < tn; ++i) {
            address t = cc.tokens[i];
            if (t == address(0) || t == cc.safe || t == address(this) || t.code.length == 0) {
                revert InvalidConfig(23);
            }
            for (uint256 j; j < i; ++j) {
                if (cc.tokens[j] == t) revert InvalidConfig(24);
            }
            _tokens[planId].push(t);
        }
    }

    function _clearVerifiers(bytes32 planId) internal {
        address[] storage old = _verifiers[planId];
        for (uint256 i; i < old.length; ++i) {
            isVerifier[planId][old[i]] = false;
        }
        delete _verifiers[planId];
    }

    /// @dev Distinct Safe owners, each with a valid signature, at least the Safe's threshold.
    function _checkOwnerSignatures(
        address safe,
        bytes32 digest,
        address[] calldata signers,
        bytes[] calldata signatures
    ) internal view {
        uint256 n = signers.length;
        if (n != signatures.length) revert BadSignature();
        if (n < ISafe(safe).getThreshold()) revert NotEnoughSigners();
        for (uint256 i; i < n; ++i) {
            address signer = signers[i];
            for (uint256 j; j < i; ++j) {
                if (signers[j] == signer) revert BadSignature();
            }
            if (!ISafe(safe).isOwner(signer)) revert NotAuthorized();
            if (!_isValidSig(signer, digest, signatures[i])) revert BadSignature();
        }
    }

    /// @dev `who` must be among `signers` with a valid signature over `digest`.
    function _requireSignedBy(address who, bytes32 digest, address[] calldata signers, bytes[] calldata signatures)
        internal
        view
    {
        if (signers.length != signatures.length) revert BadSignature();
        for (uint256 i; i < signers.length; ++i) {
            if (signers[i] == who) {
                if (!_isValidSig(who, digest, signatures[i])) revert BadSignature();
                return;
            }
        }
        revert NotAuthorized();
    }

    /// @dev Plain ECDSA first (also covers EIP-7702 delegated wallets), then EIP-1271 for contract signers.
    function _isValidSig(address signer, bytes32 digest, bytes memory signature) internal view returns (bool) {
        if (signer == address(0)) return false;
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err == ECDSA.RecoverError.NoError && recovered == signer) return true;
        return signer.code.length != 0 && SignatureChecker.isValidERC1271SignatureNow(signer, digest, signature);
    }

    function _voteKey(State storage s) internal view returns (bytes32) {
        return keccak256(abi.encode(s.nonce, s.lastCheckIn));
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
    }

    function _hashPlanStruct(Plan calldata p) internal pure returns (bytes32) {
        bytes32[] memory heirHashes = new bytes32[](p.heirs.length);
        for (uint256 i; i < p.heirs.length; ++i) {
            heirHashes[i] = keccak256(abi.encode(HEIR_TYPEHASH, p.heirs[i].account, p.heirs[i].bps));
        }
        bytes32[] memory chainHashes = new bytes32[](p.chains.length);
        for (uint256 i; i < p.chains.length; ++i) {
            ChainConfig calldata c = p.chains[i];
            chainHashes[i] = keccak256(
                abi.encode(CHAIN_TYPEHASH, c.chainId, c.safe, c.relayFeeCap, keccak256(abi.encodePacked(c.tokens)))
            );
        }
        return keccak256(
            abi.encode(
                PLAN_TYPEHASH,
                p.creator,
                p.salt,
                p.nonce,
                p.issuedAt,
                p.checkInInterval,
                p.disputePeriod,
                keccak256(abi.encodePacked(heirHashes)),
                keccak256(abi.encodePacked(p.verifiers)),
                p.verifierThreshold,
                p.verifierFallback,
                keccak256(abi.encodePacked(chainHashes))
            )
        );
    }
}
