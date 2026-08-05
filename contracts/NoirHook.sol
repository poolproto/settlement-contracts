// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NoirHook
/// @author Noir Protocol
/// @notice A Uniswap v4 hook that intercepts swaps and fills against the Noir CLOB
///         orderbook when resting limit orders offer a better price than the AMM curve.
///
/// ## Architecture Note
///
/// In Uniswap v4, each pool has exactly ONE hook. This means NoirHook can only be
/// attached to pools that Noir Protocol deploys itself — it cannot be retroactively
/// added to external pools (e.g., pools created via pools.trade or other factories).
///
/// For external v4 pools, Noir connects via `NoirRouter.sol`, which calls
/// `IPoolManager.swap()` directly. The router is permissionless and works with any
/// pool regardless of its hook configuration.
///
/// Summary of the two integration paths:
///
///   ┌──────────────────┐     ┌──────────────────────────────────┐
///   │  Noir-owned pool │     │  External pool (pools.trade etc) │
///   │  hook = NoirHook │     │  hook = anything / none          │
///   │                  │     │                                  │
///   │  beforeSwap ───► │     │  NoirRouter calls swap() ──────► │
///   │  fills vs CLOB   │     │  remainder after CLOB match      │
///   └──────────────────┘     └──────────────────────────────────┘
///
/// @dev The hook uses `beforeSwap` to check the off-chain orderbook (via the
///      registered operator) and returns a `BeforeSwapDelta` that reduces the
///      swap amount by whatever the CLOB matched, so the AMM curve only prices
///      the true remainder.
contract NoirHook is IHooks {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Constants & Immutables
    // ──────────────────────────────────────────────

    IPoolManager public immutable poolManager;

    /// @notice The operator is the only address that can submit CLOB fill results.
    ///         This is Noir's relayer — the off-chain matching engine.
    address public operator;
    address public owner;

    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    /// @notice Describes how much of an incoming swap the CLOB can fill.
    /// @param amountFilled  Quantity the orderbook matched (same sign convention as amountSpecified).
    /// @param price         The CLOB fill price (informational, for event logging).
    struct CLOBFill {
        int128 amountFilled;
        uint160 price;
    }

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @dev The operator stages a fill here before the swap tx is submitted.
    ///      Keyed by PoolId so fills are scoped to a specific pool.
    mapping(PoolId => CLOBFill) public pendingFills;

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event CLOBFillApplied(
        PoolId indexed poolId,
        int128 amountFilled,
        uint160 price
    );

    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error OnlyPoolManager();
    error OnlyOperator();
    error OnlyOwner();

    // ──────────────────────────────────────────────
    //  Modifiers
    // ──────────────────────────────────────────────

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != operator) revert OnlyOperator();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    constructor(IPoolManager _poolManager, address _operator) {
        poolManager = _poolManager;
        operator = _operator;
        owner = msg.sender;
    }

    // ──────────────────────────────────────────────
    //  Operator Interface
    // ──────────────────────────────────────────────

    /// @notice Stages a CLOB fill for the next swap on a given pool.
    /// @dev Called by the Noir relayer in the same tx (or a preceding tx in the
    ///      same block) as the user's swap. The fill is consumed in `beforeSwap`.
    function stageFill(PoolKey calldata key, CLOBFill calldata fill) external onlyOperator {
        pendingFills[key.toId()] = fill;
    }

    /// @notice Updates the operator address.
    function setOperator(address _operator) external onlyOwner {
        emit OperatorUpdated(operator, _operator);
        operator = _operator;
    }

    // ──────────────────────────────────────────────
    //  Hook Callbacks
    // ──────────────────────────────────────────────

    /// @notice Called by the PoolManager before executing a swap.
    /// @dev If the CLOB has a pending fill for this pool, we return a
    ///      `BeforeSwapDelta` that tells the PoolManager to skip the filled
    ///      portion. The AMM curve only prices the remainder.
    function beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        CLOBFill memory fill = pendingFills[id];

        // If no staged fill, let the full amount go through the AMM.
        if (fill.amountFilled == 0) {
            return (IHooks.beforeSwap.selector, BeforeSwapDelta.wrap(0), 0);
        }

        // Clear the staged fill (single use).
        delete pendingFills[id];

        // The fill.amountFilled reduces what the AMM needs to process.
        // toBeforeSwapDelta(specifiedDelta, unspecifiedDelta):
        //   - specifiedDelta: how much of amountSpecified the hook handles (negative = hook takes input)
        //   - unspecifiedDelta: how much output the hook provides (positive = hook gives output)
        //
        // For an exact-input swap (amountSpecified < 0), the hook handles part of the input
        // and provides the corresponding output from the CLOB fill.
        BeforeSwapDelta delta;
        if (params.amountSpecified < 0) {
            // Exact input: hook takes `amountFilled` of input, provides output at CLOB price.
            // The remaining (amountSpecified + amountFilled) goes to the AMM curve.
            delta = toBeforeSwapDelta(
                fill.amountFilled, // specified delta (how much input the hook absorbs)
                -fill.amountFilled // unspecified delta (output the hook provides — simplified 1:1 for clarity)
            );
        } else {
            // Exact output: hook provides `amountFilled` of the requested output.
            delta = toBeforeSwapDelta(
                -fill.amountFilled, // hook provides this much output
                fill.amountFilled   // and requires this much input
            );
        }

        emit CLOBFillApplied(id, fill.amountFilled, fill.price);

        return (IHooks.beforeSwap.selector, delta, 0);
    }

    /// @notice Returns the hook's permission flags.
    /// @dev Only `beforeSwap` is enabled. All other hooks are no-ops.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ──────────────────────────────────────────────
    //  No-op Hooks (required by IHooks interface)
    // ──────────────────────────────────────────────

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, int128) {
        return (IHooks.afterSwap.selector, 0);
    }

    function beforeInitialize(address, PoolKey calldata, uint160) external pure override returns (bytes4) {
        return IHooks.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure override returns (bytes4) {
        return IHooks.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) {
        return IHooks.beforeAddLiquidity.selector;
    }

    function afterAddLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, bytes calldata)
        external pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function afterRemoveLiquidity(address, PoolKey calldata, IPoolManager.ModifyLiquidityParams calldata, BalanceDelta, BalanceDelta, bytes calldata)
        external pure override returns (bytes4, BalanceDelta) {
        return (IHooks.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) {
        return IHooks.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external pure override returns (bytes4) {
        return IHooks.afterDonate.selector;
    }
}