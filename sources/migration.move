/// Everything that touches Cetus CLMM and lp_burn: graduation migration,
/// post-migration LP fee claiming, and TVL-based creator tranche unlocks.
///
/// Cetus orders pool coin types by the ASCII bytes of their full type names
/// (`CoinTypeA` must be the greater one), so whether `Base` ends up as coin
/// A or coin B is only known at runtime. `migrate` branches on
/// `factory::is_right_order` and records the orientation in the pool; the
/// claim/unlock entry points come in a straight and an `_inverted` variant
/// because the Cetus pool's type instantiation is fixed in the signature.
module bondingcurvesui::migration;

use cetus_clmm::clmm_math;
use cetus_clmm::config::GlobalConfig;
use cetus_clmm::factory::{Self, Pools};
use cetus_clmm::pool::{Self as clmm_pool, Pool as CetusPool};
use cetus_clmm::pool_creator;
use cetus_clmm::tick_math;
use integer_mate::i32;
use cetus_clmm::position::{Self, Position};
use cetus_clmm::rewarder::RewarderGlobalVault;
use lp_burn::lp_burn::{Self, BurnManager};
use std::type_name::{Self, TypeName};
use sui::clock::Clock;
use sui::coin::{Self, Coin};
use sui::coin_registry::{Self, Currency};
use sui::event;

use bondingcurvesui::config::{Self, LaunchpadConfig};
use bondingcurvesui::curve;
use bondingcurvesui::pool::{Self, Pool};

// === Errors ===

/// The passed Cetus pool is not the one this launch migrated into.
const EWrongCetusPool: u64 = 1;
/// The passed Cetus pool orientation does not match the entry point.
const EWrongOrientation: u64 = 2;
/// Seed sqrt price is not clear of the full-range endpoints.
const ESeedPriceOutOfEnvelope: u64 = 3;

/// Margin the seed sqrt price must keep from either full-range endpoint.
/// Matches `specs::cetus_model_specs::ENDPOINT_GUARD`; see the assert in
/// `migrate_core` for why it is checked rather than assumed.
const ENVELOPE_GUARD: u128 = 0x1_0000_0000; // 2^32

// === Events ===

/// Generic over the coin pair (like TradedEvent) so a per-token indexer
/// catches the migration with the same type-filter family and can
/// switch its price feed to the Cetus pool's own events.
public struct MigratedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    cetus_pool_id: ID,
    /// Gross amounts withdrawn from the curve (before the migration fee).
    base_amount: u64,
    quote_amount: u64,
    sqrt_price_x64: u128,
    base_is_coin_a: bool,
    tick_spacing: u32,
    /// Migration fee on the raised quote, sent to the treasury.
    migration_fee: u64,
    /// Base not absorbed by the CLMM seed (the fee's mirror share plus
    /// rounding dust), burned.
    base_burned: u64,
    quote_dust_to_platform: u64,
}

public struct LpFeesClaimedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    base_burned: u64,
    quote_platform: u64,
    quote_creator: u64,
}

/// Emitted on every claim call, whether or not it opened the gate or released
/// anything, so an indexer can plot release progress.
///
/// `sqrt_price_x64` and `market_cap_in_quote` are the values observed AT THE
/// CALL. On the call that flips `gate_open` these are worth auditing: a gate
/// opened at a price that never appears at any block boundary is the
/// signature of a single-transaction pump, and the linear window gives
/// holders the whole schedule to react to it.
public struct TvlTrancheClaimedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    /// Circulating supply (from the Currency) x CLMM price, in quote.
    market_cap_in_quote: u128,
    tvl_target: u64,
    /// Whether the target held at this observation.
    qualified: bool,
    /// True once the gate has opened (including on this very call).
    gate_open: bool,
    /// Clock time the gate opened; the linear window runs from here.
    gate_opened_at_ms: u64,
    /// Base released by this call. Always zero on the gate-opening call.
    amount: u64,
    vesting_duration_ms: u64,
    sqrt_price_x64: u128,
    total_supply: u64,
}

public struct LpRewardsClaimedEvent<phantom Base, phantom Quote> has copy, drop {
    pool_id: ID,
    reward_type: TypeName,
    platform_amount: u64,
    creator_amount: u64,
}

// === Migration ===

/// Permissionless crank: once the curve completes, anyone can migrate
/// the raised liquidity into a fresh full-range Cetus CLMM position,
/// burn the position through lp_burn (the proof stays in the launchpad
/// pool), and flush accrued curve fees.
///
/// Deliberately NOT pause-gated, unlike `create_token` and `buy`. Those two
/// are discretionary new exposure, and pausing them still leaves `sell` open
/// as an exit. A COMPLETED pool has no such exit: `sell` requires
/// PHASE_TRADING, so it is already closed by the time this runs. Gating
/// migration on the pause switch would therefore trap holders with no way out
/// at all until an admin relents — strictly worse than any incident it could
/// contain.
///
/// The flip side is the guarantee that makes it worth it: once the curve
/// completes, graduation is unstoppable, by the admin included. The raise
/// reaches a permissionless AMM regardless of who wants otherwise.
///
/// The cost of that guarantee is real and accepted: if a defect is ever found
/// in the seeding math, completed pools keep migrating through it and there
/// is no switch to stop them. That argues for verifying migration changes
/// exhaustively before publishing, not for adding a freeze.
public fun migrate<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    currency: &mut Currency<Base>,
    burn_manager: &mut BurnManager,
    cetus_config: &GlobalConfig,
    cetus_pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let position = migrate_core(cfg, pool, currency, cetus_config, cetus_pools, clock, ctx);
    let proof = lp_burn::burn_lp_v2(burn_manager, position, ctx);
    pool::store_burn_proof(pool, proof);
}

/// Creates the Cetus pool with all raised liquidity and returns the LP
/// position; separated from `migrate` so tests can run the (locally
/// executable) CLMM part without the lp_burn interface stub.
fun migrate_core<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    currency: &mut Currency<Base>,
    cetus_config: &GlobalConfig,
    cetus_pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
): Position {
    cfg.assert_version();
    pool::assert_burn_only_currency(currency);

    // Aborts unless the curve is COMPLETED, so migration cannot run
    // twice or early; everything below is atomic with it.
    let (mut base, mut quote) = pool::withdraw_for_migration(pool);
    let base_amount = base.value();
    let quote_amount = quote.value();
    let tick_spacing = pool.tick_spacing();
    let (tick_lower, tick_upper) = pool_creator::full_range_tick_range(tick_spacing);

    // Migration fee: skimmed from the raised quote before seeding, with
    // the base leg shrunk by the same ratio. The seed price is computed
    // from the GROSS amounts, i.e. the curve's final price, so graduation
    // stays gap-free.
    let migration_fee = curve::fee_amount(quote_amount, pool.migration_fee_bps());
    if (migration_fee > 0) {
        sui::balance::send_funds(quote.split(migration_fee), cfg.treasury());
    };
    let quote_net = quote_amount - migration_fee;
    let base_seed = curve::seed_base_amount(base_amount, quote_net, quote_amount);

    // The pool key was reserved at launch (permission pair + creation
    // cap held by the pool), so this cannot be front-run or blocked by a
    // third party creating the pool first.
    let base_is_coin_a = factory::is_right_order<Base, Quote>();
    let sqrt_price = if (base_is_coin_a) {
        // A = Base, B = Quote; price = quote per base.
        curve::initial_sqrt_price_x64(base_amount, quote_amount)
    } else {
        // A = Quote, B = Base; price inverted.
        curve::initial_sqrt_price_x64(quote_amount, base_amount)
    };

    // Which leg binds the deposit? For a full-range position, seeding a base
    // leg of `base_seed` costs `(1 - lower/P) / (1 - P/U)` times that leg's
    // proportional share of quote. That ratio crosses 1 at
    // `P = sqrt(lower * upper)`, which for every tick spacing is a graduation
    // price of one RAW quote unit per RAW base unit.
    //
    // Below the crossover the base leg binds and fixing it is safe — that is
    // the historical path. Above it, fixing the base leg would demand more
    // quote than the fee-shrunk `quote_net` we hold and abort inside Cetus
    // (`EAmountInAboveMaxLimit`) with NO way to retry: the phase is already
    // COMPLETED and every input is frozen, so each attempt fails identically
    // and the whole raise is stranded forever. Flooring the sqrt price buys
    // only ~1e-19 of relative slack against a ~1e-10 shortfall, so it does
    // not save us — do not reinstate that argument.
    //
    // So ask Cetus's own math which leg binds instead of assuming. Above the
    // crossover we fix the QUOTE leg, hand the CLMM the whole base balance,
    // and let the burn below absorb whatever it does not take.
    // Cetus ignores the current-tick argument (`_current_tick_index`), so this
    // derivation is redundant today. Passed anyway rather than `i32::zero()`:
    // if a future pinned Cetus rev starts reading it, a real tick stays
    // correct where a zero would silently be wrong.
    //
    // The envelope is CHECKED here rather than argued. The seeding proof
    // (`specs::cetus_model_specs::binding_leg_fallback_is_safe`) takes it as
    // a precondition: the seed price must clear both full-range endpoints by
    // ENVELOPE_GUARD, which is also exactly the condition under which Cetus's
    // own u128 liquidity and `checked_shlw` do not abort.
    //
    // That precondition is now PROVEN unreachable-by-violation:
    // `specs::envelope_specs::seed_price_is_inside_envelope` shows both
    // endpoints are cleared whenever each leg is at least 1000. The only
    // config constant it needs is MIN_QUOTE_THRESHOLD -- NOT the
    // EReserveOverflow bound on remain_base, which turns out not to be
    // load-bearing here, so relaxing the launch-ratio bounds cannot reach
    // this assert. Price margins at the reachable extremes are 15.8x at the
    // lower endpoint and 31.6x at the upper (wider still once the reserve
    // bound is counted).
    //
    // The assert stays anyway. The proof is about `curve::
    // initial_sqrt_price_x64` and the endpoint literals; this is the runtime
    // check that the two agree, and the failure mode it guards -- a
    // permanent abort on a COMPLETED pool, whose raise can then never be
    // recovered -- is severe enough to be worth naming at its real source
    // rather than surfacing from inside the dependency.
    assert!(
        sqrt_price > (curve::full_range_lower_sqrt_price() as u128) + ENVELOPE_GUARD,
        ESeedPriceOutOfEnvelope,
    );
    assert!(
        sqrt_price < (curve::full_range_upper_sqrt_price() as u128) - ENVELOPE_GUARD,
        ESeedPriceOutOfEnvelope,
    );
    let (_, need_a, need_b) = clmm_math::get_liquidity_by_amount(
        i32::from_u32(tick_lower),
        i32::from_u32(tick_upper),
        tick_math::get_tick_at_sqrt_price(sqrt_price),
        sqrt_price,
        base_seed,
        base_is_coin_a,
    );
    let need_quote = if (base_is_coin_a) need_b else need_a;
    let fix_base = need_quote <= quote_net;

    // Fixing the base leg means the CLMM takes exactly `base_seed`, so the
    // fee's mirror share is split off here and burned. Fixing the quote leg
    // means the CLMM sizes the base leg itself, so offer it everything —
    // `base_seed` would be cutting it too fine at the crossover, where the
    // proportional split leaves no room for Cetus's ceiled rounding.
    let base_excess = if (fix_base) {
        base.split(base_amount - base_seed)
    } else {
        sui::balance::zero<Base>()
    };

    // `fix_amount_a` is about the Cetus pool's coin A, not about base/quote:
    // it agrees with `fix_base` only when the base coin IS coin A.
    let fix_amount_a = base_is_coin_a == fix_base;
    // The base coin's icon becomes the Position NFT image.
    let position_url = coin_registry::icon_url(currency);
    let (position, base_left, quote_left) = if (base_is_coin_a) {
        let (position, base_left, quote_left) =
            pool_creator::create_pool_v3_with_creation_cap<Base, Quote>(
                cetus_config,
                cetus_pools,
                pool::borrow_creation_cap(pool),
                tick_spacing,
                sqrt_price,
                position_url,
                tick_lower,
                tick_upper,
                base.into_coin(ctx),
                quote.into_coin(ctx),
                fix_amount_a,
                clock,
                ctx,
            );
        (position, base_left, quote_left)
    } else {
        let (position, quote_left, base_left) =
            pool_creator::create_pool_v3_with_creation_cap<Quote, Base>(
                cetus_config,
                cetus_pools,
                pool::borrow_creation_cap(pool),
                tick_spacing,
                sqrt_price,
                position_url,
                tick_lower,
                tick_upper,
                quote.into_coin(ctx),
                base.into_coin(ctx),
                fix_amount_a,
                clock,
                ctx,
            );
        (position, base_left, quote_left)
    };

    // The fee's mirror share of base plus any rounding dust is burned
    // through the Currency; leftover quote accrues to the platform's
    // fee bucket.
    let mut base_burn = base_excess;
    base_burn.join(base_left.into_balance());
    let base_burned = base_burn.value();
    burn_or_destroy(currency, base_burn.into_coin(ctx));
    let quote_dust_to_platform = quote_left.value();
    pool::send_platform_quote(quote_left.into_balance(), cfg.treasury());

    let cetus_pool_id = position::pool_id(&position);
    pool::set_migrated(pool, cetus_pool_id, base_is_coin_a);

    event::emit(MigratedEvent<Base, Quote> {
        pool_id: object::id(pool),
        cetus_pool_id,
        base_amount,
        quote_amount,
        sqrt_price_x64: sqrt_price,
        base_is_coin_a,
        tick_spacing,
        migration_fee,
        base_burned,
        quote_dust_to_platform,
    });

    position
}

// === Post-migration LP fees ===

/// Permissionless: collects the burned position's trading fees. The
/// quote side is split between the platform treasury and the creator by
/// the pool's snapshotted bps; the base side is burned via the Currency.
/// Variant for launches where `Base` is the Cetus pool's coin A.
public fun claim_lp_fees<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    currency: &mut Currency<Base>,
    burn_manager: &BurnManager,
    cetus_config: &GlobalConfig,
    cetus_pool: &mut CetusPool<Base, Quote>,
    ctx: &mut TxContext,
) {
    assert_claimable(cfg, pool, object::id(cetus_pool), true);
    pool::assert_burn_only_currency(currency);
    let (base_fee, quote_fee) = lp_burn::collect_fee<Base, Quote>(
        burn_manager,
        cetus_config,
        cetus_pool,
        pool::borrow_burn_proof_mut(pool),
        ctx,
    );
    settle_lp_fees(cfg, pool, currency, base_fee, quote_fee, ctx);
}

/// Variant for launches where `Base` is the Cetus pool's coin B.
public fun claim_lp_fees_inverted<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    currency: &mut Currency<Base>,
    burn_manager: &BurnManager,
    cetus_config: &GlobalConfig,
    cetus_pool: &mut CetusPool<Quote, Base>,
    ctx: &mut TxContext,
) {
    assert_claimable(cfg, pool, object::id(cetus_pool), false);
    pool::assert_burn_only_currency(currency);
    let (quote_fee, base_fee) = lp_burn::collect_fee<Quote, Base>(
        burn_manager,
        cetus_config,
        cetus_pool,
        pool::borrow_burn_proof_mut(pool),
        ctx,
    );
    settle_lp_fees(cfg, pool, currency, base_fee, quote_fee, ctx);
}

fun assert_claimable<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &Pool<Base, Quote>,
    cetus_pool_id: ID,
    base_is_coin_a: bool,
) {
    cfg.assert_version();
    pool.assert_migrated();
    assert!(pool.cetus_pool_id() == option::some(cetus_pool_id), EWrongCetusPool);
    assert!(pool.base_is_coin_a() == option::some(base_is_coin_a), EWrongOrientation);
}

fun settle_lp_fees<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &Pool<Base, Quote>,
    currency: &mut Currency<Base>,
    base_fee: Coin<Base>,
    mut quote_fee: Coin<Quote>,
    ctx: &mut TxContext,
) {
    let base_burned = base_fee.value();
    burn_or_destroy(currency, base_fee);

    let quote_total = quote_fee.value();
    let quote_platform =
        ((quote_total as u128) * (pool.lp_fee_platform_bps() as u128)
            / (config::bps_denominator() as u128)) as u64;
    let quote_creator = quote_total - quote_platform;
    if (quote_platform > 0) {
        pool::send_funds(quote_fee.split(quote_platform, ctx), cfg.treasury());
    };
    if (quote_creator > 0) {
        pool::send_funds(quote_fee.split(quote_creator, ctx), pool.creator());
    };
    quote_fee.destroy_zero();

    event::emit(LpFeesClaimedEvent<Base, Quote> {
        pool_id: object::id(pool),
        base_burned,
        quote_platform,
        quote_creator,
    });
}

// === TVL creator tranche: market-cap gate, then linear release ===

// A TVL tranche does not unlock on a cliff. The first call that sees the
// market-cap target opens a one-way GATE, and the balance then releases
// LINEARLY over the pool's `tvl_vesting_duration_ms`. After the gate opens
// the price is never read again.
//
// Be clear about what this does and does not buy. The gate reads
// `clmm_pool::current_sqrt_price`, a spot value anyone can move for the
// length of one transaction, so forcing it open costs an attacker only a
// round-trip through the pool — the gate is NOT the protection. The
// protection is the window behind it:
//
//   * nothing releases in the instant the gate opens (elapsed time is zero),
//     so pump -> open -> dump cannot happen atomically;
//   * the creator's exit is rate-limited to the schedule, so holders can
//     always sell ahead of it rather than being dumped on without warning;
//   * the gate opening is a public event carrying the observed price, so a
//     gate opened at a price no block boundary ever showed is detectable.
//
// A creator who forces the gate still ends up with the whole tranche
// eventually. This is a deliberate trade of manipulation-resistance for
// simplicity and creator UX; do not document it as a guarantee that the
// target was genuinely met.
//
// Still `entry`, and payouts still go to the creator's address balance via
// `send_funds`: both are now belt-and-suspenders, but free.

/// Variant for launches where `Base` is the Cetus pool's coin A. The
/// condition is a MARKET CAP target: circulating supply (read from the
/// burn-only Currency, so burns lower it) times the CLMM price.
entry fun claim_tranche_tvl<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    cetus_pool: &CetusPool<Base, Quote>,
    currency: &Currency<Base>,
    clock: &Clock,
) {
    do_claim_tranche_tvl(cfg, pool, cetus_pool, currency, clock)
}

public(package) fun do_claim_tranche_tvl<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    cetus_pool: &CetusPool<Base, Quote>,
    currency: &Currency<Base>,
    clock: &Clock,
) {
    claim_tranche_tvl_internal(
        cfg,
        pool,
        object::id(cetus_pool),
        currency,
        clmm_pool::current_sqrt_price(cetus_pool),
        true,
        clock,
    );
}

/// Variant for launches where `Base` is the Cetus pool's coin B.
entry fun claim_tranche_tvl_inverted<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    cetus_pool: &CetusPool<Quote, Base>,
    currency: &Currency<Base>,
    clock: &Clock,
) {
    do_claim_tranche_tvl_inverted(cfg, pool, cetus_pool, currency, clock)
}

public(package) fun do_claim_tranche_tvl_inverted<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    cetus_pool: &CetusPool<Quote, Base>,
    currency: &Currency<Base>,
    clock: &Clock,
) {
    claim_tranche_tvl_internal(
        cfg,
        pool,
        object::id(cetus_pool),
        currency,
        clmm_pool::current_sqrt_price(cetus_pool),
        false,
        clock,
    );
}

fun claim_tranche_tvl_internal<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    cetus_pool_id: ID,
    currency: &Currency<Base>,
    sqrt_price_x64: u128,
    base_is_coin_a: bool,
    clock: &Clock,
) {
    cfg.assert_version();
    pool.assert_migrated();
    assert!(pool.cetus_pool_id() == option::some(cetus_pool_id), EWrongCetusPool);
    assert!(pool.base_is_coin_a() == option::some(base_is_coin_a), EWrongOrientation);
    pool::assert_burn_only_currency(currency);

    // Market cap in quote units: circulating supply x CLMM price. The
    // supply is authoritative (burn-only Currency, decreases with every
    // base burn); tvl_in_quote with a zero quote leg computes exactly
    // supply x price with staged u256 arithmetic.
    let total_supply = coin_registry::total_supply(currency).destroy_some();
    let market_cap =
        curve::tvl_in_quote(total_supply, 0, sqrt_price_x64, base_is_coin_a);
    let target = pool::tvl_tranche_target(pool);
    // Below target is NOT an error. Once the gate is open the price is
    // irrelevant, and before it opens a failed observation is just a no-op —
    // aborting would make routine claim calls fail for no reason.
    let qualified = market_cap >= (target as u128);

    let (released, creator, gate_open, gate_opened_at_ms) =
        pool::claim_tvl_tranche(pool, qualified, clock.timestamp_ms());
    let amount = released.value();
    event::emit(TvlTrancheClaimedEvent<Base, Quote> {
        pool_id: object::id(pool),
        market_cap_in_quote: market_cap,
        tvl_target: target,
        qualified,
        gate_open,
        gate_opened_at_ms,
        amount,
        vesting_duration_ms: pool.tvl_vesting_duration_ms(),
        sqrt_price_x64,
        total_supply,
    });
    // Most calls release nothing (not qualified, or the credited slice
    // floored to zero), and `send_funds` is a native that takes the balance
    // by value — so mirror the package's zero-guard rather than assume.
    if (amount > 0) {
        sui::balance::send_funds(released, creator);
    } else {
        released.destroy_zero();
    };
}

// === Post-migration LP rewards (Cetus incentives) ===

/// Permissionless: collects Cetus rewarder incentives accrued to the
/// burned position and splits them like quote-side LP fees. Without
/// this, incentives on the pair would be stranded forever.
public fun claim_lp_rewards<Base, Quote, Reward>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    burn_manager: &BurnManager,
    cetus_config: &GlobalConfig,
    cetus_pool: &mut CetusPool<Base, Quote>,
    vault: &mut RewarderGlobalVault,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_claimable(cfg, pool, object::id(cetus_pool), true);
    let reward = lp_burn::collect_reward<Base, Quote, Reward>(
        burn_manager,
        cetus_config,
        cetus_pool,
        pool::borrow_burn_proof_mut(pool),
        vault,
        clock,
        ctx,
    );
    settle_lp_rewards<Base, Quote, Reward>(cfg, pool, reward, ctx);
}

/// Variant for launches where `Base` is the Cetus pool's coin B.
public fun claim_lp_rewards_inverted<Base, Quote, Reward>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    burn_manager: &BurnManager,
    cetus_config: &GlobalConfig,
    cetus_pool: &mut CetusPool<Quote, Base>,
    vault: &mut RewarderGlobalVault,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert_claimable(cfg, pool, object::id(cetus_pool), false);
    let reward = lp_burn::collect_reward<Quote, Base, Reward>(
        burn_manager,
        cetus_config,
        cetus_pool,
        pool::borrow_burn_proof_mut(pool),
        vault,
        clock,
        ctx,
    );
    settle_lp_rewards<Base, Quote, Reward>(cfg, pool, reward, ctx);
}

fun settle_lp_rewards<Base, Quote, Reward>(
    cfg: &LaunchpadConfig,
    pool: &Pool<Base, Quote>,
    mut reward: Coin<Reward>,
    ctx: &mut TxContext,
) {
    let total = reward.value();
    let platform_amount =
        ((total as u128) * (pool.lp_fee_platform_bps() as u128)
            / (config::bps_denominator() as u128)) as u64;
    let creator_amount = total - platform_amount;
    if (platform_amount > 0) {
        pool::send_funds(reward.split(platform_amount, ctx), cfg.treasury());
    };
    if (creator_amount > 0) {
        pool::send_funds(reward.split(creator_amount, ctx), pool.creator());
    };
    reward.destroy_zero();
    event::emit(LpRewardsClaimedEvent<Base, Quote> {
        pool_id: object::id(pool),
        reward_type: type_name::with_defining_ids<Reward>(),
        platform_amount,
        creator_amount,
    });
}

// === Internal ===

fun burn_or_destroy<Base>(currency: &mut Currency<Base>, coin: Coin<Base>) {
    if (coin.value() > 0) {
        coin_registry::burn(currency, coin);
    } else {
        coin.destroy_zero();
    }
}

// === Test helpers ===

#[test_only]
/// Returns `(quote_amount, migration_fee, base_burned, sqrt_price_x64)`.
public fun migrated_event_amounts<Base, Quote>(
    ev: &MigratedEvent<Base, Quote>,
): (u64, u64, u64, u128) {
    (ev.quote_amount, ev.migration_fee, ev.base_burned, ev.sqrt_price_x64)
}

/// Runs the full migration except the lp_burn step (its interface stub
/// aborts locally) and hands the raw Position back to the test.
#[test_only]
public fun migrate_for_testing<Base, Quote>(
    cfg: &LaunchpadConfig,
    pool: &mut Pool<Base, Quote>,
    currency: &mut Currency<Base>,
    cetus_config: &GlobalConfig,
    cetus_pools: &mut Pools,
    clock: &Clock,
    ctx: &mut TxContext,
): Position {
    migrate_core(cfg, pool, currency, cetus_config, cetus_pools, clock, ctx)
}
