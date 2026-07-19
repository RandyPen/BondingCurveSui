/// Sui Prover specifications for `bondingcurvesui::curve`.
///
/// Every spec fully characterizes the target's abort conditions (`asserts`)
/// and proves the safety properties the pool module relies on:
///
/// - `derive_virtual_reserves`: vb0 >= initial_base (the floor subtraction
///   cannot underflow), exact floor/ceil formulas, vq0 > 0.
/// - `buy_out` / `buy_cost_exact_out` / `sell_out`: the constant-product
///   invariant `new_vb * new_vq >= vb * vq` never decreases, outputs never
///   exceed the corresponding virtual reserve, and reserve deltas match the
///   returned amounts exactly (conservation).
/// - `fee_amount`: fee equals the ceiled pro-rata share and never exceeds
///   the amount for bps <= 10_000.
/// - `buy_then_sell_never_profits`: composing a buy with a full sell-back
///   of the purchased base can never return more quote than was paid in.
/// - Pool solvency (`vq >= vq0`, i.e. `quote_reserve` never goes negative):
///   the INDUCTIVE STEP only. See the block comment above
///   `buy_never_decreases_product` for exactly which conjunct is proven
///   arithmetically and which is assumed from `pool.move`'s coin custody.
/// - `net_basis_fee_undercharges_boundedly`: bounds the gross-vs-net fee
///   basis discrepancy in `pool::buy_internal`'s clamped branch.
module bondingcurvesui::curve_specs;

use bondingcurvesui::curve;

#[spec_only]
use prover::prover::{requires, ensures, asserts, implies};

const U64_MAX: u128 = 0xffff_ffff_ffff_ffff;
const BPS_DENOMINATOR: u64 = 10_000;

// === derive_virtual_reserves ===

#[spec(prove, target = curve::derive_virtual_reserves)]
fun derive_virtual_reserves_spec(
    initial_base: u64,
    remain_base: u64,
    threshold: u64,
): (u64, u64, u64) {
    asserts(remain_base > 0 && initial_base > remain_base);
    asserts(threshold > 0);

    let i = initial_base.to_int();
    let r = remain_base.to_int();
    let t = threshold.to_int();
    let denom = i.sub(r);
    let max = U64_MAX.to_int();

    // vb0 = floor(I^2 / (I - R)) must fit in u64.
    let vb0 = i.mul(i).div(denom);
    asserts(vb0.lte(max));
    // vq0 = ceil(T * R / (I - R)) must fit in u64 (> 0 holds automatically).
    let vq0 = t.mul(r).add(denom).sub(1u64.to_int()).div(denom);
    asserts(vq0.lte(max));

    let (vb, vq, floor_vb) =
        curve::derive_virtual_reserves(initial_base, remain_base, threshold);

    // Exact formulas.
    ensures(vb.to_int() == vb0);
    ensures(vq.to_int() == vq0);
    // The sellable range is exactly the minted real supply.
    ensures(vb >= initial_base);
    ensures(floor_vb == vb - initial_base);
    // The curve starts with a positive quote reserve.
    ensures(vq > 0);

    (vb, vq, floor_vb)
}

// === buy_out ===

#[spec(prove, target = curve::buy_out)]
fun buy_out_spec(vb: u64, vq: u64, quote_in: u64): (u64, u64, u64) {
    let new_vq_wide = (vq as u128) + (quote_in as u128);
    asserts(new_vq_wide <= U64_MAX);
    asserts(new_vq_wide > 0);

    let k = vb.to_int().mul(vq.to_int());

    let (base_out, new_vb, new_vq) = curve::buy_out(vb, vq, quote_in);

    // Quote reserve grows by exactly the input.
    ensures(new_vq.to_int() == vq.to_int().add(quote_in.to_int()));
    // Base reserve shrinks by exactly the output (solvency: out <= vb).
    ensures(base_out <= vb);
    ensures(new_vb.to_int() == vb.to_int().sub(base_out.to_int()));
    // Constant-product invariant never decreases.
    ensures(new_vb.to_int().mul(new_vq.to_int()).gte(k));
    // The new base reserve is EXACTLY the ceiled quotient. The invariant
    // above only bounds it; callers that reason about the clamp (see
    // `clamped_buy_never_overcharges`) need the exact rounding, and without
    // this the opaque summary is too weak to derive it.
    let new_vq_int = vq.to_int().add(quote_in.to_int());
    ensures(
        new_vb.to_int() == k.add(new_vq_int).sub(1u64.to_int()).div(new_vq_int),
    );

    (base_out, new_vb, new_vq)
}

// === buy_cost_exact_out ===

#[spec(prove, target = curve::buy_cost_exact_out)]
fun buy_cost_exact_out_spec(vb: u64, vq: u64, base_out: u64): (u64, u64, u64) {
    asserts(base_out < vb);

    let k = vb.to_int().mul(vq.to_int());
    let new_vb_int = vb.to_int().sub(base_out.to_int());
    // new_vq = ceil(k / (vb - base_out)) must fit in u64.
    let new_vq_int = k.add(new_vb_int).sub(1u64.to_int()).div(new_vb_int);
    asserts(new_vq_int.lte(U64_MAX.to_int()));

    let (cost, new_vb, new_vq) = curve::buy_cost_exact_out(vb, vq, base_out);

    // Base reserve shrinks by exactly the requested output.
    ensures(new_vb.to_int() == vb.to_int().sub(base_out.to_int()));
    // Cost is exactly the quote-reserve growth (never negative).
    ensures(new_vq >= vq);
    ensures(cost.to_int() == new_vq.to_int().sub(vq.to_int()));
    // Constant-product invariant never decreases.
    ensures(new_vb.to_int().mul(new_vq.to_int()).gte(k));
    // The new quote reserve is EXACTLY the ceiled quotient, for the same
    // reason as in `buy_out_spec`.
    ensures(new_vq.to_int() == new_vq_int);

    (cost, new_vb, new_vq)
}

// === sell_out ===

#[spec(prove, target = curve::sell_out)]
fun sell_out_spec(vb: u64, vq: u64, base_in: u64): (u64, u64, u64) {
    let new_vb_wide = (vb as u128) + (base_in as u128);
    asserts(new_vb_wide <= U64_MAX);
    asserts(new_vb_wide > 0);

    let k = vb.to_int().mul(vq.to_int());

    let (quote_out, new_vb, new_vq) = curve::sell_out(vb, vq, base_in);

    // Base reserve grows by exactly the input.
    ensures(new_vb.to_int() == vb.to_int().add(base_in.to_int()));
    // Quote reserve shrinks by exactly the output (solvency: out <= vq).
    ensures(quote_out <= vq);
    ensures(new_vq.to_int() == vq.to_int().sub(quote_out.to_int()));
    // Constant-product invariant never decreases.
    ensures(new_vb.to_int().mul(new_vq.to_int()).gte(k));

    (quote_out, new_vb, new_vq)
}

// === fee_amount ===

#[spec(prove, target = curve::fee_amount)]
fun fee_amount_spec(amount: u64, bps: u64): u64 {
    let bps_denom = (BPS_DENOMINATOR as u128).to_int();
    let ceiled = amount
        .to_int()
        .mul(bps.to_int())
        .add(bps_denom)
        .sub(1u64.to_int())
        .div(bps_denom);
    asserts(ceiled.lte(U64_MAX.to_int()));

    let fee = curve::fee_amount(amount, bps);

    // Fee is exactly the ceiled pro-rata share.
    ensures(fee.to_int() == ceiled);
    // The DEFINING CEIL INEQUALITIES, stated division-free. Equivalent to the
    // exact formula above, but callers that combine several fees in one goal
    // (`net_basis_fee_undercharges_boundedly`) can only use them polynomially
    // — three nested exact quotients in a single goal is what makes Boogie
    // time out. Cf. the summary idiom documented in `cetus_model_specs`.
    let n = amount.to_int().mul(bps.to_int());
    ensures(fee.to_int().mul(bps_denom).gte(n));
    ensures(fee.to_int().mul(bps_denom).lt(n.add(bps_denom)));
    // A fee rate within 100% never charges more than the amount.
    if (bps <= BPS_DENOMINATOR) {
        ensures(fee <= amount);
    };

    fee
}

// === Scenario: round trip extracts no value ===

/// Buying with `quote_in` and immediately selling the entire purchase back
/// returns at most `quote_in` — rounding always favors the curve, so a
/// buy/sell round trip can never drain quote from the pool.
#[spec(prove)]
fun buy_then_sell_never_profits(vb: u64, vq: u64, quote_in: u64) {
    requires(vb > 0);
    requires(vq > 0);
    requires((vq as u128) + (quote_in as u128) <= U64_MAX);

    let (base_out, vb1, vq1) = curve::buy_out(vb, vq, quote_in);
    let (quote_out, vb2, _vq2) = curve::sell_out(vb1, vq1, base_out);

    // The virtual base returns exactly to its starting point...
    ensures(vb2 == vb);
    // ...and the seller gets back no more than they paid.
    ensures(quote_out <= quote_in);
}

// === Pool solvency: the inductive step ===
//
// WHAT SOLVENCY MEANS HERE. The pool holds `quote_reserve` real quote and
// tracks virtual reserves `(vb, vq)` seeded at `(vb0, vq0)`, maintaining
// `quote_reserve == vq - vq0`. Every sell pays out of `quote_reserve`, so
// "the pool can always cover what outstanding sells withdraw" is exactly
//
//     vq >= vq0   at every reachable state.
//
// That is an inductive invariant with TWO conjuncts, and it is worth being
// precise about which one is arithmetic and which one is custodial:
//
//   (K) k = vb*vq  never decreases from k0 = vb0*vq0.
//       Pure arithmetic. `buy_out`/`sell_out`/`buy_cost_exact_out` each ceil
//       the reserve they recompute, so each step has k' >= k; chaining is
//       transitivity. PROVEN below, per operation.
//
//   (B) vb <= vb0  — the virtual base never rises above its seed.
//       NOT arithmetic. `vb` grows only on sells, by exactly `base_in`
//       (conservation, proven in `sell_out_spec`), and it falls on buys by
//       exactly `base_out`. So (B) says precisely: users cannot sell back
//       more base than the curve has ever issued. That is enforced by Sui
//       coin custody in `pool.move` (a seller must present `Coin<Base>` the
//       curve minted), not by `curve.move`. It is assumed as a hypothesis in
//       the step lemmas below and flagged in each one.
//
// Given (K) and (B), solvency is immediate and division-free:
//       vb0*vq >= vb*vq >= vb0*vq0  =>  vq >= vq0   (vb0 > 0).
// That last implication is `product_and_base_bound_imply_solvency`.
//
// WHAT IS THEREFORE NOT PROVEN. This is the INDUCTIVE STEP, not the full
// induction. The prover here reasons about pure functions with no notion of
// pool state, so nothing in this file quantifies over reachable traces or
// establishes (B). Closing the induction needs a stateful prover (or a
// `pool.move` the prover could load) that carries `(K) && (B)` as a struct
// invariant on `Pool` and discharges (B) from the fact that `sell` consumes
// a `Coin<Base>` whose supply is bounded by the mints `buy` performed. What
// IS closed here: given the invariant at a state, every curve operation
// re-establishes it, and it implies `vq >= vq0`.

/// (K) for `buy_out`: `div_ceil` on the base side makes the product
/// non-decreasing, and the buy moves the base reserve DOWN — so a buy can
/// never threaten (B) either.
#[spec(prove)]
fun buy_never_decreases_product(vb: u64, vq: u64, quote_in: u64) {
    requires(vb > 0);
    requires(vq > 0);
    requires((vq as u128) + (quote_in as u128) <= U64_MAX);

    let (_, vb1, vq1) = curve::buy_out(vb, vq, quote_in);

    ensures(vb1.to_int().mul(vq1.to_int()).gte(vb.to_int().mul(vq.to_int())));
    ensures(vb1 <= vb);
    ensures(vq1 >= vq);
}

/// (K) for `buy_cost_exact_out` — the clamped completing buy. Same shape:
/// the ceil is on the quote side here, and the base reserve still only falls.
#[spec(prove)]
fun exact_out_buy_never_decreases_product(vb: u64, vq: u64, base_out: u64) {
    requires(vq > 0);
    requires(base_out < vb);
    // `buy_cost_exact_out` aborts (`EReserveOverflow`) when the ceiled new
    // quote reserve leaves u64 — buying out nearly the whole base reserve
    // costs unboundedly much. The lemma is about the executions that return.
    let k = vb.to_int().mul(vq.to_int());
    let new_vb_int = vb.to_int().sub(base_out.to_int());
    requires(
        k.add(new_vb_int).sub(1u64.to_int()).div(new_vb_int).lte(U64_MAX.to_int()),
    );

    let (_, vb1, vq1) = curve::buy_cost_exact_out(vb, vq, base_out);

    ensures(vb1.to_int().mul(vq1.to_int()).gte(vb.to_int().mul(vq.to_int())));
    ensures(vb1 <= vb);
    ensures(vq1 >= vq);
}

/// (K) for `sell_out`. This is the operation that can lower `vq`, so it is
/// the only one where (B) does any work.
#[spec(prove)]
fun sell_never_decreases_product(vb: u64, vq: u64, base_in: u64) {
    requires(vb > 0);
    requires(vq > 0);
    requires((vb as u128) + (base_in as u128) <= U64_MAX);

    let (_, vb1, vq1) = curve::sell_out(vb, vq, base_in);

    ensures(vb1.to_int().mul(vq1.to_int()).gte(vb.to_int().mul(vq.to_int())));
    ensures(vb1 >= vb);
    ensures(vq1 <= vq);
}

/// The algebraic core: (K) and (B) together force solvency. Division-free,
/// so it is cheap and composes with any chain of operations that maintains
/// the two conjuncts.
#[spec(prove)]
fun product_and_base_bound_imply_solvency(vb0: u64, vq0: u64, vb: u64, vq: u64) {
    requires(vb0 > 0);
    // (B): the virtual base never rose above its seed.
    requires(vb <= vb0);
    // (K): the constant product never fell below its seed.
    requires(vb.to_int().mul(vq.to_int()).gte(vb0.to_int().mul(vq0.to_int())));

    // Hence the quote reserve `vq - vq0` that the pool hands out is never
    // negative: the pool is solvent.
    ensures(vq >= vq0);
}

/// INDUCTIVE STEP, buy. Assuming the invariant at `(vb, vq)`, a buy
/// re-establishes it and the pool stays solvent. (B) needs no hypothesis
/// here: buys only lower `vb`.
#[spec(prove)]
fun buy_preserves_solvency_invariant(
    vb0: u64,
    vq0: u64,
    vb: u64,
    vq: u64,
    quote_in: u64,
) {
    requires(vb0 > 0);
    requires(vb > 0);
    requires(vq > 0);
    requires(vb <= vb0); // (B)
    requires(vb.to_int().mul(vq.to_int()).gte(vb0.to_int().mul(vq0.to_int()))); // (K)
    requires((vq as u128) + (quote_in as u128) <= U64_MAX);

    let (_, vb1, vq1) = curve::buy_out(vb, vq, quote_in);

    ensures(vb1 <= vb0); // (B) preserved
    ensures(vb1.to_int().mul(vq1.to_int()).gte(vb0.to_int().mul(vq0.to_int()))); // (K) preserved
    ensures(vq1 >= vq0); // solvent
}

/// INDUCTIVE STEP, clamped completing buy.
#[spec(prove)]
fun exact_out_buy_preserves_solvency_invariant(
    vb0: u64,
    vq0: u64,
    vb: u64,
    vq: u64,
    base_out: u64,
) {
    requires(vb0 > 0);
    requires(vq > 0);
    requires(base_out < vb);
    requires(vb <= vb0); // (B)
    requires(vb.to_int().mul(vq.to_int()).gte(vb0.to_int().mul(vq0.to_int()))); // (K)
    // Non-aborting executions only; see `exact_out_buy_never_decreases_product`.
    let k = vb.to_int().mul(vq.to_int());
    let new_vb_int = vb.to_int().sub(base_out.to_int());
    requires(
        k.add(new_vb_int).sub(1u64.to_int()).div(new_vb_int).lte(U64_MAX.to_int()),
    );

    let (_, vb1, vq1) = curve::buy_cost_exact_out(vb, vq, base_out);

    ensures(vb1 <= vb0); // (B) preserved
    ensures(vb1.to_int().mul(vq1.to_int()).gte(vb0.to_int().mul(vq0.to_int()))); // (K) preserved
    ensures(vq1 >= vq0); // solvent
}

/// INDUCTIVE STEP, sell. This is the case that needs (B) as a genuine
/// hypothesis: `vb + base_in <= vb0` is the custodial fact that the base
/// being sold was issued by this curve. Under it the sell cannot push `vq`
/// below `vq0` — i.e. `sell_out` can never withdraw more quote than the pool
/// holds, which is the underflow the prior audit could only fuzz for.
#[spec(prove)]
fun sell_preserves_solvency_invariant(
    vb0: u64,
    vq0: u64,
    vb: u64,
    vq: u64,
    base_in: u64,
) {
    requires(vb0 > 0);
    requires(vb > 0);
    requires(vq > 0);
    requires(vb <= vb0);
    // (B) for the post-state: users cannot sell back more base than the curve
    // ever issued. Enforced by coin custody in `pool.move`, not here.
    requires((vb as u128) + (base_in as u128) <= (vb0 as u128));
    requires(vb.to_int().mul(vq.to_int()).gte(vb0.to_int().mul(vq0.to_int()))); // (K)

    let (quote_out, vb1, vq1) = curve::sell_out(vb, vq, base_in);

    ensures(vb1 <= vb0); // (B) preserved
    ensures(vb1.to_int().mul(vq1.to_int()).gte(vb0.to_int().mul(vq0.to_int()))); // (K) preserved
    ensures(vq1 >= vq0); // solvent: the payout left the reserve non-negative
    // Equivalently, in the pool's own bookkeeping: the payout never exceeds
    // the tracked `quote_reserve == vq - vq0`.
    ensures(quote_out.to_int().lte(vq.to_int().sub(vq0.to_int())));
}

/// Round trip, stated so it COMPOSES with `buy_then_sell_never_profits`
/// rather than restating it. That lemma says the trader gets back no more
/// quote than they paid; this one says the same fact from the POOL's side —
/// the quote reserve ends at least where it started, and the product has not
/// decreased — which is the form the induction above consumes.
///
/// Note the argument is the product one, not a subtraction one: the sell
/// returns `vb` exactly to its starting value, so `vb*vq2 >= vb*vq` with
/// `vb > 0` gives `vq2 >= vq` directly.
#[spec(prove)]
fun buy_then_sell_never_lowers_quote_reserve(vb: u64, vq: u64, quote_in: u64) {
    requires(vb > 0);
    requires(vq > 0);
    requires((vq as u128) + (quote_in as u128) <= U64_MAX);

    let (base_out, vb1, vq1) = curve::buy_out(vb, vq, quote_in);
    let (_, vb2, vq2) = curve::sell_out(vb1, vq1, base_out);

    ensures(vb2 == vb);
    // The pool never ends a round trip with less quote than it began with.
    ensures(vq2 >= vq);
    // And the product is still non-decreasing across the composite step, so
    // a round trip is just another operation the induction can absorb.
    ensures(vb2.to_int().mul(vq2.to_int()).gte(vb.to_int().mul(vq.to_int())));
}

// === vested_amount ===

/// The two properties `pool::claim_tvl_tranche` relies on but cannot state:
/// a release never exceeds the tranche, and completion drains it EXACTLY.
/// If the first failed the tranche would over-release (and `locked.split`
/// would abort); if the second failed, dust would stay locked forever with
/// no path to claim it.
#[spec(prove, target = curve::vested_amount)]
fun vested_amount_spec(total: u64, served_ms: u64, duration_ms: u64): u64 {
    asserts(duration_ms > 0);

    let res = curve::vested_amount(total, served_ms, duration_ms);

    // Never over-releases.
    ensures(res <= total);
    // Reaches the whole tranche exactly at (or past) completion.
    if (served_ms >= duration_ms) {
        ensures(res == total);
    };
    // Nothing is released before the schedule starts.
    if (served_ms == 0) {
        ensures(res == 0);
    };
    // Exactly the floored pro-rata share while in progress.
    if (served_ms < duration_ms) {
        ensures(
            res.to_int()
                == total.to_int().mul(served_ms.to_int()).div(duration_ms.to_int()),
        );
    };

    res
}

/// Monotonicity in elapsed time. This is what makes `entitled - withdrawn`
/// in `pool::claim_tvl_tranche` safe: `withdrawn` is a previous `entitled`
/// at a smaller elapsed time, so the subtraction can never underflow.
#[spec(prove)]
fun vested_amount_is_monotone(total: u64, s1: u64, s2: u64, duration_ms: u64) {
    requires(duration_ms > 0);
    requires(s1 <= s2);

    let v1 = curve::vested_amount(total, s1, duration_ms);
    let v2 = curve::vested_amount(total, s2, duration_ms);

    ensures(v1 <= v2);
}

// === seed_base_amount ===

/// The CLMM seed can never degenerate to an empty base leg once the
/// launch-time floors hold. A zero here aborts `add_liquidity_fix_coin`, and
/// because migration cannot be paused and a COMPLETED pool cannot sell, that
/// abort strands the entire raise permanently.
///
/// The bounds mirror `config`: `MIN_REMAIN_BASE`, `MIN_QUOTE_THRESHOLD` and
/// `MAX_MIGRATION_FEE_BPS`. Proving it here is what turns those constants
/// from "no counterexample found by sweeping" into a guarantee.
#[spec(prove)]
fun seed_base_never_degenerates(base_amount: u64, quote_amount: u64, bps: u64) {
    requires(base_amount >= 1_000_000_000); // config::MIN_REMAIN_BASE
    requires(quote_amount >= 1_000); // config::MIN_QUOTE_THRESHOLD
    requires(quote_amount <= U64_MAX as u64);
    requires(bps <= 1_000); // config::MAX_MIGRATION_FEE_BPS

    let fee = curve::fee_amount(quote_amount, bps);
    // The ceiled fee never consumes the whole raise...
    ensures(fee < quote_amount);

    let quote_net = quote_amount - fee;
    let base_seed = curve::seed_base_amount(base_amount, quote_net, quote_amount);

    // ...so the base leg handed to Cetus is never empty.
    ensures(base_seed > 0);
    // And it never exceeds what the pool actually holds.
    ensures(base_seed <= base_amount);
}

// === Scenario: the completing-buy clamp never overcharges ===

/// `pool::buy_internal` clamps the completing buy: when the unclamped output
/// would reach `cap`, it charges `buy_cost_exact_out(cap)` instead of the
/// full net input. That is only sound if the clamped cost is at most the net
/// it replaces — otherwise the pool would take more quote than the caller
/// supplied and the change split would abort mid-trade.
///
/// The argument is a rounding-direction one (`buy_out` ceils the new base
/// reserve, `buy_cost_exact_out` ceils the new quote reserve, and the two
/// line up), which is exactly the kind that is easy to get subtly wrong.
#[spec(prove)]
fun clamped_buy_never_overcharges(vb: u64, vq: u64, net: u64, cap: u64) {
    requires(vb > 0);
    requires(vq > 0);
    requires((vq as u128) + (net as u128) <= U64_MAX);
    requires(cap < vb);

    let (out, _, _) = curve::buy_out(vb, vq, net);

    // Mirrors `buy_internal`: the exact-out cost is only computed on the
    // clamp branch. Outside it the call could overflow `EReserveOverflow`,
    // which is precisely why the real code never makes it there.
    if (out >= cap) {
        let (cost, _, _) = curve::buy_cost_exact_out(vb, vq, cap);
        // It charges no more than the unclamped branch would have.
        ensures(cost <= net);
    };
}

// === fee_amount monotonicity ===

/// The clamp branch also recomputes the fee on the reduced cost. Charging
/// `fee(cost)` where `fee(net)` was budgeted is only safe if the fee is
/// monotone in the amount — together with `clamped_buy_never_overcharges`
/// this is what gives `cost + fee(cost) <= net + fee(net) == gross`.
#[spec(prove)]
fun fee_amount_is_monotone(a1: u64, a2: u64, bps: u64) {
    requires(a1 <= a2);
    // Within a 100% rate the fee never exceeds the amount, so no overflow.
    requires(bps <= BPS_DENOMINATOR);

    let f1 = curve::fee_amount(a1, bps);
    let f2 = curve::fee_amount(a2, bps);

    ensures(f1 <= f2);
}

// === The fee basis discrepancy ===

/// `pool::buy_internal` charges the fee on two different bases depending on
/// the branch: the normal path takes `fee_amount(gross, bps)` on the GROSS
/// input, the clamped completing-buy path takes `fee_amount(cost, bps)` where
/// `cost` is the NET exact-out cost. A net basis is strictly the smaller of
/// the two, so the clamped branch UNDERCHARGES — which contradicts the
/// module's stated invariant that every rounding favors the protocol.
///
/// `pool.move` cannot be loaded by the prover (CetusClmm dependency), so the
/// discrepancy is characterized here purely over `curve`, for the exact
/// relationship the two branches stand in: `net = gross - fee(gross)`.
///
/// The result bounds the leak: it is non-negative (never favors the protocol)
/// and never exceeds the fee ON the fee, i.e. `bps` of the fee itself — about
/// 1% of the fee at the platform's 100 bps trade rate, for at most one
/// clamped trade per pool.
///
/// PROOF (all polynomial, using only the ceil inequalities in
/// `fee_amount_spec`; write `D = 10_000`, `F = fee(gross)`, `f = fee(net)`,
/// `ff = fee(F)`):
///   F*D  <  gross*bps + D   = (net + F)*bps + D    (ceil upper, gross = net+F)
///   net*bps <= f*D  and  F*bps <= ff*D             (ceil lower, twice)
///   => F*D < f*D + ff*D + D  => F < f + ff + 1  => F - f <= ff.
#[spec(prove)]
fun net_basis_fee_undercharges_boundedly(gross: u64, bps: u64) {
    // A rate within 100%, which `config` enforces for every fee it stores.
    requires(bps <= BPS_DENOMINATOR);

    let fee_gross = curve::fee_amount(gross, bps);
    // The gross-basis fee never exceeds the input, so the net is well defined.
    ensures(fee_gross <= gross);
    let net = gross - fee_gross;

    let fee_net = curve::fee_amount(net, bps);
    let fee_on_fee = curve::fee_amount(fee_gross, bps);

    // DIRECTION: the net basis never charges MORE than the gross basis, so
    // the clamped branch can only ever shortchange the protocol, never the
    // user. (The pool is therefore never left short of quote by this.)
    ensures(fee_net <= fee_gross);
    // MAGNITUDE: and it shortchanges it by at most `bps` of the fee itself.
    ensures(fee_gross - fee_net <= fee_on_fee);
}
