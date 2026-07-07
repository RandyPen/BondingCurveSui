---
name: launchpad-data
description: Query BondingCurveSui launchpad data from a web frontend or agent — enumerate launches, subscribe to one token's trades, read live pool state, build candlestick (K-line) charts, and hand off to Cetus/noodles after migration. Use when rendering launchpad UI, indexing events, or an agent needs market data.
---

# Launchpad data retrieval

Object IDs live in `deployments.json` at the repo root (`launchpadPackage`, `launchpadConfig`, per-network). `<PKG>` below means the launchpad package id. Never guess addresses — read that file.

## Event model (the one rule)

- **Global events** are plain types; one filter enumerates everything.
  `PoolCreatedEvent` (module `pool`) carries the coin pair as `TypeName` **fields** (`base`, `quote`) plus `pool_id`, `creator`, `threshold`, initial virtual reserves.
- **Pool-scoped events** are **generic over the pair** `<Base, Quote>`, so one fully-instantiated type filter subscribes to exactly one token:
  - module `pool`: `TradedEvent`, `CurveCompletedEvent`, `CurveFeesDistributedEvent`, `TrancheLockedEvent`, `TrancheUnlockedEvent`, `EmergencyWithdrawEvent`
  - module `migration`: `MigratedEvent`, `LpFeesClaimedEvent`, `TvlTrancheUnlockedEvent`, `LpRewardsClaimedEvent`

Type filter string format (JSON-RPC `MoveEventType` requires the full instantiation):

```
<PKG>::pool::TradedEvent<0x..::mycoin::MYCOIN, 0x2::sui::SUI>
```

JSON-RPC `queryEvents` supports only: `MoveEventType` (exact), `MoveEventModule`, `Sender`, tx digest. **No filtering by event field contents** (the documented `MoveEventField` is not actually supported by fullnodes). GraphQL is the same, but its `type` filter supports prefix matching (`<PKG>::pool::TradedEvent` without generics matches all instantiations); note GraphQL cannot combine `type` and `module` in one filter.

## Enumerating launches / resolving a pool

```ts
import { SuiClient, getFullnodeUrl } from '@mysten/sui/client';
const client = new SuiClient({ url: getFullnodeUrl('mainnet') });

const page = await client.queryEvents({
  query: { MoveEventType: `${PKG}::pool::PoolCreatedEvent` },
  order: 'descending', limit: 50, cursor,
});
// parsedJson: { pool_id, base: {name}, quote: {name}, creator, threshold,
//               virtual_base, virtual_quote, curve_fee_bps, tick_spacing }
```

`base.name`/`quote.name` are full type names without the leading `0x` prefix convention of TypeName (e.g. `abc..::mycoin::MYCOIN`) — prepend `0x` when building type filters from them.

## Live state: read the Pool object (source of truth for "now")

```ts
const obj = await client.getObject({ id: poolId, options: { showContent: true } });
// fields: phase (0 TRADING / 1 COMPLETED / 2 MIGRATED / 3 HALTED),
// virtual_base, virtual_quote, virtual_base_floor, threshold,
// base_reserve, lp_base_reserve, quote_reserve (progress bar = quote_reserve / threshold),
// platform_fees, creator_fees, curve_fee_bps, tranches[], creator,
// cetus_pool_id / base_is_coin_a / completed_at_ms (post-completion)
```

Rule of thumb: **history = events, current state = object read.** Don't reconstruct progress bars from event folds when one `getObject` gives it.

For quotes (expected output incl. fees and the completing-buy clamp) call the view functions via `devInspectTransactionBlock` on `pool::quote_buy` / `pool::quote_sell`; both return `(0, 0)` when the pool is no longer TRADING.

## Trade feed and K-line (curve phase)

Subscribe with cursor polling (event WebSocket subscriptions are deprecated):

```ts
let cursor: EventId | null = savedCursor;
setInterval(async () => {
  const r = await client.queryEvents({
    query: { MoveEventType: `${PKG}::pool::TradedEvent<${BASE}, ${QUOTE}>` },
    cursor, order: 'ascending', limit: 200,
  });
  for (const ev of r.data) ingest(ev);
  if (r.hasNextPage) cursor = r.nextCursor;
}, 2500);
```

Per event: `parsedJson = { pool_id, trader, is_buy, quote_amount (net, fee excluded), base_amount, fee, virtual_base, virtual_quote }`. Timestamp is **not** in the payload — use the envelope `timestampMs` (checkpoint time; all events of one tx share it; order within a tx by `id.eventSeq`).

K-line assembly per bucket:
- trade price (for high/low): `quote_amount / base_amount`
- close: `virtual_quote / virtual_base` of the bucket's last event (post-trade marginal price)
- open: previous bucket's close; first-ever open from `PoolCreatedEvent` initial virtuals
- volume: sum `base_amount` (base) or `quote_amount + fee` (quote)
- decimals: base is fixed (see `deployments.json` `baseDecimals`); quote decimals resolved once from its `Currency`/metadata.

Creator first-buy tranches also emit `TradedEvent` (trader = creator), so the chart starts complete.

## Migration handoff

On `MigratedEvent<Base, Quote>` (`parsedJson: { cetus_pool_id, base_is_coin_a, sqrt_price_x64, ... }`) the curve freezes and trading moves to Cetus. Curve end price equals the CLMM seed price by construction — no gap at the stitch. Do **not** try to ingest Cetus `SwapEvent` from a browser: it is a single non-generic type distinguished only by a `pool` field, which no RPC filter can select. Options, best first:

1. **Embed a third-party chart widget**, e.g. noodles.fi:
   `https://noodles.fi/tv-widget?coinA=<QUOTE_TYPE>&coinB=<BASE_TYPE>&theme=dark`
   (full type strings, same as the event type args). Fresh pools may take minutes to be indexed — until then show a static price from `sqrt_price_x64` (`price = (sqrt_price_x64 / 2^64)^2`, oriented by `base_is_coin_a`, price is coinB-per-coinA).
2. Link out to the Cetus pool page using `cetus_pool_id`.
3. Poll the Cetus pool object's `current_sqrt_price` for a coarse self-rendered line.
4. A backend indexer ingesting Cetus `SwapEvent` filtered by `pool == cetus_pool_id` (only at scale).

## Scale note

Browser-direct fullnode polling is fine for an MVP. At scale, run a thin indexer subscribing by `MoveEventModule` (`pool` + `migration`) into a DB; the generic event types then mainly benefit third parties and light clients.
