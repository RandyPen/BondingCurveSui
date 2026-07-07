---
name: launchpad-launch
description: The full 3-transaction token creation flow on BondingCurveSui, written for autonomous agents — generating and publishing the coin package (bytecode template), registering the Currency at 0xc, and calling create_token with creator first-buy tranches. Use when an agent or backend needs to launch a token programmatically.
---

# Launching a token (agent flow, 3 transactions)

IDs from `deployments.json`. Constraints enforced on-chain by `create_token`:
- fresh `TreasuryCap<Base>` with **zero supply**;
- Currency decimals **must equal** `deployments.json.constants.baseDecimals` (6);
- the coin must **not be regulated** (no `create_regulated_currency_*`; a revealed regulated state aborts with `ERegulatedBase = 23`);
- one launch per Base type, ever (`EBaseAlreadyLaunched`);
- the quote must be whitelisted AND allowed by Cetus's permission-pair config at the configured tick_spacing (else the launch aborts — see README).

## tx1 — publish the coin package

Each token is its own one-time-witness coin module. For programmatic launches, patch a **pre-compiled bytecode template** instead of compiling Move per launch, using `@mysten/move-bytecode-template`:

Template source (compile once with `sui move build`):

```move
module template::template {
    use sui::coin;
    public struct TEMPLATE has drop {}
    fun init(witness: TEMPLATE, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness, 6, b"TMPL", b"Template Coin", b"description", option::none(), ctx,
        );
        transfer::public_transfer(treasury_cap, ctx.sender());
        transfer::public_transfer(metadata, ctx.sender());
    }
}
```

Rules: module name and OTW struct name must stay in sync (struct = module name upper-cased); decimals constant stays 6; metadata is transferred (NOT frozen — tx2 needs `&CoinMetadata`, and freezing is fine too since tx2 only reads it; either works, transfer keeps it simple).

```ts
import init, * as template from '@mysten/move-bytecode-template';
await init();
let bytes = fromBase64(TEMPLATE_MODULE_BASE64);
bytes = template.update_identifiers(bytes, { TEMPLATE: 'MYCOIN', template: 'mycoin' });
bytes = template.update_constants(bytes, /* symbol/name/description/icon vectors */);

const tx = new Transaction();
const [upgradeCap] = tx.publish({ modules: [toBase64(bytes)], dependencies: ['0x1', '0x2'] });
tx.transferObjects([upgradeCap], sender); // or make package immutable later
```

From the result's `objectChanges`, record: `packageId`, the created `TreasuryCap<...::mycoin::MYCOIN>` id, the `CoinMetadata<...>` id. `BASE = `${packageId}::mycoin::MYCOIN``.

## tx2 — register the Currency (permissionless)

```ts
tx.moveCall({
  target: '0x2::coin_registry::migrate_legacy_metadata',
  typeArguments: [BASE],
  arguments: [tx.object('0xc'), tx.object(coinMetadataId)],
});
```

This creates and **shares** the unique `Currency<Base>` at a derived address. Get `CURRENCY_ID` from the tx's `objectChanges` (created shared object of type `0x2::coin_registry::Currency<BASE>`). It cannot be used mutably in the same transaction it is created in — that is why tx2 and tx3 are separate.

## tx3 — create_token

```
pool::create_token<Base, Quote>(
    cfg: &mut LaunchpadConfig,
    currency: &mut Currency<Base>,
    treasury_cap: TreasuryCap<Base>,       // consumed: supply becomes burn-only
    creation_fee: Coin<Quote>,             // EXACT amount (QuoteParams.creation_fee)
    threshold: Option<u64>,                // none => per-quote default
    description: String,                   // project info, empty = unset
    twitter: String, telegram: String, website: String, // <= 1000/500/500/500 chars
    tranche_quote_in: vector<u64>,         // creator first-buy tranches (<= 16)
    tranche_lock_kind: vector<u8>,         // 0 = time lock, 1 = market-cap target
    tranche_lock_param: vector<u64>,       // unlock_ts_ms | market cap in quote units
    payment: Coin<Quote>,                  // funds the tranche buys; change returned
    cetus_config: &GlobalConfig, cetus_pools: &mut Pools,   // pool-key reservation
    clock: &Clock, ctx,
): Coin<Quote>                             // change
```

Tranche rules (aborts otherwise): the three vectors must be equal length; time locks need `unlock_ts >= now + min_lock_duration_ms` (config, default 24h); market-cap targets need `>= QuoteParams.min_tvl_target` and `>= tvl_target_multiplier (default 3) x graduation market cap` (graduation mcap = (I+R)/R x threshold = 5 x threshold with default supply split); each tranche's gross must be `>= min_buy_amount`; tranches execute as normal curve buys (1% fee applies) and may even drain the whole curve.

```ts
const tx = new Transaction();
tx.setSender(sender);
const creationFee = tx.add(coinWithBalance({ type: QUOTE, balance: CREATION_FEE }));
const payment = tx.add(coinWithBalance({ type: QUOTE, balance: trancheBudget }));
const change = tx.moveCall({
  target: `${PKG}::pool::create_token`,
  typeArguments: [BASE, QUOTE],
  arguments: [
    tx.object(CFG),
    tx.object(CURRENCY_ID),
    tx.object(treasuryCapId),
    creationFee,
    tx.pure.option('u64', null),                       // threshold: default
    tx.pure.string('a meme with a plan'),              // description
    tx.pure.string('https://x.com/meme'),              // twitter
    tx.pure.string(''),                                // telegram (unset)
    tx.pure.string('https://meme.xyz'),                // website
    tx.pure.vector('u64', [100_000_000n]),             // one tranche, 100 quote gross
    tx.pure.vector('u8', [0]),                         // time lock
    tx.pure.vector('u64', [BigInt(Date.now()) + 86_400_000n]), // unlock in 24h
    payment,
    tx.object(CETUS_GLOBAL_CONFIG),
    tx.object(CETUS_POOLS),
    tx.object('0x6'),
  ],
});
tx.transferObjects([change], sender);
```

From the result: `PoolCreatedEvent.pool_id` (persist it), `TrancheLockedEvent` per tranche (`quote_in` = actual spend after any completing-buy refund), `TradedEvent` for each tranche buy.

What tx3 does besides minting: reserves the Cetus pool key (permission pair — nobody can front-run the future migration), claims the MetadataCap into the pool (the creator can update name/description/icon later via `pool::update_base_metadata(pool, currency, name?, description?, icon_url?)`; symbol immutable), converts supply to burn-only (anyone can burn via the Currency; total supply on-chain, mint impossible).

## After launch (agent lifecycle)

- Trade: `launchpad-trade` skill. Watch your pool via `TradedEvent<Base, Quote>` (`launchpad-data` skill).
- Creator-only maintenance (both check `ctx.sender() == pool.creator`):
  - `pool::update_project_info(pool, description, twitter, telegram, website)` — full replace of the pool's project info; emits `ProjectInfoUpdatedEvent<Base, Quote>`.
  - `pool::update_base_metadata(pool, currency, name?, description?, icon_url?)` — updates the coin's Currency metadata through the pool-held MetadataCap (symbol immutable; pass none to leave a field unchanged).
- On drain: attach `migration::migrate` to the completing buy, or crank it separately (`launchpad-keeper` skill).
- Unlock tranches: time — `pool::unlock_tranche_time(pool, index, clock)` (permissionless, pays the creator); market-cap — `migration::unlock_tranche_tvl{,_inverted}(pool, cetus_pool, currency, index)` (private `entry`; call as a direct PTB command; requires MIGRATED and circulating-supply × price ≥ target; `Pool.base_is_coin_a` decides which variant).

## Platform-assisted single-signature launch (recommended UX)

The three transactions are a framework constraint (one module per coin +
coin_registry's share-then-mutate timing), but only tx3 must be signed by the
creator:

1. Platform backend publishes the coin package from the bytecode template
   (tx1) and immediately runs the permissionless `migrate_legacy_metadata`
   (tx2), then transfers the zero-supply `TreasuryCap` to the creator.
2. The creator signs a single transaction: `create_token` with their
   tranches and project info. Creator attribution is automatic
   (`pool.creator = sender`, and only the sender's TreasuryCap works).

The inter-transaction gaps are safe: tx2 is permissionless (anyone doing it
first is helping), metadata/premint tampering needs the TreasuryCap the
creator holds, and the Cetus pool cannot be front-run before tx3 (no base
supply exists). Best practice when the platform publishes: make the coin
package immutable (or burn the UpgradeCap) — upgrades cannot mint (the OTW
is consumed and the cap destroyed at launch), but immutability is cleaner.

## Abort quick reference (module `pool` unless noted)

| code | const | usual cause |
|---|---|---|
| 4 | ESupplyNotZero | template minted in init |
| 5 | EDecimalsMismatch | template decimals ≠ 6 |
| 6 | EMetadataCapClaimed | someone claimed the metadata cap first |
| 7/8/9/10 | tranche vector/kind/param errors | see tranche rules above |
| 14 | EWrongCreationFee | fee coin not exact |
| 15 | EInsufficientPayment | payment < sum of tranche gross |
| 23 | ERegulatedBase | regulated coin |
| 25 | EProjectInfoTooLong | description > 1000 or a link > 500 chars |
| config 4 | EQuoteNotListed | quote not whitelisted/disabled |
| config 7 | EBaseAlreadyLaunched | base type reused |
| config 8 | EThresholdTooLow | custom threshold < per-quote min |
| cetus factory | EQuoteCoinTypeNotInAllowedPairConfig | quote not Cetus-allowed at tick_spacing |
