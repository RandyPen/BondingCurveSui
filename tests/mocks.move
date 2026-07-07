// Test coins and setup helpers.
//
// Type-name ordering matters for Cetus pool creation (CoinTypeA must be
// lexicographically greater than CoinTypeB). Module names are chosen so that
//   zzz_base::ZZZ_BASE > mock_quote::MOCK_QUOTE > aaa_base::AAA_BASE
// letting migration tests cover both orientations.

#[test_only]
module bondingcurvesui::mock_quote {
    public struct MOCK_QUOTE has drop {}
}

#[test_only]
module bondingcurvesui::zzz_base {
    public struct ZZZ_BASE has drop {}
}

#[test_only]
module bondingcurvesui::aaa_base {
    public struct AAA_BASE has drop {}
}

// The legacy `coin::create_currency` path is used deliberately: launches are
// expected to arrive with a classic TreasuryCap + CoinMetadata, which then
// goes through `migrate_legacy_metadata` — the exact flow mocked here.
#[test_only]
#[allow(deprecated_usage)]
module bondingcurvesui::mocks {
    use cetus_clmm::config::{AdminCap as CetusAdminCap, GlobalConfig};
    use cetus_clmm::factory::{Self, Pools};
    use std::unit_test;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::coin_registry::{Self, Currency};
    use sui::test_utils;

    /// Creates a fresh base coin exactly like a launch's transactions 1+2
    /// would: publish (create_currency) then register a Currency via legacy
    /// metadata migration. Returns a zero-supply cap and the Currency value.
    public fun new_base_currency<T: drop>(decimals: u8, ctx: &mut TxContext): (TreasuryCap<T>, Currency<T>) {
        let otw = test_utils::create_one_time_witness<T>();
        let (cap, metadata) = coin::create_currency(
            otw,
            decimals,
            b"TST",
            b"Test Base",
            b"launchpad test base coin",
            option::none(),
            ctx,
        );
        let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
        let currency = coin_registry::migrate_legacy_metadata_for_testing(&mut registry, &metadata, ctx);
        coin_registry::share_for_testing(registry);
        transfer::public_freeze_object(metadata);
        (cap, currency)
    }

    public fun mint_quote<Q>(amount: u64, ctx: &mut TxContext): Coin<Q> {
        coin::mint_for_testing<Q>(amount, ctx)
    }

    /// A REGULATED base coin whose regulated state has been revealed on the
    /// Currency (as a pre-launch keeper would do): create_token must reject
    /// it.
    public fun new_regulated_base_currency<T: drop>(
        decimals: u8,
        ctx: &mut TxContext,
    ): (TreasuryCap<T>, Currency<T>) {
        let otw = test_utils::create_one_time_witness<T>();
        let (cap, deny_cap, metadata) = coin::create_regulated_currency_v2(
            otw,
            decimals,
            b"TST",
            b"Test Base",
            b"regulated test base coin",
            option::none(),
            false,
            ctx,
        );
        let mut registry = coin_registry::create_coin_data_registry_for_testing(ctx);
        let mut currency =
            coin_registry::migrate_legacy_metadata_for_testing(&mut registry, &metadata, ctx);
        coin_registry::migrate_regulated_state_by_cap(&mut currency, &deny_cap);
        coin_registry::share_for_testing(registry);
        transfer::public_freeze_object(metadata);
        transfer::public_transfer(deny_cap, ctx.sender());
        (cap, currency)
    }

    /// A local Cetus environment: GlobalConfig with the default 1% fee tier
    /// (tick_spacing 200), a Pools registry with an initialized
    /// permission-pair manager, and MOCK_QUOTE allowed as a permission-pair
    /// quote at tick_spacing 200 (on mainnet, Cetus's pool manager does that
    /// per quote coin). The sender receives all Cetus ACL roles.
    public struct CetusEnv {
        admin_cap: CetusAdminCap,
        config: GlobalConfig,
        pools: Pools,
    }

    public fun new_cetus_env(ctx: &mut TxContext): CetusEnv {
        let (admin_cap, mut config) =
            cetus_clmm::config::new_global_config_for_test(ctx, 2000);
        cetus_clmm::config::add_fee_tier(&mut config, 200, 10000, ctx);
        let mut pools = factory::new_pools_for_test(ctx);
        factory::init_manager_and_whitelist(&config, &mut pools, ctx);
        factory::add_allowed_pair_config<bondingcurvesui::mock_quote::MOCK_QUOTE>(
            &config,
            &mut pools,
            200,
            ctx,
        );
        CetusEnv { admin_cap, config, pools }
    }

    /// Borrows what Cetus entry points need, in one call so the borrows
    /// coexist.
    public fun cetus_refs(env: &mut CetusEnv): (&GlobalConfig, &mut Pools) {
        (&env.config, &mut env.pools)
    }

    public fun destroy_cetus_env(env: CetusEnv) {
        let CetusEnv { admin_cap, config, pools } = env;
        unit_test::destroy(admin_cap);
        unit_test::destroy(config);
        unit_test::destroy(pools);
    }
}
