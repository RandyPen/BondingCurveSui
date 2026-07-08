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
use prover::prover::{requires, ensures, asserts};

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
