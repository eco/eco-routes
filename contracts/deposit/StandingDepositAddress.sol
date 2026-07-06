// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IIntentSource} from "../interfaces/IIntentSource.sol";

/**
 * @title StandingDepositAddress
 * @notice Thin base for the STANDING (streaming/flash) deposit-address templates: ONE standing intent per
 *         deposit address, drawn down per deposit rather than a FRESH one-shot intent per deposit.
 * @dev A deliberately separate base from {BaseDepositAddress} (which the three immutable one-shot templates
 *      inherit and which is NOT modified here — deposit clones are immutable CREATE2, so migration ships
 *      NEW templates). It captures ONLY the cross-family common surface: init, the direct-transfer top-up
 *      (`sweep`/`fundPool`), the pool-account view, the salt-epoch scheme, and the keeper `reopen`.
 *
 *      TOP-UP MECHANIC: once the standing intent is `Funded`, {IIntentSource-fund} is a silent no-op
 *      (`onlyFundable`), so a per-deposit top-up MUST be a DIRECT TRANSFER into the escrow pool Account.
 *      Users send tokens to this stable clone (their CEX-withdrawal address); `sweep`/`fundPool` moves the
 *      clone's whole balance into the CURRENT-epoch pool Account. Draw-down is solver/operator-driven off
 *      this contract (the flash policy's `flashSlice` / the streaming policy's settle path).
 *
 *      SALT-EPOCH: the standing intent's route salt is `keccak256(abi.encode(address(this), epoch))`
 *      (deterministic — no `block.timestamp`, so the hash and pool address are stable and collision-free).
 *      Because {IIntentSource-closeStream} is terminal (`Refunded`) and a `Refunded` hash can never be
 *      re-published, a keeper `reopen` (bump `epoch`) is the only restart path.
 */
abstract contract StandingDepositAddress is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ============ Storage ============

    /// @notice User's destination address on the target chain (bytes32 for cross-VM compatibility).
    bytes32 public destinationAddress;

    /// @notice Depositor on the source chain: the keeper (refunds via closeStream, reopen authority).
    address public depositor;

    /// @notice Initialization flag.
    bool public initialized;

    /// @notice Current salt epoch. Bumped by {reopen} after the prior epoch's streams are terminal.
    uint256 public epoch;

    // ============ Errors ============

    error AlreadyInitialized();
    error NotInitialized();
    error OnlyFactory();
    error InvalidDestinationAddress();
    error InvalidDepositor();
    error InvalidFunder();
    error NotKeeper();
    /// @notice `reopen` attempted while a current-epoch (source-chain) intent is not yet `Refunded`.
    error EpochNotClosed(bytes32 intentHash);

    // ============ Init ============

    /**
     * @notice Initialize the deposit address (called once by the factory after CREATE2 deployment).
     * @param _destinationAddress User's destination address (bytes32 for cross-VM compatibility).
     * @param _depositor Keeper/refund recipient on the source chain.
     */
    function initialize(
        bytes32 _destinationAddress,
        address _depositor
    ) external {
        if (initialized) revert AlreadyInitialized();
        if (msg.sender != _factory()) revert OnlyFactory();
        if (_destinationAddress == bytes32(0)) {
            revert InvalidDestinationAddress();
        }
        if (_depositor == address(0)) revert InvalidDepositor();

        destinationAddress = _destinationAddress;
        depositor = _depositor;
        initialized = true;
    }

    // ============ Top-up (direct transfer) ============

    /**
     * @notice Permissionless top-up: move the clone's ENTIRE source-token balance into the current-epoch
     *         pool Account by direct transfer (the only working top-up for a `Funded` standing intent).
     */
    function sweep() external nonReentrant {
        _sweep();
    }

    /// @notice Alias of {sweep} (funding vocabulary).
    function fundPool() external nonReentrant {
        _sweep();
    }

    /**
     * @notice Top-up funded via ERC-20 approval: pull `min(allowance, balance)` from `funder` into the
     *         clone, then sweep the whole balance into the pool Account (preserves the one-shot templates'
     *         `createIntentWithApproval` semantics).
     * @param funder Address that approved this contract to spend its tokens.
     */
    function fundPoolWithApproval(address funder) external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (funder == address(0)) revert InvalidFunder();

        address token = _sourceToken();
        uint256 allowance = IERC20(token).allowance(funder, address(this));
        uint256 balance = IERC20(token).balanceOf(funder);
        uint256 amount = allowance < balance ? allowance : balance;
        if (amount > 0) {
            IERC20(token).safeTransferFrom(funder, address(this), amount);
        }
        _sweep();
    }

    /// @notice The current-epoch pool Account that deposits are swept into (the source escrow Account).
    function poolAccount() external view returns (address) {
        return _depositPoolAccount();
    }

    // ============ Epoch lifecycle ============

    /**
     * @notice Rotate to a fresh epoch after the current epoch's (source-chain) standing intents are
     *         terminal, then re-open the streams under the new salt.
     * @dev Keeper-only (`depositor`). Requires every hash returned by {_currentEpochIntentHashes} — the
     *      intents whose escrow is reclaimable ON THIS chain — to be `Refunded` (i.e. the keeper has run
     *      the source-side {IIntentSource-closeStream}). Cross-chain legs (e.g. a destination-chain pool)
     *      are reclaimed separately on their own chain and are NOT gated here (their status is not readable
     *      on this chain — see the template docs).
     */
    function reopen() external nonReentrant {
        if (!initialized) revert NotInitialized();
        if (msg.sender != depositor) revert NotKeeper();

        IIntentSource src = IIntentSource(_portalAddress());
        bytes32[] memory hashes = _currentEpochIntentHashes();
        for (uint256 i; i < hashes.length; ++i) {
            if (src.getRewardStatus(hashes[i]) != IIntentSource.Status.Refunded) {
                revert EpochNotClosed(hashes[i]);
            }
        }

        unchecked {
            epoch += 1;
        }
        _open();
    }

    // ============ Internal ============

    /// @notice Uniform deterministic salt for the current epoch's route(s).
    function _saltForEpoch() internal view returns (bytes32) {
        return keccak256(abi.encode(address(this), epoch));
    }

    function _sweep() internal {
        if (!initialized) revert NotInitialized();
        address token = _sourceToken();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal > 0) {
            IERC20(token).safeTransfer(_depositPoolAccount(), bal);
        }
    }

    // ---- Family hooks ----------------------------------------------------

    /// @notice Factory that deployed this clone (init authority).
    function _factory() internal view virtual returns (address);

    /// @notice The Portal (PortalProxy) this family's intents anchor to.
    function _portalAddress() internal view virtual returns (address);

    /// @notice The source token users deposit (swept into the pool).
    function _sourceToken() internal view virtual returns (address);

    /// @notice The current-epoch pool Account deposits are swept into.
    function _depositPoolAccount() internal view virtual returns (address);

    /// @notice The current-epoch intent hashes whose escrow is reclaimable on THIS chain (gate for reopen).
    function _currentEpochIntentHashes()
        internal
        view
        virtual
        returns (bytes32[] memory);

    /// @notice (Re)publish/fund the current-epoch standing intent(s). Idempotent.
    function _open() internal virtual;
}
