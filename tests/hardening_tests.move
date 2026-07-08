#[test_only]
module bondingcurvesui::hardening_tests;

use std::unit_test;
use sui::clock::{Self, Clock};
use sui::test_scenario::{Self as ts, Scenario};

use bondingcurvesui::config::{Self, AdminCap, LaunchpadConfig};
use bondingcurvesui::mock_quote::MOCK_QUOTE;
use bondingcurvesui::mocks;
use bondingcurvesui::pool::{Self, Pool};
use bondingcurvesui::zzz_base::ZZZ_BASE;

const ADMIN: address = @0xAD;
const ADMIN2: address = @0xAD2;
const CREATOR: address = @0xC0FFEE;

const THRESHOLD: u64 = 3_000_000_000;
const MIN_THRESHOLD: u64 = 1_000_000_000;
const CREATION_FEE: u64 = 10_000_000;
const MIN_BUY: u64 = 1_000;
const MIN_TVL_TARGET: u64 = 1_000;
const MIN_LOCK_MS: u64 = 24 * 60 * 60 * 1000; // config default

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

/// create_token through the fail-closed factory: `new_sealed_base_for_testing`
/// stands in for publishing a template coin whose `init` calls `seal`.
/// `_tamper` is retained for call-site compatibility but is now a no-op — the
/// receipt flow structurally prevents pre-minting or pre-claiming the caps.
fun try_create(
    scenario: &mut Scenario,
    clock: &Clock,
    threshold: Option<u64>,
    tranche_quote_in: vector<u64>,
    tranche_lock_kind: vector<u8>,
    tranche_lock_param: vector<u64>,
    payment: u64,
    _tamper: u8,
) {
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
        threshold,
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        b"".to_string(),
        tranche_quote_in,
        tranche_lock_kind,
        tranche_lock_param,
        mocks::mint_quote<MOCK_QUOTE>(payment, scenario.ctx()),
        cetus_config,
        cetus_pools,
        clock,
        scenario.ctx(),
    );
    transfer::public_transfer(change, CREATOR);
    ts::return_shared(cfg);
    mocks::destroy_cetus_env(cetus_env);
    unit_test::destroy(currency);
}

// === Base coin sanity ===

// Note: the former `create_rejects_preminted_supply` and
// `create_rejects_claimed_metadata_cap` tests were removed. With coin creation
// held by the launchpad's `seal`, the base coin is always freshly created with
// zero supply and the MetadataCap is claimed by `seal` itself — there is no way
// for a caller to pre-mint or pre-claim, so those vectors are structurally
// impossible rather than runtime-rejected.

// === Threshold selection ===

#[test]
fun create_accepts_custom_threshold() {
    let (mut scenario, clock) = setup();
    try_create(
        &mut scenario,
        &clock,
        option::some(MIN_THRESHOLD),
        vector[],
        vector[],
        vector[],
        0,
        0,
    );
    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        assert!(pool.threshold() == MIN_THRESHOLD);
        ts::return_shared(pool);
    };
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = config::EThresholdTooLow)]
fun create_rejects_threshold_below_minimum() {
    let (mut scenario, clock) = setup();
    try_create(
        &mut scenario,
        &clock,
        option::some(MIN_THRESHOLD - 1),
        vector[],
        vector[],
        vector[],
        0,
        0,
    );
    clock.destroy_for_testing();
    scenario.end();
}

// === Tranche validation ===

#[test, expected_failure(abort_code = pool::ETooManyTranches)]
fun create_rejects_too_many_tranches() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    let mut quote_in = vector[];
    let mut kinds = vector[];
    let mut params = vector[];
    let mut i = 0u64;
    while (i < 17) {
        quote_in.push_back(1_000_000);
        kinds.push_back(pool::lock_kind_time());
        params.push_back(1_000 + MIN_LOCK_MS);
        i = i + 1;
    };
    try_create(&mut scenario, &clock, option::none(), quote_in, kinds, params, 20_000_000, 0);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EInvalidLockKind)]
fun create_rejects_unknown_lock_kind() {
    let (mut scenario, clock) = setup();
    try_create(
        &mut scenario,
        &clock,
        option::none(),
        vector[1_000_000],
        vector[7],
        vector[1],
        1_000_000,
        0,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EInvalidLockParam)]
fun create_rejects_zero_tvl_target() {
    let (mut scenario, clock) = setup();
    try_create(
        &mut scenario,
        &clock,
        option::none(),
        vector[1_000_000],
        vector[pool::lock_kind_tvl()],
        vector[0],
        1_000_000,
        0,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EInsufficientPayment)]
fun create_rejects_underfunded_tranches() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    try_create(
        &mut scenario,
        &clock,
        option::none(),
        vector[10_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        9_999_999, // one short
        0,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EInvalidLockParam)]
fun create_rejects_tvl_target_below_minimum() {
    let (mut scenario, clock) = setup();
    try_create(
        &mut scenario,
        &clock,
        option::none(),
        vector[1_000_000],
        vector[pool::lock_kind_tvl()],
        vector[MIN_TVL_TARGET - 1],
        1_000_000,
        0,
    );
    clock.destroy_for_testing();
    scenario.end();
}

// === First-buy per-kind cap (time 3% / tvl 5%): clamp + refund ===

#[test]
fun oversized_first_buy_clamps_to_cap() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000);
    // Enable the caps (time 3%, tvl 5%); the test config defaults to no cap.
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_launch_params(
            &admin_cap, &mut cfg, 9,
            800_000_000_000_000, 200_000_000_000_000,
            200, MIN_LOCK_MS, 3, 300, 500,
        );
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    // A time tranche funded far beyond the 3% cap is CLAMPED to exactly 3% of
    // total supply (I+R = 1e15 → 3e13), and the excess quote is refunded rather
    // than aborting the launch.
    try_create(
        &mut scenario,
        &clock,
        option::none(),
        vector[2_000_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        2_000_100_000,
        0,
    );
    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (_, _, _, locked, _) = pool.tranche_info(0);
        assert!(locked == 30_000_000_000_000); // exactly 3% of supply
        ts::return_shared(pool);
    };
    clock.destroy_for_testing();
    scenario.end();
}

// === Regulated base coin (honeypot) rejection ===
//
// The former `create_rejects_regulated_base` runtime test was removed: a
// regulated base coin can no longer even reach `create_token`. Creating a
// `DenyCapV2` requires calling `create_regulated_currency_v2` with the coin's
// one-time witness, which consumes that witness — so the same coin can never
// also be passed to `seal` to obtain a `FactoryReceipt`. `create_token`
// requires a receipt by value, so a regulated coin is rejected at the type
// level (no receipt can exist), not by a runtime abort. The residual
// `ERegulatedBase` assertion remains in `create_token` purely as defense in
// depth and is unreachable.

// === Launch parameter guard rails ===

#[test, expected_failure(abort_code = config::EInvalidLaunchParams)]
fun launch_params_reject_extreme_ratio() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        // initial/remain ratio of 2000 exceeds the 1000 cap.
        config::set_launch_params(
            &admin_cap, &mut cfg, 9, 2_000_000_000, 1_000_000, 200, 0, 3, 300, 500,
        );
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

// === Quote views after completion ===

#[test]
fun quote_views_zero_when_not_trading() {
    let (mut scenario, mut clock) = setup();
    clock.set_for_testing(1_000_000);
    complete_with_tvl_tranche(&mut scenario, &clock);
    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (out, fee) = pool.quote_buy(100_000_000);
        assert!(out == 0 && fee == 0);
        let (out2, fee2) = pool.quote_sell(100_000_000);
        assert!(out2 == 0 && fee2 == 0);
        ts::return_shared(pool);
    };
    clock.destroy_for_testing();
    scenario.end();
}

// === Quote whitelist administration ===

#[test, expected_failure(abort_code = config::EQuoteNotListed)]
fun disabled_quote_rejects_new_launches() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_quote_enabled<MOCK_QUOTE>(&admin_cap, &mut cfg, false);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    try_create(&mut scenario, &clock, option::none(), vector[], vector[], vector[], 0, 0);
    clock.destroy_for_testing();
    scenario.end();
}

#[test]
fun disabling_quote_does_not_affect_live_pools() {
    let (mut scenario, clock) = setup();
    try_create(&mut scenario, &clock, option::none(), vector[], vector[], vector[], 0, 0);
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_quote_enabled<MOCK_QUOTE>(&admin_cap, &mut cfg, false);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    // Trading continues on the live pool.
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (base, change) = pool::buy(
            &cfg,
            &mut pool,
            mocks::mint_quote<MOCK_QUOTE>(1_000_000, scenario.ctx()),
            0,
            &clock,
            scenario.ctx(),
        );
        assert!(base.value() > 0);
        transfer::public_transfer(base, CREATOR);
        transfer::public_transfer(change, CREATOR);
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = config::EQuoteAlreadyListed)]
fun add_quote_rejects_duplicates() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::add_quote<MOCK_QUOTE>(&admin_cap, &mut cfg, 6, 1_000, 1_000, 0, 1, 1);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

// === Fee parameter bounds ===

#[test, expected_failure(abort_code = config::EFeeTooHigh)]
fun fee_params_capped_at_ten_percent() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_fee_params(&admin_cap, &mut cfg, 1_001, 5_000, 5_000, 500);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = config::EFeeTooHigh)]
fun migration_fee_capped_at_max() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_fee_params(&admin_cap, &mut cfg, 100, 5_000, 5_000, 1_001);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = config::EFeeTooHigh)]
fun fee_split_capped_at_bps_denominator() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_fee_params(&admin_cap, &mut cfg, 100, 10_001, 5_000, 500);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = config::EInvalidLaunchParams)]
fun launch_params_reject_remain_ge_initial() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_launch_params(&admin_cap, &mut cfg, 6, 1_000, 1_000, 200, 0, 3, 300, 500);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

// === Helper: completed pool (used by view tests) ===

/// Completes the ZZZ curve with a TVL tranche so the halted-unlock path
/// can be exercised.
fun complete_with_tvl_tranche(scenario: &mut Scenario, clock: &Clock) {
    try_create(
        scenario,
        clock,
        option::none(),
        vector[100_000_000],
        vector[pool::lock_kind_tvl()],
        vector[50_000_000_000],
        100_000_000,
        0,
    );
    scenario.next_tx(CREATOR);
    {
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (base, change) = pool::buy(
            &cfg,
            &mut pool,
            mocks::mint_quote<MOCK_QUOTE>(10_000_000_000, scenario.ctx()),
            0,
            clock,
            scenario.ctx(),
        );
        transfer::public_transfer(base, CREATOR);
        transfer::public_transfer(change, CREATOR);
        assert!(pool.phase() == pool::phase_completed());
        ts::return_shared(cfg);
        ts::return_shared(pool);
    };
}


// === AdminCap transfer ===

#[test]
fun admin_cap_transfers_only_via_contract_function() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        config::transfer_admin(admin_cap, ADMIN2, scenario.ctx());
    };
    // The new admin can operate; the old admin no longer holds the cap.
    scenario.next_tx(ADMIN2);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_treasury(&admin_cap, &mut cfg, ADMIN2);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    scenario.next_tx(ADMIN);
    {
        assert!(!scenario.has_most_recent_for_sender<AdminCap>());
    };
    clock.destroy_for_testing();
    scenario.end();
}
