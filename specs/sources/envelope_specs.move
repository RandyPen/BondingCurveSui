/// The lemma that discharges the seed-price envelope assert in
/// `migration::migrate_core`.
///
/// `migrate_core` asserts that the Q64.64 seed sqrt price clears BOTH Cetus
/// full-range endpoints by `ENVELOPE_GUARD = 2^32` before it creates the
/// pool. That assert is not defensive decoration: it is the hypothesis of
/// `cetus_model_specs::binding_leg_fallback_is_safe`, which is what makes the
/// binding-leg fallback safe, and it is also exactly the condition under
/// which Cetus's own u128 liquidity and `checked_shlw` do not abort.
///
/// But an assert on a COMPLETED pool is not free. `migrate` is permissionless
/// and cannot be paused, every input to it is already frozen, and a COMPLETED
/// curve cannot sell — so if the assert could ever fire, each retry would
/// fail identically and the entire raise would be stranded forever. Its
/// unreachability therefore has to be a theorem, not a comment. This module
/// is that theorem.
///
/// WHAT IS PROVED. For any two legs of at least `MIN_LEG = 1000` raw units,
///
///     LO + 2^32  <  initial_sqrt_price_x64(a, b)  <  UP - 2^32
///
/// with `LO`/`UP` the full-range sqrt prices of the platform's only fee tier
/// (`curve::full_range_lower_sqrt_price` / `_upper_`). `migrate_core` calls it
/// as `(base, quote)` or `(quote, base)` depending on the Cetus coin ordering,
/// so the statement is deliberately symmetric in the two arguments and covers
/// both branches at once.
///
/// WHY `MIN_LEG = 1000` IS THE ONLY HYPOTHESIS NEEDED. The reachable inputs
/// are the pool's balances at completion:
///
///   * quote: at least the graduation threshold, and `config` floors every
///     threshold at `MIN_QUOTE_THRESHOLD = 1_000` (`set_quote_params` asserts
///     `min_threshold >= MIN_QUOTE_THRESHOLD` and `default_threshold >=
///     min_threshold`, and `resolve_threshold` admits nothing below
///     `min_threshold`);
///   * base: the minted CLMM reserve, at least `MIN_REMAIN_BASE = 1e9`.
///
/// Both are u64 coin values, so `1000 <= a, b <= u64::MAX` is sound, and it
/// turns out to be *sufficient*. In particular the proof does NOT need the
/// `vb0 = I^2/(I-R) <= u64::MAX` bound that `curve::derive_virtual_reserves`
/// and `config::set_launch_params` enforce (which caps `remain_base` at
/// `floor(u64::MAX/4) = 4.61e18`, the minimum of `I^2/(I-R)` sitting at
/// `I = 2R`), nor `MIN_REMAIN_BASE` beyond the shared `1000` floor. Relaxing
/// either would not invalidate this proof — only `MIN_QUOTE_THRESHOLD` and
/// u64-ness of a coin balance are load-bearing here.
///
/// THE MARGIN IS NOT THIN. Worst reachable corners, using only the bounds
/// above (`isqrt(b * 2^128 / a)`):
///
///   a = u64::MAX, b = 1000  ->  p = 135_818_791_312, i.e. 15.8x above
///                               `LO + 2^32 = 8_597_752_973`;
///   a = 1000, b = u64::MAX  ->  p = 2.505e27, i.e. 31.6x below
///                               `UP - 2^32 = 7.908e28`.
///
/// Adding the `vb0` cap on the base leg widens those to 31.6x and 63.1x.
///
/// HOW IT IS PROVED. `clmm_math_specs::initial_sqrt_price_x64_spec` is already
/// proven and, being a `<fn>_spec`, is substituted here as an opaque summary:
/// it gives `s^2 <= ratio < (s+1)^2` for `ratio = floor(b * 2^128 / a)`, so
/// `isqrt`'s Newton loop is never re-entered. The rest is a division-free
/// argument — the two defining floor inequalities of `ratio` are multiplied
/// through by the *constant* extreme of the opposite leg, which reduces each
/// endpoint to one concrete big-integer comparison:
///
///   lower: `1000 * 2^128 >= (LO+2^32+1)^2 * u64::MAX`     (249.5x headroom)
///   upper: `1000 * (UP-2^32)^2 > u64::MAX * 2^128`        (996.4x headroom)
///
/// Keeping the divisions out of the goal is the same discipline that took
/// `cetus_model_specs` from a 900s timeout to seconds; see its header.
module bondingcurvesui::envelope_specs;

use bondingcurvesui::curve;

#[spec_only]
use prover::prover::{requires, ensures};
#[spec_only]
use std::integer::Integer;

/// The Q64.64 ratio scale, matching `curve::initial_sqrt_price_x64`.
const TWO_POW_128: u256 = 0x1_0000_0000_0000_0000_0000_0000_0000_0000;

const U64_MAX: u64 = 0xffff_ffff_ffff_ffff;

/// Floor on either leg. `config::MIN_QUOTE_THRESHOLD` for the quote side;
/// `config::MIN_REMAIN_BASE` (1e9) is far above it on the base side.
const MIN_LEG: u64 = 1_000;

// The guarded endpoints, pre-added and pre-subtracted into literals.
//
// `migration` writes them as `full_range_lower_sqrt_price() + ENVELOPE_GUARD`
// and `full_range_upper_sqrt_price() - ENVELOPE_GUARD`; both are constant
// folds of `LO = 4302785677`, `UP = 79084200890414257525634219231` and
// `ENVELOPE_GUARD = 2^32`. Stated folded because a `requires`/`ensures` is
// itself evaluated: writing `p + GUARD < UP` would have the prover reason
// about an addition on a symbolic value where the constant is all that is
// wanted.
const LO_GUARD: u128 = 8597752973; // 4302785677 + 2^32
const UP_GUARD: u128 = 79084200890414257521339251935; // UP - 2^32

/// `LO_GUARD + 1` and its square: the smallest sqrt price that clears the
/// lower endpoint, and the smallest ratio that forces it.
const LO_GUARD_1: u128 = 8597752974;
const LO_GUARD_1_SQ: u256 = 73921356201925844676;

/// `UP_GUARD^2`: the ratio at which the sqrt price would reach the upper
/// endpoint.
const UP_GUARD_SQ: u256 =
    6254310830475399242175745333033708585072290198145401244225;

// === The lemma ===

/// The seed sqrt price always lands strictly inside the guarded full-range
/// envelope, so `migration::migrate_core`'s `ESeedPriceOutOfEnvelope` assert
/// is unreachable.
#[spec(prove)]
fun seed_price_is_inside_envelope(amount_a: u64, amount_b: u64) {
    requires(amount_a >= MIN_LEG);
    requires(amount_b >= MIN_LEG);

    let sp = curve::initial_sqrt_price_x64(amount_a, amount_b);

    let a: Integer = amount_a.to_int();
    let b: Integer = amount_b.to_int();
    let scale: Integer = TWO_POW_128.to_int();
    let num: Integer = b.mul(scale);
    // Exactly the quotient `initial_sqrt_price_x64_spec` brackets against.
    let ratio: Integer = num.div(a);
    let ratio1: Integer = ratio.add(1u256.to_int());
    let s: Integer = sp.to_int();
    let s1: Integer = s.add(1u256.to_int());

    // (1) The defining floor bounds of `ratio`. Everything below uses only
    //     these two, never the quotient itself.
    ensures(ratio.mul(a).lte(num));
    ensures(num.lt(ratio1.mul(a)));

    // === Lower endpoint ===

    // (2) Multiply (1) through by the constant extreme of the other leg:
    //     `ratio1 * u64::MAX >= ratio1 * a > num >= MIN_LEG * 2^128`.
    ensures(ratio1.mul(U64_MAX.to_int()).gt(MIN_LEG.to_int().mul(scale)));
    // (3) `MIN_LEG * 2^128 >= (LO_GUARD+1)^2 * u64::MAX` is a concrete
    //     comparison, so cancelling `u64::MAX` gives `ratio + 1 > K`, i.e.
    //     `ratio >= K` over the integers.
    ensures(ratio.gte(LO_GUARD_1_SQ.to_int()));
    // (4) The opaque summary's upper bracket `ratio < (sp+1)^2` then forces
    //     `(sp+1)^2 > (LO_GUARD+1)^2`, and squaring is monotone on
    //     non-negatives, so `sp + 1 > LO_GUARD + 1`.
    ensures(s1.mul(s1).gt(LO_GUARD_1.to_int().mul(LO_GUARD_1.to_int())));
    ensures(s1.gt(LO_GUARD_1.to_int()));
    ensures(sp > LO_GUARD);

    // === Upper endpoint ===

    // (5) The summary's lower bracket `sp^2 <= ratio`, multiplied by the
    //     constant floor of the other leg: `sp^2 * MIN_LEG <= ratio * a`,
    //     and `ratio * a <= num <= u64::MAX * 2^128` by (1).
    ensures(s.mul(s).mul(MIN_LEG.to_int()).lte(U64_MAX.to_int().mul(scale)));
    // (6) `MIN_LEG * UP_GUARD^2 > u64::MAX * 2^128` is again concrete, so
    //     `sp^2 < UP_GUARD^2`, and monotone squaring gives the conclusion.
    ensures(s.mul(s).lt(UP_GUARD_SQ.to_int()));
    ensures(sp < UP_GUARD);
}
