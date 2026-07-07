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
module bondingcurvesui::pool {
    use cetus_clmm::config::GlobalConfig as CetusGlobalConfig;
    use cetus_clmm::factory::{Self, Pools as CetusPools, PoolCreationCap};
    use lp_burn::lp_burn::CetusLPBurnProof;
    use std::type_name::{Self, TypeName};
    use sui::balance::{Self, Balance};
    use sui::clock::Clock;
    use sui::coin::{Self, Coin, TreasuryCap};
    use sui::coin_registry::{Self, Currency};
    use sui::event;

    use bondingcurvesui::config::{Self, AdminCap, LaunchpadConfig};
    use bondingcurvesui::curve;

    // === Errors ===

    /// Pool version is newer than this package supports.
    const EVersionMismatch: u64 = 1;
    /// Curve is not in the trading phase.
    const ENotTrading: u64 = 2;
    /// Curve has not completed yet.
    const ENotCompleted: u64 = 3;
    /// Base coin already has minted supply.
    const ESupplyNotZero: u64 = 4;
    /// Currency decimals differ from the configured base decimals.
    const EDecimalsMismatch: u64 = 5;
    /// The Currency's MetadataCap was already claimed by someone else.
    const EMetadataCapClaimed: u64 = 6;
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
    /// Emergency withdrawal grace period has not elapsed.
    const EGracePeriodActive: u64 = 21;
    /// Pool is not halted.
    const ENotHalted: u64 = 22;
    /// Base coin is a regulated currency (has a deny cap).
    const ERegulatedBase: u64 = 23;

    // === Constants ===

    const VERSION: u64 = 1;
    const MAX_TRANCHES: u64 = 16;
    /// A completed pool must stay unmigratable this long before the admin
    /// backstop can move its funds (migration normally takes seconds).
    const EMERGENCY_GRACE_MS: u64 = 7 * 24 * 60 * 60 * 1000;

    // Lifecycle phases.
    const PHASE_TRADING: u8 = 0;
    const PHASE_COMPLETED: u8 = 1;
    const PHASE_MIGRATED: u8 = 2;
    /// Terminal failure state: migration was impossible and the admin
    /// backstop drained the pool after the grace period.
    const PHASE_HALTED: u8 = 3;

    // Creator-tranche lock kinds.
    const LOCK_KIND_TIME: u8 = 0;
    const LOCK_KIND_TVL: u8 = 1;

    // === Structs ===

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
        version: u64,
        creator: address,
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
        tick_spacing: u32,
        min_buy_amount: u64,
        // Creator first-buy tranches.
        tranches: vector<CreatorTranche<Base>>,
        /// Reserves the (Base, Quote, tick_spacing) Cetus pool key at launch
        /// so nobody can front-run the migration's pool creation.
        pool_creation_cap: PoolCreationCap,
        /// Clock time when the curve completed (0 while trading).
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

    public struct EmergencyWithdrawEvent<phantom Base, phantom Quote> has copy, drop {
        pool_id: ID,
        base_amount: u64,
        quote_amount: u64,
    }

    // === Token creation ===

    /// Launches a new token on the bonding curve.
    ///
    /// Preconditions (transactions 1 and 2 of the launch flow):
    /// - the base coin package is published and `treasury_cap` has zero supply;
    /// - `coin_registry::migrate_legacy_metadata` has created the shared
    ///   `Currency<Base>`.
    ///
    /// This function mints the fixed total supply, permanently freezes the
    /// currency metadata, converts the supply to burn-only (consuming the
    /// treasury cap), reserves the future Cetus pool key (mints a
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
        treasury_cap: TreasuryCap<Base>,
        creation_fee: Coin<Quote>,
        threshold: Option<u64>,
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

        // Base coin sanity: fresh supply, expected decimals, and a metadata
        // cap that nobody claimed before us.
        let mut treasury_cap = treasury_cap;
        assert!(treasury_cap.total_supply() == 0, ESupplyNotZero);
        assert!(coin_registry::decimals(currency) == cfg.base_decimals(), EDecimalsMismatch);
        assert!(!coin_registry::is_metadata_cap_claimed(currency), EMetadataCapClaimed);
        // Reject regulated base coins: a creator keeping a DenyCapV2 could
        // deny-list every other holder and become the only address able to
        // sell (honeypot). Note the legacy-migration path leaves the state
        // Unknown and `is_regulated` false; a hidden deny cap is only
        // rejected once someone reveals it by calling the permissionless
        // `coin_registry::migrate_regulated_state_by_metadata` with the
        // coin's frozen RegulatedCoinMetadata object — run a keeper that
        // does this for every new coin before listing it (see README).
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

        // Freeze metadata forever, then give up mint authority: supply
        // becomes burn-only through the shared Currency object.
        let metadata_cap = coin_registry::claim_metadata_cap(currency, &treasury_cap, ctx);
        coin_registry::delete_metadata_cap(currency, metadata_cap);
        coin_registry::make_supply_burn_only(currency, treasury_cap);

        let (virtual_base, virtual_quote, virtual_base_floor) =
            curve::derive_virtual_reserves(initial_base, remain_base, threshold);

        let mut pool = Pool<Base, Quote> {
            id: object::new(ctx),
            version: VERSION,
            creator: ctx.sender(),
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
            tick_spacing: cfg.tick_spacing(),
            min_buy_amount: quote_params.quote_min_buy_amount(),
            tranches: vector[],
            pool_creation_cap,
            completed_at_ms: 0,
            cetus_pool_id: option::none(),
            base_is_coin_a: option::none(),
            burn_proof: option::none(),
        };
        let pool_id = pool.id.to_inner();

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
        });

        // Creator first-buy tranches.
        execute_tranche_buys(
            &mut pool,
            tranche_quote_in,
            tranche_lock_kind,
            tranche_lock_param,
            &mut payment,
            cfg.min_lock_duration_ms(),
            quote_params.quote_min_tvl_target(),
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
        treasury_cap: TreasuryCap<Base>,
        creation_fee: Coin<Quote>,
        threshold: Option<u64>,
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
            treasury_cap,
            creation_fee,
            threshold,
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
        clock: &Clock,
    ) {
        let count = quote_in.length();
        assert!(lock_kind.length() == count, ETrancheVectorMismatch);
        assert!(lock_param.length() == count, ETrancheVectorMismatch);
        assert!(count <= MAX_TRANCHES, ETooManyTranches);

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
            } else {
                abort EInvalidLockKind
            };

            let gross = quote_in[i];
            assert!(gross >= pool.min_buy_amount, EBelowMinBuy);
            assert!(payment.value() >= gross, EInsufficientPayment);
            let creator = pool.creator;
            let (base_out, change) =
                buy_internal(pool, payment.balance_mut().split(gross), creator, clock);
            // The completing tranche buy may leave unused quote; return it.
            let quote_spent = gross - change.value();
            payment.balance_mut().join(change);

            let base_locked = base_out.value();
            pool.tranches.push_back(CreatorTranche {
                locked: base_out,
                kind,
                unlock_ts_ms: if (kind == LOCK_KIND_TIME) param else 0,
                tvl_target: if (kind == LOCK_KIND_TVL) param else 0,
                claimed: false,
            });
            event::emit(TrancheLockedEvent<Base, Quote> {
                pool_id: pool.id.to_inner(),
                index: i,
                kind,
                unlock_ts_ms: if (kind == LOCK_KIND_TIME) param else 0,
                tvl_target: if (kind == LOCK_KIND_TVL) param else 0,
                quote_in: quote_spent,
                base_locked,
            });
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
            buy_internal(pool, quote_in.into_balance(), ctx.sender(), clock);
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
        pool.assert_pool_version();
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
        clock: &Clock,
    ): (Balance<Base>, Balance<Quote>) {
        pool.assert_pool_version();
        assert!(pool.phase == PHASE_TRADING, ENotTrading);

        let gross = quote_in.value();
        let fee = curve::fee_amount(gross, pool.curve_fee_bps);
        let net = gross - fee;

        let sellable = pool.virtual_base - pool.virtual_base_floor;
        let (out, new_vb, new_vq) = curve::buy_out(pool.virtual_base, pool.virtual_quote, net);
        assert!(out > 0, EZeroOutput);

        let (base_out_amount, net_used, fee_used, new_vb, new_vq) = if (out >= sellable) {
            // Completing buy: charge only what the remaining range costs.
            let (cost, new_vb, new_vq) = curve::buy_cost_exact_out(
                pool.virtual_base,
                pool.virtual_quote,
                sellable,
            );
            (sellable, cost, curve::fee_amount(cost, pool.curve_fee_bps), new_vb, new_vq)
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
        pool.assert_pool_version();
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
        pool: &mut Pool<Base, Quote>,
        index: u64,
        clock: &Clock,
    ) {
        pool.assert_pool_version();
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

    // === Emergency backstop ===

    /// Backstop for a completed pool stuck unmigrated for 7 days (e.g. the
    /// Cetus fee tier for its tick_spacing disappeared): the admin may drain
    /// it to the treasury for off-chain restitution, moving the pool to the
    /// terminal HALTED phase.
    ///
    /// TRUST NOTE: on-chain this only checks "COMPLETED + 7 days elapsed" —
    /// it cannot prove migration is actually impossible. The counterweight
    /// is that `migrate` is permissionless and unpausable, so anyone can
    /// preempt the drain with a single transaction at any point in the
    /// grace window; the platform must run a keeper that cranks `migrate`
    /// on every CurveCompletedEvent, making this window moot in practice.
    public fun emergency_withdraw<Base, Quote>(
        _: &AdminCap,
        cfg: &LaunchpadConfig,
        pool: &mut Pool<Base, Quote>,
        clock: &Clock,
    ) {
        cfg.assert_version();
        let (base, quote) = withdraw_for_migration(pool); // asserts COMPLETED
        assert!(
            clock.timestamp_ms() >= pool.completed_at_ms + EMERGENCY_GRACE_MS,
            EGracePeriodActive,
        );
        pool.phase = PHASE_HALTED;
        event::emit(EmergencyWithdrawEvent<Base, Quote> {
            pool_id: pool.id.to_inner(),
            base_amount: base.value(),
            quote_amount: quote.value(),
        });
        balance::send_funds(base, cfg.treasury());
        balance::send_funds(quote, cfg.treasury());
        distribute_curve_fees(cfg, pool);
    }

    /// In the terminal HALTED phase the pool will never migrate, so TVL
    /// conditions are unsatisfiable; every remaining tranche becomes
    /// claimable (permissionless trigger, funds go to the creator).
    public fun unlock_tranche_halted<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
        index: u64,
    ) {
        pool.assert_pool_version();
        assert!(pool.phase == PHASE_HALTED, ENotHalted);
        let creator = pool.creator;
        let pool_id = pool.id.to_inner();
        let tranche = pool.borrow_tranche_mut(index);
        let unlocked = take_tranche(tranche);
        event::emit(TrancheUnlockedEvent<Base, Quote> {
            pool_id,
            index,
            amount: unlocked.value(),
            creator,
        });
        balance::send_funds(unlocked, creator);
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

    public fun lp_fee_platform_bps<Base, Quote>(pool: &Pool<Base, Quote>): u64 {
        pool.lp_fee_platform_bps
    }

    public fun tick_spacing<Base, Quote>(pool: &Pool<Base, Quote>): u32 { pool.tick_spacing }

    public fun lock_kind_time(): u8 { LOCK_KIND_TIME }

    public fun lock_kind_tvl(): u8 { LOCK_KIND_TVL }

    public fun phase_trading(): u8 { PHASE_TRADING }

    public fun phase_completed(): u8 { PHASE_COMPLETED }

    public fun phase_migrated(): u8 { PHASE_MIGRATED }

    public fun phase_halted(): u8 { PHASE_HALTED }

    public fun completed_at_ms<Base, Quote>(pool: &Pool<Base, Quote>): u64 {
        pool.completed_at_ms
    }

    // === Admin ===

    /// After a package upgrade, raise a pool's version to the new package
    /// VERSION.
    public fun bump_pool_version<Base, Quote>(
        _: &AdminCap,
        pool: &mut Pool<Base, Quote>,
    ) {
        pool.version = VERSION;
    }

    // === Package-internal API (migration module) ===

    /// Hands the migration module everything that seeds the CLMM pool:
    /// all raised quote and the reserved LP base (plus any defensive dust
    /// left on the sellable side).
    public(package) fun withdraw_for_migration<Base, Quote>(
        pool: &mut Pool<Base, Quote>,
    ): (Balance<Base>, Balance<Quote>) {
        pool.assert_pool_version();
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
        pool.assert_pool_version();
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

    public(package) fun assert_pool_version<Base, Quote>(pool: &Pool<Base, Quote>) {
        assert!(pool.version <= VERSION, EVersionMismatch);
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

    #[test_only]
    public fun emergency_withdraw_event_amounts<Base, Quote>(
        ev: &EmergencyWithdrawEvent<Base, Quote>,
    ): (u64, u64) {
        (ev.base_amount, ev.quote_amount)
    }
}
