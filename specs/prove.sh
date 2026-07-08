#!/usr/bin/env bash
# Runs the Sui Prover over the formal-verification package.
#
# Prerequisites:
#   brew install asymptotic-code/sui-prover/sui-prover   # bundles boogie + z3
#   brew install dotnet@8                                # boogie runtime
#
# Usage: ./prove.sh [extra sui-prover flags]
#   e.g. ./prove.sh --functions buy_out_spec --verbose
set -euo pipefail

cd "$(dirname "$0")"

# The bundled boogie is a .NET 8 app; Homebrew's dotnet@8 is keg-only.
if [[ -d /opt/homebrew/opt/dotnet@8/libexec ]]; then
  export DOTNET_ROOT=/opt/homebrew/opt/dotnet@8/libexec
  export PATH="/opt/homebrew/opt/dotnet@8/bin:$PATH"
fi

# 300s gives the nonlinear u256 goals headroom; the suite normally
# finishes in a couple of minutes.
exec sui-prover --timeout 300 --force-timeout "$@"
