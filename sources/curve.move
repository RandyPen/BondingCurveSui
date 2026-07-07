/// Pure constant-product bonding-curve math over virtual reserves.
///
/// The curve trades a virtual base reserve `vb` against a virtual quote
/// reserve `vq` with invariant `vb * vq = k`. All rounding favors the
/// protocol: buyers receive floored output and pay ceiled cost, sellers
/// receive floored output, fees are ceiled.
///
/// Reserve derivation for a launch with `I` real curve tokens, `R` tokens
/// reserved for the CLMM liquidity, and graduation threshold `T` (quote):
///
///   vb0      = I^2 / (I - R)          initial virtual base
///   floor_vb = vb0 - I                virtual base at completion
///   vq0      = T * R / (I - R)        initial virtual quote
///
/// Selling the curve down to `floor_vb` hands out exactly the `I` real
/// tokens and raises exactly `T` quote (up to rounding), and the final curve
/// price equals `T / R` — the same price at which the `T` quote + `R` base
/// seed the CLMM pool, so graduation causes no price gap.
module bondingcurvesui::curve;

// === Errors ===

/// initial base must be strictly greater than remain (both > 0).
const EInvalidReserveParams: u64 = 1;
/// Threshold must be positive.
const EInvalidThreshold: u64 = 2;
/// Derived virtual reserve does not fit in u64.
const EReserveOverflow: u64 = 3;
/// Swap output exceeds the available virtual reserve.
const EExcessiveOutput: u64 = 4;
/// Constant-product invariant would decrease.
const EInvariantViolation: u64 = 5;
/// sqrt price computation received a zero amount.
const EZeroAmount: u64 = 6;

const BPS_DENOMINATOR: u64 = 10_000;
const U64_MAX: u128 = 0xffff_ffff_ffff_ffff;

// === Reserve derivation ===

/// Returns `(vb0, vq0, floor_vb)` for a launch (see module doc).
/// `floor_vb` is defined as `vb0 - initial_base` so the sellable virtual
/// range is exactly the minted real supply regardless of rounding.
public fun derive_virtual_reserves(
    initial_base: u64,
    remain_base: u64,
    threshold: u64,
): (u64, u64, u64) {
    assert!(remain_base > 0 && initial_base > remain_base, EInvalidReserveParams);
    assert!(threshold > 0, EInvalidThreshold);
    let denom = (initial_base - remain_base) as u128;
    let vb0 = (initial_base as u128) * (initial_base as u128) / denom;
    assert!(vb0 <= U64_MAX, EReserveOverflow);
    // Ceiled so the raise needed to drain the curve never falls below T.
    let vq0 = div_ceil((threshold as u128) * (remain_base as u128), denom);
    assert!(vq0 > 0 && vq0 <= U64_MAX, EReserveOverflow);
    ((vb0 as u64), (vq0 as u64), (vb0 as u64) - initial_base)
}

// === Swap math ===

/// Base received for a net quote input. Returns `(base_out, new_vb, new_vq)`.
public fun buy_out(vb: u64, vq: u64, quote_in: u64): (u64, u64, u64) {
    let k = (vb as u128) * (vq as u128);
    let new_vq = (vq as u128) + (quote_in as u128);
    assert!(new_vq <= U64_MAX, EReserveOverflow);
    // Ceiled new base reserve => floored output for the buyer.
    let new_vb = div_ceil(k, new_vq);
    let base_out = (vb as u128) - new_vb;
    assert_invariant(k, new_vb, new_vq);
    ((base_out as u64), (new_vb as u64), (new_vq as u64))
}

/// Output-only preview of `buy_out`, without invariant bookkeeping.
public fun buy_out_preview(vb: u64, vq: u64, quote_in: u64): u64 {
    let (base_out, _, _) = buy_out(vb, vq, quote_in);
    base_out
}

/// Net quote cost for an exact base output (used to clamp the completing
/// buy). Returns `(quote_cost, new_vb, new_vq)`.
public fun buy_cost_exact_out(vb: u64, vq: u64, base_out: u64): (u64, u64, u64) {
    assert!(base_out < vb, EExcessiveOutput);
    let k = (vb as u128) * (vq as u128);
    let new_vb = (vb - base_out) as u128;
    // Ceiled new quote reserve => ceiled cost for the buyer.
    let new_vq = div_ceil(k, new_vb);
    assert!(new_vq <= U64_MAX, EReserveOverflow);
    let cost = new_vq - (vq as u128);
    assert_invariant(k, new_vb, new_vq);
    ((cost as u64), (new_vb as u64), (new_vq as u64))
}

/// Quote received for a base input. Returns `(quote_out, new_vb, new_vq)`.
public fun sell_out(vb: u64, vq: u64, base_in: u64): (u64, u64, u64) {
    let k = (vb as u128) * (vq as u128);
    let new_vb = (vb as u128) + (base_in as u128);
    assert!(new_vb <= U64_MAX, EReserveOverflow);
    // Ceiled new quote reserve => floored output for the seller.
    let new_vq = div_ceil(k, new_vb);
    let quote_out = (vq as u128) - new_vq;
    assert_invariant(k, new_vb, new_vq);
    ((quote_out as u64), (new_vb as u64), (new_vq as u64))
}

/// Ceiled fee on `amount` at `bps` basis points.
public fun fee_amount(amount: u64, bps: u64): u64 {
    (div_ceil((amount as u128) * (bps as u128), BPS_DENOMINATOR as u128) as u64)
}

// === CLMM price / TVL math ===

/// Cetus Q64.64 sqrt price for an initial pool holding `amount_a` of
/// coin A and `amount_b` of coin B: `sqrt(amount_b / amount_a) * 2^64`.
public fun initial_sqrt_price_x64(amount_a: u64, amount_b: u64): u128 {
    assert!(amount_a > 0 && amount_b > 0, EZeroAmount);
    let ratio_x128 = ((amount_b as u256) << 128) / (amount_a as u256);
    (isqrt(ratio_x128) as u128)
}

/// CLMM pool TVL expressed in quote units, from oriented balances and the
/// current Q64.64 sqrt price. `base_is_a` tells whether the base coin is
/// the pool's CoinTypeA. price(B per A) = sqrt_price^2 / 2^128.
public fun tvl_in_quote(
    base_balance: u64,
    quote_balance: u64,
    sqrt_price_x64: u128,
    base_is_a: bool,
): u128 {
    let sp = sqrt_price_x64 as u256;
    let base = base_balance as u256;
    // Staged mul/div keeps intermediates within u256 for any valid
    // sqrt price (< 2^97) and u64 balance.
    let base_value_in_quote = if (base_is_a) {
        // base * sp^2 / 2^128
        (((base * sp) >> 64) * sp) >> 64
    } else {
        // base * 2^128 / sp^2
        (((base << 64) / sp) << 64) / sp
    };
    let total = (quote_balance as u256) + base_value_in_quote;
    if (total > (std::u128::max_value!() as u256)) {
        std::u128::max_value!()
    } else {
        (total as u128)
    }
}

/// Floored integer square root.
public fun isqrt(x: u256): u256 {
    if (x == 0) return 0;
    // Initial guess: a power of two >= sqrt(x), found by halving the bit
    // length; Newton iterations then converge monotonically downward.
    let mut bit = 0u16;
    let mut probe = x;
    while (probe > 0) {
        probe = probe >> 1;
        bit = bit + 1;
    };
    let mut guess = 1u256 << (((bit + 1) / 2) as u8);
    loop {
        let next = (guess + x / guess) >> 1;
        if (next >= guess) return guess;
        guess = next;
    }
}

// === Internal ===

fun div_ceil(numerator: u128, denominator: u128): u128 {
    (numerator + denominator - 1) / denominator
}

fun assert_invariant(k: u128, new_vb: u128, new_vq: u128) {
    // div_ceil makes this hold by construction; kept as defense in depth.
    assert!((new_vb as u256) * (new_vq as u256) >= (k as u256), EInvariantViolation);
}
