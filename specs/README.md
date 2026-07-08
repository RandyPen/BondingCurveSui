# Formal verification (Sui Prover)

This package proves safety properties of the bonding-curve math with the
[Sui Prover](https://github.com/asymptotic-code/sui-prover). It verifies the
**exact file the main package publishes**: `sources/curve.move` is a relative
symlink to `../sources/curve.move`.

The verification scope is `bondingcurvesui::curve` — the pure math every
trade, migration price, and TVL unlock depends on. The `pool`/`migration`
modules are not in scope: they depend on CetusClmm/LpBurn, which the prover's
compilation pipeline cannot process, and their logic is state-machine glue
over the curve math verified here (covered by the unit/integration tests).

## What is proven

`curve_specs.move` — swap math. Each spec fully characterizes the target's
abort conditions (`asserts`) and proves:

| Target | Properties |
|--------|-----------|
| `derive_virtual_reserves` | exact floor/ceil formulas for `vb0`/`vq0`; `vb0 >= initial_base` so the `floor_vb` subtraction never underflows; `vq0 > 0` |
| `buy_out` | `new_vq = vq + quote_in`; `base_out <= vb` (solvency) with `new_vb = vb - base_out` (conservation); `new_vb * new_vq >= vb * vq` (invariant never decreases) |
| `buy_cost_exact_out` | `new_vb = vb - base_out`; `cost = new_vq - vq >= 0`; invariant never decreases |
| `sell_out` | `new_vb = vb + base_in`; `quote_out <= vq` (solvency) with `new_vq = vq - quote_out`; invariant never decreases |
| `fee_amount` | fee is exactly `ceil(amount * bps / 10_000)`; `fee <= amount` whenever `bps <= 10_000` |
| `buy_then_sell_never_profits` (scenario) | buying with `quote_in` and selling the entire purchase back returns `quote_out <= quote_in` — a round trip can never drain quote from the pool |

`clmm_math_specs.move` — CLMM price / TVL math:

| Target | Properties |
|--------|-----------|
| `isqrt` | result is the exact floored integer square root: `r^2 <= x < (r+1)^2`, proven against the Newton iteration via an external loop invariant |
| `initial_sqrt_price_x64` | the returned Q64.64 sqrt price exactly brackets `floor(amount_b * 2^128 / amount_a)` |
| `tvl_in_quote` | aborts only when dividing by a zero sqrt price (`!base_is_a` branch); TVL never undercounts the quote side; zero base means TVL equals the quote balance |

## Running

```bash
brew install asymptotic-code/sui-prover/sui-prover   # bundles boogie + z3
brew install dotnet@8                                # boogie is a .NET 8 app

./prove.sh                       # full suite
./prove.sh --functions buy_out_spec --verbose
```

`prove.sh` exports `DOTNET_ROOT` for Homebrew's keg-only dotnet@8 and runs
with `--timeout 300` (headroom for the nonlinear u256 goals; the whole suite
normally verifies in a couple of minutes).

## Prover-driven changes to `curve.move`

Two behavior-preserving rewrites keep `isqrt`/`initial_sqrt_price_x64`
verifiable — the prover's SMT encoding cannot reason about shifts of
*symbolic* u256 values (a shift with a variable base or a bit-length prescan
leaves the result under-constrained):

- `isqrt` starts Newton at the constant `1 << 128` (an upper bracket of
  sqrt for every u256) instead of prescanning the bit length. Same results,
  a few dozen extra halving iterations for small inputs — it runs once per
  migration.
- `initial_sqrt_price_x64` scales with `* Q128` (a hex literal) instead of
  `<< 128`; identical for any u64 amount.

## Layout notes

- Specs live in separate modules and attach to the curve functions with
  `#[spec(prove, target = curve::...)]`, so the production sources carry no
  prover-specific code and regular `sui move build` / tests are unaffected.
- Per sui-prover requirements this package declares **no explicit
  Sui/MoveStdlib dependencies** (the prover injects its own), which is also
  why it cannot simply depend on the main package.
