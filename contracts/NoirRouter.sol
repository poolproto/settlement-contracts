// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title NoirRouter
/// @author Noir Protocol
/// @notice Routes the unfilled remainder of a CLOB order into a Uniswap v4 pool.
///
/// Flow:
///   1. The off-chain matching engine fills as much as possible against resting
///      limit orders on the CLOB.
///   2. Any unmatched quantity is forwarded here.
///   3. This contract calls `IPoolManager.swap()` on the specified v4 pool,
///      converting the remainder at the current AMM curve price.
///
/// This router is permissionless — it works with ANY Uniswap v4 pool, including
/// pools deployed via pools.trade or any other v4 pool factory. No special hook
/// or permission is required on the target pool.
///
/// @dev EIP-712 domain uses chainId 4663 (Robinhood Chain).
contract NoirRouter {
    using SafeERC20 for IERC20;

    // ──────────────────────────────────────────────
    //  Constants
    // ──────────────────────────────────────────────

    IPoolManager public immutable poolManager;

    bytes32 public constant ROUTE_TYPEHASH = keccak256(
        "RouteOrder(address trader,address tokenIn,address tokenOut,uint256 amountIn,uint256 minAmountOut,uint24 fee,int24 tickSpacing,address hooks,uint256 nonce,uint256 deadline)"
    );

    bytes32 public immutable DOMAIN_SEPARATOR;

    // ──────────────────────────────────────────────
    //  State
    // ──────────────────────────────────────────────

    /// @notice Tracks used nonces per trader to prevent replay.
    mapping(address => mapping(uint256 => bool)) public usedNonces;

    // ──────────────────────────────────────────────
    //  Types
    // ──────────────────────────────────────────────

    /// @param trader      The address whose funds are being routed.
    /// @param tokenIn     The token the trader is selling.
    /// @param tokenOut    The token the trader is buying.
    /// @param amountIn    Remaining quantity to fill (after CLOB matching).
    /// @param minAmountOut Minimum acceptable output (slippage protection).
    /// @param fee         Pool fee tier.
    /// @param tickSpacing Pool tick spacing.
    /// @param hooks       Hook address on the target pool (address(0) if none).
    /// @param nonce       Replay-protection nonce.
    /// @param deadline    Unix timestamp after which this route is invalid.
    /// @param signature   EIP-712 signature from the trader.
    struct RouteOrder {
        address trader;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    // ──────────────────────────────────────────────
    //  Events
    // ──────────────────────────────────────────────

    event Routed(
        address indexed trader,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        int256 amountOut
    );

    // ──────────────────────────────────────────────
    //  Errors
    // ──────────────────────────────────────────────

    error DeadlinePassed();
    error NonceAlreadyUsed();
    error InvalidSignature();
    error InsufficientOutput();

    // ──────────────────────────────────────────────
    //  Constructor
    // ──────────────────────────────────────────────

    constructor(IPoolManager _poolManager) {
        poolManager = _poolManager;

        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("NoirRouter"),
                keccak256("1"),
                uint256(4663), // Robinhood Chain
                address(this)
            )
        );
    }

    // ──────────────────────────────────────────────
    //  External
    // ──────────────────────────────────────────────

    /// @notice Routes an unfilled order remainder through a Uniswap v4 pool.
    /// @dev Called by the Noir relayer after partial CLOB fills.
    ///      The trader must have approved this contract for `amountIn` of `tokenIn`.
    function route(RouteOrder calldata order) external returns (BalanceDelta delta) {
        // --- Checks ---
        if (block.timestamp > order.deadline) revert DeadlinePassed();
        if (usedNonces[order.trader][order.nonce]) revert NonceAlreadyUsed();

        bytes32 structHash = keccak256(
            abi.encode(
                ROUTE_TYPEHASH,
                order.trader,
                order.tokenIn,
                order.tokenOut,
                order.amountIn,
                order.minAmountOut,
                order.fee,
                order.tickSpacing,
                order.hooks,
                order.nonce,
                order.deadline
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address signer = _recover(digest, order.signature);
        if (signer != order.trader) revert InvalidSignature();

        // --- Effects ---
        usedNonces[order.trader][order.nonce] = true;

        // --- Interactions ---
        // Pull tokenIn from the trader.
        IERC20(order.tokenIn).safeTransferFrom(order.trader, address(this), order.amountIn);

        // Build the v4 PoolKey. Currency.wrap(address) maps an ERC-20 to a v4 Currency.
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(order.tokenIn < order.tokenOut ? order.tokenIn : order.tokenOut),
            currency1: Currency.wrap(order.tokenIn < order.tokenOut ? order.tokenOut : order.tokenIn),
            fee: order.fee,
            tickSpacing: order.tickSpacing,
            hooks: IHooks(order.hooks)
        });

        // Determine swap direction: zeroForOne = true when selling currency0.
        bool zeroForOne = order.tokenIn < order.tokenOut;

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(order.amountIn), // Negative = exact-input
            sqrtPriceLimitX96: zeroForOne
                ? TickMath.MIN_SQRT_PRICE + 1
                : TickMath.MAX_SQRT_PRICE - 1
        });

        // Approve the PoolManager to take tokenIn.
        IERC20(order.tokenIn).forceApprove(address(poolManager), order.amountIn);

        delta = poolManager.swap(key, params, "");

        // Verify slippage. amount1() is positive when we receive tokens.
        uint256 received = uint256(zeroForOne ? int256(delta.amount1()) : int256(delta.amount0()));
        if (received < order.minAmountOut) revert InsufficientOutput();

        // Transfer output tokens to the trader.
        IERC20(order.tokenOut).safeTransfer(order.trader, received);

        emit Routed(order.trader, order.tokenIn, order.tokenOut, order.amountIn, zeroForOne ? delta.amount1() : delta.amount0());
    }

    // ──────────────────────────────────────────────
    //  Internal
    // ──────────────────────────────────────────────

    /// @dev Recovers the signer from a 65-byte ECDSA signature.
    function _recover(bytes32 digest, bytes calldata sig) internal pure returns (address) {
        require(sig.length == 65, "invalid sig length");
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 0x20))
            v := byte(0, calldataload(add(sig.offset, 0x40)))
        }
        return ecrecover(digest, v, r, s);
    }
}

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";