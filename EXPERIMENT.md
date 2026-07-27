# Experiment: BalanceForwarder vs extended depository

**Question:** can we keep the Layerswap depository completely **original** (no
`depositERC20All` extension) and still get fully-dynamic, zero-dust deposits —
using the simplest possible periphery contract instead?

**Answer: yes.** This branch replaces the extended depository with
[`BalanceForwarder`](https://sepolia.etherscan.io/address/0x3eA40608b36AC87dADBd1b32D3a2668997ffDa3f#code)
(`0x3eA4…Da3f`, verified, ~40 lines) and re-proves the depository flows (1 & 4)
in all three funding modes against the **original** depository
`0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4`.

## How it works

`executeWithBalance(token, target, amountOffset, data)`:
1. reads **its own** live `token` balance (the router pays the swap output
   straight to the forwarder),
2. patches that amount into the caller-supplied calldata template at
   `amountOffset` (for `depositERC20(bytes32,address,address,uint256)` the
   amount word is at byte `4 + 3×32 = 100`),
3. `forceApprove(target, amount)` → `target.call(patched data)` → approve reset,
4. reverts `BalanceNotConsumed` unless it exits at exactly **0** (the zero-dust
   guarantee, enforced on-chain).

The generic calldata-template design means it works with **any** exact-amount
function on any contract — not just this depository.

The deposit tail shrinks from three calls (`approve(max)` → `depositERC20All`
→ `approve(0)`) to **one** (`forwarder.executeWithBalance(...)`), and the
swap's recipient becomes the forwarder.

## The flows re-proven here

The **1st and 4th** diagrams (the two ending in the Depository) are the flows
this experiment retargets — same shapes as the main branch, but the Depository
is the untouched original and the dynamic-amount bridge is the forwarder:

![The four flows; this experiment re-proves #1 (user → uniswap → depository) and #4 (user → fee EOA + uniswap → depository) against the ORIGINAL depository via BalanceForwarder](docs/flow-diagrams.jpg)

## The six proven transactions (original depository, full dynamic output)

| Cell | tx | gas | vs extended-depository baseline |
|---|---|---|---|
| Flow 1 gasless | [`0x5d4488da…`](https://sepolia.etherscan.io/tx/0x5d4488da77bc1d15c432e20dddb249a55670b2228ded11f2a5c9f0ea0b1596bd) | 241,801 | +14,095 |
| Flow 4 gasless | [`0xa906d2e0…`](https://sepolia.etherscan.io/tx/0xa906d2e059380dbbfe0176d091a40ce589e2c1d4d9367fe52dc548d6851ecf93) | 252,612 | +392 |
| Flow 1 user-erc20 | [`0xcd06d8ec…`](https://sepolia.etherscan.io/tx/0xcd06d8ec9c0d2e61210ef832f08f3ae7645f0a8929631dc19ef7ff9aa15ee65d) | 223,798 | +507 |
| Flow 4 user-erc20 | [`0x15e214b0…`](https://sepolia.etherscan.io/tx/0x15e214b025b249d298cf8dd8a6e5a127f1e6fefe9f070fdfbbdae7502736f6b5) | 235,681 | +490 |
| Flow 1 user-eth | [`0xb7335634…`](https://sepolia.etherscan.io/tx/0xb7335634d7daf4c42e64de8855e92a220dd0334e5f886cbae0ff74a0e55ddf32) | 191,847 | +551 |
| Flow 4 user-eth | [`0xd52126ed…`](https://sepolia.etherscan.io/tx/0xd52126ed7ee14d9c3a151c94ac262df9cc3282412843407e96366b45086c9493) | 208,083 | +7,469 |

Verified after all six: forwarder and router at 0 in ETH/USDC/WETH; zero
residual allowances. (The two outlier deltas are cold-storage effects of
first-time token/receiver slots on this branch's runs, not systematic cost;
the systematic overhead of the forwarder hop is ≈ +400–600 gas.)

## Should flows 2 & 3 use the forwarder too (one unified shape)?

**No — measured and reasoned:** flows 2 & 3 pay EOAs, and the router already
pays recipients directly inside the swap/`PAY_PORTION`/`SWEEP` commands — zero
extra calls. Routing their payouts through the forwarder would add an external
call, a `balanceOf`, an approve set/reset cycle, and a `transferFrom` per flow
(≈ +35–50k gas) while providing nothing: the forwarder exists to bridge
*dynamic amount → exact-amount contract call*, and EOAs don't need that bridge.
Flows 2 & 3 stay router-direct (their scripts are untouched on this branch).

## Comparison

| | Extended depository (`depositERC20All`) | BalanceForwarder |
|---|---|---|
| Depository contract | modified (redeployed) | **100% original** |
| Custom code | 1 function inside the depository | 1 standalone ~40-line contract |
| Deposit tail | 3 calls | **1 call** |
| Gas | baseline | ≈ +0.5k (noise) |
| Generality | Layerswap deposits only | **any exact-amount function on any contract** |
| Trust surface | depository owner unchanged | stateless/no-owner periphery; router-like rule: never hold funds across txs (anyone can direct its balance) |
| Stranded-funds edge | MC3 collector swept strangers' tokens into deposits | forwarder collects instead — starts empty, and its own terminal check keeps it that way |

**Conclusion:** the forwarder matches the extended depository on gas and zero-dust
guarantees while keeping the depository untouched and being more generic. If
"don't modify the depository" is a requirement (e.g. using Layerswap's own
deployment on mainnet), this is the shape to ship.
