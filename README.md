# settlement-contracts

On-chain settlement layer for Noir Protocol.

Non-custodial. Nothing moves unless both sides signed for it.

## Architecture

The matching engine runs off-chain. When two orders cross, the engine produces a `SettlementBatch` — the trade parameters signed by both buyer and seller. The `Settlement` contract verifies both signatures and atomically transfers assets.

```
off-chain matching engine
        ↓
  SettlementBatch (both sigs)
        ↓
  Settlement.settle()
        ↓
  asset → buyer
  collateral → seller
```

No funds ever pass through Noir Protocol. The contract transfers directly between counterparties.

## Contract

`contracts/Settlement.sol`

- `settle(batch)` — verifies EIP-712 signatures from both parties, executes atomic swap
- `cancel(tradeId)` — either party can cancel before settlement
- `settled[id]` / `cancelled[id]` — public state, fully auditable

## Deploy

```bash
# using Foundry
forge build
forge deploy --rpc-url $RPC_URL contracts/Settlement.sol:Settlement
```

## Security

- No admin keys, no upgradeable proxy
- Each trade is a one-time `bytes32 tradeId` — replay-proof
- Deadline enforced on-chain
- Pure EIP-712 signature verification — no trusted oracle

## License

MIT
