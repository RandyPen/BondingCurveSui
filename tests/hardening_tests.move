#[test_only]
module bondingcurvesui::hardening_tests;

use std::unit_test;
use sui::clock::{Self, Clock};
use sui::coin_registry;
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

/// create_token with full control over the treasury/currency pair.
fun try_create(
    scenario: &mut Scenario,
    clock: &Clock,
    threshold: Option<u64>,
    tranche_quote_in: vector<u64>,
    tranche_lock_kind: vector<u8>,
    tranche_lock_param: vector<u64>,
    payment: u64,
    tamper: u8, // 0 none, 1 pre-mint supply, 2 pre-claim metadata cap
) {
    scenario.next_tx(@0x0);
    let (mut cap, mut currency) = mocks::new_base_currency<ZZZ_BASE>(6, scenario.ctx());
    scenario.next_tx(CREATOR);
    if (tamper == 1) {
        let premint = cap.mint(1, scenario.ctx());
        transfer::public_transfer(premint, CREATOR);
    } else if (tamper == 2) {
        let mcap = coin_registry::claim_metadata_cap(&mut currency, &cap, scenario.ctx());
        transfer::public_transfer(mcap, CREATOR);
    };
    let mut cetus_env = mocks::new_cetus_env(scenario.ctx());
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
    let change = pool::create_token<ZZZ_BASE, MOCK_QUOTE>(
        &mut cfg,
        &mut currency,
        cap,
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

#[test, expected_failure(abort_code = pool::ESupplyNotZero)]
fun create_rejects_preminted_supply() {
    let (mut scenario, clock) = setup();
    try_create(&mut scenario, &clock, option::none(), vector[], vector[], vector[], 0, 1);
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = pool::EMetadataCapClaimed)]
fun create_rejects_claimed_metadata_cap() {
    let (mut scenario, clock) = setup();
    try_create(&mut scenario, &clock, option::none(), vector[], vector[], vector[], 0, 2);
    clock.destroy_for_testing();
    scenario.end();
}

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

// === Regulated base coin (honeypot) rejection ===

#[test, expected_failure(abort_code = pool::ERegulatedBase)]
fun create_rejects_regulated_base() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(@0x0);
    let (cap, mut currency) =
        mocks::new_regulated_base_currency<ZZZ_BASE>(6, scenario.ctx());
    scenario.next_tx(CREATOR);
    let mut cetus_env = mocks::new_cetus_env(scenario.ctx());
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
    let change = pool::create_token<ZZZ_BASE, MOCK_QUOTE>(
        &mut cfg,
        &mut currency,
        cap,
        mocks::mint_quote<MOCK_QUOTE>(CREATION_FEE, scenario.ctx()),
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
    transfer::public_transfer(change, CREATOR);
    ts::return_shared(cfg);
    mocks::destroy_cetus_env(cetus_env);
    unit_test::destroy(currency);
    clock.destroy_for_testing();
    scenario.end();
}

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
            &admin_cap, &mut cfg, 6, 2_000_000_000, 1_000_000, 200, 0, 3,
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
        config::set_launch_params(&admin_cap, &mut cfg, 6, 1_000, 1_000, 200, 0, 3);
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
