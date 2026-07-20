# BondingCurveSui

**A bonding-curve launchpad TEMPLATE for Sui Move.** This repository is a production-grade, audited reference implementation of a PumpFun-style token launchpad — fork it, adjust the tokenomics knobs, and ship your own launchpad. It is a clean rewrite inspired by moonbags-contracts-sui, with different requirements and several structural optimizations.

What you get out of the box:

- a complete on-chain lifecycle (launch → bonding-curve trading → Cetus CLMM full-range migration → LP burn → fee sharing), 72 unit tests including real CLMM pool creation;
- every business number is an admin-configurable parameter, not a hardcoded constant: supply split, per-quote graduation thresholds, fees and platform/creator splits, lock minimums, market-cap unlock multiplier — see `deployments.json` for a worked production parameter set;
- developer skills (`skills/`) covering data indexing/K-lines, trading PTBs, agent-driven token launches, and platform keeper operations;
- a documented trust model and known trade-offs (below), so you know exactly what you are shipping.

Typical customization points when forking: fee-split recipients (e.g. route the treasury share to a staking or buyback contract), additional tranche unlock-condition kinds in `pool.move` (time and market-cap are implemented), quote whitelist policy, and the frontend/keeper layer. The contracts are chain-complete with no privileged off-chain component beyond the two recommended keepers.

## Core features

- **Constant-product bonding curve with virtual reserves**: native u256/u128 math, all rounding favors the protocol, the invariant is asserted on every trade.
- **Quote coin whitelist**: admin-managed (`add_quote<Quote>` / `set_quote_enabled`), with per-quote graduation threshold, creation fee, minimum buy, and minimum market-cap unlock target. Pools are generic: `Pool<Base, Quote>`.
- **Single graduation path**: once the curve drains, anyone can trigger `migrate`; all liquidity enters Cetus CLMM as a **full-range** position (`full_range_tick_range`), with the coin A/B assignment branched at runtime on the ASCII order of the type names.
- **Migration fee (gap-free)**: at migration the platform takes `migration_fee_bps` (default 1%, hard cap 10%, snapshotted at launch) of the raised quote; the base leg of the CLMM seed is shrunk by the same ratio and the excess base is **burned**, so the seed price still equals the curve's final price — graduation causes no price gap. `MigratedEvent` records the fee and the burn.
- **Front-run protection for pool creation (critical)**: while the TreasuryCap is still held at launch (zero supply, nobody owns base coins yet), `create_token` mints a Cetus `PoolCreationCap` and calls `register_permission_pair`; migration uses `create_pool_v3_with_creation_cap`. Without this, an attacker with dust amounts could create the `(Base, Quote, tick_spacing)` pool first and permanently brick migration with `EPoolAlreadyExist`, stranding all raised funds (found in security review; fixed with regression tests). **Operational precondition**: every whitelisted quote must be allowed in Cetus's `allowed_pair_config` for the configured tick_spacing, otherwise launches abort. Status: Cetus has confirmed (2026-07-07) that **SUI and USDC** are allowed for permission-pair creation at the 1% fee tier (tick_spacing 200); additional quotes require Cetus's pool manager to run `add_allowed_pair_config`.
- **No admin access to pool funds — ever**: with the pool key reserved at launch, migration cannot be blocked by third parties, so there is no emergency-withdraw backstop and no code path by which the admin can touch pool reserves in any phase. The residual (accepted) risk is Cetus-governance action against a specific coin (deny-listing, fee-tier removal), documented under Known trade-offs.
- **Launch parameter guard rails**: `set_launch_params` enforces `initial/remain ≤ 1000` so extreme ratios cannot push the CLMM seed price outside Cetus's representable range and permanently block migration.
- **LP burn**: after migration the position is burned through Cetus's official `lp_burn::burn_lp_v2`; the `CetusLPBurnProof` is held by the protocol (inside the pool object). Anyone can trigger `claim_lp_fees` — the quote side is split between platform treasury and creator by configurable bps, the **base side is always burned**.
- **Taker referral (curve phase only)**: `buy` / `sell` take an `Option<address>` referrer. The referral share (`referral_bps`, default 10% of the curve fee, hard cap 10%, snapshotted at launch) is **carved out of the platform's cut** — `set_fee_params` enforces `referral_bps <= curve_fee_platform_bps`, so the creator's remainder is bit-for-bit unaffected. With the defaults a referred trade splits the 1% fee **50% platform / 10% referrer / 40% creator**. Payment is immediate via `balance::send_funds`, like the platform and creator legs — see **Curve fees are paid, not accrued** below. Self-referral aborts (`ESelfReferral`); a second wallet defeats it, so this is a guard rail, not a sybil defence. After graduation, trades leave the curve entirely and referral no longer applies — outer-pool volume is monetized through the burned LP position's fees (and optionally a Cetus `Partner` object on the frontend's own routed flow).
- **Curve fees are paid, not accrued**: all three legs of a curve trade's fee (platform treasury, creator, referrer) are transferred inside the trade that earns them via `balance::send_funds`. Nothing rests on the pool, so there is no `distribute_curve_fees` crank and no unclaimed balance to strand. Sui's funds accumulator is what makes this free: `balance::send_funds` → `funds_accumulator::add_impl` computes the accumulator address and emits a merge event — it never takes the accumulator as an input object, so a deposit costs no storage and contends with nothing (an address receiving from every pool is not a hot spot). Measured on localnet against an accrue-then-claim build, a trade is **1,216 MIST cheaper** — paying three recipients is free, and dropping the two `Balance` fields shrank the pool object by 16 bytes. Recipients always come from stored state (`cfg.treasury()`, `pool.creator`), never from the caller. Two consequences: (1) fees follow whoever held the role **at trade time** — a creator who hands over the role via `accept_creator` keeps what they already earned rather than passing unclaimed accruals to the nominee; (2) there is no balance to query, so `CurveFeesPaidEvent` is the record of record for fee accounting. LP fees and rewards still need a permissionless crank, because collecting those requires passing Cetus's own objects.
- **Currency (BurnOnly)**: at launch, after minting the fixed supply (default 800M curve + 200M LP = 1B total, 6 decimals), `make_supply_burn_only` consumes the TreasuryCap. Anyone can then burn base coins via the shared `Currency<T>`; total supply stays on-chain queryable and minting is impossible. The **MetadataCap is claimed into the pool** (dynamic object field): the creator — and only the creator — can later update the coin's name/description/icon via `update_base_metadata` (symbol is immutable in coin_registry). Buyers should be aware metadata is creator-mutable.
- **Creator first-buy tranches**: exactly two lock kinds exist — time and market-cap — and **each can be used at most once per pool**. A tranche is a *singleton dynamic field* on the `Pool` (`TimeTrancheKey {}` / `TvlTrancheKey {}`, empty structs: the key type is the identity, there is no index). The key is therefore the constraint: once a launch has written one kind, that key is taken, and a second entry of the same kind in the `tranche_*` vectors **aborts with `ETooManyTranches`** rather than being appended, merged, or silently dropped. (A first-buy that locked nothing is likewise an abort, not a skip — otherwise it would leave the key free and hand the next same-kind entry a fresh full cap.) So the legal inputs are exactly: no tranche, one time, one market-cap, or one of each (`MAX_TRANCHES = 2`). Staggered vesting is not expressible — a single time tranche is a cliff, and a single market-cap tranche gates once and then vests linearly. Each has its own independent base cap (`max_time_base` / `max_tvl_base`), so the two stack without competing; an over-cap buy is clamped to the cap with the excess quote refunded. Unlock calls take no index — they address the singleton directly, so `unlock_tranche_time` on a pool with only a market-cap tranche aborts `ETrancheNotFound` ("wrong kind" is a typed absence, not a runtime check). Conditions:
  - time lock (`unlock_tranche_time`, unlockable in any phase), duration at least the admin-configured `min_lock_duration_ms` (default 24 hours);
  - **market-cap target** (`claim_tranche_tvl{,_inverted}`): circulating supply (the BurnOnly `Currency`'s `total_supply`, which decreases with burns) × Cetus pool price ≥ target (in quote units), target at least the per-quote `min_tvl_target` AND at least `tvl_target_multiplier` (default 3, admin-adjustable) times the launch's graduation market cap — otherwise the condition would be satisfied the moment migration lands; only triggerable after migration. **This target is a one-way GATE, not a cliff**: the first qualifying observation opens it and the balance then releases LINEARLY over `tvl_vesting_duration_ms` (default 10 days), after which the price is never read again. The gate is a CLMM spot read and is cheap to force with a single-transaction pump — it is deliberately not the protection. The protection is the window behind it: nothing releases in the instant the gate opens, the creator's exit is rate-limited to the schedule, and the gate opening is a public event carrying the observed price (a gate opened at a price no block boundary ever showed is the signature of a pump). Do not document this as proof the target was genuinely met. Note: base burns lower the market cap.
- **Regulated-coin (honeypot) rejection**: `create_token` asserts `!coin_registry::is_regulated`. The legacy-migration path leaves the regulated state `Unknown` (a hidden DenyCap is undetectable on-chain), so the **platform must run a keeper**: on discovering a new coin's frozen `RegulatedCoinMetadata<T>` object, call the permissionless `coin_registry::migrate_regulated_state_by_metadata` to permanently mark it Regulated — a marked coin can never pass `create_token`, while honest coins have no such object and cannot be griefed. Frontends should filter on the same signal.
- **Cetus incentive claiming**: `claim_lp_rewards{,_inverted}<Base, Quote, Reward>` collects rewarder incentives via `lp_burn::collect_reward`, split platform/creator by `lp_fee_platform_bps` (without this they would be stranded forever).
- **Project info on the pool**: description + twitter/telegram/website live as a plain `ProjectInfo` field of the pool (one `getObject` returns them, no dynamic-field lookup), set at launch, creator-updatable via `update_project_info` (length-capped, every change evented). Coin-level name/description/icon live in the `Currency` (see above).
- **Transferable creator role (two-step)**: `nominate_creator` (creator-only, overwrites any pending nomination, cancellable via `cancel_creator_nomination`) then `accept_creator` (nominee-only) reassigns `pool.creator` — the new address takes over the creator fee/reward share, future tranche unlocks (including tranches locked before the transfer), and the project-info / metadata update rights. While a nomination is pending every right stays with the current creator, and a typo'd address can never take the role. Every step is evented.
- **One shared object per pool**: trades on different tokens never contend; the global `LaunchpadConfig` only keeps a `Base type → pool ID` registry (prevents duplicate launches).
- **AdminCap is `key`-only**: cannot be `public_transfer`red or wrapped; the only way to move it is `transfer_admin`.
- **Address-balance payouts**: every outbound payment (creation fee, curve-fee distribution, LP fees/rewards, tranche unlocks, entry-wrapper outputs) is credited via `balance::send_funds` to the recipient's **address balance (funds accumulator)** instead of creating Coin objects — no object proliferation, and funds sent within a transaction cannot be spent in that same transaction. Recipients (treasury multisig, creators) need address-balance-aware wallets/SDK (`Withdrawal` reservation + `balance::redeem_funds`). The `buy`/`sell` public functions still RETURN Coin values for PTB composability.

## Lifecycle (3-transaction launch)

1. **tx1** — the creator publishes the coin package (standard OTW `coin::create_currency`; decimals must equal the configured `base_decimals`), holding a zero-supply `TreasuryCap` + `CoinMetadata`.
2. **tx2** — `sui::coin_registry::migrate_legacy_metadata` (permissionless) creates the shared `Currency<Base>` in the `0xc` registry. (It cannot be used mutably in the same transaction that creates it, hence the split from tx3.)
3. **tx3** — `pool::create_token<Base, Quote>` (or `create_token_entry`; takes Cetus `GlobalConfig` + `Pools`): validation, minting, **Cetus pool-key reservation (permission pair)**, MetadataCap custody (creator keeps update rights), supply → BurnOnly, virtual-reserve derivation, creator first-buy tranches, pool shared.

Afterwards: `buy`/`sell` (exact-in + min-out) → the draining buy flips the pool to `COMPLETED` → anyone calls `migration::migrate` (passing Cetus GlobalConfig/Pools + the lp_burn BurnManager) → `MIGRATED`; `claim_lp_fees` and market-cap unlocks become active.

## Curve parameters

For `I` (real curve tokens), `R` (tokens reserved for the LP), threshold `T` (quote units):
`vb0 = I²/(I−R)`, `floor = vb0 − I`, `vq0 = ⌈T·R/(I−R)⌉`.
Draining the curve sells exactly `I`, raises ≈`T`, and the final curve price `T/R` equals the CLMM seed price (no migration price gap; covered by unit tests).

## Developer skills (`skills/`)

Hands-on guides for frontend/agent developers, used together with `deployments.json` at the repo root (fill in addresses after deployment):

- **`launchpad-data`** — data retrieval: the event model (global events by field, pool-scoped events by `<Base, Quote>` generic type filters), cursor polling, K-line construction, object-state reads, and the post-migration handoff to noodles/Cetus charts;
- **`launchpad-trade`** — trading PTBs: devInspect quoting + slippage, buy/sell moveCalls, the **atomic drain-buy + `migrate` in one PTB** pattern, and an abort-code table;
- **`launchpad-launch`** — the full agent launch flow: bytecode-template coin package publishing → `migrate_legacy_metadata` Currency registration → `create_token` (tranche parameter encoding and constraints);
- **`launchpad-keeper`** — platform operations: the two mandatory keepers (instant migration, regulated-coin marking), permissionless cranks (fee distribution / LP fees / rewards / unlocks), admin operations and an alerting checklist.

To auto-load them as Claude Code project skills, symlink or copy the directories into `.claude/skills/`.

## Build and test

```bash
sui move build
sui move test   # 86 tests
```

The curve math (`sources/curve.move`) is additionally formally verified with
the Sui Prover — constant-product invariant preservation, reserve
conservation/solvency, exact fee/`isqrt` semantics, and a no-profit
round-trip theorem. See `specs/README.md`; run with `specs/prove.sh`.

The **migration seeding branch selection** is proved too, which matters
because a wrong branch there strands the whole raise permanently (`migrate` is
permissionless and cannot be paused, and a COMPLETED pool cannot sell). The
lemma — *if fixing the base leg would demand more quote than the pool holds,
then fixing the quote leg demands no more base than it holds* — is proved over
`specs/sources/cetus_model.move`, a faithful port of the Cetus liquidity math,
since the prover's pipeline cannot load the CetusClmm dependency tree. Two
bridges carry it to production: the port's formulas are annotated against the
pinned Cetus rev, and `full_range_sqrt_prices_match_cetus` asserts the
full-range constants against the real dependency, so a dependency bump fails
loudly. The proof assumes the seed price stays 2^32 away from either
full-range endpoint — the same condition under which Cetus's own `u128`
liquidity and `checked_shlw` do not abort.

Dependency notes are in `Move.toml`: CetusClmm is pinned to exactly what MVR resolves on mainnet (cetus-contracts @ clmm-v14 — real sources, so unit tests create real CLMM pools); the lp_burn interface is vendored locally (`vendor/lp_burn`) to drop its clmm_vester transitive dependency, whose MVR resolution fails outside mainnet.

## Deployment checklist (read before testnet/mainnet)

1. **Refresh published-at addresses**:
   - `mvr resolve @cetuspackages/clmm --network mainnet` → latest CLMM package (2026-07-07: v14 `0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3`). The CetusClmm git dependency carries no published-at; configure this address before a mainnet publish (Move.lock env pinning, or temporarily switch to an `r.mvr` dependency in a mainnet environment).
   - `mvr resolve @cetuspackages/lpburn --network mainnet` → latest lp_burn package (2026-07-07: v7 `0xa5d8457e049c8f2a04b7b47e925b200f457e57016aa158f050a931c8ead99fe0`, already set in `vendor/lp_burn/Move.toml`).
2. **Testnet notes**: Cetus's MVR metadata is broken on testnet (clmm has no git_info; lpburn has no mapping), which is why the git-pinned dependencies are used. lp_burn IS deployed on testnet (BurnManager id in `deployments.json`, sourced from the cetus-clmm-interface lp_burn README), so the full `migrate` round trip can be smoke-tested there.
3. **Protocol feature check**: payouts rely on the address-balance (funds accumulator) protocol feature — verify it is enabled on the target network's protocol version before publishing; if it is not, every fee distribution/unlock aborts.
4. **First actions after publish**: whitelist quotes (`add_quote<SUI>` / `add_quote<USDC>` …); confirm the `tick_spacing=200` fee tier exists in Cetus `GlobalConfig` (mainnet default, 1%); **verify each whitelisted quote is allowed in Cetus `allowed_pair_config` for that tick_spacing** — SUI and USDC confirmed allowed at tick_spacing 200 by the Cetus team (2026-07-07); others require contacting Cetus. Verify on-chain before whitelisting (`factory::is_allowed_coin` / a dry-run `register_permission_pair`).
5. **On-chain smoke test**: launch a test coin through the 3 transactions → small buys/sells → drain → `migrate` (verify the Cetus pool price and burn proof) → `claim_lp_fees` round trip → `coin_registry::burn` reduces supply.
6. **Upgrades**: after a package upgrade call `bump_config_version` — that single global gate locks out the old package across every pool at once. There is no per-pool version to bump.
7. **Two mandatory keepers**:
   - Migration keeper: listen for `CurveCompletedEvent` and call `migrate` immediately (frontends can also attach `migrate` to the drain buy atomically);
   - Regulated-marking keeper: watch for newly published frozen `RegulatedCoinMetadata<T>` objects and call `migrate_regulated_state_by_metadata` to permanently mark regulated coins before they can launch.

## Known trade-offs

- There is **no emergency withdrawal**: if Cetus governance deny-lists a launched coin or removes the pool's fee tier before migration, that pool's raised funds are permanently stuck (accepted by design — the alternative, an admin backstop, was removed because it gave the admin a theoretical path to drain healthy pools; the permission-pair reservation eliminates all third-party migration-blocking).

- Cross-transaction price manipulation of the market-cap unlock has no two-step confirmation (accepted for v1: the only beneficiary is the creator; cost is 2× pool fees + slippage + arbitrage risk; the event records the sqrt price, circulating supply and computed market cap for auditability). Shipped since: TVL tranches now gate-and-vest (see above). A further hardening could add a poke → confirm-after-N-hours flow.
- A regulated coin's `Unknown` state cannot be refuted on-chain (the framework has no "prove no DenyCap exists" predicate); the on-chain assert only blocks revealed Regulated states — the rest of the loop is closed by the regulated-marking keeper (see deployment checklist).
- The completing buy charges its fee on net cost while normal buys charge on gross input (a bps² -order inconsistency); not unified.
- Fee-split rules are still TBD → everything is admin-configurable bps (curve fee hard-capped at 10%; platform/creator splits snapshotted into each pool at launch).
