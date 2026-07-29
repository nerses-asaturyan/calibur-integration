#!/usr/bin/env bash
# Fetch a live Fly (Magpie) same-chain swap quote+transaction and emit it
# abi-encoded for forge vm.ffi:  abi.encode(address to, bytes data, uint256 amountOutMin).
#
# args: <network> <sellToken> <buyToken> <sellAmount> <taker>
# No API key required for /aggregator/quote/transaction. `taker` is used as both
# fromAddress and toAddress, so the swap pulls from and delivers to that address.
set -euo pipefail

R=$(curl -s "https://api.fly.trade/aggregator/quote/transaction?network=$1&fromTokenAddress=$2&toTokenAddress=$3&fromAddress=$5&toAddress=$5&sellAmount=$4&slippage=0.005&gasless=false")

read -r TO DATA MIN < <(printf '%s' "$R" | python3 -c "
import json,sys
d=json.load(sys.stdin)
tx=d['transaction']
print(tx['to'], tx['data'], d['quote']['typedData']['message']['amountOutMin'])
")

cast abi-encode "r(address,bytes,uint256)" "$TO" "$DATA" "$MIN"
