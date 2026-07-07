# BondingCurveSui

A PumpFun-style token launchpad on Sui Move — a clean rewrite inspired by moonbags-contracts-sui, with different requirements and several structural optimizations.

## Core features

- **Constant-product bonding curve with virtual reserves**: native u256/u128 math, all rounding favors the protocol, the invariant is asserted on every trade.
- **Quote coin whitelist**: admin-managed (`add_quote<Quote>` / `set_quote_enabled`), with per-quote graduation threshold, creation fee, minimum buy, and minimum market-cap unlock target. Pools are generic: `Pool<Base, Quote>`.
- **Single graduation path**: once the curve drains, anyone can trigger `migrate`; all liquidity enters Cetus CLMM as a **full-range** position (`full_range_tick_range`), with the coin A/B assignment branched at runtime on the ASCII order of the type names.
- **Front-run protection for pool creation (critical)**: while the TreasuryCap is still held at launch (zero supply, nobody owns base coins yet), `create_token` mints a Cetus `PoolCreationCap` and calls `register_permission_pair`; migration uses `create_pool_v3_with_creation_cap`. Without this, an attacker with dust amounts could create the `(Base, Quote, tick_spacing)` pool first and permanently brick migration with `EPoolAlreadyExist`, stranding all raised funds (found in security review; fixed with regression tests). **Operational precondition**: every whitelisted quote must be allowed in Cetus's `allowed_pair_config` for the configured tick_spacing, otherwise launches abort. Status: Cetus has confirmed (2026-07-07) that **SUI and USDC** are allowed for permission-pair creation at the 1% fee tier (tick_spacing 200); additional quotes require Cetus's pool manager to run `add_allowed_pair_config`.
- **Emergency backstop**: a pool stuck in COMPLETED for **7 days** can be drained by the admin via `emergency_withdraw` (funds to treasury, pool enters the terminal HALTED phase, event logged); in HALTED every tranche becomes permissionlessly releasable to the creator (market-cap conditions are permanently unsatisfiable). **Trust note**: on-chain this only checks "COMPLETED + 7 days" — it cannot prove migration is impossible. The counterweight: `migrate` is permissionless and unpausable, so anyone can preempt the drain with one transaction; the platform must run a keeper that migrates on every `CurveCompletedEvent`, making the window moot in practice.
- **Launch parameter guard rails**: `set_launch_params` enforces `initial/remain ≤ 1000` so extreme ratios cannot push the CLMM seed price outside Cetus's representable range and permanently block migration.
- **LP burn**: after migration the position is burned through Cetus's official `lp_burn::burn_lp_v2`; the `CetusLPBurnProof` is held by the protocol (inside the pool object). Anyone can trigger `claim_lp_fees` — the quote side is split between platform treasury and creator by configurable bps, the **base side is always burned**.
- **Currency (BurnOnly)**: at launch, after minting the fixed supply (default 8M curve + 2M LP, 6 decimals), the metadata cap is claimed and deleted (metadata frozen forever) and `make_supply_burn_only` consumes the TreasuryCap. Anyone can then burn base coins via the shared `Currency<T>`; total supply stays on-chain queryable and minting is impossible.
- **Creator first-buy tranches**: up to 16 tranches at launch, each with its own unlock condition:
  - time lock (`unlock_tranche_time`, unlockable in any phase), duration at least the admin-configured `min_lock_duration_ms` (default 1 hour);
  - **market-cap target** (`unlock_tranche_tvl{,_inverted}`): circulating supply (the BurnOnly `Currency`'s `total_supply`, which decreases with burns) × Cetus pool price ≥ target (in quote units), target at least the per-quote `min_tvl_target`; only triggerable after migration; implemented as **private `entry`** functions that transfer directly to the creator, which breaks the atomic "pump price → unlock → dump" PTB composition. Note: base burns lower the market cap.
- **Regulated-coin (honeypot) rejection**: `create_token` asserts `!coin_registry::is_regulated`. The legacy-migration path leaves the regulated state `Unknown` (a hidden DenyCap is undetectable on-chain), so the **platform must run a keeper**: on discovering a new coin's frozen `RegulatedCoinMetadata<T>` object, call the permissionless `coin_registry::migrate_regulated_state_by_metadata` to permanently mark it Regulated — a marked coin can never pass `create_token`, while honest coins have no such object and cannot be griefed. Frontends should filter on the same signal.
- **Cetus incentive claiming**: `claim_lp_rewards{,_inverted}<Base, Quote, Reward>` collects rewarder incentives via `lp_burn::collect_reward`, split platform/creator by `lp_fee_platform_bps` (without this they would be stranded forever).
- **One shared object per pool**: trades on different tokens never contend; the global `LaunchpadConfig` only keeps a `Base type → pool ID` registry (prevents duplicate launches).
- **AdminCap is `key`-only**: cannot be `public_transfer`red or wrapped; the only way to move it is `transfer_admin`.
- **Address-balance payouts**: every outbound payment (creation fee, curve-fee distribution, LP fees/rewards, tranche unlocks, emergency withdraw, entry-wrapper outputs) is credited via `balance::send_funds` to the recipient's **address balance (funds accumulator)** instead of creating Coin objects — no object proliferation, and funds sent within a transaction cannot be spent in that same transaction. Recipients (treasury multisig, creators) need address-balance-aware wallets/SDK (`Withdrawal` reservation + `balance::redeem_funds`). The `buy`/`sell` public functions still RETURN Coin values for PTB composability.

## Lifecycle (3-transaction launch)

1. **tx1** — the creator publishes the coin package (standard OTW `coin::create_currency`; decimals must equal the configured `base_decimals`), holding a zero-supply `TreasuryCap` + `CoinMetadata`.
2. **tx2** — `sui::coin_registry::migrate_legacy_metadata` (permissionless) creates the shared `Currency<Base>` in the `0xc` registry. (It cannot be used mutably in the same transaction that creates it, hence the split from tx3.)
3. **tx3** — `pool::create_token<Base, Quote>` (or `create_token_entry`; takes Cetus `GlobalConfig` + `Pools`): validation, minting, **Cetus pool-key reservation (permission pair)**, metadata freeze, supply → BurnOnly, virtual-reserve derivation, creator first-buy tranches, pool shared.

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
sui move test   # 75 tests
```

Dependency notes are in `Move.toml`: CetusClmm is pinned to exactly what MVR resolves on mainnet (cetus-contracts @ clmm-v14 — real sources, so unit tests create real CLMM pools); the lp_burn interface is vendored locally (`vendor/lp_burn`) to drop its clmm_vester transitive dependency, whose MVR resolution fails outside mainnet.

## Deployment checklist (read before testnet/mainnet)

1. **Refresh published-at addresses**:
   - `mvr resolve @cetuspackages/clmm --network mainnet` → latest CLMM package (2026-07-07: v14 `0x25ebb9a7c50eb17b3fa9c5a30fb8b5ad8f97caaf4928943acbcff7153dfee5e3`). The CetusClmm git dependency carries no published-at; configure this address before a mainnet publish (Move.lock env pinning, or temporarily switch to an `r.mvr` dependency in a mainnet environment).
   - `mvr resolve @cetuspackages/lpburn --network mainnet` → latest lp_burn package (2026-07-07: v7 `0xa5d8457e049c8f2a04b7b47e925b200f457e57016aa158f050a931c8ead99fe0`, already set in `vendor/lp_burn/Move.toml`).
2. **Testnet notes**: Cetus's MVR metadata is broken on testnet (clmm has no git_info; lpburn has no mapping), which is why the git-pinned dependencies are used. lp_burn IS deployed on testnet (BurnManager id in `deployments.json`, sourced from the cetus-clmm-interface lp_burn README), so the full `migrate` round trip can be smoke-tested there.
3. **Protocol feature check**: payouts rely on the address-balance (funds accumulator) protocol feature — verify it is enabled on the target network's protocol version before publishing; if it is not, every fee distribution/unlock aborts.
4. **First actions after publish**: whitelist quotes (`add_quote<SUI>` / `add_quote<USDC>` …); confirm the `tick_spacing=200` fee tier exists in Cetus `GlobalConfig` (mainnet default, 1%); **verify each whitelisted quote is allowed in Cetus `allowed_pair_config` for that tick_spacing** — SUI and USDC confirmed allowed at tick_spacing 200 by the Cetus team (2026-07-07); others require contacting Cetus. Verify on-chain before whitelisting (`factory::is_allowed_coin` / a dry-run `register_permission_pair`).
5. **On-chain smoke test**: launch a test coin through the 3 transactions → small buys/sells → drain → `migrate` (verify the Cetus pool price and burn proof) → `claim_lp_fees` round trip → `coin_registry::burn` reduces supply.
6. **Upgrades**: after a package upgrade call `bump_config_version`, and `bump_pool_version` per live pool as needed.
7. **Two mandatory keepers**:
   - Migration keeper: listen for `CurveCompletedEvent` and call `migrate` immediately (also neutralizes the 7-day emergency window);
   - Regulated-marking keeper: watch for newly published frozen `RegulatedCoinMetadata<T>` objects and call `migrate_regulated_state_by_metadata` to permanently mark regulated coins before they can launch.

## Known trade-offs

- Cross-transaction price manipulation of the market-cap unlock has no two-step confirmation (accepted for v1: the only beneficiary is the creator; cost is 2× pool fees + slippage + arbitrage risk; the event records the sqrt price, circulating supply and computed market cap for auditability). A v1.1 hardening could add a poke → confirm-after-N-hours flow.
- A regulated coin's `Unknown` state cannot be refuted on-chain (the framework has no "prove no DenyCap exists" predicate); the on-chain assert only blocks revealed Regulated states — the rest of the loop is closed by the regulated-marking keeper (see deployment checklist).
- The completing buy charges its fee on net cost while normal buys charge on gross input (a bps² -order inconsistency); not unified.
- Fee-split rules are still TBD → everything is admin-configurable bps (curve fee hard-capped at 10%; platform/creator splits snapshotted into each pool at launch).
