/// Sui Prover specifications for the CLMM price / TVL math in
/// `bondingcurvesui::curve`.
///
/// - `isqrt`: the result is the exact floored integer square root
///   (`r^2 <= x < (r+1)^2`), proven against the Newton iteration via
///   external loop invariants.
/// - `initial_sqrt_price_x64`: the returned Q64.64 sqrt price brackets the
///   true ratio `amount_b / amount_a`.
/// - `tvl_in_quote`: abort characterization plus lower-bound sanity (the
///   reported TVL never undercounts the quote side).
module bondingcurvesui::clmm_math_specs;

use bondingcurvesui::curve;

#[spec_only]
use prover::prover::{requires, ensures, asserts};

/// 2^128: the Newton iteration's constant initial guess, and the scale
/// factor of the Q64.64 ratio in `initial_sqrt_price_x64`.
const TWO_POW_128: u256 = 0x1_0000_0000_0000_0000_0000_0000_0000_0000;

// === isqrt ===

// Newton loop: `guess` stays a strict upper bracket of the root
// ((guess+1)^2 > x), positive, and small enough that `guess + x / guess`
// cannot overflow.
#[spec_only(loop_inv(target = curve::isqrt, label = 0))]
#[ext(no_abort)]
fun isqrt_newton_inv(guess: u256, x: u256): bool {
    let g1 = guess.to_int().add(1u64.to_int());
    guess > 0 && guess <= TWO_POW_128 && x.to_int().lt(g1.mul(g1))
}

#[spec(prove, target = curve::isqrt, boogie_opt = b"vcsSplitOnEveryAssert")]
fun isqrt_spec(x: u256): u256 {
    let res = curve::isqrt(x);

    // res == floor(sqrt(x)): res^2 <= x < (res+1)^2.
    let r = res.to_int();
    let r1 = r.add(1u64.to_int());
    ensures(r.mul(r).lte(x.to_int()));
    ensures(x.to_int().lt(r1.mul(r1)));

    res
}

// === initial_sqrt_price_x64 ===

#[spec(prove, target = curve::initial_sqrt_price_x64)]
fun initial_sqrt_price_x64_spec(amount_a: u64, amount_b: u64): u128 {
    asserts(amount_a > 0 && amount_b > 0);

    let sp = curve::initial_sqrt_price_x64(amount_a, amount_b);

    // sp == floor(sqrt(amount_b * 2^128 / amount_a)): squaring the price
    // brackets the (floored) ratio scaled by 2^128.
    let ratio = amount_b.to_int().mul(TWO_POW_128.to_int()).div(amount_a.to_int());
    let s = sp.to_int();
    let s1 = s.add(1u64.to_int());
    ensures(s.mul(s).lte(ratio));
    ensures(ratio.lt(s1.mul(s1)));

    sp
}

// === tvl_in_quote ===

#[spec(prove, target = curve::tvl_in_quote)]
fun tvl_in_quote_spec(
    base_balance: u64,
    quote_balance: u64,
    sqrt_price_x64: u128,
    base_is_a: bool,
): u128 {
    // Only the base-is-coin-B branch divides by the sqrt price.
    asserts(base_is_a || sqrt_price_x64 > 0);

    let tvl = curve::tvl_in_quote(base_balance, quote_balance, sqrt_price_x64, base_is_a);

    // TVL never undercounts the quote side.
    ensures(tvl >= (quote_balance as u128));
    // With no base tokens the TVL is exactly the quote balance.
    if (base_balance == 0) {
        ensures(tvl == (quote_balance as u128));
    };

    tvl
}
