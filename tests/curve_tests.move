#[test_only]
module bondingcurvesui::curve_tests;

use bondingcurvesui::curve;

// Mainnet-like launch parameters: 8M curve tokens, 2M LP tokens
// (6 decimals), thresholds in various quote decimals.
const I: u64 = 8_000_000_000_000;
const R: u64 = 2_000_000_000_000;
const T_6DEC: u64 = 3_000_000_000; // e.g. 3000 USDC-like (6 decimals)
const T_9DEC: u64 = 400_000_000_000; // e.g. 400 SUI-like (9 decimals)

// === derive_virtual_reserves ===

#[test]
fun derivation_matches_formulas() {
    let (vb0, vq0, floor_vb) = curve::derive_virtual_reserves(I, R, T_6DEC);
    // vb0 = I^2/(I-R) = 64e24/6e12
    assert!(vb0 == 10_666_666_666_666);
    // Sellable range is exactly the minted real supply.
    assert!(vb0 - floor_vb == I);
    // vq0 = ceil(T*R/(I-R)) = 1e9
    assert!(vq0 == 1_000_000_000);
}

#[test]
fun sellable_range_is_exact_for_ragged_params() {
    // Parameters chosen so I^2/(I-R) rounds: floor_vb must absorb the
    // rounding so that vb0 - floor_vb == I exactly.
    let (vb0, _, floor_vb) = curve::derive_virtual_reserves(7_777_777, 1_234_567, 999);
    assert!(vb0 - floor_vb == 7_777_777);
}

#[test, expected_failure(abort_code = curve::EInvalidReserveParams)]
fun derivation_rejects_remain_ge_initial() {
    curve::derive_virtual_reserves(1_000, 1_000, 1);
}

#[test, expected_failure(abort_code = curve::EInvalidThreshold)]
fun derivation_rejects_zero_threshold() {
    curve::derive_virtual_reserves(1_000, 100, 0);
}

// === Drain accounting ===

/// Buying the entire sellable range must hand out exactly I tokens and
/// cost at least T, and the end price must equal the CLMM seed price T/R.
fun assert_drain_exact(threshold: u64) {
    let (vb0, vq0, floor_vb) = curve::derive_virtual_reserves(I, R, threshold);
    let sellable = vb0 - floor_vb;
    let (cost, new_vb, new_vq) = curve::buy_cost_exact_out(vb0, vq0, sellable);
    assert!(new_vb == floor_vb);
    // The raise is never below the configured threshold. The flooring of
    // vb0 and ceiling of vq0 (1 unit each) are amplified by at most
    // vb0/floor_vb ~= I/R + 1 when projected onto the final cost.
    let amplification = I / R + 2;
    assert!(cost >= threshold && cost <= threshold + amplification);
    // End price vs CLMM seed price T/R: new_vq/new_vb == T/R within
    // rounding, i.e. |new_vq * R - T * new_vb| small relative to scale.
    let lhs = (new_vq as u128) * (R as u128);
    let rhs = (threshold as u128) * (new_vb as u128);
    let diff = if (lhs > rhs) { lhs - rhs } else { rhs - lhs };
    // new_vq carries the amplified rounding (<= amplification quote
    // units, weighted by R) and floor_vb carries <= 1 base unit
    // (weighted by T). Relative price error stays ~1e-12.
    assert!(diff <= (amplification as u128) * (R as u128) + (threshold as u128));
}

#[test]
fun drain_is_exact_6dec_quote() {
    assert_drain_exact(T_6DEC);
}

#[test]
fun drain_is_exact_9dec_quote() {
    assert_drain_exact(T_9DEC);
}

#[test]
fun incremental_buys_never_exceed_threshold_budget() {
    // Buying in many chunks must never be cheaper than the single-shot
    // drain (protocol-favoring rounding).
    let (vb0, vq0, floor_vb) = curve::derive_virtual_reserves(I, R, T_6DEC);
    let mut vb = vb0;
    let mut vq = vq0;
    let mut total_out = 0u64;
    let mut spent = 0u64;
    let chunk = T_6DEC / 10;
    while (vb > floor_vb) {
        let remaining = vb - floor_vb;
        let (out, cost) = if (curve::buy_out_preview(vb, vq, chunk) >= remaining) {
            let (cost, nvb, nvq) = curve::buy_cost_exact_out(vb, vq, remaining);
            vb = nvb;
            vq = nvq;
            (remaining, cost)
        } else {
            let (out, nvb, nvq) = curve::buy_out(vb, vq, chunk);
            vb = nvb;
            vq = nvq;
            (out, chunk)
        };
        total_out = total_out + out;
        spent = spent + cost;
    };
    assert!(total_out == I);
    assert!(spent >= T_6DEC);
    // Chunked buying pays more than single-shot only via per-chunk
    // rounding: at most 1 unit per chunk.
    assert!(spent <= T_6DEC + 2 + 11);
}

// === Swap math and rounding direction ===

#[test]
fun buy_then_sell_never_profits() {
    let (vb0, vq0, _) = curve::derive_virtual_reserves(I, R, T_6DEC);
    let quote_in = 123_456_789;
    let (base_out, vb1, vq1) = curve::buy_out(vb0, vq0, quote_in);
    let (quote_back, _, _) = curve::sell_out(vb1, vq1, base_out);
    assert!(quote_back <= quote_in);
}

#[test]
fun exact_out_cost_covers_exact_in() {
    // Paying the quoted exact-out cost must deliver at least that output.
    let (vb0, vq0, _) = curve::derive_virtual_reserves(I, R, T_6DEC);
    let want_out = 1_000_000_123_456;
    let (cost, _, _) = curve::buy_cost_exact_out(vb0, vq0, want_out);
    let (got_out, _, _) = curve::buy_out(vb0, vq0, cost);
    assert!(got_out >= want_out);
}

#[test]
fun zero_input_zero_output() {
    let (vb0, vq0, _) = curve::derive_virtual_reserves(I, R, T_6DEC);
    let (out, vb1, vq1) = curve::buy_out(vb0, vq0, 0);
    assert!(out == 0 && vb1 == vb0 && vq1 == vq0);
    let (out2, vb2, vq2) = curve::sell_out(vb0, vq0, 0);
    assert!(out2 == 0 && vb2 == vb0 && vq2 == vq0);
}

#[test, expected_failure(abort_code = curve::EExcessiveOutput)]
fun exact_out_rejects_draining_virtual_reserve() {
    let (vb0, vq0, _) = curve::derive_virtual_reserves(I, R, T_6DEC);
    curve::buy_cost_exact_out(vb0, vq0, vb0);
}

// === fee_amount ===

#[test]
fun fee_rounds_up() {
    assert!(curve::fee_amount(10_000, 100) == 100); // exact 1%
    assert!(curve::fee_amount(10_001, 100) == 101); // ceiled
    assert!(curve::fee_amount(1, 1) == 1); // minimum nonzero
    assert!(curve::fee_amount(0, 100) == 0);
    assert!(curve::fee_amount(1_000_000, 0) == 0);
}

// === isqrt ===

#[test]
fun isqrt_edges() {
    assert!(curve::isqrt(0) == 0);
    assert!(curve::isqrt(1) == 1);
    assert!(curve::isqrt(3) == 1);
    assert!(curve::isqrt(4) == 2);
    assert!(curve::isqrt(15) == 3);
    assert!(curve::isqrt(16) == 4);
    assert!(curve::isqrt(17) == 4);
    // Perfect square of a large value.
    let big = 0xffff_ffff_ffff_ffff_ffff_ffff_ffff_ffffu256; // 2^128 - 1
    assert!(curve::isqrt(big * big) == big);
    assert!(curve::isqrt(big * big + 2 * big) == big); // (big+1)^2 - 1
    // Max u256 input terminates and is correct: isqrt(2^256 - 1) = 2^128 - 1.
    assert!(curve::isqrt(std::u256::max_value!()) == big);
}

// === initial_sqrt_price_x64 ===

#[test]
fun sqrt_price_matches_known_values() {
    // Equal amounts -> price 1 -> sqrt price = 2^64.
    assert!(curve::initial_sqrt_price_x64(1_000_000, 1_000_000) == 1 << 64);
    // price 4 -> sqrt price = 2 * 2^64.
    assert!(curve::initial_sqrt_price_x64(1_000_000, 4_000_000) == 2 << 64);
    // price 1/4 -> sqrt price = 2^63.
    assert!(curve::initial_sqrt_price_x64(4_000_000, 1_000_000) == 1 << 63);
}

#[test]
fun sqrt_price_graduation_within_cetus_bounds() {
    // The seed price for both orientations of a realistic graduation must
    // sit inside Cetus's representable sqrt price range.
    let min_sqrt_price = 4295048016u128; // cetus tick_math::min_sqrt_price
    let max_sqrt_price = 79226673515401279992447579055u128;
    let sp_base_a = curve::initial_sqrt_price_x64(R, T_6DEC);
    let sp_base_b = curve::initial_sqrt_price_x64(T_6DEC, R);
    assert!(sp_base_a > min_sqrt_price && sp_base_a < max_sqrt_price);
    assert!(sp_base_b > min_sqrt_price && sp_base_b < max_sqrt_price);
    let sp9_a = curve::initial_sqrt_price_x64(R, T_9DEC);
    let sp9_b = curve::initial_sqrt_price_x64(T_9DEC, R);
    assert!(sp9_a > min_sqrt_price && sp9_a < max_sqrt_price);
    assert!(sp9_b > min_sqrt_price && sp9_b < max_sqrt_price);
}

#[test, expected_failure(abort_code = curve::EZeroAmount)]
fun sqrt_price_rejects_zero() {
    curve::initial_sqrt_price_x64(0, 1);
}

// === tvl_in_quote ===

#[test]
fun tvl_balanced_pool_counts_base_at_price() {
    // Pool seeded at price 2 (quote per base), base is coin A:
    // sqrt price = sqrt(2) * 2^64. 100 base + 200 quote -> TVL = 400.
    let sp = curve::initial_sqrt_price_x64(100, 200);
    let tvl = curve::tvl_in_quote(100, 200, sp, true);
    // isqrt flooring can shave a unit.
    assert!(tvl >= 399 && tvl <= 400);
}

#[test]
fun tvl_inverted_orientation() {
    // Same pool but base is coin B: price(A per B) seen from quote=A side
    // is 1/2, sqrt price computed from (amount_base=100, amount_quote=200)
    // orientation: A=quote(200), B=base(100) -> price B per A... the pool
    // price is B/A = 100/200 = 0.5; sqrt = sqrt(0.5)*2^64.
    let sp = curve::initial_sqrt_price_x64(200, 100);
    let tvl = curve::tvl_in_quote(100, 200, sp, false);
    // base value = 100 / 0.5 = 200 -> TVL = 400.
    assert!(tvl >= 399 && tvl <= 401);
}

#[test]
fun tvl_zero_base() {
    let sp = curve::initial_sqrt_price_x64(1, 1);
    assert!(curve::tvl_in_quote(0, 777, sp, true) == 777);
    assert!(curve::tvl_in_quote(0, 777, sp, false) == 777);
}

#[test]
fun tvl_extreme_inputs_do_not_abort() {
    // Max u64 balances at Cetus's max sqrt price: price ~= 2^64, so the
    // base leg is just under 2^128. Must compute (near u128::max)
    // without overflow in either orientation.
    let max_sqrt_price = 79226673515401279992447579055u128;
    let tvl = curve::tvl_in_quote(
        0xffff_ffff_ffff_ffff,
        0xffff_ffff_ffff_ffff,
        max_sqrt_price,
        true,
    );
    assert!(tvl > 1u128 << 127);
    let min_sqrt_price = 4295048016u128; // price ~= 2^-64
    let tvl_inv = curve::tvl_in_quote(
        0xffff_ffff_ffff_ffff,
        0xffff_ffff_ffff_ffff,
        min_sqrt_price,
        false,
    );
    assert!(tvl_inv > 1u128 << 127);
}
