#!/usr/bin/env bash
# Fetch a live 0x Swap API (AllowanceHolder) quote and emit it abi-encoded for
# forge vm.ffi:  abi.encode(address to, bytes data, uint256 minBuyAmount).
#
# args: <chainId> <sellToken> <buyToken> <sellAmount> <taker>
# Requires ZEROX_API_KEY in the environment (or .env at repo root).
set -euo pipefail
[ -n "${ZEROX_API_KEY:-}" ] || source .env 2>/dev/null || true

R=$(curl -s "https://api.0x.org/swap/allowance-holder/quote?chainId=$1&sellToken=$2&buyToken=$3&sellAmount=$4&taker=$5" \
  -H "0x-api-key: ${ZEROX_API_KEY}" -H "0x-version: v2")

read -r TO DATA MIN < <(printf '%s' "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
t=d['transaction']
print(t['to'], t['data'], d['minBuyAmount'])
")

cast abi-encode "r(address,bytes,uint256)" "$TO" "$DATA" "$MIN"
