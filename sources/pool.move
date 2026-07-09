/// Bonding-curve pool lifecycle: token creation (with creator first-buy
/// tranches), curve trading, fee accrual, and time-based tranche unlocks.
///
/// Each launched token gets its own shared `Pool<Base, Quote>` object; the
/// global `LaunchpadConfig` only records `Base -> pool ID`, so trades on
/// different tokens never contend on a shared object.
///
/// Phase machine: `TRADING -> COMPLETED -> MIGRATED`. The completing buy
/// only flips the phase; the actual Cetus migration is a separate
/// permissionless crank in `bondingcurvesui::migration`.
module bondingcurvesui::pool;

use cetus_clmm::config::GlobalConfig as CetusGlobalConfig;
use cetus_clmm::factory::{Self, Pools as CetusPools, PoolCreationCap};
use lp_burn::lp_burn::CetusLPBurnProof;
use std::string::String;
use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::clock::Clock;
use sui::coin::{Self, Coin, TreasuryCap};
use sui::coin_registry::{Self, Currency, MetadataCap};
use sui::dynamic_object_field as dof;
use sui::event;

use bondingcurvesui::config::{Self, LaunchpadConfig};
use bondingcurvesui::curve;

// === Errors ===

/// Curve is not in the trading phase.
const ENotTrading: u64 = 2;
/// Curve has not completed yet.
const ENotCompleted: u64 = 3;
/// Base coin already has minted supply.
const ESupplyNotZero: u64 = 4;
/// Currency decimals differ from the configured base decimals.
const EDecimalsMismatch: u64 = 5;
// Code 6 (EMetadataCapClaimed) retired: `seal` claims the MetadataCap itself
// (via finalize) and hands it to `create_token` in the FactoryReceipt, so there
// is no external metadata-cap-claim race to guard against.
/// Tranche parameter vectors have different lengths.
const ETrancheVectorMismatch: u64 = 7;
/// More first-buy tranches than allowed.
const ETooManyTranches: u64 = 8;
/// Unknown tranche lock kind.
const EInvalidLockKind: u64 = 9;
/// Lock parameter invalid (time not in the future / zero TVL target).
const EInvalidLockParam: u64 = 10;
/// Output below the caller's slippage bound.
const ESlippage: u64 = 11;
/// Buy input below the per-quote minimum.
const EBelowMinBuy: u64 = 12;
/// Trade produces zero output.
const EZeroOutput: u64 = 13;
/// Creation fee coin does not match the configured fee.
const EWrongCreationFee: u64 = 14;
/// Payment coin cannot cover the tranche buys.
const EInsufficientPayment: u64 = 15;
/// Tranche index out of bounds.
const ETrancheNotFound: u64 = 16;
/// Tranche was already claimed.
const ETrancheAlreadyClaimed: u64 = 17;
/// Tranche unlock conditions are not met.
const ETrancheLocked: u64 = 18;
/// Currency supply is not burn-only (wrong Currency object state).
const ESupplyNotBurnOnly: u64 = 19;
/// Pool has not migrated yet.
const ENotMigrated: u64 = 20;
// Codes 21/22 retired (emergency backstop removed: the Cetus pool key
// is reserved at launch, so migration cannot be blocked by third
// parties).
/// Base coin is a regulated currency (has a deny cap).
const ERegulatedBase: u64 = 23;
/// Caller is not the pool creator.
const ENotCreator: u64 = 24;
/// A project-info field exceeds its length limit.
const EProjectInfoTooLong: u64 = 25;
/// Caller is not the nominated pending creator.
const ENotPendingCreator: u64 = 26;
/// No creator nomination is pending.
const ENoPendingCreator: u64 = 27;
// Code 28 (ETrancheExceedsCap) retired: an over-cap first-buy is now clamped to
// the cap with the excess quote refunded, rather than aborting.

// === Constants ===

const MAX_TRANCHES: u64 = 16;
/// Sentinel passed to `buy_internal` for public buys: no first-buy cap (only
/// the curve-completion clamp applies).
const NO_FIRST_BUY_CAP: u64 = 0xffff_ffff_ffff_ffff;
const MAX_DESCRIPTION_LEN: u64 = 1000;
const MAX_LINK_LEN: u64 = 500;

// Lifecycle phases.
const PHASE_TRADING: u8 = 0;
const PHASE_COMPLETED: u8 = 1;
const PHASE_MIGRATED: u8 = 2;

// Creator-tranche lock kinds.
const LOCK_KIND_TIME: u8 = 0;
const LOCK_KIND_TVL: u8 = 1;

/// Platform base-coin decimals, hard-coded into `seal` (never a caller/template
/// parameter). Must equal `LaunchpadConfig.base_decimals` so `create_token`
/// accepts sealed coins.
const STD_BASE_DECIMALS: u8 = 9;

// === Structs ===

/// Dynamic-object-field key for the MetadataCap held by the pool.
public struct MetadataCapKey has copy, drop, store {}

/// Provenance proof produced by `seal` and consumed by `create_token`.
///
/// `seal` is the SOLE constructor: it creates the base `Currency<T>` through
/// `coin_registry::new_currency_with_otw` (the UNREGULATED path) and never
/// calls `make_regulated`. So holding a `FactoryReceipt<T>` proves the base
/// coin is provably, permanently unregulated (no `DenyCapV2`, regulated state
/// can never be `Regulated` or `Unknown`). `create_token` requires it by
/// value, which is the fail-closed gate — a coin created any other way has no
/// receipt and cannot open a pool. The one-time witness of `T` is consumed
/// exactly once, so a regulated twin of `T` can never also have a receipt.
public struct FactoryReceipt<phantom T> has key, store {
    id: UID,
    /// Zero-supply treasury cap; `create_token` mints the fixed supply from it,
    /// then converts the supply to burn-only.
    treasury: TreasuryCap<T>,
    /// Metadata-update cap (already claimed by `seal`'s `finalize`); stored in
    /// the pool so the creator keeps name/description/icon update rights.
    metadata_cap: MetadataCap<T>,
}

/// Project links and description, shown on token pages. A plain pool
/// field (not a dynamic field) so a single getObject returns it.
/// Empty strings mean unset.
public struct ProjectInfo has store, copy, drop {
    description: String,
    twitter: String,
    telegram: String,
    website: String,
}

/// A creator first-buy tranche, locked until its unlock condition holds.
public struct CreatorTranche<phantom Base> has store {
    locked: Balance<Base>,
    kind: u8,
    /// Unlock timestamp (ms) when `kind == LOCK_KIND_TIME`.
    unlock_ts_ms: u64,
    /// Post-migration CLMM TVL target in quote units when
    /// `kind == LOCK_KIND_TVL`.
    tvl_target: u64,
    claimed: bool,
}

public struct Pool<phantom Base, phantom Quote> has key {
    id: UID,
    creator: address,
    /// Nominated next creator (two-step transfer); `creator` keeps every
    /// right until the nominee accepts.
    pending_creator: Option<address>,
    phase: u8,
    // Curve state.
    virtual_base: u64,
    virtual_quote: u64,
    /// Virtual base reserve at which the curve is complete.
    virtual_base_floor: u64,
    /// Quote raise target, for reference and events.
    threshold: u64,
    /// Sellable real tokens.
    base_reserve: Balance<Base>,
    /// Real tokens reserved for the CLMM liquidity at migration.
    lp_base_reserve: Balance<Base>,
    /// Quote collected by the curve (net of fees).
    quote_reserve: Balance<Quote>,
    // Accrued curve fees, split at trade time.
    platform_fees: Balance<Quote>,
    creator_fees: Balance<Quote>,
    // Parameters snapshotted at launch; later admin config changes do
    // not affect live pools.
    curve_fee_bps: u64,
    curve_fee_platform_bps: u64,
    lp_fee_platform_bps: u64,
    migration_fee_bps: u64,
    tick_spacing: u32,
    min_buy_amount: u64,
    /// Project description and social links; creator-updatable.
    project: ProjectInfo,
    // Creator first-buy tranches.
    tranches: vector<CreatorTranche<Base>>,
    /// Reserves the (Base, Quote, tick_spacing) Cetus pool key at launch
    /// so nobody can front-run the migration's pool creation.
    pool_creation_cap: PoolCreationCap,
    /// Clock time when the curve completed (0 while trading);
    /// informational, for indexers.
    completed_at_ms: u64,
    // Post-migration state.
    cetus_pool_id: Option<ID>,
    base_is_coin_a: Option<bool>,
    burn_proof: Option<CetusLPBurnProof>,
}

// === Events ===

public struct PoolCreatedEvent has copy, drop {
    pool_id: ID,
    base: TypeName,
    quote: TypeName,
    creator: address,
    threshold: u64,
    virtual_base: u64,
    virtual_quote: u64,
    curve_fee_bps: u64,
    tick_spacing: u32,
    project: ProjectInfo,
}

public struct ProjectInfoUpdatedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    project: ProjectInfo,
}

public struct TrancheLockedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    index: u64,
    kind: u8,
    unlock_ts_ms: u64,
    tvl_target: u64,
    quote_in: u64,
    base_locked: u64,
}

/// Generic over the coin pair so indexers can subscribe to one token's
/// trades directly via a MoveEventType filter (the creation event
/// instead carries the pair as TypeName fields, so a single event type
/// enumerates all launches).
public struct TradedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    trader: address,
    is_buy: bool,
    /// Net quote moved through the curve (fee excluded).
    quote_amount: u64,
    base_amount: u64,
    fee: u64,
    virtual_base: u64,
    virtual_quote: u64,
}

public struct CurveCompletedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    quote_raised: u64,
}

public struct CurveFeesDistributedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    platform_amount: u64,
    creator_amount: u64,
}

public struct TrancheUnlockedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    index: u64,
    amount: u64,
    creator: address,
}

public struct CreatorNominatedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    creator: address,
    nominee: address,
}

public struct CreatorNominationCancelledEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    creator: address,
    nominee: address,
}

public struct CreatorTransferredEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    from: address,
    to: address,
}

// === Token creation ===

/// Creates the base coin's `Currency` on behalf of the launchpad and returns a
/// `FactoryReceipt<T>`. Call this from the base coin module's `init`, passing
/// the one-time witness — that is the only place a `T` OTW exists.
///
/// Because the launchpad (not the coin author) runs the currency constructor,
/// and it uses the UNREGULATED `new_currency_with_otw`, the coin is provably
/// unregulated: the OTW is consumed here, so the same `T` can never also be
/// passed to `create_regulated_currency_v2` to obtain a `DenyCapV2`. Decimals
/// are hard-coded to the platform standard; supply is left at zero (minted
/// later in `create_token`). The `Currency<T>` is finalized (sent to the coin
/// registry) and must be shared with `coin_registry::finalize_registration`
/// before `create_token`.
public fun seal<T: drop>(
    otw: T,
    symbol: String,
    name: String,
    description: String,
    icon_url: String,
    ctx: &mut TxContext,
): FactoryReceipt<T> {
    let (initializer, treasury) = coin_registry::new_currency_with_otw<T>(
        otw,
        STD_BASE_DECIMALS,
        symbol,
        name,
        description,
        icon_url,
        ctx,
    );
    let metadata_cap = coin_registry::finalize(initializer, ctx);
    FactoryReceipt { id: object::new(ctx), treasury, metadata_cap }
}

#[test_only]
/// Mirrors `seal` for tests, but recovers the `Currency<T>` by value (via the
/// framework's test-only finalize) instead of routing it through the registry,
/// so tests can pass it straight to `create_token` as `&mut`. Produces the same
/// matched, provably-unregulated `(receipt, currency)` a real launch would.
public fun new_sealed_base_for_testing<T: drop>(
    ctx: &mut TxContext,
): (FactoryReceipt<T>, Currency<T>) {
    let otw = sui::test_utils::create_one_time_witness<T>();
    let (initializer, treasury) = coin_registry::new_currency_with_otw<T>(
        otw,
        STD_BASE_DECIMALS,
        b"TST".to_string(),
        b"Test Base".to_string(),
        b"launchpad test base coin".to_string(),
        // Matches mocks::base_icon_url(); migration tests assert this icon is
        // stamped onto the Cetus position NFT.
        b"https://example.com/base-icon.png".to_string(),
        ctx,
    );
    let (currency, metadata_cap) = coin_registry::finalize_unwrap_for_testing<T>(initializer, ctx);
    (FactoryReceipt { id: object::new(ctx), treasury, metadata_cap }, currency)
}

/// Launches a new token on the bonding curve.
///
/// Launch flow (three transactions):
/// 1. publish the base coin package — its `init` calls `seal`, which creates
///    the provably-unregulated `Currency<Base>` and returns a `FactoryReceipt`;
/// 2. `coin_registry::finalize_registration` shares that `Currency<Base>`;
/// 3. this call, passing the receipt from step 1.
///
/// Requiring `receipt: FactoryReceipt<Base>` is the fail-closed gate: only
/// `seal` mints a receipt, and only via the unregulated constructor, so a
/// base coin that could carry a `DenyCapV2` can never reach a pool.
///
/// This function mints the fixed total supply from the receipt's treasury cap,
/// takes custody of the MetadataCap (the creator keeps metadata-update rights
/// through update_base_metadata), converts the supply to burn-only (consuming
/// the treasury cap), reserves the future Cetus pool key (mints a
/// PoolCreationCap and registers the permission pair, so nobody can
/// front-run migration by creating the pool first), optionally executes
/// creator first-buy tranches, and shares the pool. Returns the change
/// from `payment`.
///
/// Note: the quote coin must be in Cetus's allowed-pair config for the
/// configured tick_spacing (SUI at 200 by default; other quotes need
/// Cetus's pool manager to allow them), otherwise this aborts.
public fun create_token<Base, Quote>(
    cfg: &mut LaunchpadConfig,
    currency: &mut Currency<Base>,
    receipt: FactoryReceipt<Base>,
    creation_fee: Coin<Quote>,
    threshold: Option<u64>,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    tranche_quote_in: vector<u64>,
    tranche_lock_kind: vector<u8>,
    tranche_lock_param: vector<u64>,
    mut payment: Coin<Quote>,
    cetus_config: &CetusGlobalConfig,
    cetus_pools: &mut CetusPools,
    clock: &Clock,
    ctx: &mut TxContext,
): Coin<Quote> {
    cfg.assert_version();
    cfg.assert_not_paused();

    let quote_params = config::enabled_quote_params(cfg, type_name::with_defining_ids<Quote>());
    let threshold = config::resolve_threshold(&quote_params, threshold);

    // Creation fee must match exactly; split it off `payment` client-side.
    assert!(creation_fee.value() == quote_params.quote_creation_fee(), EWrongCreationFee);
    send_funds(creation_fee, cfg.treasury());

    // Unwrap the factory receipt. Holding it proves the base coin was created
    // by `seal` via the unregulated constructor (provenance gate); the treasury
    // cap and metadata cap are the matched pair `seal` produced.
    let FactoryReceipt { id: receipt_id, treasury: mut treasury_cap, metadata_cap } = receipt;
    receipt_id.delete();

    // Base coin sanity: fresh supply and the expected decimals.
    assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
    assert!(coin_registry::decimals(currency) == cfg.base_decimals(), EDecimalsMismatch);
    // Redundant belt-and-suspenders: `seal` already guarantees the base coin
    // is unregulated (the receipt could not exist otherwise), so this can never
    // fire. Kept as a cheap defense-in-depth assertion.
    assert!(!coin_registry::is_regulated(currency), ERegulatedBase);

    // Mint the full fixed supply.
    let initial_base = cfg.initial_virtual_base();
    let remain_base = cfg.remain_base();
    let base_reserve = treasury_cap.mint_balance(initial_base);
    let lp_base_reserve = treasury_cap.mint_balance(remain_base);

    // Reserve the Cetus pool key for this launch while we still hold the
    // treasury cap. No base coin circulates before this point, so a
    // front-runner can never create the (Base, Quote, tick_spacing) pool
    // and brick the migration.
    let pool_creation_cap = factory::mint_pool_creation_cap<Base>(
        cetus_config,
        cetus_pools,
        &mut treasury_cap,
        ctx,
    );
    factory::register_permission_pair<Base, Quote>(
        cetus_config,
        cetus_pools,
        cfg.tick_spacing(),
        &pool_creation_cap,
        ctx,
    );

    // The MetadataCap came from the receipt (claimed by `seal`'s finalize) and
    // is stored in the pool below, so the creator keeps the right to update
    // name/description/icon through update_base_metadata. Give up mint
    // authority: supply becomes burn-only through the shared Currency object.
    coin_registry::make_supply_burn_only(currency, treasury_cap);

    let (virtual_base, virtual_quote, virtual_base_floor) =
        curve::derive_virtual_reserves(initial_base, remain_base, threshold);

    let mut pool = Pool<Base, Quote> {
        id: object::new(ctx),
        creator: ctx.sender(),
        pending_creator: option::none(),
        phase: PHASE_TRADING,
        virtual_base,
        virtual_quote,
        virtual_base_floor,
        threshold,
        base_reserve,
        lp_base_reserve,
        quote_reserve: balance::zero(),
        platform_fees: balance::zero(),
        creator_fees: balance::zero(),
        curve_fee_bps: cfg.curve_fee_bps(),
        curve_fee_platform_bps: cfg.curve_fee_platform_bps(),
        lp_fee_platform_bps: cfg.lp_fee_platform_bps(),
        migration_fee_bps: cfg.migration_fee_bps(),
        tick_spacing: cfg.tick_spacing(),
        min_buy_amount: quote_params.quote_min_buy_amount(),
        project: new_project_info(description, twitter, telegram, website),
        tranches: vector[],
        pool_creation_cap,
        completed_at_ms: 0,
        cetus_pool_id: option::none(),
        base_is_coin_a: option::none(),
        burn_proof: option::none(),
    };
    let pool_id = pool.id.to_inner();
    dof::add(&mut pool.id, MetadataCapKey {}, metadata_cap);

    event::emit(PoolCreatedEvent {
        pool_id,
        base: type_name::with_defining_ids<Base>(),
        quote: type_name::with_defining_ids<Quote>(),
        creator: pool.creator,
        threshold,
        virtual_base,
        virtual_quote,
        curve_fee_bps: pool.curve_fee_bps,
        tick_spacing: pool.tick_spacing,
        project: pool.project,
    });

    // Creator first-buy tranches. A market-cap target below
    // multiplier x graduation market cap would unlock (almost)
    // immediately after migration; graduation market cap is
    // (I + R) * threshold / R in quote units.
    let min_mcap_target =
        (cfg.tvl_target_multiplier() as u128)
            * ((initial_base + remain_base) as u128)
            * (threshold as u128)
            / (remain_base as u128);
    // Independent per-lock-kind first-buy caps, in base units of total supply.
    let supply = ((initial_base + remain_base) as u128);
    let max_time_base = ((supply * (cfg.first_buy_time_cap_bps() as u128) / 10_000) as u64);
    let max_tvl_base = ((supply * (cfg.first_buy_tvl_cap_bps() as u128) / 10_000) as u64);
    execute_tranche_buys(
        &mut pool,
        tranche_quote_in,
        tranche_lock_kind,
        tranche_lock_param,
        &mut payment,
        cfg.min_lock_duration_ms(),
        quote_params.quote_min_tvl_target(),
        min_mcap_target,
        max_time_base,
        max_tvl_base,
        clock,
    );

    config::register_pool(cfg, type_name::with_defining_ids<Base>(), pool_id);
    transfer::share_object(pool);
    payment
}

/// CLI-friendly wrapper: change from `payment` is returned to the sender.
entry fun create_token_entry<Base, Quote>(
    cfg: &mut LaunchpadConfig,
    currency: &mut Currency<Base>,
    receipt: FactoryReceipt<Base>,
    creation_fee: Coin<Quote>,
    threshold: Option<u64>,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    tranche_quote_in: vector<u64>,
    tranche_lock_kind: vector<u8>,
    tranche_lock_param: vector<u64>,
    payment: Coin<Quote>,
    cetus_config: &CetusGlobalConfig,
    cetus_pools: &mut CetusPools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let change = create_token<Base, Quote>(
        cfg,
        currency,
        receipt,
        creation_fee,
        threshold,
        description,
        twitter,
        telegram,
        website,
        tranche_quote_in,
        tranche_lock_kind,
        tranche_lock_param,
        payment,
        cetus_config,
        cetus_pools,
        clock,
        ctx,
    );
    send_funds(change, ctx.sender());
}

fun execute_tranche_buys<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
    quote_in: vector<u64>,
    lock_kind: vector<u8>,
    lock_param: vector<u64>,
    payment: &mut Coin<Quote>,
    min_lock_duration_ms: u64,
    min_tvl_target: u64,
    min_mcap_target: u128,
    max_time_base: u64,
    max_tvl_base: u64,
    clock: &Clock,
) {
    let count = quote_in.length();
    assert!(lock_kind.length() == count, ETrancheVectorMismatch);
    assert!(lock_param.length() == count, ETrancheVectorMismatch);
    assert!(count <= MAX_TRANCHES, ETooManyTranches);

    // Cumulative base locked per lock kind; each capped independently so the
    // two first-buy kinds stack without interfering.
    let mut time_base = 0;
    let mut tvl_base = 0;
    let mut i = 0;
    while (i < count) {
        let kind = lock_kind[i];
        let param = lock_param[i];
        // Locks must be substantive, not nominal (e.g. now+1ms or a
        // market-cap target of 1): admin-configured floors apply.
        if (kind == LOCK_KIND_TIME) {
            assert!(param >= clock.timestamp_ms() + min_lock_duration_ms, EInvalidLockParam);
        } else if (kind == LOCK_KIND_TVL) {
            assert!(param >= min_tvl_target && param > 0, EInvalidLockParam);
            assert!((param as u128) >= min_mcap_target, EInvalidLockParam);
        } else {
            abort EInvalidLockKind
        };

        let gross = quote_in[i];
        assert!(gross >= pool.min_buy_amount, EBelowMinBuy);
        assert!(payment.value() >= gross, EInsufficientPayment);
        let creator = pool.creator;
        // Remaining first-buy budget for this lock kind. The buy is clamped to
        // it; any quote beyond what fits under the cap is returned to the
        // creator as change (rather than aborting the whole launch). TIME and
        // TVL budgets are tracked independently so the two kinds stack.
        let budget = if (kind == LOCK_KIND_TIME) max_time_base - time_base
            else max_tvl_base - tvl_base;
        let (base_out, change) =
            buy_internal(pool, payment.balance_mut().split(gross), creator, budget, clock);
        // Cap-clamped (and/or completion-clamped) excess quote returns to payment.
        let quote_spent = gross - change.value();
        payment.balance_mut().join(change);

        let base_locked = base_out.value();
        if (kind == LOCK_KIND_TIME) time_base = time_base + base_locked
        else tvl_base = tvl_base + base_locked;
        if (base_locked == 0) {
            // This lock kind's cap was already exhausted by an earlier tranche;
            // nothing to lock (the quote was fully refunded above). Skip it
            // rather than record a no-op tranche.
            base_out.destroy_zero();
        } else {
            // Emit the on-chain tranche index (matches unlock calls), not the
            // input-vector index, so skipped no-ops don't shift it.
            let tranche_index = pool.tranches.length();
            pool.tranches.push_back(CreatorTranche {
                locked: base_out,
                kind,
                unlock_ts_ms: if (kind == LOCK_KIND_TIME) param else 0,
                tvl_target: if (kind == LOCK_KIND_TVL) param else 0,
                claimed: false,
            });
            event::emit(TrancheLockedEvent<Base, Quote> {
                pool_id: pool.id.to_inner(),
                index: tranche_index,
                kind,
                unlock_ts_ms: if (kind == LOCK_KIND_TIME) param else 0,
                tvl_target: if (kind == LOCK_KIND_TVL) param else 0,
                quote_in: quote_spent,
                base_locked,
            });
        };
        i = i + 1;
    };
}

// === Trading ===

/// Buys base with a gross quote input (fee taken from it). Returns the
/// bought base and any unused quote (nonzero only on the completing buy).
public fun buy<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    quote_in: Coin<Quote>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): (Coin<Base>, Coin<Quote>) {
    cfg.assert_version();
    cfg.assert_not_paused();
    assert!(quote_in.value() >= pool.min_buy_amount, EBelowMinBuy);

    let (base_out, change) =
        buy_internal(pool, quote_in.into_balance(), ctx.sender(), NO_FIRST_BUY_CAP, clock);
    assert!(base_out.value() >= min_base_out, ESlippage);
    (base_out.into_coin(ctx), change.into_coin(ctx))
}

/// Sells base for quote (fee taken from the quote proceeds).
public fun sell<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    base_in: Coin<Base>,
    min_quote_out: u64,
    ctx: &mut TxContext,
): Coin<Quote> {
    cfg.assert_version();
    assert!(pool.phase == PHASE_TRADING, ENotTrading);

    let amount_in = base_in.value();
    let (quote_out, new_vb, new_vq) =
        curve::sell_out(pool.virtual_base, pool.virtual_quote, amount_in);
    let fee = curve::fee_amount(quote_out, pool.curve_fee_bps);
    let net_out = quote_out - fee;
    assert!(net_out > 0, EZeroOutput);
    assert!(net_out >= min_quote_out, ESlippage);

    pool.virtual_base = new_vb;
    pool.virtual_quote = new_vq;
    pool.base_reserve.join(base_in.into_balance());
    let mut out = pool.quote_reserve.split(quote_out);
    pool.accrue_fee(out.split(fee));

    event::emit(TradedEvent<Base, Quote> {
        pool_id: pool.id.to_inner(),
        trader: ctx.sender(),
        is_buy: false,
        quote_amount: quote_out,
        base_amount: amount_in,
        fee,
        virtual_base: new_vb,
        virtual_quote: new_vq,
    });
    out.into_coin(ctx)
}

entry fun buy_entry<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    quote_in: Coin<Quote>,
    min_base_out: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (base_out, change) = buy(cfg, pool, quote_in, min_base_out, clock, ctx);
    send_funds(base_out, ctx.sender());
    send_funds(change, ctx.sender());
}

entry fun sell_entry<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    base_in: Coin<Base>,
    min_quote_out: u64,
    ctx: &mut TxContext,
) {
    let quote_out = sell(cfg, pool, base_in, min_quote_out, ctx);
    send_funds(quote_out, ctx.sender());
}

/// Curve buy over a gross quote balance. Returns `(base_out, change)`;
/// `change` is nonzero only when the buy completes the curve.
fun buy_internal<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
    mut quote_in: Balance<Quote>,
    trader: address,
    max_base_out: u64,
    clock: &Clock,
): (Balance<Base>, Balance<Quote>) {
    assert!(pool.phase == PHASE_TRADING, ENotTrading);

    let gross = quote_in.value();
    let fee = curve::fee_amount(gross, pool.curve_fee_bps);
    let net = gross - fee;

    // Clamp base output to the smaller of the remaining curve (completion) and
    // an optional per-buy cap: creator first-buys pass their remaining cap
    // budget; public buys pass NO_FIRST_BUY_CAP. Excess quote is returned.
    let sellable = pool.virtual_base - pool.virtual_base_floor;
    let cap = if (sellable < max_base_out) sellable else max_base_out;
    let (out, new_vb, new_vq) = curve::buy_out(pool.virtual_base, pool.virtual_quote, net);
    assert!(out > 0, EZeroOutput);

    let (base_out_amount, net_used, fee_used, new_vb, new_vq) = if (out >= cap) {
        // Charge only what the clamped range costs; the rest is caller change.
        let (cost, new_vb, new_vq) = curve::buy_cost_exact_out(
            pool.virtual_base,
            pool.virtual_quote,
            cap,
        );
        (cap, cost, curve::fee_amount(cost, pool.curve_fee_bps), new_vb, new_vq)
    } else {
        (out, net, fee, new_vb, new_vq)
    };

    pool.virtual_base = new_vb;
    pool.virtual_quote = new_vq;
    pool.quote_reserve.join(quote_in.split(net_used));
    pool.accrue_fee(quote_in.split(fee_used));
    // Whatever remains in quote_in is the caller's change.

    let base_out = pool.base_reserve.split(base_out_amount);

    event::emit(TradedEvent<Base, Quote> {
        pool_id: pool.id.to_inner(),
        trader,
        is_buy: true,
        quote_amount: net_used,
        base_amount: base_out_amount,
        fee: fee_used,
        virtual_base: new_vb,
        virtual_quote: new_vq,
    });

    if (pool.virtual_base == pool.virtual_base_floor) {
        pool.phase = PHASE_COMPLETED;
        pool.completed_at_ms = clock.timestamp_ms();
        event::emit(CurveCompletedEvent<Base, Quote> {
            pool_id: pool.id.to_inner(),
            quote_raised: pool.quote_reserve.value(),
        });
    };
    (base_out, quote_in)
}

fun accrue_fee<Base, Quote>(pool: &mut Pool<Base, Quote>, mut fee: Balance<Quote>) {
    let platform_cut =
        ((fee.value() as u128) * (pool.curve_fee_platform_bps as u128)
            / (config::bps_denominator() as u128)) as u64;
    pool.platform_fees.join(fee.split(platform_cut));
    pool.creator_fees.join(fee);
}

// === Fee distribution ===

/// Permissionless: pays accrued curve fees out to the platform treasury
/// and the creator.
public fun distribute_curve_fees<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
) {
    cfg.assert_version();
    let platform_amount = pool.platform_fees.value();
    let creator_amount = pool.creator_fees.value();
    if (platform_amount > 0) {
        balance::send_funds(pool.platform_fees.withdraw_all(), cfg.treasury());
    };
    if (creator_amount > 0) {
        balance::send_funds(pool.creator_fees.withdraw_all(), pool.creator);
    };
    if (platform_amount > 0 || creator_amount > 0) {
        event::emit(CurveFeesDistributedEvent<Base, Quote> {
            pool_id: pool.id.to_inner(),
            platform_amount,
            creator_amount,
        });
    };
}

// === Creator tranche unlock (time path) ===

/// Permissionless trigger; the tokens always go to the pool creator.
/// Time-locked tranches unlock in any phase.
public fun unlock_tranche_time<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    index: u64,
    clock: &Clock,
) {
    cfg.assert_version();
    let now = clock.timestamp_ms();
    let creator = pool.creator;
    let pool_id = pool.id.to_inner();
    let tranche = pool.borrow_tranche_mut(index);
    assert!(tranche.kind == LOCK_KIND_TIME, ETrancheLocked);
    assert!(now >= tranche.unlock_ts_ms, ETrancheLocked);
    let unlocked = take_tranche(tranche);
    event::emit(TrancheUnlockedEvent<Base, Quote> {
        pool_id,
        index,
        amount: unlocked.value(),
        creator,
    });
    balance::send_funds(unlocked, creator);
}

// === Creator role ===

// Two-step transfer of the whole creator role: the creator share of
// curve/LP fees and rewards, future tranche unlocks (including tranches
// locked before the transfer), and the project info / base metadata
// update rights. Nothing changes hands until the nominee accepts —
// while a nomination is pending, every right stays with the current
// creator, and a typo'd address can never take the role.

/// Creator-only: nominate the next creator. Overwrites any pending
/// nomination.
public fun nominate_creator<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    to: address,
    ctx: &TxContext,
) {
    cfg.assert_version();
    assert!(ctx.sender() == pool.creator, ENotCreator);
    pool.pending_creator = option::some(to);
    event::emit(CreatorNominatedEvent<Base, Quote> {
        pool_id: pool.id.to_inner(),
        creator: pool.creator,
        nominee: to,
    });
}

/// Creator-only: withdraw the pending nomination.
public fun cancel_creator_nomination<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    ctx: &TxContext,
) {
    cfg.assert_version();
    assert!(ctx.sender() == pool.creator, ENotCreator);
    assert!(pool.pending_creator.is_some(), ENoPendingCreator);
    let nominee = pool.pending_creator.extract();
    event::emit(CreatorNominationCancelledEvent<Base, Quote> {
        pool_id: pool.id.to_inner(),
        creator: pool.creator,
        nominee,
    });
}

/// Nominee-only: complete the transfer and take over the creator role.
public fun accept_creator<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    ctx: &TxContext,
) {
    cfg.assert_version();
    assert!(pool.pending_creator == option::some(ctx.sender()), ENotPendingCreator);
    pool.pending_creator = option::none();
    event::emit(CreatorTransferredEvent<Base, Quote> {
        pool_id: pool.id.to_inner(),
        from: pool.creator,
        to: ctx.sender(),
    });
    pool.creator = ctx.sender();
}

// === Project info ===

/// Creator-only: replace the pool's project description and links.
public fun update_project_info<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    description: String,
    twitter: String,
    telegram: String,
    website: String,
    ctx: &TxContext,
) {
    cfg.assert_version();
    assert!(ctx.sender() == pool.creator, ENotCreator);
    pool.project = new_project_info(description, twitter, telegram, website);
    event::emit(ProjectInfoUpdatedEvent<Base, Quote> {
        pool_id: pool.id.to_inner(),
        project: pool.project,
    });
}

fun new_project_info(
    description: String,
    twitter: String,
    telegram: String,
    website: String,
): ProjectInfo {
    assert!(description.length() <= MAX_DESCRIPTION_LEN, EProjectInfoTooLong);
    assert!(twitter.length() <= MAX_LINK_LEN, EProjectInfoTooLong);
    assert!(telegram.length() <= MAX_LINK_LEN, EProjectInfoTooLong);
    assert!(website.length() <= MAX_LINK_LEN, EProjectInfoTooLong);
    ProjectInfo { description, twitter, telegram, website }
}

/// Returns `(description, twitter, telegram, website)`.
public fun project_info<Base, Quote>(
    pool: &Pool<Base, Quote>,
): (String, String, String, String) {
    (
        pool.project.description,
        pool.project.twitter,
        pool.project.telegram,
        pool.project.website,
    )
}

// === Metadata management ===

/// Creator-only: update the launched coin's metadata through the
/// MetadataCap held by the pool. The symbol is immutable in
/// coin_registry; pass none for fields to leave unchanged.
public fun update_base_metadata<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &Pool<Base, Quote>,
    currency: &mut Currency<Base>,
    mut name: Option<String>,
    mut description: Option<String>,
    mut icon_url: Option<String>,
    ctx: &TxContext,
) {
    cfg.assert_version();
    assert!(ctx.sender() == pool.creator, ENotCreator);
    let cap = dof::borrow<MetadataCapKey, MetadataCap<Base>>(&pool.id, MetadataCapKey {});
    if (name.is_some()) {
        coin_registry::set_name(currency, cap, name.extract());
    };
    if (description.is_some()) {
        coin_registry::set_description(currency, cap, description.extract());
    };
    if (icon_url.is_some()) {
        coin_registry::set_icon_url(currency, cap, icon_url.extract());
    };
    name.destroy_none();
    description.destroy_none();
    icon_url.destroy_none();
}

// === Views ===

/// Quotes a buy: returns `(base_out, fee)` for a gross quote input, or
/// `(0, 0)` when the curve is no longer trading.
public fun quote_buy<Base, Quote>(pool: &Pool<Base, Quote>, quote_in: u64): (u64, u64) {
    if (pool.phase != PHASE_TRADING) return (0, 0);
    let fee = curve::fee_amount(quote_in, pool.curve_fee_bps);
    let net = quote_in - fee;
    let sellable = pool.virtual_base - pool.virtual_base_floor;
    let out = curve::buy_out_preview(pool.virtual_base, pool.virtual_quote, net);
    if (out >= sellable) {
        let (cost, _, _) = curve::buy_cost_exact_out(
            pool.virtual_base,
            pool.virtual_quote,
            sellable,
        );
        (sellable, curve::fee_amount(cost, pool.curve_fee_bps))
    } else {
        (out, fee)
    }
}

/// Quotes a sell: returns `(net_quote_out, fee)` for a base input, or
/// `(0, 0)` when the curve is no longer trading.
public fun quote_sell<Base, Quote>(pool: &Pool<Base, Quote>, base_in: u64): (u64, u64) {
    if (pool.phase != PHASE_TRADING) return (0, 0);
    let (quote_out, _, _) =
        curve::sell_out(pool.virtual_base, pool.virtual_quote, base_in);
    let fee = curve::fee_amount(quote_out, pool.curve_fee_bps);
    (quote_out - fee, fee)
}

public fun phase<Base, Quote>(pool: &Pool<Base, Quote>): u8 { pool.phase }

public fun creator<Base, Quote>(pool: &Pool<Base, Quote>): address { pool.creator }

public fun pending_creator<Base, Quote>(pool: &Pool<Base, Quote>): Option<address> {
    pool.pending_creator
}

public fun threshold<Base, Quote>(pool: &Pool<Base, Quote>): u64 { pool.threshold }

public fun virtual_reserves<Base, Quote>(pool: &Pool<Base, Quote>): (u64, u64, u64) {
    (pool.virtual_base, pool.virtual_quote, pool.virtual_base_floor)
}

public fun real_reserves<Base, Quote>(pool: &Pool<Base, Quote>): (u64, u64, u64) {
    (pool.base_reserve.value(), pool.lp_base_reserve.value(), pool.quote_reserve.value())
}

public fun accrued_fees<Base, Quote>(pool: &Pool<Base, Quote>): (u64, u64) {
    (pool.platform_fees.value(), pool.creator_fees.value())
}

public fun tranche_count<Base, Quote>(pool: &Pool<Base, Quote>): u64 {
    pool.tranches.length()
}

/// Returns `(kind, unlock_ts_ms, tvl_target, locked_amount, claimed)`.
public fun tranche_info<Base, Quote>(
    pool: &Pool<Base, Quote>,
    index: u64,
): (u8, u64, u64, u64, bool) {
    assert!(index < pool.tranches.length(), ETrancheNotFound);
    let tranche = &pool.tranches[index];
    (
        tranche.kind,
        tranche.unlock_ts_ms,
        tranche.tvl_target,
        tranche.locked.value(),
        tranche.claimed,
    )
}

public fun cetus_pool_id<Base, Quote>(pool: &Pool<Base, Quote>): Option<ID> {
    pool.cetus_pool_id
}

public fun base_is_coin_a<Base, Quote>(pool: &Pool<Base, Quote>): Option<bool> {
    pool.base_is_coin_a
}

public fun migration_fee_bps<Base, Quote>(pool: &Pool<Base, Quote>): u64 {
    pool.migration_fee_bps
}

public fun lp_fee_platform_bps<Base, Quote>(pool: &Pool<Base, Quote>): u64 {
    pool.lp_fee_platform_bps
}

public fun tick_spacing<Base, Quote>(pool: &Pool<Base, Quote>): u32 { pool.tick_spacing }

public fun lock_kind_time(): u8 { LOCK_KIND_TIME }

public fun lock_kind_tvl(): u8 { LOCK_KIND_TVL }

public fun phase_trading(): u8 { PHASE_TRADING }

public fun phase_completed(): u8 { PHASE_COMPLETED }

public fun phase_migrated(): u8 { PHASE_MIGRATED }

public fun completed_at_ms<Base, Quote>(pool: &Pool<Base, Quote>): u64 {
    pool.completed_at_ms
}

// === Package-internal API (migration module) ===

/// Hands the migration module everything that seeds the CLMM pool:
/// all raised quote and the reserved LP base (plus any defensive dust
/// left on the sellable side).
public(package) fun withdraw_for_migration<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
): (Balance<Base>, Balance<Quote>) {
    assert!(pool.phase == PHASE_COMPLETED, ENotCompleted);
    let mut base = pool.lp_base_reserve.withdraw_all();
    // The drain clamp empties base_reserve exactly; join defensively.
    base.join(pool.base_reserve.withdraw_all());
    (base, pool.quote_reserve.withdraw_all())
}

public(package) fun set_migrated<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
    cetus_pool_id: ID,
    base_is_coin_a: bool,
) {
    pool.phase = PHASE_MIGRATED;
    pool.cetus_pool_id.fill(cetus_pool_id);
    pool.base_is_coin_a.fill(base_is_coin_a);
}

public(package) fun store_burn_proof<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
    proof: CetusLPBurnProof,
) {
    pool.burn_proof.fill(proof);
}

/// Quote dust from migration joins the platform's accrued fees.
public(package) fun accrue_platform_quote<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
    quote: Balance<Quote>,
) {
    pool.platform_fees.join(quote);
}

public(package) fun borrow_burn_proof_mut<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
): &mut CetusLPBurnProof {
    pool.burn_proof.borrow_mut()
}

public(package) fun borrow_creation_cap<Base, Quote>(
    pool: &Pool<Base, Quote>,
): &PoolCreationCap {
    &pool.pool_creation_cap
}

/// Takes a TVL tranche's balance after the migration module validated
/// the TVL condition. Returns `(unlocked, creator)`.
public(package) fun take_tvl_tranche<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
    index: u64,
): (Balance<Base>, address) {
    let creator = pool.creator;
    let pool_id = pool.id.to_inner();
    let tranche = pool.borrow_tranche_mut(index);
    assert!(tranche.kind == LOCK_KIND_TVL, ETrancheLocked);
    let unlocked = take_tranche(tranche);
    event::emit(TrancheUnlockedEvent<Base, Quote> {
        pool_id,
        index,
        amount: unlocked.value(),
        creator,
    });
    (unlocked, creator)
}

public(package) fun tranche_tvl_target<Base, Quote>(
    pool: &Pool<Base, Quote>,
    index: u64,
): u64 {
    assert!(index < pool.tranches.length(), ETrancheNotFound);
    pool.tranches[index].tvl_target
}


public(package) fun assert_migrated<Base, Quote>(pool: &Pool<Base, Quote>) {
    assert!(pool.phase == PHASE_MIGRATED, ENotMigrated);
}

/// Asserts the caller passed the canonical burn-only Currency object.
public(package) fun assert_burn_only_currency<Base>(currency: &Currency<Base>) {
    assert!(coin_registry::is_supply_burn_only(currency), ESupplyNotBurnOnly);
}

// === Internal helpers ===

fun borrow_tranche_mut<Base, Quote>(
    pool: &mut Pool<Base, Quote>,
    index: u64,
): &mut CreatorTranche<Base> {
    assert!(index < pool.tranches.length(), ETrancheNotFound);
    &mut pool.tranches[index]
}

fun take_tranche<Base>(tranche: &mut CreatorTranche<Base>): Balance<Base> {
    assert!(!tranche.claimed, ETrancheAlreadyClaimed);
    tranche.claimed = true;
    tranche.locked.withdraw_all()
}

/// Single outbound-payment choke point: non-zero value is credited to
/// the recipient's address balance (funds accumulator) instead of
/// creating a Coin object; zero coins are destroyed.
public(package) fun send_funds<T>(coin: Coin<T>, recipient: address) {
    if (coin.value() > 0) {
        balance::send_funds(coin.into_balance(), recipient);
    } else {
        coin.destroy_zero();
    }
}

// === Test helpers ===

#[test_only]
public fun tranche_locked_event_amounts<Base, Quote>(
    ev: &TrancheLockedEvent<Base, Quote>,
): (u64, u64) {
    (ev.quote_in, ev.base_locked)
}

#[test_only]
public fun fees_distributed_event_amounts<Base, Quote>(
    ev: &CurveFeesDistributedEvent<Base, Quote>,
): (u64, u64) {
    (ev.platform_amount, ev.creator_amount)
}

#[test_only]
public fun tranche_unlocked_event_amount<Base, Quote>(
    ev: &TrancheUnlockedEvent<Base, Quote>,
): (u64, address) {
    (ev.amount, ev.creator)
}
