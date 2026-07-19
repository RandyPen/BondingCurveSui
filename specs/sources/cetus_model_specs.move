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
/// HOW IT IS PROVED. The earlier attempt handed Boogie the four model
/// functions inlined, i.e. four nested floor/ceil divisions over products of
/// large symbolic u256 values, and it timed out at 900s. The divisions are
/// the whole difficulty and they are also unnecessary: what the argument
/// actually uses is only the DEFINING INEQUALITIES of floor and ceil. So each
/// model function gets a `_spec` summary below stating exactly those bounds
/// (the prover substitutes a `<fn>_spec` contract for the body when proving
/// callers), and the lemma itself becomes pure polynomial reasoning with no
/// division anywhere.
///
/// The chain, with `Q = 2^64`, `L_a = liquidity_from_a(p, U, base)` and
/// `L_b = liquidity_from_b(LO, p, quote)`:
///
///   (1) L_a*(U-p)*Q <= p*U*base                 floor, from liquidity_from_a
///   (2) need_quote*Q < L_a*(p-LO) + Q           ceil,  from delta_b
///   (3) need_quote > quote, and both are integers, so need_quote >= quote+1;
///       with (2) that gives  quote*Q < L_a*(p-LO)
///   (4) multiply (3) by (U-p)*Q and substitute (1):
///           quote*Q^2*(U-p) < (p-LO)*p*U*base
///   (5) L_b*(p-LO) <= quote*Q                   floor, from liquidity_from_b
///       multiply by (U-p)*Q and chain through (4), then cancel (p-LO) > 0:
///           L_b*(U-p)*Q < p*U*base
///   (6) need_base*p*U < L_b*(U-p)*Q + p*U       ceil,  from delta_a
///       with (5) that is < (base+1)*p*U, and p*U > 0 gives need_base <= base.
///
/// Every step is a polynomial inequality over `Integer` (arbitrary precision,
/// so no u256 overflow reasoning is entangled with the argument). Steps (4)
/// and (5) are stated as explicit intermediate lemmas because they are where
/// the solver has to multiply an inequality through by a positive product and
/// then cancel it again — the two moves Z3 does not reliably find alone.
///
/// WHAT THIS DOES AND DOES NOT BUY. The proof is about `cetus_model`, not
/// about Cetus's bytecode; see that module's header for the two bridging
/// obligations (formula fidelity at the pinned rev, and the full-range
/// constants, which `full_range_sqrt_prices_match_cetus` pins against the
/// real dependency).
module bondingcurvesui_specs::cetus_model_specs;

use bondingcurvesui_specs::cetus_model;

#[spec_only]
use prover::prover::{requires, ensures};
#[spec_only]
use std::integer::Integer;

/// Full-range sqrt price bounds of the platform's only fee tier (Cetus tick
/// spacing 200 => ticks +/-443600). `config::PLATFORM_TICK_SPACING` pins the
/// spacing so these are constants; `full_range_sqrt_prices_match_cetus`
/// asserts they are what Cetus computes.
const LO: u256 = 4302785677;
const UP: u256 = 79084200890414257525634219231;

const Q64: u256 = 0x1_0000_0000_0000_0000;

const U64_MAX: u256 = 0xffff_ffff_ffff_ffff;

const U256_MAX: u256 =
    0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff_ffff;

/// Minimum distance the seed price keeps from either full-range endpoint.
///
/// This is what bounds the liquidity, and through it every intermediate
/// product below `2^256`. Cetus's own math needs the same thing and enforces
/// it differently: liquidity is a `u128` there, and `get_delta_a` shifts
/// through `checked_shlw`, so a price pressed against an endpoint aborts
/// inside Cetus before this lemma's branch is ever reached. Stating it as a
/// precondition keeps the model faithful instead of proving a property about
/// arithmetic that would have already failed.
///
/// It costs nothing in practice: `curve::initial_sqrt_price_x64` returns
/// `isqrt(amount_b * 2^128 / amount_a)` for u64 amounts, so the seed price
/// only approaches an endpoint for a seed lopsided beyond about 2^62:1 --
/// far outside what the `config` launch floors permit.
const ENDPOINT_GUARD: u256 = 0x1_0000_0000; // 2^32

// === Summaries of the model functions ===
//
// Each states only what floor/ceil guarantees, as a pair of polynomial
// inequalities. These are what the lemma consumes; the divisions stay inside
// these small goals instead of compounding inside the big one.

/// `floor(p*u*a / ((u-p)*Q))`: the defining floor bounds.
#[spec(prove)]
fun liquidity_from_a_spec(p: u256, u: u256, amount_a: u256): u256 {
    requires(p > 0);
    requires(u > p);
    // Keeps `p * u * amount_a` inside u256 (it reaches 99.6% of the range at
    // the corner, so the bound is load-bearing, not slack).
    requires(u <= UP);
    requires(amount_a <= U64_MAX);
    let result = cetus_model::liquidity_from_a(p, u, amount_a);

    let n: Integer = p.to_int().mul(u.to_int()).mul(amount_a.to_int());
    let d: Integer = u.to_int().sub(p.to_int()).mul(Q64.to_int());
    ensures(result.to_int().mul(d).lte(n));
    ensures(n.lt(result.to_int().add(1u256.to_int()).mul(d)));
    result
}

/// `floor(b*Q / (p-lo))`: the defining floor bounds.
#[spec(prove)]
fun liquidity_from_b_spec(lo: u256, p: u256, amount_b: u256): u256 {
    requires(p > lo);
    requires(amount_b <= U64_MAX);
    let result = cetus_model::liquidity_from_b(lo, p, amount_b);

    let n: Integer = amount_b.to_int().mul(Q64.to_int());
    let d: Integer = p.to_int().sub(lo.to_int());
    ensures(result.to_int().mul(d).lte(n));
    ensures(n.lt(result.to_int().add(1u256.to_int()).mul(d)));
    result
}

/// `ceil(L*(p-lo) / Q)`: the defining ceil bounds. The `L == 0` early return
/// is consistent with them (both sides collapse to 0).
#[spec(prove)]
fun delta_b_spec(lo: u256, p: u256, liquidity: u256): u256 {
    requires(p > lo);
    // `div_ceil` forms `numerator + denominator - 1`, so the headroom has to
    // cover the bias, not just the numerator.
    requires(
        liquidity
            .to_int()
            .mul(p.to_int().sub(lo.to_int()))
            .add(Q64.to_int())
            .lte(U256_MAX.to_int()),
    );
    let result = cetus_model::delta_b(lo, p, liquidity);

    let n: Integer = liquidity.to_int().mul(p.to_int().sub(lo.to_int()));
    ensures(result.to_int().mul(Q64.to_int()).gte(n));
    ensures(result.to_int().mul(Q64.to_int()).lt(n.add(Q64.to_int())));
    result
}

/// `ceil(L*(u-p)*Q / (p*u))`: the defining ceil bounds.
#[spec(prove)]
fun delta_a_spec(p: u256, u: u256, liquidity: u256): u256 {
    requires(p > 0);
    requires(u > p);
    // As in `delta_b_spec`: headroom for the `div_ceil` bias.
    requires(
        liquidity
            .to_int()
            .mul(u.to_int().sub(p.to_int()))
            .mul(Q64.to_int())
            .add(p.to_int().mul(u.to_int()))
            .lte(U256_MAX.to_int()),
    );
    let result = cetus_model::delta_a(p, u, liquidity);

    let n: Integer = liquidity
        .to_int()
        .mul(u.to_int().sub(p.to_int()))
        .mul(Q64.to_int());
    let d: Integer = p.to_int().mul(u.to_int());
    ensures(result.to_int().mul(d).gte(n));
    ensures(result.to_int().mul(d).lt(n.add(d)));
    result
}

// === The lemma ===

/// If fixing the base leg would demand more quote than is available, then
/// fixing the quote leg demands no more base than is available.
#[spec(prove)]
fun binding_leg_fallback_is_safe(p: u256, base: u256, quote: u256) {
    // The seed price is strictly inside the full range: `pool_creator`
    // asserts this before creating the pool, and `curve` proves the derived
    // sqrt price stays in the envelope.
    // Strictly inside the full range, and clear of both endpoints by
    // `ENDPOINT_GUARD` -- see that constant for why the margin is needed and
    // why it is free in practice.
    requires(p > LO + ENDPOINT_GUARD);
    requires(p < UP - ENDPOINT_GUARD);
    // Both legs are u64 coin amounts, and non-empty (`seed_base_never_
    // degenerates` proves the base leg is non-zero under the config floors).
    requires(base > 0);
    requires(base <= U64_MAX);
    requires(quote > 0);
    requires(quote <= U64_MAX);

    let l_a = cetus_model::liquidity_from_a(p, UP, base);
    let need_quote = cetus_model::delta_b(LO, p, l_a);
    let l_b = cetus_model::liquidity_from_b(LO, p, quote);
    let need_base = cetus_model::delta_a(p, UP, l_b);

    // Positive factors the argument multiplies and cancels by.
    let q: Integer = Q64.to_int();
    let span_hi: Integer = UP.to_int().sub(p.to_int()); // U - p > 0
    let span_lo: Integer = p.to_int().sub(LO.to_int()); // p - LO > 0
    let pu: Integer = p.to_int().mul(UP.to_int()); // p*U > 0

    if (need_quote > quote) {
        // (3) need_quote >= quote+1 with the ceil bound on delta_b.
        ensures(quote.to_int().mul(q).lt(l_a.to_int().mul(span_lo)));
        // (4) multiply through by (U-p)*Q and substitute the floor bound.
        ensures(
            quote.to_int().mul(q).mul(q).mul(span_hi)
                .lt(span_lo.mul(pu).mul(base.to_int())),
        );
        // (5) the same product for the quote leg, after cancelling (p-LO).
        ensures(l_b.to_int().mul(span_hi).mul(q).lt(pu.mul(base.to_int())));
        // (6) the conclusion.
        ensures(need_base <= base);
    };
}
