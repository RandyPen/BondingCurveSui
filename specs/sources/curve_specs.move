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
