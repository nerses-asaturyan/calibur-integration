# Architecture — the final flow matrix

**Thesis, proven on-chain (13 Sepolia txs, table in the README):** users fund
payment flows in ERC-20 (gaslessly, by signature) or in ERC-20/native ETH
(sending one tx themselves); one atomic transaction runs exact-in Uniswap
swaps and pays out to EOAs and/or the Layerswap depository — with zero dust
and no orchestration contracts.

## Design principles (fixed by decision)

1. **The user is always a plain EOA** — never EIP-7702-delegated. Only the
   relayer's executor is a Calibur smart account.
2. **Exact-in swaps only** — the UI lets users send any amount; quoted floors
   are slippage revert-guards, never amount-shapers.
3. **Zero dust** — every intermediary (router, Multicall3, executor) exits
   every tx at 0. Dynamic-amount exits do the work: swap-recipient targeting,
   `PAY_PORTION`/`SWEEP`, and `depositERC20All` (whole-balance, run-time read —
   the one function we added to the original Layerswap depository, and the only
   custom code in the system).
4. **Public infrastructure over new contracts** — Universal Router (swaps +
   payment commands), Permit2 (signature pulls), Multicall3 (user-sent
   batching), WETH9. The router is an *executor, not a brain*: routes are
   chosen off-chain (QuoterV2) and encoded; on-chain protection is min-out.

## The matrix (4 flows × 3 modes — all proven)

Flows: **1** all→swap→depository · **2** exact fee→EOA, rest→swap→user ·
**3** swap→live-exact split (user+fee) · **4** exact fee→EOA, rest→swap→depository.

| Mode | Entry | Inbound mechanism | Depository flows (1&4) | Notes |
|---|---|---|---|---|
| gasless | relayer's Calibur batch (ERC-7821) | EIP-3009 (USDC) / EIP-2612 / **Permit2, spender = executor** (any plain token; bonus tx) | executor collects → `depositERC20All` | user signs only; nonce unspent on revert |
| user-erc20 | router-only (flows 2&3) / Multicall3 (flows 1&4) | `PERMIT2_PERMIT` in-router (mempool-safe) / in-batch EIP-2612 permit | MC3 collects → `depositERC20All` | ⚠️ flows 1&4 on mainnet REQUIRE MEV-protected submission |
| user-eth | router-only (2&3) / Multicall3 value-legs (1&4) | `msg.value` (no signature exists for native — protocol fact) | MC3 collects → `depositERC20All` | user pays own gas by definition |

## Precision rules

- **Split before swap** (flows 2, 4 fee legs): exact bips of the known input.
- **Split after swap, EOAs only** (flow 3): live-exact bips of the actual
  output (`PAY_PORTION` + `SWEEP`).
- **Deposit after swap** (flows 1, 4): the FULL dynamic output via
  `depositERC20All` — no floors, no remainder legs.

## Trust model & residual risks

- Executor is pass-through (0 before/after every flow); leaked gasless
  signatures are unusable (spender/`to` binding); atomicity protects the nonce.
- **Multicall3 permits (flows 1&4 user-erc20):** the 2612 permit is created and
  consumed in one atomic user tx, but the signature binds only
  spender = Multicall3 — public-mempool submission is front-runnable ⇒
  **private submission required on mainnet**. The permit leg is
  `allowFailure=true` so nonce-griefing can't strand an allowance-with-revert.
- **Stranded-funds side effect:** `depositERC20All` from MC3 sweeps MC3's whole
  token balance — strangers' stranded tokens ride into the deposit (receiver
  gains; Layerswap credits more than the user sent — accounting should expect
  this edge). Never park funds in public pass-through contracts between txs.
- **Slippage window:** floors are quoted pre-broadcast; violent moves revert
  the flow (safe: retry with fresh quote).
- **Relayer liveness** (gasless): a signature is worthless without a
  broadcaster; run redundant relayers.

## Hard limits (protocol-level, by design)

1. **Gasless native ETH inbound is impossible** for a plain EOA — no signature
   can move ETH. User-sent is the native path (proven).
2. **Plain tokens need one `approve(Permit2)` tx per token, ever** — then
   signature-only (bonus tx). EIP-3009/2612 tokens are signature-only from
   day one.
3. **User-sent ERC-20 + depository in one PUBLIC-mempool tx** — unsafe; the
   private-submission requirement is irreducible without new contracts or
   user-side 7702 (both banned).

## Aggregator slot (0x etc., skipped for now)

Any protocol qualifies as the swap leg if it accepts pre-funded/pulled input
and pays a designated recipient: 0x Swap API v2 (Settler/AllowanceHolder,
mainnet-only) replaces the router leg one-for-one when needed.
