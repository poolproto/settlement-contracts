# settlement-contracts

On-chain infrastructure for Pool Protocol — a CLOB matching engine for tokenized equities on Robinhood Chain (chain ID 4663).

**Pool is liquidity. Orderbook is the market on top.**

The matching engine runs off-chain. When two orders cross, the engine fills against resting limit orders on the CLOB first. Any unfilled remainder routes through Uniswap v4 pools for immediate execution at the AMM curve price.

## Architecture

```
         incoming order
              │
     ┌────────┴────────┐
     │  CLOB matching   │  ← off-chain engine matches against resting limit orders
     │  engine          │
     └────────┬────────┘
              │
      ┌───────┴───────┐
      │               │
  filled           remainder
      │               │
      ▼               ▼
 Settlement.sol   PoolRouter.sol
 (atomic swap)    (swap via v4 pool)
```

For Pool's own pools, `PoolHook` intercepts swaps at the v4 level and fills against the CLOB before the AMM curve is touched — giving limit-order traders priority over passive LPs.

## Contracts

### `contracts/Settlement.sol`

Settles matched CLOB trades. Both buyer and seller sign an EIP-712 `SettlementBatch`; the contract verifies signatures and atomically transfers assets. No funds pass through Pool — transfers go directly between counterparties.

- `settle(batch)` — verifies both EIP-712 signatures, executes atomic swap
- `cancel(tradeId)` — either party can cancel before settlement
- `settled[id]` / `cancelled[id]` — public state, fully auditable

### `contracts/PoolRouter.sol`

Routes unfilled order remainders into Uniswap v4 pools. Works with any v4 pool permissionlessly — including pools deployed via pools.trade or any other v4 pool factory.

- Accepts a signed `RouteOrder` (EIP-712, chainId 4663) with the unmatched quantity
- Calls `IPoolManager.swap()` on the specified pool
- Enforces slippage protection via `minAmountOut`
- Replay-protected via per-trader nonces

### `contracts/PoolHook.sol`

A Uniswap v4 hook that intercepts `beforeSwap` and fills against the CLOB orderbook when resting limit orders offer a better price than the curve.

- Returns `BeforeSwapDelta` to skip the AMM for the CLOB-matched portion
- Only active on Pool-deployed pools (v4 pools accept exactly one hook)
- For external pools, Pool connects via the Router instead

## Integration Paths

| Pool type | Integration | How it works |
|-----------|------------|--------------|
| Pool-owned pool | `PoolHook` (beforeSwap) | Hook intercepts swaps, fills vs CLOB first, remainder hits AMM |
| External pool (pools.trade, etc.) | `PoolRouter` | Router calls `IPoolManager.swap()` after CLOB matching |

Pool routes through Uniswap v4 pools — this is permissionless, like deploying on Ethereum. No partnership or special access required.

## Build & Test

```bash
# Install dependencies
forge install

# Build
forge build

# Test
forge test
```

## Security

- No admin keys, no upgradeable proxy on Settlement
- Each trade is a one-time `bytes32 tradeId` — replay-proof
- Deadline enforced on-chain
- Pure EIP-712 signature verification — no trusted oracle
- PoolHook operator is the only permissioned role (the relayer that stages CLOB fills)

## License

MIT