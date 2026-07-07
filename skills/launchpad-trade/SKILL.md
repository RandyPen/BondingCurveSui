---
name: launchpad-trade
description: Build buy/sell PTBs against BondingCurveSui pools with the @mysten/sui TypeScript SDK — quoting with slippage, coin preparation, the atomic drain-buy+migrate pattern, and parsing results. Use when implementing trading in a web frontend or an autonomous agent.
---

# Trading on the bonding curve (PTB construction)

IDs from `deployments.json`: `<PKG>` = launchpadPackage, `<CFG>` = launchpadConfig; `CLOCK = 0x6`. Type args are always `[BASE_TYPE, QUOTE_TYPE]` in that order.

Pools trade only in the `TRADING` phase (`Pool.phase == 0`). Trading fee (default 1%) is taken in quote; amounts below are raw units.

## Quote first (slippage protection is mandatory)

`pool::quote_buy(pool, gross_quote_in): (base_out, fee)` and `pool::quote_sell(pool, base_in): (net_quote_out, fee)` are on-chain views matching execution exactly (including the completing-buy clamp). They return `(0,0)` when not TRADING. Call via devInspect:

```ts
import { Transaction } from '@mysten/sui/transactions';
import { bcs } from '@mysten/sui/bcs';

async function quoteBuy(grossIn: bigint): Promise<{ out: bigint; fee: bigint }> {
  const tx = new Transaction();
  tx.moveCall({
    target: `${PKG}::pool::quote_buy`,
    typeArguments: [BASE, QUOTE],
    arguments: [tx.object(POOL_ID), tx.pure.u64(grossIn)],
  });
  const r = await client.devInspectTransactionBlock({ sender, transactionBlock: tx });
  const [outBytes, feeBytes] = r.results![0].returnValues!;
  return { out: bcs.u64().parse(Uint8Array.from(outBytes[0])),
           fee: bcs.u64().parse(Uint8Array.from(feeBytes[0])) };
}
// minOut = out * (10000n - slippageBps) / 10000n
```

## Buy

`pool::buy(cfg, pool, quote_in: Coin<Quote>, min_base_out: u64, clock, ctx): (Coin<Base>, Coin<Quote>)` — gross input (fee comes out of it); the second return is change, nonzero **only** on the buy that completes the curve.

```ts
import { coinWithBalance } from '@mysten/sui/transactions';

const tx = new Transaction();
tx.setSender(sender);
// SUI quote: split from gas. Other quotes: coinWithBalance selects+merges.
const payment = QUOTE === '0x2::sui::SUI'
  ? tx.splitCoins(tx.gas, [grossIn])[0]
  : tx.add(coinWithBalance({ type: QUOTE, balance: grossIn }));

const [baseOut, change] = tx.moveCall({
  target: `${PKG}::pool::buy`,
  typeArguments: [BASE, QUOTE],
  arguments: [tx.object(CFG), tx.object(POOL_ID), payment,
              tx.pure.u64(minOut), tx.object('0x6')],
});
tx.transferObjects([baseOut, change], sender);
await client.signAndExecuteTransaction({ transaction: tx, signer, options: { showEvents: true } });
```

(`buy_entry`/`sell_entry` exist for CLI use; from the SDK prefer the public functions above — you keep the returned coins as PTB values.)

## Sell

`pool::sell(cfg, pool, base_in: Coin<Base>, min_quote_out: u64, ctx): Coin<Quote>` — fee comes out of the proceeds. Prepare `base_in` with `coinWithBalance({ type: BASE, balance })`, transfer the returned quote coin to the sender.

## Atomic drain-buy + migrate (recommended pattern)

The buy that empties the curve only flips the pool to `COMPLETED`; migration is a separate permissionless call. When your quote shows this buy will drain the curve (`out == virtual_base − virtual_base_floor`, equivalently `out` equals the pool's remaining `base_reserve`), append `migration::migrate` to the same PTB — completion and Cetus migration then land atomically, with zero frozen-trading window:

```ts
const [baseOut, change] = tx.moveCall({ target: `${PKG}::pool::buy`, ... });
tx.moveCall({
  target: `${PKG}::migration::migrate`,
  typeArguments: [BASE, QUOTE],
  arguments: [
    tx.object(CFG), tx.object(POOL_ID),
    tx.object(CURRENCY_ID),          // shared Currency<Base>
    tx.object(LP_BURN_MANAGER),      // lp_burn BurnManager (shared)
    tx.object(CETUS_GLOBAL_CONFIG),  // cetus_clmm GlobalConfig (shared)
    tx.object(CETUS_POOLS),          // cetus_clmm factory Pools (shared)
    tx.object('0x6'),
  ],
});
tx.transferObjects([baseOut, change], sender);
```

Caveats: if someone front-runs the drain, `migrate` aborts and the **whole PTB reverts including your buy** — only attach it when the quote indicates a drain, and retry without it on failure. Only this one transaction carries the Cetus objects; ordinary buys stay light.

## Error handling (abort codes, module `pool`)

| code | meaning | client action |
|---|---|---|
| 2 `ENotTrading` | curve completed/migrated | refresh phase; route user to Cetus |
| 11 `ESlippage` | below `min_*_out` | re-quote and retry |
| 12 `EBelowMinBuy` | input under per-quote minimum | raise amount |
| 13 `EZeroOutput` | dust in/out | raise amount |
| 1 `EVersionMismatch` | package upgraded | update `<PKG>` |
| `EPaused` (config, 2) | launchpad paused (buys only; sells still work) | show notice |

Confirm fills from the execution result's `TradedEvent<Base, Quote>` (fields: `quote_amount` net, `base_amount`, `fee`, post-trade `virtual_base/virtual_quote`) rather than re-reading state.

## Post-migration

`buy`/`sell` abort with `ENotTrading` after completion. Swaps then go through Cetus (aggregator SDK or Cetus SDK) against `Pool.cetus_pool_id` with orientation `Pool.base_is_coin_a`. See the `launchpad-data` skill for the chart/data handoff.
