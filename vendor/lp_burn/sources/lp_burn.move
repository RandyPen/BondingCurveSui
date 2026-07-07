/// Interface stub of the mainnet Cetus lp_burn package (see Move.toml header).
/// Function bodies abort; on-chain the real implementation is linked via
/// published-at. `redeem` (CETUS vesting) is intentionally omitted — this
/// project does not call it.
#[allow(unused_type_parameter, unused_field)]
module lp_burn::lp_burn {
    use cetus_clmm::config::GlobalConfig;
    use cetus_clmm::pool::Pool;
    use cetus_clmm::position::Position;
    use cetus_clmm::rewarder::RewarderGlobalVault;
    use std::string::String;
    use sui::clock::Clock;
    use sui::coin::Coin;
    use sui::table::Table;

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

    public fun burn_lp_v2(
        _manager: &mut BurnManager,
        _position: Position,
        _ctx: &mut TxContext,
    ): CetusLPBurnProof {
        abort 0
    }

    public fun collect_fee<CoinTypeA, CoinTypeB>(
        _m: &BurnManager,
        _config: &GlobalConfig,
        _pool: &mut Pool<CoinTypeA, CoinTypeB>,
        _position: &mut CetusLPBurnProof,
        _ctx: &mut TxContext,
    ): (Coin<CoinTypeA>, Coin<CoinTypeB>) {
        abort 0
    }

    public fun collect_reward<CoinTypeA, CoinTypeB, CoinTypeC>(
        _m: &BurnManager,
        _config: &GlobalConfig,
        _pool: &mut Pool<CoinTypeA, CoinTypeB>,
        _position_nft: &mut CetusLPBurnProof,
        _vault: &mut RewarderGlobalVault,
        _clock: &Clock,
        _ctx: &mut TxContext,
    ): Coin<CoinTypeC> {
        abort 0
    }
}
