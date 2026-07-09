#[test_only]
module bondingcurvesui::lifecycle_tests;

use sui::clock::{Self, Clock};
use sui::coin::Coin;
use sui::coin_registry::{Self, Currency};
use std::unit_test;
use sui::test_scenario::{Self as ts, Scenario};

use bondingcurvesui::config::{Self, AdminCap, LaunchpadConfig};
use bondingcurvesui::mock_quote::MOCK_QUOTE;
use bondingcurvesui::mocks;
use bondingcurvesui::pool::{Self, Pool};
use bondingcurvesui::zzz_base::ZZZ_BASE;

const ADMIN: address = @0xAD;
const CREATOR: address = @0xC0FFEE;
const TRADER: address = @0x7EADE7;
const NEW_CREATOR: address = @0xBEEF;

const I: u64 = 800_000_000_000_000; // matches config defaults (800M @ 6 dec)
const R: u64 = 200_000_000_000_000; // 200M @ 6 dec
const THRESHOLD: u64 = 3_000_000_000;
const MIN_THRESHOLD: u64 = 1_000_000_000;
const CREATION_FEE: u64 = 10_000_000;
const MIN_BUY: u64 = 1_000;
const MIN_TVL_TARGET: u64 = 1_000;
const MIN_LOCK_MS: u64 = 24 * 60 * 60 * 1000; // config default

// === Setup helpers ===

fun setup(): (Scenario, Clock) {
    let mut scenario = ts::begin(ADMIN);
    config::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::add_quote<MOCK_QUOTE>(
            &admin_cap,
            &mut cfg,
            6,
            THRESHOLD,
            MIN_THRESHOLD,
            CREATION_FEE,
            MIN_BUY,
            MIN_TVL_TARGET,
        );
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    let clock = clock::create_for_testing(scenario.ctx());
    (scenario, clock)
}

/// Creates a ZZZ_BASE launch as CREATOR with the given tranches and
/// payment budget. Returns the Currency for later burn checks.
fun create_test_token(
    scenario: &mut Scenario,
    clock: &Clock,
    tranche_quote_in: vector<u64>,
    tranche_lock_kind: vector<u8>,
    tranche_lock_param: vector<u64>,
    payment_amount: u64,
): Currency<ZZZ_BASE> {
    scenario.next_tx(CREATOR);
    let (receipt, mut currency) = pool::new_sealed_base_for_testing<ZZZ_BASE>(scenario.ctx());
    let mut cetus_env = mocks::new_cetus_env(scenario.ctx());
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
    let change = pool::create_token<ZZZ_BASE, MOCK_QUOTE>(
        &mut cfg,
        &mut currency,
        receipt,
        mocks::mint_quote<MOCK_QUOTE>(CREATION_FEE, scenario.ctx()),
        option::none(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        tranche_quote_in,
        tranche_lock_kind,
        tranche_lock_param,
        mocks::mint_quote<MOCK_QUOTE>(payment_amount, scenario.ctx()),
        cetus_config,
        cetus_pools,
        clock,
        scenario.ctx(),
    );
    transfer::public_transfer(change, CREATOR);
    ts::return_shared(cfg);
    mocks::destroy_cetus_env(cetus_env);
    currency
}

fun buy_as(
    scenario: &mut Scenario,
    clock: &Clock,
    trader: address,
    quote_in: u64,
    min_out: u64,
): (u64, u64) {
    scenario.next_tx(trader);
    let cfg = scenario.take_shared<LaunchpadConfig>();
    let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
    let (base, change) = pool::buy(
        &cfg,
        &mut pool,
        mocks::mint_quote<MOCK_QUOTE>(quote_in, scenario.ctx()),
        min_out,
        clock,
        scenario.ctx(),
    );
    let base_out = base.value();
    let change_out = change.value();
    transfer::public_transfer(base, trader);
    transfer::public_transfer(change, trader);
    ts::return_shared(cfg);
    ts::return_shared(pool);
    (base_out, change_out)
}

fun sell_as(scenario: &mut Scenario, trader: address, min_out: u64): u64 {
    scenario.next_tx(trader);
    let cfg = scenario.take_shared<LaunchpadConfig>();
    let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
    let base = scenario.take_from_sender<Coin<ZZZ_BASE>>();
    let quote = pool::sell(&cfg, &mut pool, base, min_out, scenario.ctx());
    let out = quote.value();
    transfer::public_transfer(quote, trader);
    ts::return_shared(cfg);
    ts::return_shared(pool);
    out
}

fun end(scenario: Scenario, clock: Clock, currency: Currency<ZZZ_BASE>) {
    clock.destroy_for_testing();
    unit_test::destroy(currency);
    scenario.end();
}

// === Creation ===

#[test]
fun create_token_initializes_pool() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );

    // Supply is fixed at I + R and burn-only.
    assert!(coin_registry::is_supply_burn_only(&currency));
    assert!(coin_registry::total_supply(&currency) == option::some(I + R));
    // The MetadataCap is held by the pool (not deleted): the creator
    // keeps metadata-update rights.
    assert!(coin_registry::is_metadata_cap_claimed(&currency));

    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        assert!(pool.phase() == pool::phase_trading());
        assert!(pool.creator() == CREATOR);
        assert!(pool.threshold() == THRESHOLD);
        let (vb, vq, floor) = pool.virtual_reserves();
        assert!(vb - floor == I);
        // vq0 = T*R/(I-R), exact for these round numbers.
        assert!((vq as u128) == (THRESHOLD as u128) * (R as u128) / ((I - R) as u128));
        let (base, lp_base, quote) = pool.real_reserves();
        assert!(base == I && lp_base == R && quote == 0);
        assert!(pool.tranche_count() == 0);
        ts::return_shared(pool);
    };

    // Creation fee exactness is enforced on-chain (EWrongCreationFee) and
    // paid into the treasury's address balance (funds accumulator), so
    // there is no Coin object to inspect here.
    end(scenario, clock, currency);
}

#[test]
fun create_token_with_tranches_locks_first_buys() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000_000);
    let budget = 500_000_000;
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000, 200_000_000],
        vector[pool::lock_kind_time(), pool::lock_kind_tvl()],
        vector[1_000_000 + MIN_LOCK_MS, 50_000_000_000],
        budget,
    );

    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        assert!(pool.tranche_count() == 2);
        let (kind0, ts0, tvl0, locked0, claimed0) = pool.tranche_info(0);
        assert!(kind0 == pool::lock_kind_time());
        assert!(ts0 == 1_000_000 + MIN_LOCK_MS && tvl0 == 0);
        assert!(locked0 > 0 && !claimed0);
        let (kind1, ts1, tvl1, locked1, claimed1) = pool.tranche_info(1);
        assert!(kind1 == pool::lock_kind_tvl());
        assert!(ts1 == 0 && tvl1 == 50_000_000_000);
        assert!(locked1 > 0 && !claimed1);
        // Second tranche bought at a worse price than the first.
        assert!(locked1 < 2 * locked0);
        // Fees accrued on both tranche buys.
        let (platform_fees, creator_fees) = pool.accrued_fees();
        assert!(platform_fees + creator_fees == 3_000_000); // 1% of 300M gross
        ts::return_shared(pool);
    };

    // Creator got the change back.
    scenario.next_tx(CREATOR);
    {
        let change = scenario.take_from_sender<Coin<MOCK_QUOTE>>();
        assert!(change.value() == budget - 300_000_000);
        scenario.return_to_sender(change);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = config::EQuoteNotListed)]
fun create_token_rejects_unlisted_quote() {
    let mut scenario = ts::begin(ADMIN);
    config::init_for_testing(scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());
    // No add_quote: creation must abort.
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    end(scenario, clock, currency);
}

// `create_token_rejects_wrong_decimals` was removed: `seal` hard-codes the base
// decimals to the platform standard (9) and is the only way to obtain the
// receipt `create_token` requires, so a wrong-decimals base coin can no longer
// reach `create_token`. The `EDecimalsMismatch` assertion remains as defense
// against an admin misconfiguring `base_decimals` away from 9.

#[test, expected_failure(abort_code = config::EBaseAlreadyLaunched)]
fun create_token_rejects_duplicate_base() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    // ZZZ_BASE registered already; a second launch with the same base
    // type must abort even though this is a fresh cap/currency.
    let currency2 = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    unit_test::destroy(currency2);
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::EWrongCreationFee)]
fun create_token_rejects_wrong_creation_fee() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(CREATOR);
    let (receipt, mut currency) = pool::new_sealed_base_for_testing<ZZZ_BASE>(scenario.ctx());
    let mut cetus_env = mocks::new_cetus_env(scenario.ctx());
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
    let change = pool::create_token<ZZZ_BASE, MOCK_QUOTE>(
        &mut cfg,
        &mut currency,
        receipt,
        mocks::mint_quote<MOCK_QUOTE>(CREATION_FEE - 1, scenario.ctx()),
        option::none(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        vector[],
        vector[],
        vector[],
        mocks::mint_quote<MOCK_QUOTE>(0, scenario.ctx()),
        cetus_config,
        cetus_pools,
        &clock,
        scenario.ctx(),
    );
    mocks::destroy_cetus_env(cetus_env);
    transfer::public_transfer(change, CREATOR);
    ts::return_shared(cfg);
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ETrancheVectorMismatch)]
fun create_token_rejects_ragged_tranche_vectors() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000],
        vector[pool::lock_kind_time()],
        vector[], // missing param
        100_000_000,
    );
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::EInvalidLockParam)]
fun create_token_rejects_past_time_lock() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(5_000_000);
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000],
        vector[pool::lock_kind_time()],
        vector[5_000_000 + MIN_LOCK_MS - 1], // just below the minimum duration
        100_000_000,
    );
    end(scenario, clock, currency);
}

// === Trading ===

#[test]
fun buy_and_sell_roundtrip_with_fees() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );

    let quote_in = 100_000_000; // 100 quote units gross
    let (base_out, change) = buy_as(&mut scenario, &clock, TRADER, quote_in, 0);
    assert!(base_out > 0 && change == 0);

    scenario.next_tx(TRADER);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let fee = 1_000_000; // 1% of gross
        let (platform_fees, creator_fees) = pool.accrued_fees();
        assert!(platform_fees + creator_fees == fee);
        // 70/30 split from config defaults.
        assert!(platform_fees == fee * 7 / 10);
        let (_, _, quote_reserve) = pool.real_reserves();
        assert!(quote_reserve == quote_in - fee);
        ts::return_shared(pool);
    };

    // Selling everything back returns less than paid (two fees + rounding).
    let quote_back = sell_as(&mut scenario, TRADER, 0);
    assert!(quote_back < quote_in);

    scenario.next_tx(TRADER);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (base, lp_base, _) = pool.real_reserves();
        assert!(base == I && lp_base == R); // all tokens returned
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun buy_respects_min_out() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    let (expected, _) = quote_buy_view(&mut scenario, 100_000_000);
    buy_as(&mut scenario, &clock, TRADER, 100_000_000, expected + 1);
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::EBelowMinBuy)]
fun buy_rejects_dust() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    buy_as(&mut scenario, &clock, TRADER, MIN_BUY - 1, 0);
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ESlippage)]
fun sell_respects_min_out() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    buy_as(&mut scenario, &clock, TRADER, 100_000_000, 0);
    let (expected, _) = quote_sell_view(&mut scenario);
    sell_as(&mut scenario, TRADER, expected + 1);
    end(scenario, clock, currency);
}

fun quote_buy_view(scenario: &mut Scenario, quote_in: u64): (u64, u64) {
    scenario.next_tx(TRADER);
    let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
    let (out, fee) = pool.quote_buy(quote_in);
    ts::return_shared(pool);
    (out, fee)
}

fun quote_sell_view(scenario: &mut Scenario): (u64, u64) {
    scenario.next_tx(TRADER);
    let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
    let base = scenario.take_from_sender<Coin<ZZZ_BASE>>();
    let (out, fee) = pool.quote_sell(base.value());
    scenario.return_to_sender(base);
    ts::return_shared(pool);
    (out, fee)
}

// === Completion ===

#[test]
fun completing_buy_drains_curve_and_returns_change() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );

    // Pay far more than the threshold: the drain clamp must cap the
    // charge near threshold + fee and refund the rest.
    let overpay = 10_000_000_000;
    let (base_out, change) = buy_as(&mut scenario, &clock, TRADER, overpay, 0);
    assert!(base_out == I);
    // Charged ~= threshold + 1% fee; change covers the rest.
    let max_charge = THRESHOLD + THRESHOLD / 100 + 100;
    assert!(change >= overpay - max_charge);

    scenario.next_tx(TRADER);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        assert!(pool.phase() == pool::phase_completed());
        let (base, lp_base, quote) = pool.real_reserves();
        assert!(base == 0); // sellable side fully drained
        assert!(lp_base == R);
        assert!(quote >= THRESHOLD); // raised at least the threshold
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotTrading)]
fun buy_blocked_after_completion() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    buy_as(&mut scenario, &clock, TRADER, 10_000_000_000, 0);
    buy_as(&mut scenario, &clock, TRADER, 100_000_000, 0);
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotTrading)]
fun sell_blocked_after_completion() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    buy_as(&mut scenario, &clock, TRADER, 10_000_000_000, 0);
    sell_as(&mut scenario, TRADER, 0);
    end(scenario, clock, currency);
}

#[test]
fun creator_tranches_can_drain_whole_curve() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    // Single tranche paying enough gross to complete the curve.
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[4_000_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        4_000_000_000,
    );
    // The completing tranche buy leaves change: the event must report
    // the actual spend (~threshold + 1% fee), not the gross budget.
    let events =
        sui::event::events_by_type<pool::TrancheLockedEvent<ZZZ_BASE, MOCK_QUOTE>>();
    assert!(events.length() == 1);
    let (quote_spent, base_locked) = pool::tranche_locked_event_amounts(&events[0]);
    assert!(quote_spent < 4_000_000_000);
    assert!(quote_spent >= THRESHOLD);
    assert!(base_locked == I);

    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        assert!(pool.phase() == pool::phase_completed());
        let (_, _, _, locked, _) = pool.tranche_info(0);
        assert!(locked == I); // creator locked the whole sellable supply
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

// === Pause ===

#[test, expected_failure(abort_code = config::EPaused)]
fun pause_blocks_buys() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_paused(&admin_cap, &mut cfg, true);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    buy_as(&mut scenario, &clock, TRADER, 100_000_000, 0);
    end(scenario, clock, currency);
}

#[test]
fun pause_does_not_block_sells() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    buy_as(&mut scenario, &clock, TRADER, 100_000_000, 0);
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_paused(&admin_cap, &mut cfg, true);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    let out = sell_as(&mut scenario, TRADER, 0);
    assert!(out > 0);
    end(scenario, clock, currency);
}

// === Fee distribution ===

#[test]
fun distribute_curve_fees_pays_treasury_and_creator() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    buy_as(&mut scenario, &clock, TRADER, 100_000_000, 0);

    let (platform_expected, creator_expected);
    scenario.next_tx(TRADER);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (p, c) = pool.accrued_fees();
        platform_expected = p;
        creator_expected = c;
        pool::distribute_curve_fees(&cfg, &mut pool);
        let (p2, c2) = pool.accrued_fees();
        assert!(p2 == 0 && c2 == 0);
        ts::return_shared(cfg);
        ts::return_shared(pool);
        // Payouts go to address balances (funds accumulator), not Coin
        // objects; assert the exact amounts through the event.
        let events = sui::event::events_by_type<
            pool::CurveFeesDistributedEvent<ZZZ_BASE, MOCK_QUOTE>,
        >();
        assert!(events.length() == 1);
        let (platform_paid, creator_paid) =
            pool::fees_distributed_event_amounts(&events[0]);
        assert!(platform_paid == platform_expected);
        assert!(creator_paid == creator_expected);
    };
    assert!(platform_expected > 0 && creator_expected > 0);
    end(scenario, clock, currency);
}

// === Time-lock unlock ===

#[test]
fun time_tranche_unlocks_at_boundary() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        100_000_000,
    );

    clock.set_for_testing(1_000 + MIN_LOCK_MS); // exactly at the unlock timestamp
    scenario.next_tx(TRADER); // permissionless: anyone can trigger
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::unlock_tranche_time(&cfg, &mut pool, 0, &clock);
        let (_, _, _, locked, claimed) = pool.tranche_info(0);
        assert!(locked == 0 && claimed);
        ts::return_shared(cfg);
        ts::return_shared(pool);
        // Funds went to the creator's address balance; verify via event.
        let events = sui::event::events_by_type<
            pool::TrancheUnlockedEvent<ZZZ_BASE, MOCK_QUOTE>,
        >();
        assert!(events.length() == 1);
        let (amount, recipient) = pool::tranche_unlocked_event_amount(&events[0]);
        assert!(amount > 0 && recipient == CREATOR);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ETrancheLocked)]
fun time_tranche_locked_before_boundary() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        100_000_000,
    );
    clock.set_for_testing(1_000 + MIN_LOCK_MS - 1);
    scenario.next_tx(TRADER);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::unlock_tranche_time(&cfg, &mut pool, 0, &clock);
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ETrancheAlreadyClaimed)]
fun tranche_cannot_be_claimed_twice() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        100_000_000,
    );
    clock.set_for_testing(2_000 + MIN_LOCK_MS);
    scenario.next_tx(TRADER);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::unlock_tranche_time(&cfg, &mut pool, 0, &clock);
        pool::unlock_tranche_time(&cfg, &mut pool, 0, &clock);
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

// === Project info ===

#[test]
fun creator_can_update_project_info() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::update_project_info(
            &cfg,
            &mut pool,
            b"a meme with a plan".to_string(),
            b"https://x.com/meme".to_string(),
            b"https://t.me/meme".to_string(),
            b"https://meme.xyz".to_string(),
            scenario.ctx(),
        );
        let (description, twitter, telegram, website) = pool.project_info();
        assert!(description == b"a meme with a plan".to_string());
        assert!(twitter == b"https://x.com/meme".to_string());
        assert!(telegram == b"https://t.me/meme".to_string());
        assert!(website == b"https://meme.xyz".to_string());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

// === Creator role transfer (two-step) ===

/// Nominate as CREATOR, accept as NEW_CREATOR.
fun transfer_creator_role(scenario: &mut Scenario) {
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::nominate_creator(&cfg, &mut pool, NEW_CREATOR, scenario.ctx());
        assert!(pool.pending_creator() == option::some(NEW_CREATOR));
        assert!(pool.creator() == CREATOR); // unchanged until accepted
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    scenario.next_tx(NEW_CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::accept_creator(&cfg, &mut pool, scenario.ctx());
        assert!(pool.creator() == NEW_CREATOR);
        assert!(pool.pending_creator().is_none());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
}

#[test]
fun creator_can_transfer_role() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    transfer_creator_role(&mut scenario);
    // The settings rights follow the role.
    scenario.next_tx(NEW_CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::update_project_info(
            &cfg,
            &mut pool,
            b"under new management".to_string(),
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            scenario.ctx(),
        );
        let (description, _, _, _) = pool.project_info();
        assert!(description == b"under new management".to_string());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test]
fun creator_keeps_rights_while_nomination_pending() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::nominate_creator(&cfg, &mut pool, NEW_CREATOR, scenario.ctx());
        // Still the creator: settings rights keep working.
        pool::update_project_info(
            &cfg,
            &mut pool,
            b"still mine".to_string(),
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            scenario.ctx(),
        );
        let (description, _, _, _) = pool.project_info();
        assert!(description == b"still mine".to_string());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotCreator)]
fun nominee_has_no_rights_while_pending() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::nominate_creator(&cfg, &mut pool, NEW_CREATOR, scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    scenario.next_tx(NEW_CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        // Nominated but not yet accepted: no settings rights.
        pool::update_project_info(
            &cfg,
            &mut pool,
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            scenario.ctx(),
        );
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotCreator)]
fun old_creator_loses_rights_after_transfer() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    transfer_creator_role(&mut scenario);
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        // The old creator can no longer act on the pool.
        pool::update_project_info(
            &cfg,
            &mut pool,
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            b"".to_string(),
            scenario.ctx(),
        );
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotCreator)]
fun non_creator_cannot_nominate() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(TRADER);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::nominate_creator(&cfg, &mut pool, TRADER, scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotPendingCreator)]
fun accept_requires_matching_nomination() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::nominate_creator(&cfg, &mut pool, NEW_CREATOR, scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    scenario.next_tx(TRADER); // not the nominee
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::accept_creator(&cfg, &mut pool, scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotPendingCreator)]
fun cancelled_nomination_cannot_be_accepted() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::nominate_creator(&cfg, &mut pool, NEW_CREATOR, scenario.ctx());
        pool::cancel_creator_nomination(&cfg, &mut pool, scenario.ctx());
        assert!(pool.pending_creator().is_none());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    scenario.next_tx(NEW_CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::accept_creator(&cfg, &mut pool, scenario.ctx());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

#[test]
fun tranche_unlock_pays_new_creator_after_transfer() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        100_000_000,
    );
    transfer_creator_role(&mut scenario);
    clock.set_for_testing(1_000 + MIN_LOCK_MS);
    scenario.next_tx(TRADER); // permissionless crank
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::unlock_tranche_time(&cfg, &mut pool, 0, &clock);
        ts::return_shared(cfg);
        ts::return_shared(pool);
        // A tranche locked before the transfer pays the new creator.
        let events = sui::event::events_by_type<
            pool::TrancheUnlockedEvent<ZZZ_BASE, MOCK_QUOTE>,
        >();
        assert!(events.length() == 1);
        let (amount, recipient) = pool::tranche_unlocked_event_amount(&events[0]);
        assert!(amount > 0 && recipient == NEW_CREATOR);
    };
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::EProjectInfoTooLong)]
fun project_info_rejects_oversized_link() {
    let (mut scenario, clock) = setup();
    let currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let mut long = b"".to_string();
        let mut i = 0u64;
        while (i < 501) {
            long.append(b"x".to_string());
            i = i + 1;
        };
        pool::update_project_info(
            &cfg,
            &mut pool,
            b"".to_string(),
            long,
            b"".to_string(),
            b"".to_string(),
            scenario.ctx(),
        );
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

// === Creator metadata updates ===

#[test]
fun creator_can_update_metadata() {
    let (mut scenario, clock) = setup();
    let mut currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::update_base_metadata(
            &cfg,
            &pool,
            &mut currency,
            option::some(b"Renamed Coin".to_string()),
            option::none(),
            option::some(b"https://example.com/icon.png".to_string()),
            scenario.ctx(),
        );
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    assert!(coin_registry::name(&currency) == b"Renamed Coin".to_string());
    assert!(coin_registry::icon_url(&currency) == b"https://example.com/icon.png".to_string());
    // Untouched field keeps its original value.
    assert!(coin_registry::description(&currency) == b"launchpad test base coin".to_string());
    end(scenario, clock, currency);
}

#[test, expected_failure(abort_code = pool::ENotCreator)]
fun non_creator_cannot_update_metadata() {
    let (mut scenario, clock) = setup();
    let mut currency = create_test_token(
        &mut scenario, &clock, vector[], vector[], vector[], 0,
    );
    scenario.next_tx(TRADER);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        pool::update_base_metadata(
            &cfg,
            &pool,
            &mut currency,
            option::some(b"Hijacked".to_string()),
            option::none(),
            option::none(),
            scenario.ctx(),
        );
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}

// === TVL tranche guard (pre-migration) ===

#[test, expected_failure(abort_code = pool::ETrancheLocked)]
fun tvl_tranche_rejects_time_unlock_path() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    let currency = create_test_token(
        &mut scenario,
        &clock,
        vector[100_000_000],
        vector[pool::lock_kind_tvl()],
        vector[50_000_000_000],
        100_000_000,
    );
    clock.set_for_testing(99_000_000);
    scenario.next_tx(TRADER);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        // Time-unlock entry must not release a TVL tranche.
        pool::unlock_tranche_time(&cfg, &mut pool, 0, &clock);
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    end(scenario, clock, currency);
}
