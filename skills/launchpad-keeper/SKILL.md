---
name: launchpad-keeper
description: Operate the BondingCurveSui platform — the two mandatory keepers (instant migration, regulated-coin marking), permissionless cranks (fee distribution, LP fee/reward claiming, tranche unlocks), and admin operations. Use when building platform ops/bots or administering the launchpad.
---

# Platform keepers and cranks

IDs from `deployments.json`. Everything here except the Admin section is **permissionless** — any funded address can run it; payouts always go to the hardcoded recipients (treasury / creator), never the caller.

**Payout mechanism**: all payouts are credited to the recipient's **address balance** (`balance::send_funds`, funds accumulator) — no Coin objects are created. The treasury/creator spends them via an address-balance-aware wallet or a PTB `Withdrawal` reservation + `balance::redeem_funds`. Keeper receipts therefore do not show up in `getOwnedObjects`; check address balances instead.

## Keeper 1 — migrate on completion (MANDATORY)

Subscribe to `<PKG>::pool::CurveCompletedEvent` (module filter on `pool` also works) and immediately call:

```
migration::migrate<Base, Quote>(cfg, pool, currency, burn_manager,
                                cetus_config, cetus_pools, clock)
```

Resolve `Base/Quote` from the pool object's type. This creates the full-range Cetus pool at the curve's end price, burns the LP via lp_burn (proof stored in the pool), burns base dust, flushes curve fees, and flips the pool to `MIGRATED`. Idempotent-safe: a second call aborts (`ENotCompleted`).

Why mandatory: frontends may also attach `migrate` to the drain buy atomically (see `launchpad-trade`), but the keeper is the backstop that keeps the completion→migration window at seconds.

## Keeper 2 — mark regulated coins (MANDATORY)

`create_token` rejects coins whose Currency is marked Regulated, but coins created via `coin::create_regulated_currency_*` and registered through the legacy path sit in the `Unknown` state where the deny cap is invisible on-chain. Close the loop off-chain:

1. Watch for newly created frozen objects of type `0x2::coin::RegulatedCoinMetadata<T>` (every regulated coin creates one at publish time; honest coins never have one).
2. For each, call the permissionless `0x2::coin_registry::migrate_regulated_state_by_metadata<T>(currency, regulated_metadata)` — this permanently marks the Currency Regulated, so `create_token` will reject that `T` forever.
3. Frontends should additionally hide any launched pool whose base later turns out regulated.

There is no griefing vector: only coins that actually have a `RegulatedCoinMetadata` object can be marked.

## Permissionless cranks (run on demand or on a schedule)

- `pool::distribute_curve_fees(cfg, pool)` — pays accrued curve fees to treasury + creator. Auto-runs at migration; run periodically for long-lived TRADING pools.
- `migration::claim_lp_fees<Base, Quote>(cfg, pool, currency, burn_manager, cetus_config, cetus_pool)` — collects the burned position's Cetus trading fees: quote side split treasury/creator by the pool's `lp_fee_platform_bps`, **base side burned** (supply drops). Use `claim_lp_fees_inverted` when `Pool.base_is_coin_a == false` (then the Cetus pool type is `Pool<Quote, Base>`). Wrong pool object or wrong orientation aborts.
- `migration::claim_lp_rewards<Base, Quote, Reward>(cfg, pool, burn_manager, cetus_config, cetus_pool, rewarder_vault, clock)` (+`_inverted`) — collects Cetus rewarder incentives for the position, split like quote LP fees. Only relevant when Cetus adds incentives to the pair.
- `pool::unlock_tranche_time(pool, index, clock)` — releases a matured time tranche to the creator.
- `migration::unlock_tranche_tvl{,_inverted}(pool, cetus_pool, currency, index)` — private `entry`: call as a direct PTB command (its output can't be composed, by design). Condition: pool MIGRATED and market cap (Currency circulating supply × Cetus price) ≥ the tranche target. Event `TvlTrancheUnlockedEvent` records supply, sqrt price and computed market cap.

## Admin operations (require the key-only AdminCap)

- Quote whitelist: `config::add_quote<Q>(cap, cfg, decimals, default_threshold, min_threshold, creation_fee, min_buy_amount, min_tvl_target)`, `update_quote<Q>`, `set_quote_enabled<Q>`. Precondition for every quote: Cetus's pool manager must have run `factory::add_allowed_pair_config<Q>(.., tick_spacing, ..)` — otherwise every launch with that quote aborts. SUI and USDC are confirmed allowed at tick_spacing 200 (Cetus team, 2026-07-07).
- Fees: `set_fee_params(curve_fee_bps ≤ 1000, curve_fee_platform_bps, lp_fee_platform_bps)` — live pools keep their launch-time snapshot.
- Launch params: `set_launch_params(base_decimals, initial_virtual_base, remain_base, tick_spacing, min_lock_duration_ms, tvl_target_multiplier)` — guarded by `initial/remain ≤ 1000` and `tvl_target_multiplier > 0`; affects only future launches. The multiplier (default 3) is the on-chain floor for market-cap tranche targets relative to each launch's graduation market cap.
- `set_treasury`, `set_paused` (pause blocks only create+buy; sells/unlocks/migrate/claims never pause).
- `transfer_admin(cap, to)` — the only way to move the AdminCap.
- After a package upgrade: `bump_config_version`, and `bump_pool_version` per live pool.

## Watch list (alerting)

- `CurveCompletedEvent` with no matching `MigratedEvent` within ~1 minute → Keeper 1 failure. A pool that stays COMPLETED means migration is aborting — investigate Cetus-side state (fee tier, coin allow-list, package version) immediately; there is no admin backstop.
- `PoolCreatedEvent` whose base has a `RegulatedCoinMetadata` object → Keeper 2 missed a coin; hide the pool in the frontend.
- Cetus `GlobalConfig.package_version` bumps → rebuild/relink against the new Cetus package before it breaks `migrate`/claims.
