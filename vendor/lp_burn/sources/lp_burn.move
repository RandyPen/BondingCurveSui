/// TESTNET functional lp_burn, compiled against the REAL Cetus clmm
/// (cetus-contracts / cetus A). Cetus's official testnet lp_burn is built against
/// their interface-STUB clmm (a different original package id), so its Position
/// type is incompatible with the real clmm our launches use and cannot be linked.
/// This minimal drop-in provides the exact interface `migration.move` needs so
/// migration can run end-to-end on testnet:
///   - `burn_lp_v2`  permanently locks the LP Position inside a burn proof.
///   - `collect_fee` / `collect_reward` delegate to the real Cetus pool.
///
/// Published as part of the launchpad package via `--with-unpublished-
/// dependencies`; `init` shares the BurnManager. The public signatures match the
/// real lp_burn, so on MAINNET (where `published-at` is set in Move.toml) this
/// source is used only for type-checking and the real on-chain lp_burn is linked
/// instead — the `init`/bodies here are never deployed there.
#[allow(unused_type_parameter, unused_field)]
module lp_burn::lp_burn {
    use cetus_clmm::config::GlobalConfig;
    use cetus_clmm::pool::{Self, Pool};
    use cetus_clmm::position::Position;
    use cetus_clmm::rewarder::RewarderGlobalVault;
    use std::string::String;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::table::{Self, Table};

    public struct BurnManager has key {
        id: UID,
        position: Table<ID, Table<ID, BurnedPositionInfo>>,
        must_full_range: bool,
        package_version: u64,
    }

    public struct CetusLPBurnProof has key, store {
        id: UID,
        name: String,
        description: String,
        image_url: String,
        position: Position,
    }

    public struct BurnedPositionInfo has store {
        burned_position_id: ID,
        position_id: ID,
        pool_id: ID,
    }

    fun init(ctx: &mut TxContext) {
        transfer::share_object(BurnManager {
            id: object::new(ctx),
            position: table::new(ctx),
            must_full_range: false,
            package_version: 1,
        });
    }

    /// Locks a Cetus LP Position permanently by consuming it into a burn proof.
    /// The launchpad stores the returned proof in its pool, so the seeded
    /// liquidity can never be withdrawn.
    public fun burn_lp_v2(
        _manager: &mut BurnManager,
        position: Position,
        ctx: &mut TxContext,
    ): CetusLPBurnProof {
        CetusLPBurnProof {
            id: object::new(ctx),
            name: b"".to_string(),
            description: b"".to_string(),
            image_url: b"".to_string(),
            position,
        }
    }

    /// Collects trading fees accrued to the locked position, via the real pool.
    public fun collect_fee<CoinTypeA, CoinTypeB>(
        _m: &BurnManager,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        proof: &mut CetusLPBurnProof,
        ctx: &mut TxContext,
    ): (Coin<CoinTypeA>, Coin<CoinTypeB>) {
        let (a, b) = pool::collect_fee<CoinTypeA, CoinTypeB>(config, pool, &proof.position, true);
        (coin::from_balance(a, ctx), coin::from_balance(b, ctx))
    }

    /// Collects rewarder incentives accrued to the locked position.
    public fun collect_reward<CoinTypeA, CoinTypeB, CoinTypeC>(
        _m: &BurnManager,
        config: &GlobalConfig,
        pool: &mut Pool<CoinTypeA, CoinTypeB>,
        proof: &mut CetusLPBurnProof,
        vault: &mut RewarderGlobalVault,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<CoinTypeC> {
        let reward = pool::collect_reward<CoinTypeA, CoinTypeB, CoinTypeC>(
            config, pool, &proof.position, vault, true, clock,
        );
        coin::from_balance(reward, ctx)
    }
}
