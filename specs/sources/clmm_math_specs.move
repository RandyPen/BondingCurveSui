/// Sui Prover specifications for the CLMM price / TVL math in
/// `bondingcurvesui::curve`.
///
/// - `isqrt`: the result is the exact floored integer square root
///   (`r^2 <= x < (r+1)^2`), proven against the Newton iteration via
///   external loop invariants.
/// - `initial_sqrt_price_x64`: the returned Q64.64 sqrt price brackets the
///   true ratio `amount_b / amount_a`.
/// - `tvl_in_quote`: abort characterization, the exact nested-floor value of
///   both orientations, the resulting one-sided error bound (the computed
///   TVL never OVERSTATES the true `base*price + quote`), monotonicity in
///   the sqrt price, and unreachability of the u128 saturation clamp.
///
/// The last three matter because `migration::claim_tranche_tvl_internal`
/// gates every creator tranche on
/// `tvl_in_quote(total_supply, 0, sqrt_price, base_is_coin_a) >= target`.
/// With the quote leg pinned to zero the whole gate is the base-leg
/// computation, so bounds phrased about the quote leg say nothing about it.
module bondingcurvesui::clmm_math_specs;

use bondingcurvesui::curve;

#[spec_only]
use prover::prover::{requires, ensures, asserts};
#[spec_only]
use std::integer::Integer;

/// 2^128: the Newton iteration's constant initial guess, and the scale
/// factor of the Q64.64 ratio in `initial_sqrt_price_x64`.
const TWO_POW_128: u256 = 0x1_0000_0000_0000_0000_0000_0000_0000_0000;

/// 2^64: the Q64.64 fixed-point scale of a sqrt price.
const TWO_POW_64: u256 = 0x1_0000_0000_0000_0000;

const U128_MAX: u128 = 0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff;

const U64_MAX: u128 = 0xffff_ffff_ffff_ffff;

/// Cetus's global sqrt-price bounds, the Q64.64 prices at ticks +/-443636.
/// Every `current_sqrt_price` a Cetus pool can report lies in this interval.
const CETUS_MIN_SQRT_PRICE: u128 = 4295048016;
const CETUS_MAX_SQRT_PRICE: u128 = 79226673515401279992447579055;

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

#[spec(prove, target = curve::tvl_in_quote, boogie_opt = b"vcsSplitOnEveryAssert")]
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

    let b: Integer = base_balance.to_int();
    let q: Integer = quote_balance.to_int();
    let s: Integer = sqrt_price_x64.to_int();
    let t: Integer = tvl.to_int();
    let q64: Integer = TWO_POW_64.to_int();
    let q128: Integer = TWO_POW_128.to_int();

    let one: Integer = 1u256.to_int();
    let umax: Integer = U128_MAX.to_int();

    if (base_is_a) {
        // The body is `((b*s >> 64) * s) >> 64`, i.e. two nested floors.
        let a1: Integer = b.mul(s).div(q64);
        let v: Integer = a1.mul(s).div(q64);
        // The body computes exactly `q + v`, saturating at u128::MAX.
        ensures(t == (if (q.add(v).lte(umax)) q.add(v) else umax));

        // Defining inequalities of the two floors.
        ensures(a1.mul(q64).lte(b.mul(s)));
        ensures(b.mul(s).lt(a1.add(one).mul(q64)));
        ensures(v.mul(q64).lte(a1.mul(s)));
        ensures(a1.mul(s).lt(v.add(one).mul(q64)));
        // Scale each of them by the factor still missing, so the solver never
        // has to find the multiplication itself.
        ensures(a1.mul(q64).mul(s).lte(b.mul(s).mul(s)));
        // Non-strict: scaling by `s` collapses the strict bound when s == 0.
        ensures(b.mul(s).mul(s).lte(a1.mul(q64).mul(s).add(q64.mul(s))));
        ensures(v.mul(q64).mul(q64).lte(a1.mul(s).mul(q64)));
        ensures(a1.mul(s).mul(q64).lt(v.mul(q64).mul(q64).add(q128)));
        // Composite floor characterization of the base leg alone.
        ensures(v.mul(q128).lte(b.mul(s).mul(s)));
        ensures(b.mul(s).mul(s).lt(v.mul(q128).add(s.mul(q64)).add(q128)));

        // (1) NEVER OVERSTATES. Exact value is `q + b*s^2/2^128`; common
        // denominator 2^128. Holds unconditionally: the saturating clamp can
        // only lower the result further.
        ensures(t.mul(q128).lte(q.mul(q128).add(b.mul(s).mul(s))));
        // Tightness: the two nested floors together lose strictly less than
        // `s/2^64 + 1` quote units. Requires the clamp not to have fired.
        if (tvl < U128_MAX) {
            ensures(
                q.mul(q128).add(b.mul(s).mul(s))
                    .lt(t.mul(q128).add(s.mul(q64)).add(q128)),
            );
        };
    } else {
        // The body is `((b << 64) / s << 64) / s`.
        let a1: Integer = b.mul(q64).div(s);
        let v: Integer = a1.mul(q64).div(s);
        ensures(t == (if (q.add(v).lte(umax)) q.add(v) else umax));

        ensures(a1.mul(s).lte(b.mul(q64)));
        ensures(b.mul(q64).lt(a1.add(one).mul(s)));
        ensures(v.mul(s).lte(a1.mul(q64)));
        ensures(a1.mul(q64).lt(v.add(one).mul(s)));
        ensures(a1.mul(s).mul(q64).lte(b.mul(q64).mul(q64)));
        ensures(b.mul(q64).mul(q64).lt(a1.mul(s).mul(q64).add(s.mul(q64))));
        ensures(v.mul(s).mul(s).lte(a1.mul(q64).mul(s)));
        ensures(a1.mul(q64).mul(s).lt(v.mul(s).mul(s).add(s.mul(s))));
        ensures(v.mul(s).mul(s).lte(b.mul(q128)));
        ensures(b.mul(q128).lt(v.mul(s).mul(s).add(s.mul(q64)).add(s.mul(s))));

        // (1) NEVER OVERSTATES. Exact value is `q + b*2^128/s^2`; common
        // denominator s^2.
        ensures(t.mul(s).mul(s).lte(q.mul(s).mul(s).add(b.mul(q128))));
        if (tvl < U128_MAX) {
            ensures(
                q.mul(s).mul(s).add(b.mul(q128))
                    .lt(t.mul(s).mul(s).add(s.mul(q64)).add(s.mul(s))),
            );
        };
    };

    tvl
}

/// (2) MONOTONICITY IN THE PRICE.
///
/// `tvl_in_quote` is monotone in `sqrt_price_x64` — in the direction that
/// makes the base leg worth more. The direction depends on the orientation,
/// because `sqrt_price_x64` is always Cetus's price of coin A in coin B:
///
/// - `base_is_a`: base is priced at `s^2 / 2^128`, so it RISES with `s`.
/// - `!base_is_a`: base is priced at `2^128 / s^2`, so it FALLS as `s` rises.
///
/// Together with the market-cap gate (`market_cap >= target`) this is what
/// makes "the tranche opens only once the price is high enough" a real
/// statement: there is a single threshold price per orientation, and no
/// rounding artifact can let a worse price open a gate that a better price
/// leaves shut.
///
/// Proved through the `tvl_in_quote_spec` summary above (which pins the
/// result to an exact nested-floor expression), so no division reasoning is
/// duplicated here.
#[spec(prove, boogie_opt = b"vcsSplitOnEveryAssert")]
fun tvl_in_quote_is_monotone_in_price(
    base_balance: u64,
    quote_balance: u64,
    sp_lo: u128,
    sp_hi: u128,
    base_is_a: bool,
) {
    // A zero sqrt price is not a price; the `!base_is_a` branch divides by it.
    requires(sp_lo > 0);
    requires(sp_lo <= sp_hi);

    let tvl_lo = curve::tvl_in_quote(base_balance, quote_balance, sp_lo, base_is_a);
    let tvl_hi = curve::tvl_in_quote(base_balance, quote_balance, sp_hi, base_is_a);

    let b: Integer = base_balance.to_int();
    let sl: Integer = sp_lo.to_int();
    let sh: Integer = sp_hi.to_int();
    let q64: Integer = TWO_POW_64.to_int();

    if (base_is_a) {
        let a_lo: Integer = b.mul(sl).div(q64);
        let a_hi: Integer = b.mul(sh).div(q64);
        // Each stage is monotone: numerator up => floor up.
        ensures(b.mul(sl).lte(b.mul(sh)));
        ensures(a_lo.lte(a_hi));
        ensures(a_lo.mul(sl).lte(a_hi.mul(sh)));
        ensures(a_lo.mul(sl).div(q64).lte(a_hi.mul(sh).div(q64)));
        ensures(tvl_lo <= tvl_hi);
    } else {
        let a_lo: Integer = b.mul(q64).div(sl);
        let a_hi: Integer = b.mul(q64).div(sh);
        // Each stage is antitone: denominator up => floor down.
        ensures(a_hi.lte(a_lo));
        ensures(a_hi.mul(q64).lte(a_lo.mul(q64)));
        ensures(a_hi.mul(q64).div(sh).lte(a_lo.mul(q64).div(sh)));
        ensures(a_lo.mul(q64).div(sh).lte(a_lo.mul(q64).div(sl)));
        ensures(a_hi.mul(q64).div(sh).lte(a_lo.mul(q64).div(sl)));
        ensures(tvl_hi <= tvl_lo);
    };
}

/// (3) THE u128 SATURATION CLAMP IS UNREACHABLE.
///
/// `tvl_in_quote` clamps to `u128::MAX` when the staged u256 total does not
/// fit a u128. That clamp is not merely unlikely — it cannot fire for any
/// sqrt price a Cetus pool can hold, at any u64 balances.
///
/// The margin is thin but real, and it is thin for a structural reason:
/// Cetus's price range is very nearly `[2^-64, 2^64]` (the global tick bounds
/// `+/-443636` give `MIN * MAX ~ 2^128`), and a u64 balance at the top of
/// that range is worth just under `2^128` quote units. Concretely the worst
/// corner leaves about `1.279e34` (~2^113) of headroom below `u128::MAX` in
/// both orientations.
///
/// So `market_cap` in `migration::claim_tranche_tvl_internal` is always the
/// true floored supply x price, never a saturated sentinel that would open
/// every tranche gate at once.
#[spec(prove, boogie_opt = b"vcsSplitOnEveryAssert")]
fun tvl_in_quote_clamp_is_unreachable(
    base_balance: u64,
    quote_balance: u64,
    sqrt_price_x64: u128,
    base_is_a: bool,
) {
    // Cetus's global sqrt-price bounds (ticks +/-443636). Any price a live
    // `Pool` reports lies in this closed interval, whatever the tick spacing.
    requires(sqrt_price_x64 >= CETUS_MIN_SQRT_PRICE);
    requires(sqrt_price_x64 <= CETUS_MAX_SQRT_PRICE);

    let tvl = curve::tvl_in_quote(base_balance, quote_balance, sqrt_price_x64, base_is_a);

    let b: Integer = base_balance.to_int();
    let q: Integer = quote_balance.to_int();
    let s: Integer = sqrt_price_x64.to_int();
    let q64: Integer = TWO_POW_64.to_int();
    let q128: Integer = TWO_POW_128.to_int();
    let bmax: Integer = U64_MAX.to_int();
    let smin: Integer = CETUS_MIN_SQRT_PRICE.to_int();
    let smax: Integer = CETUS_MAX_SQRT_PRICE.to_int();
    let umax: Integer = U128_MAX.to_int();

    if (base_is_a) {
        let v: Integer = b.mul(s).div(q64).mul(s).div(q64);
        // `v * 2^128 <= b*s^2` comes from the summary; bound `b*s^2` by the
        // corner, one factor at a time.
        ensures(b.mul(s).lte(bmax.mul(smax)));
        ensures(b.mul(s).mul(s).lte(bmax.mul(smax).mul(smax)));
        ensures(v.mul(q128).lte(bmax.mul(smax).mul(smax)));
        // Add the quote leg and compare against `u128::MAX`, all scaled by
        // 2^128 so the comparison stays a constant one.
        ensures(q.mul(q128).add(v.mul(q128)).lte(bmax.mul(q128).add(bmax.mul(smax).mul(smax))));
        ensures(bmax.mul(q128).add(bmax.mul(smax).mul(smax)).lt(umax.mul(q128)));
        ensures(q.add(v).lt(umax));
    } else {
        let v: Integer = b.mul(q64).div(s).mul(q64).div(s);
        // `v * s^2 <= b*2^128` from the summary; `s >= smin` shrinks the left.
        ensures(v.mul(smin).mul(smin).lte(v.mul(s).mul(s)));
        ensures(v.mul(smin).mul(smin).lte(bmax.mul(q128)));
        ensures(q.mul(smin).mul(smin).add(v.mul(smin).mul(smin))
            .lte(bmax.mul(smin).mul(smin).add(bmax.mul(q128))));
        ensures(bmax.mul(smin).mul(smin).add(bmax.mul(q128)).lt(umax.mul(smin).mul(smin)));
        ensures(q.add(v).lt(umax));
    };

    // Hence the saturating branch was not taken and the result is the exact
    // floored value, not the sentinel.
    ensures(tvl < U128_MAX);
}
