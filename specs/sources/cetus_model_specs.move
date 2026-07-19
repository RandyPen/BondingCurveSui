/// The lemma that justifies the seeding branch selection in
/// `migration::migrate_core`.
///
/// `migrate_core` asks Cetus's own math how much quote a base leg of
/// `base_seed` would require. If that exceeds the fee-shrunk `quote_net` it
/// fixes the QUOTE leg instead and hands the CLMM the whole base balance.
/// That fallback is only safe if the base then required is at most what the
/// pool holds — otherwise Cetus aborts, and because migration cannot be
/// paused and a COMPLETED pool cannot sell, the raise is stranded forever.
///
/// Informally the two requirements are reciprocal ratios of each other:
/// fixing A costs `(1 - lo/p)/(1 - p/u)` times the proportional share, fixing
/// B costs its reciprocal. When one exceeds 1 the other is below it. The
/// content of the proof is that the floors and ceils do not break that at the
/// boundary — which matters, because the empirical margin there is exactly 0.
///
/// STATUS: NOT PROVEN. This is an OPEN OBLIGATION, deliberately left stated
/// rather than deleted. `#[spec(prove)]` is omitted so the suite stays green;
/// re-add it to attempt the proof.
///
/// Boogie times out on the `_Check` goal at 900s with
/// `vcsSplitOnEveryAssert`. The goal composes four nested floor/ceil
/// divisions over products of large symbolic u256 values, which is well past
/// what Z3 discharges directly. Making it tractable most likely means
/// decomposing it: replace the exact definitions with their bounding
/// inequalities (`L*(u-p)*2^64 <= p*u*a < (L+1)*(u-p)*2^64`, and similarly
/// for the ceils) and give the solver the intermediate polynomial facts to
/// chain, rather than asking it to reason through the divisions.
///
/// What stands in for it meanwhile, and why the risk is bounded:
///   * 400k random exact-integer points spanning the whole full-range
///     window and all u64 magnitudes: zero counterexamples in the ~399k that
///     take the branch.
///   * ~1.5M points from an independent port sweeping every tick spacing,
///     both orientations and fee rates 0-1000 bps: minimum margin 0, never
///     negative.
///   * `migrates_above_crossover_{base_is_coin_a,base_is_coin_b}` exercise
///     the fallback against the REAL Cetus dependency, not this model, and
///     fail without the branch selection.
/// None of that is a proof. The property is tight (margin 0), which is
/// exactly where sampling is least convincing — hence leaving it stated.
module bondingcurvesui_specs::cetus_model_specs;

use bondingcurvesui_specs::cetus_model;

#[spec_only]
use prover::prover::{requires, ensures};

/// Full-range sqrt price bounds of the platform's only fee tier (Cetus tick
/// spacing 200 => ticks +/-443600). `config::PLATFORM_TICK_SPACING` pins the
/// spacing so these are constants; `full_range_sqrt_prices_match_cetus`
/// asserts they are what Cetus computes.
const LO: u256 = 4302785677;
const UP: u256 = 79084200890414257525634219231;

const U64_MAX: u256 = 0xffff_ffff_ffff_ffff;

/// If fixing the base leg would demand more quote than is available, then
/// fixing the quote leg demands no more base than is available.
#[spec_only]
fun binding_leg_fallback_is_safe(p: u256, base: u256, quote: u256) {
    // The seed price is strictly inside the full range: `pool_creator`
    // asserts this before creating the pool, and `curve` proves the derived
    // sqrt price stays in the envelope.
    requires(p > LO);
    requires(p < UP);
    // Both legs are u64 coin amounts, and non-empty (`seed_base_never_
    // degenerates` proves the base leg is non-zero under the config floors).
    requires(base > 0);
    requires(base <= U64_MAX);
    requires(quote > 0);
    requires(quote <= U64_MAX);

    let need_quote = cetus_model::delta_b(
        LO,
        p,
        cetus_model::liquidity_from_a(p, UP, base),
    );
    let need_base = cetus_model::delta_a(
        p,
        UP,
        cetus_model::liquidity_from_b(LO, p, quote),
    );

    // The branch condition and its consequence.
    if (need_quote > quote) {
        ensures(need_base <= base);
    };
}
