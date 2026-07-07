#[test_only]
module bondingcurvesui::migration_tests {
    use cetus_clmm::pool::Pool as CetusPool;
    use std::unit_test;
    use sui::clock::{Self, Clock};
    use sui::coin_registry::{Self, Currency};
    use sui::test_scenario::{Self as ts, Scenario};

    use bondingcurvesui::aaa_base::AAA_BASE;
    use bondingcurvesui::config::{Self, AdminCap, LaunchpadConfig};
    use bondingcurvesui::curve;
    use bondingcurvesui::migration;
    use bondingcurvesui::mock_quote::MOCK_QUOTE;
    use bondingcurvesui::mocks;
    use bondingcurvesui::pool::{Self, Pool};
    use bondingcurvesui::zzz_base::ZZZ_BASE;

    const ADMIN: address = @0xAD;
    const CREATOR: address = @0xC0FFEE;
    const TRADER: address = @0x7EADE7;

    const R: u64 = 2_000_000_000_000;
    const THRESHOLD: u64 = 3_000_000_000;
    const MIN_THRESHOLD: u64 = 1_000_000_000;
    const CREATION_FEE: u64 = 10_000_000;
    const MIN_BUY: u64 = 1_000;
    const MIN_TVL_TARGET: u64 = 1_000;

    // The unlock condition is market cap: circulating supply (I + R = 10M
    // tokens) x CLMM price (THRESHOLD / R at graduation), i.e. about
    // 5 * THRESHOLD = 15e9 right after migration.
    const REACHABLE_TVL_TARGET: u64 = 5_000_000_000;
    const UNREACHABLE_TVL_TARGET: u64 = 20_000_000_000;

    // === Helpers (generic over the base coin to cover both orderings) ===

    fun setup(): (Scenario, Clock, mocks::CetusEnv) {
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
        // One Cetus environment shared by launch (permission-pair
        // registration) and migration (creation-cap pool creation).
        let cetus_env = mocks::new_cetus_env(scenario.ctx());
        let clock = clock::create_for_testing(scenario.ctx());
        (scenario, clock, cetus_env)
    }

    /// Launches `B`, optionally with a single TVL-locked tranche, then
    /// drains the curve with one big TRADER buy so it is ready to migrate.
    fun launch_and_complete<B: drop>(
        scenario: &mut Scenario,
        clock: &Clock,
        cetus_env: &mut mocks::CetusEnv,
        tvl_target: Option<u64>,
    ): Currency<B> {
        scenario.next_tx(@0x0);
        let (cap, mut currency) = mocks::new_base_currency<B>(6, scenario.ctx());
        scenario.next_tx(CREATOR);
        {
            let mut cfg = scenario.take_shared<LaunchpadConfig>();
            let (tranche_in, kinds, params) = if (tvl_target.is_some()) {
                (
                    vector[100_000_000],
                    vector[pool::lock_kind_tvl()],
                    vector[tvl_target.destroy_some()],
                )
            } else {
                (vector[], vector[], vector[])
            };
            let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
            let change = pool::create_token<B, MOCK_QUOTE>(
                &mut cfg,
                &mut currency,
                cap,
                mocks::mint_quote<MOCK_QUOTE>(CREATION_FEE, scenario.ctx()),
                option::none(),
                tranche_in,
                kinds,
                params,
                mocks::mint_quote<MOCK_QUOTE>(100_000_000, scenario.ctx()),
                cetus_config,
                cetus_pools,
                clock,
                scenario.ctx(),
            );
            transfer::public_transfer(change, CREATOR);
            ts::return_shared(cfg);
        };
        scenario.next_tx(TRADER);
        {
            let cfg = scenario.take_shared<LaunchpadConfig>();
            let mut pool = scenario.take_shared<Pool<B, MOCK_QUOTE>>();
            let (base, change) = pool::buy(
                &cfg,
                &mut pool,
                mocks::mint_quote<MOCK_QUOTE>(10_000_000_000, scenario.ctx()),
                0,
                clock,
                scenario.ctx(),
            );
            transfer::public_transfer(base, TRADER);
            transfer::public_transfer(change, TRADER);
            assert!(pool.phase() == pool::phase_completed());
            ts::return_shared(cfg);
            ts::return_shared(pool);
        };
        currency
    }

    /// Runs migrate_for_testing (everything except the lp_burn step) and
    /// destroys the returned raw Position.
    fun migrate<B: drop>(
        scenario: &mut Scenario,
        clock: &Clock,
        cetus_env: &mut mocks::CetusEnv,
        currency: &mut Currency<B>,
    ) {
        scenario.next_tx(TRADER); // permissionless crank
        let cfg = scenario.take_shared<LaunchpadConfig>();
        let mut pool = scenario.take_shared<Pool<B, MOCK_QUOTE>>();
        let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
        let position = migration::migrate_for_testing(
            &cfg,
            &mut pool,
            currency,
            cetus_config,
            cetus_pools,
            clock,
            scenario.ctx(),
        );
        ts::return_shared(cfg);
        ts::return_shared(pool);
        unit_test::destroy(position);
    }

    fun end<B>(
        scenario: Scenario,
        clock: Clock,
        cetus_env: mocks::CetusEnv,
        currency: Currency<B>,
    ) {
        clock.destroy_for_testing();
        mocks::destroy_cetus_env(cetus_env);
        unit_test::destroy(currency);
        scenario.end();
    }

    // === Migration ===

    #[test]
    fun migrate_straight_order_creates_full_range_pool() {
        let (mut scenario, clock, mut cetus_env) = setup();
        // ZZZ_BASE > MOCK_QUOTE in ASCII order: base becomes coin A.
        let mut currency = launch_and_complete<ZZZ_BASE>(&mut scenario, &clock, &mut cetus_env, option::none());
        let supply_before = coin_registry::total_supply(&currency).destroy_some();
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);

        scenario.next_tx(TRADER);
        {
            let pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
            let cetus_pool = scenario.take_shared<CetusPool<ZZZ_BASE, MOCK_QUOTE>>();
            assert!(pool.phase() == pool::phase_migrated());
            assert!(pool.base_is_coin_a() == option::some(true));
            assert!(pool.cetus_pool_id() == option::some(object::id(&cetus_pool)));

            // The CLMM pool holds the graduation liquidity.
            let (base_bal, quote_bal) = cetus_clmm::pool::balances(&cetus_pool);
            assert!(base_bal.value() > 0 && quote_bal.value() > 0);
            // Base side seeded fully; quote may lose ~1e-9 relative to
            // isqrt/liquidity flooring (that dust accrues to the platform).
            assert!(base_bal.value() + 10 >= R);
            assert!(quote_bal.value() >= THRESHOLD - THRESHOLD / 1_000_000);

            // Pool price matches the curve's end price sqrt(T/R).
            let expected_sqrt = curve::initial_sqrt_price_x64(R, THRESHOLD);
            let actual_sqrt = cetus_clmm::pool::current_sqrt_price(&cetus_pool);
            let diff = if (expected_sqrt > actual_sqrt) {
                expected_sqrt - actual_sqrt
            } else {
                actual_sqrt - expected_sqrt
            };
            assert!(diff <= expected_sqrt / 1_000_000); // within 1e-6 relative

            // Launchpad reserves are empty and curve fees were flushed.
            let (base, lp_base, quote) = pool.real_reserves();
            assert!(base == 0 && lp_base == 0 && quote == 0);
            let (platform_fees, creator_fees) = pool.accrued_fees();
            assert!(platform_fees == 0 && creator_fees == 0);
            ts::return_shared(pool);
            ts::return_shared(cetus_pool);
        };

        // Any base dust was burned, never parked anywhere.
        let supply_after = coin_registry::total_supply(&currency).destroy_some();
        assert!(supply_after <= supply_before);
        end(scenario, clock, cetus_env, currency);
    }

    #[test]
    fun migrate_inverted_order_creates_full_range_pool() {
        let (mut scenario, clock, mut cetus_env) = setup();
        // AAA_BASE < MOCK_QUOTE in ASCII order: base becomes coin B.
        let mut currency = launch_and_complete<AAA_BASE>(&mut scenario, &clock, &mut cetus_env, option::none());
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);

        scenario.next_tx(TRADER);
        {
            let pool = scenario.take_shared<Pool<AAA_BASE, MOCK_QUOTE>>();
            let cetus_pool = scenario.take_shared<CetusPool<MOCK_QUOTE, AAA_BASE>>();
            assert!(pool.phase() == pool::phase_migrated());
            assert!(pool.base_is_coin_a() == option::some(false));
            assert!(pool.cetus_pool_id() == option::some(object::id(&cetus_pool)));

            let (quote_bal, base_bal) = cetus_clmm::pool::balances(&cetus_pool);
            assert!(base_bal.value() + 10 >= R);
            assert!(quote_bal.value() >= THRESHOLD - THRESHOLD / 1_000_000);

            // Inverted orientation: price = base per quote = R / THRESHOLD.
            let expected_sqrt = curve::initial_sqrt_price_x64(THRESHOLD, R);
            let actual_sqrt = cetus_clmm::pool::current_sqrt_price(&cetus_pool);
            let diff = if (expected_sqrt > actual_sqrt) {
                expected_sqrt - actual_sqrt
            } else {
                actual_sqrt - expected_sqrt
            };
            assert!(diff <= expected_sqrt / 1_000_000);
            ts::return_shared(pool);
            ts::return_shared(cetus_pool);
        };
        end(scenario, clock, cetus_env, currency);
    }

    #[test, expected_failure(abort_code = pool::ENotCompleted)]
    fun migrate_rejected_while_trading() {
        let (mut scenario, clock, mut cetus_env) = setup();
        scenario.next_tx(@0x0);
        let (cap, mut currency) = mocks::new_base_currency<ZZZ_BASE>(6, scenario.ctx());
        scenario.next_tx(CREATOR);
        {
            let mut cfg = scenario.take_shared<LaunchpadConfig>();
            let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
            let change = pool::create_token<ZZZ_BASE, MOCK_QUOTE>(
                &mut cfg,
                &mut currency,
                cap,
                mocks::mint_quote<MOCK_QUOTE>(CREATION_FEE, scenario.ctx()),
                option::none(),
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
        };
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency); // curve still trading
        end(scenario, clock, cetus_env, currency);
    }

    #[test, expected_failure(abort_code = pool::ENotCompleted)]
    fun migrate_cannot_run_twice() {
        let (mut scenario, clock, mut cetus_env) = setup();
        let mut currency = launch_and_complete<ZZZ_BASE>(&mut scenario, &clock, &mut cetus_env, option::none());
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);
        end(scenario, clock, cetus_env, currency);
    }

    // === TVL tranche unlock ===

    #[test]
    fun tvl_tranche_unlocks_when_target_reached() {
        let (mut scenario, clock, mut cetus_env) = setup();
        let mut currency = launch_and_complete<ZZZ_BASE>(
            &mut scenario,
            &clock,
            &mut cetus_env,
            option::some(REACHABLE_TVL_TARGET),
        );
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);

        scenario.next_tx(TRADER); // permissionless trigger
        {
            let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
            let cetus_pool = scenario.take_shared<CetusPool<ZZZ_BASE, MOCK_QUOTE>>();
            migration::do_unlock_tranche_tvl(
                &mut pool,
                &cetus_pool,
                &currency,
                0);
            let (_, _, _, locked, claimed) = pool.tranche_info(0);
            assert!(locked == 0 && claimed);
            ts::return_shared(pool);
            ts::return_shared(cetus_pool);
        };
        end(scenario, clock, cetus_env, currency);
    }

    #[test]
    fun tvl_tranche_unlocks_inverted_orientation() {
        let (mut scenario, clock, mut cetus_env) = setup();
        let mut currency = launch_and_complete<AAA_BASE>(
            &mut scenario,
            &clock,
            &mut cetus_env,
            option::some(REACHABLE_TVL_TARGET),
        );
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);

        scenario.next_tx(TRADER);
        {
            let mut pool = scenario.take_shared<Pool<AAA_BASE, MOCK_QUOTE>>();
            let cetus_pool = scenario.take_shared<CetusPool<MOCK_QUOTE, AAA_BASE>>();
            migration::do_unlock_tranche_tvl_inverted(
                &mut pool,
                &cetus_pool,
                &currency,
                0);
            let (_, _, _, locked, claimed) = pool.tranche_info(0);
            assert!(locked == 0 && claimed);
            ts::return_shared(pool);
            ts::return_shared(cetus_pool);
        };
        end(scenario, clock, cetus_env, currency);
    }

    #[test, expected_failure(abort_code = migration::ETvlBelowTarget)]
    fun tvl_tranche_locked_below_target() {
        let (mut scenario, clock, mut cetus_env) = setup();
        let mut currency = launch_and_complete<ZZZ_BASE>(
            &mut scenario,
            &clock,
            &mut cetus_env,
            option::some(UNREACHABLE_TVL_TARGET),
        );
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);

        scenario.next_tx(TRADER);
        {
            let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
            let cetus_pool = scenario.take_shared<CetusPool<ZZZ_BASE, MOCK_QUOTE>>();
            migration::do_unlock_tranche_tvl(
                &mut pool,
                &cetus_pool,
                &currency,
                0);
            ts::return_shared(pool);
            ts::return_shared(cetus_pool);
        };
        end(scenario, clock, cetus_env, currency);
    }

    #[test, expected_failure(abort_code = pool::ENotMigrated)]
    fun tvl_tranche_locked_before_migration() {
        let (mut scenario, clock, mut cetus_env) = setup();
        // Complete the curve but do NOT migrate.
        let currency = launch_and_complete<ZZZ_BASE>(
            &mut scenario,
            &clock,
            &mut cetus_env,
            option::some(REACHABLE_TVL_TARGET),
        );
        // Even with a plausible-looking Cetus pool of the right type, the
        // phase check must fire before anything else.
        let fake_pool_id = forge_cetus_pool(&mut scenario, &clock);
        scenario.next_tx(TRADER);
        {
            let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
            let fake_pool =
                scenario.take_shared_by_id<CetusPool<ZZZ_BASE, MOCK_QUOTE>>(fake_pool_id);
            migration::do_unlock_tranche_tvl(&mut pool, &fake_pool, &currency, 0);
            ts::return_shared(pool);
            ts::return_shared(fake_pool);
        };
        end(scenario, clock, cetus_env, currency);
    }

    // === Migration-bricking front-run is blocked ===

    /// Before the permission-pair reservation existed, an attacker holding
    /// dust amounts of Base+Quote could permissionlessly create the
    /// (Base, Quote, tick_spacing) Cetus pool first, making the launchpad's
    /// migration abort forever. create_token now reserves the pool key, so
    /// the permissionless path must reject the attacker.
    #[test, expected_failure(
        abort_code = cetus_clmm::pool_creator::EPoolIsPermission,
        location = cetus_clmm::pool_creator,
    )]
    fun front_running_cetus_pool_creation_is_blocked() {
        let (mut scenario, clock, mut cetus_env) = setup();
        let currency = launch_and_complete<ZZZ_BASE>(
            &mut scenario,
            &clock,
            &mut cetus_env,
            option::none(),
        );

        // Attacker holds base dust (bought from the curve) and tries to
        // create the pool in the SAME Cetus environment before migrate runs.
        scenario.next_tx(TRADER);
        {
            let (tick_lower, tick_upper) = cetus_clmm::pool_creator::full_range_tick_range(200);
            let (cetus_config, cetus_pools) = cetus_env.cetus_refs();
            let (position, base_left, quote_left) =
                cetus_clmm::pool_creator::create_pool_v3<ZZZ_BASE, MOCK_QUOTE>(
                    cetus_config,
                    cetus_pools,
                    200,
                    curve::initial_sqrt_price_x64(1_000, 1_000_000),
                    std::string::utf8(b""),
                    tick_lower,
                    tick_upper,
                    sui::coin::mint_for_testing<ZZZ_BASE>(1_000_000, scenario.ctx()),
                    mocks::mint_quote<MOCK_QUOTE>(4_000_000_000, scenario.ctx()),
                    true,
                    &clock,
                    scenario.ctx(),
                );
            transfer::public_transfer(base_left, TRADER);
            transfer::public_transfer(quote_left, TRADER);
            unit_test::destroy(position);
        };
        end(scenario, clock, cetus_env, currency);
    }

    /// Attacker-forged CetusPool<ZZZ_BASE, MOCK_QUOTE> at a pumped price in
    /// a private Cetus environment. Returns its object ID.
    fun forge_cetus_pool(scenario: &mut Scenario, clock: &Clock): ID {
        scenario.next_tx(TRADER);
        let mut attacker_env = mocks::new_cetus_env(scenario.ctx());
        let (tick_lower, tick_upper) = cetus_clmm::pool_creator::full_range_tick_range(200);
        let (cetus_config, cetus_pools) = attacker_env.cetus_refs();
        let (position, base_left, quote_left) =
            cetus_clmm::pool_creator::create_pool_v3<ZZZ_BASE, MOCK_QUOTE>(
                cetus_config,
                cetus_pools,
                200,
                curve::initial_sqrt_price_x64(1_000, 1_000_000), // price pumped 1000x
                std::string::utf8(b""),
                tick_lower,
                tick_upper,
                sui::coin::mint_for_testing<ZZZ_BASE>(1_000_000, scenario.ctx()),
                mocks::mint_quote<MOCK_QUOTE>(4_000_000_000, scenario.ctx()),
                true,
                clock,
                scenario.ctx(),
            );
        let fake_pool_id = cetus_clmm::position::pool_id(&position);
        transfer::public_transfer(base_left, TRADER);
        transfer::public_transfer(quote_left, TRADER);
        unit_test::destroy(position);
        mocks::destroy_cetus_env(attacker_env);
        fake_pool_id
    }

    #[test, expected_failure(abort_code = migration::EWrongCetusPool)]
    fun tvl_unlock_rejects_foreign_cetus_pool() {
        let (mut scenario, clock, mut cetus_env) = setup();
        let mut currency = launch_and_complete<ZZZ_BASE>(
            &mut scenario,
            &clock,
            &mut cetus_env,
            option::some(REACHABLE_TVL_TARGET),
        );
        migrate(&mut scenario, &clock, &mut cetus_env, &mut currency);
        // A second, unrelated launch that also migrated (same coin pair
        // shape is impossible, so use the other base; its Cetus pool has
        // MOCK_QUOTE as coin A, same as an attacker-crafted pool would).
        let mut aux_currency = launch_and_complete<AAA_BASE>(&mut scenario, &clock, &mut cetus_env, option::none());
        migrate(&mut scenario, &clock, &mut cetus_env, &mut aux_currency);

        // Attacker forges a second CetusPool<ZZZ_BASE, MOCK_QUOTE> at an
        // absurdly high price in their own environment and passes it to the
        // unlock entry: the object-identity check must reject it.
        let fake_pool_id = forge_cetus_pool(&mut scenario, &clock);
        scenario.next_tx(TRADER);
        {
            let mut pool = scenario.take_shared<Pool<ZZZ_BASE, MOCK_QUOTE>>();
            let fake_pool =
                scenario.take_shared_by_id<CetusPool<ZZZ_BASE, MOCK_QUOTE>>(fake_pool_id);
            migration::do_unlock_tranche_tvl(&mut pool, &fake_pool, &currency, 0);
            ts::return_shared(pool);
            ts::return_shared(fake_pool);
        };
        unit_test::destroy(aux_currency);
        end(scenario, clock, cetus_env, currency);
    }
}
