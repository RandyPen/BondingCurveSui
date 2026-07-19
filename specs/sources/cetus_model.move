/// A faithful port of the Cetus CLMM liquidity math that `migration::
/// migrate_core` depends on, restricted to the platform's single fee tier.
///
/// WHY A PORT. The seeding branch selection is sound only if a mathematical
/// lemma holds (see `cetus_model_specs`). That lemma ranges over Cetus's
/// `clmm_math`, which the specs package cannot load — the prover's
/// compilation pipeline cannot process the CetusClmm dependency tree. So the
/// functions are re-stated here and the lemma is proven about the port.
///
/// WHAT THAT DOES AND DOES NOT BUY. The proof is about this model, not about
/// Cetus's bytecode. Two things bridge the gap, and both must hold for the
/// lemma to say anything about production:
///
///   1. The formulas below match `clmm_math::get_liquidity_from_a/_b` and
///      `get_delta_a/_b` at the pinned rev. Each is annotated with the exact
///      source it mirrors. Shifts are written as multiplication/division by
///      `2^64` because the prover cannot reason about symbolic u256 shifts —
///      identical semantics, see `curve::initial_sqrt_price_x64` for the same
///      trick and the same reason.
///   2. The full-range sqrt prices are the pinned tier's actual values. The
///      migration test `full_range_sqrt_prices_match_cetus` asserts that
///      against Cetus itself, so a dependency bump fails loudly.
///
/// A Cetus upgrade that changed these formulas would invalidate the lemma
/// silently. That is the residual risk of proving against a port, and it is
/// why the rev is git-pinned in Move.toml.
module bondingcurvesui_specs::cetus_model;

/// 2^64, the Q64.64 scale. A literal rather than `1 << 64` for the same
/// reason `curve` uses `Q128`: symbolic u256 shifts are under-constrained in
/// the prover, multiplication is modelled exactly.
const Q64: u256 = 0x1_0000_0000_0000_0000;

/// Mirrors `clmm_math::get_liquidity_from_a(sqrt_price_0, sqrt_price_1,
/// amount_a, round_up = false)`:
///     div_round(p0 * p1 * amount_a, |p0 - p1| << 64, false)
public fun liquidity_from_a(p: u256, u: u256, amount_a: u256): u256 {
    p * u * amount_a / ((u - p) * Q64)
}

/// Mirrors `clmm_math::get_liquidity_from_b(sqrt_price_0, sqrt_price_1,
/// amount_b, round_up = false)`:
///     div_round(amount_b << 64, |p0 - p1|, false)
public fun liquidity_from_b(lo: u256, p: u256, amount_b: u256): u256 {
    amount_b * Q64 / (p - lo)
}

/// Mirrors `clmm_math::get_delta_a(sqrt_price_0, sqrt_price_1, liquidity,
/// round_up = true)`:
///     div_round(checked_shlw(liquidity * |p0 - p1|), p0 * p1, true)
public fun delta_a(p: u256, u: u256, liquidity: u256): u256 {
    if (liquidity == 0) return 0;
    let numerator = liquidity * (u - p) * Q64;
    let denominator = p * u;
    div_ceil(numerator, denominator)
}

/// Mirrors `clmm_math::get_delta_b(sqrt_price_0, sqrt_price_1, liquidity,
/// round_up = true)`. Cetus writes it as `(product >> 64) + 1` when the low
/// 64 bits are set, which is exactly the ceiled quotient.
public fun delta_b(lo: u256, p: u256, liquidity: u256): u256 {
    if (liquidity == 0) return 0;
    div_ceil(liquidity * (p - lo), Q64)
}

fun div_ceil(numerator: u256, denominator: u256): u256 {
    (numerator + denominator - 1) / denominator
}
