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
    while (i < 3) {
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
    let change = create_returning_change(
        &mut scenario,
        &clock,
        vector[2_000_000_000],
        vector[pool::lock_kind_time()],
        vector[1_000 + MIN_LOCK_MS],
        2_000_100_000,
    );
    // The refund half of the claim above, which previously went unasserted:
    // change exceeds the 100_000 of slack in the payment, so quote from the
    // tranche's own gross came back rather than being kept by the pool.
    assert!(change > 100_000);
    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        let (_, locked, _) = pool.time_tranche_info();
        assert!(locked == MAX_TIME_BASE); // exactly 3% of supply
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
        // initial/remain ratio of 2000 exceeds the 1000 cap. Scaled so
        // remain_base clears MIN_REMAIN_BASE and the ratio assert is what
        // fires.
        config::set_launch_params(
            &admin_cap, &mut cfg, 9, 2_000_000_000_000, 1_000_000_000, 200, 0, 3, 300, 500,
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
            option::none(),
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
        config::set_fee_params(&admin_cap, &mut cfg, 1_001, 5_000, 1_000, 5_000, 500);
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
        config::set_fee_params(&admin_cap, &mut cfg, 100, 5_000, 1_000, 5_000, 1_001);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

/// The referral share sits at its hard cap by default, so it can only ever
/// be lowered without a package upgrade.
#[test, expected_failure(abort_code = config::EFeeTooHigh)]
fun referral_bps_capped_at_max() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_fee_params(&admin_cap, &mut cfg, 100, 5_000, 1_001, 5_000, 500);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

/// Referral must be carved out of the platform's cut, never the creator's:
/// a platform share below the referral share is rejected.
#[test, expected_failure(abort_code = config::EFeeTooHigh)]
fun referral_bps_cannot_exceed_platform_share() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_fee_params(&admin_cap, &mut cfg, 100, 500, 1_000, 5_000, 500);
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
        config::set_fee_params(&admin_cap, &mut cfg, 100, 10_001, 1_000, 5_000, 500);
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
        // Both legs above MIN_REMAIN_BASE, so the equal-reserves assert is
        // what fires rather than the floor.
        config::set_launch_params(
            &admin_cap, &mut cfg, 9, 1_000_000_000, 1_000_000_000, 200, 0, 3, 300, 500,
        );
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
            option::none(),
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

// === Version gate ===

fun version_setup(): Scenario {
    let mut scenario = ts::begin(ADMIN);
    config::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    scenario
}

/// The decisive case: an upgrade never removes the old package, so the old
/// package's copy of `bump_config_version` stays callable forever. It must
/// not pull `version` back down to its own VERSION and re-admit itself.
#[test, expected_failure(abort_code = config::EVersionNotNewer)]
fun bump_rejects_downgrade_from_older_package() {
    let scenario = version_setup();
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    // As if a newer package had already bumped the config past this one.
    config::set_version_for_testing(&mut cfg, config::package_version_for_testing() + 1);
    config::bump_config_version(&admin_cap, &mut cfg);
    abort
}

/// init leaves the config at this package's VERSION, so there is nothing to
/// bump; the guard rejects the no-op rather than silently succeeding.
#[test, expected_failure(abort_code = config::EVersionNotNewer)]
fun bump_rejects_same_version() {
    let scenario = version_setup();
    let admin_cap = scenario.take_from_sender<AdminCap>();
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    config::bump_config_version(&admin_cap, &mut cfg);
    abort
}

/// The upgrade path itself: a config left behind by an older package is
/// raised to the calling package's VERSION.
#[test]
fun bump_raises_config_to_package_version() {
    let scenario = version_setup();
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_version_for_testing(&mut cfg, config::package_version_for_testing() - 1);
        config::bump_config_version(&admin_cap, &mut cfg);
        assert!(config::version_for_testing(&cfg) == config::package_version_for_testing());
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    scenario.end();
}

/// Once a newer package has bumped the config, this package's gated entries
/// abort — the property the whole gate exists for.
#[test, expected_failure(abort_code = config::EVersionMismatch)]
fun bumped_config_locks_out_this_package() {
    let scenario = version_setup();
    let mut cfg = scenario.take_shared<LaunchpadConfig>();
    config::set_version_for_testing(&mut cfg, config::package_version_for_testing() + 1);
    config::assert_version(&cfg);
    abort
}

// === Degenerate-launch floors ===

// Migration cannot be paused and a COMPLETED pool cannot sell, so a launch
// whose CLMM seed degenerates strands its raise permanently. These floors
// move that failure to config time, where it is recoverable.

#[test, expected_failure(abort_code = config::EInvalidLaunchParams)]
/// `remain_base = 1` floors `base_seed` to 0 for ANY raise, so the coin handed
/// to Cetus would be empty and `add_liquidity_fix_coin` would abort.
fun launch_params_reject_remain_base_below_floor() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_launch_params(
            &admin_cap, &mut cfg, 9, 1_000_000_000_000, 999_999_999, 200, 0, 3, 300, 500,
        );
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = config::EThresholdTooLow)]
/// A raise of a few raw units lets the ceiled migration fee consume it whole,
/// leaving `quote_net == 0` and the same empty seed.
fun add_quote_rejects_min_threshold_below_floor() {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        // ZZZ_BASE as an unregistered quote type: MOCK_QUOTE is already
        // listed by `setup`, and the duplicate check fires before the
        // threshold floor.
        config::add_quote<ZZZ_BASE>(&admin_cap, &mut cfg, 6, 1_000_000, 999, 0, 1, 1);
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    clock.destroy_for_testing();
    scenario.end();
}

// === First-buy caps ===

// `init_for_testing` sets both caps to 10_000 bps so the existing tranche
// tests can use large first-buys, which means the clamp, refund and
// skip-exhausted branches of `execute_tranche_buys` are never reached by the
// rest of the suite. These tests install production-like caps and drive all
// three, so the logic is protected against regression rather than merely
// correct today.

const TIME_CAP_BPS: u64 = 300; // 3% of supply, the production default
const TVL_CAP_BPS: u64 = 500; // 5% of supply, the production default
// init_for_testing mints 8e14 + 2e14 = 1e15 total supply.
const MAX_TIME_BASE: u64 = 30_000_000_000_000; // 3% of 1e15
const MAX_TVL_BASE: u64 = 50_000_000_000_000; // 5% of 1e15
/// Far more quote than the caps can absorb, so every first-buy below is
/// oversized and must be clamped.
const OVERSIZED_BUY: u64 = 1_000_000_000;

fun setup_with_caps(): (Scenario, Clock) {
    let (mut scenario, clock) = setup();
    scenario.next_tx(ADMIN);
    {
        let admin_cap = scenario.take_from_sender<AdminCap>();
        let mut cfg = scenario.take_shared<LaunchpadConfig>();
        config::set_launch_params(
            &admin_cap, &mut cfg, 9,
            800_000_000_000_000, 200_000_000_000_000,
            200, MIN_LOCK_MS, 3, TIME_CAP_BPS, TVL_CAP_BPS,
        );
        scenario.return_to_sender(admin_cap);
        ts::return_shared(cfg);
    };
    (scenario, clock)
}

/// Like `try_create`, but returns the creator's change so the refund of
/// cap-clamped quote can be asserted.
fun create_returning_change(
    scenario: &mut Scenario,
    clock: &Clock,
    tranche_quote_in: vector<u64>,
    tranche_lock_kind: vector<u8>,
    tranche_lock_param: vector<u64>,
    payment: u64,
): u64 {
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
        mocks::mint_quote<MOCK_QUOTE>(payment, scenario.ctx()),
        cetus_config,
        cetus_pools,
        clock,
        scenario.ctx(),
    );
    let change_value = change.value();
    transfer::public_transfer(change, CREATOR);
    ts::return_shared(cfg);
    mocks::destroy_cetus_env(cetus_env);
    unit_test::destroy(currency);
    change_value
}

#[test]
/// The TIME and TVL caps are tracked independently and stack: a launch can
/// take both in full, and neither eats into the other's budget.
fun first_buy_caps_are_independent_and_stack() {
    let (mut scenario, clock) = setup_with_caps();
    create_returning_change(
        &mut scenario,
        &clock,
        vector[OVERSIZED_BUY, OVERSIZED_BUY],
        vector[pool::lock_kind_time(), pool::lock_kind_tvl()],
        vector[1_000_000 + MIN_LOCK_MS, 50_000_000_000],
        2 * OVERSIZED_BUY,
    );
    scenario.next_tx(CREATOR);
    {
        let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
        // Each kind fills its own budget, in its own vector.
        assert!(pool.time_tranche_exists());
        assert!(pool.tvl_tranche_exists());
        let (_, locked0, _) = pool.time_tranche_info();
        let (_, locked1, _) = pool.tvl_tranche_info();
        assert!(locked0 == MAX_TIME_BASE);
        assert!(locked1 == MAX_TVL_BASE);
        ts::return_shared(pool);
    };
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = pool::ETooManyTranches)]
/// A pool holds at most ONE time tranche. Two in the same launch is rejected
/// outright rather than merged or silently dropped — the singleton dynamic
/// field is the whole record, so a second one has nowhere to go.
///
/// The vector is length 2, so `MAX_TRANCHES` is satisfied and the per-kind
/// uniqueness assert is what fires (`create_rejects_too_many_tranches`
/// covers the length bound separately).
fun create_rejects_two_time_tranches() {
    let (mut scenario, clock) = setup_with_caps();
    let unlock_at = 1_000_000 + MIN_LOCK_MS;
    create_returning_change(
        &mut scenario,
        &clock,
        vector[OVERSIZED_BUY, OVERSIZED_BUY],
        vector[pool::lock_kind_time(), pool::lock_kind_time()],
        vector[unlock_at, unlock_at],
        2 * OVERSIZED_BUY,
    );
    clock.destroy_for_testing();
    scenario.end();
}

#[test, expected_failure(abort_code = pool::ETooManyTranches)]
/// Uniqueness is enforced per kind, not just for TIME: a second TVL tranche
/// is rejected the same way. `first_buy_caps_are_independent_and_stack`
/// covers the allowed combination (one of each).
fun create_rejects_two_tvl_tranches() {
    let (mut scenario, clock) = setup_with_caps();
    create_returning_change(
        &mut scenario,
        &clock,
        vector[OVERSIZED_BUY, OVERSIZED_BUY],
        vector[pool::lock_kind_tvl(), pool::lock_kind_tvl()],
        vector[50_000_000_000, 50_000_000_000],
        2 * OVERSIZED_BUY,
    );
    clock.destroy_for_testing();
    scenario.end();
}
