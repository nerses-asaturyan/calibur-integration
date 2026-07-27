# Final Architecture — Gasless DeFi Deposit Flows (PoC, Sepolia)

**Thesis, proven on-chain:** a user moves funds with *only off-chain signatures*
(no gas, no transactions of their own); a relayer sponsors **one atomic
transaction** that pulls the funds, runs a real multi-protocol DeFi chain, and
pays out to one or more destinations — **with zero dust** and (almost) zero
contracts of our own.

## 1. Design principles (fixed)

1. **The user is always a plain EOA.** The user is *never* EIP-7702-delegated —
   they only ever produce off-chain signatures. All account-level complexity
   lives on the relayer side.
2. **Only the relayer is a smart account.** The relayer EOA is delegated to
   Uniswap's audited **Calibur** singleton (EIP-7702) and executes ERC-7821
   batches; it broadcasts, pays all gas, and is the signature's `to`.
3. **Unowned infrastructure does the dynamic work.** Uniswap's Universal Router
   (swap chains, splits, sweeps, native ETH) and Aave v3 (`withdraw(MAX)`)
   provide every dynamic-amount primitive. The router is an *executor, not a
   brain* — routes are chosen off-chain (QuoterV2 / SOR) and encoded; on-chain
   protection is min-out floors only.
4. **One contract of our own, only where an event is required:** the
   `LayerswapDepository` (deployed + verified), extended with `depositERC20All`
   — the whole-balance, run-time-read deposit that makes flows **zero-dust**.
5. **Atomicity as the safety net.** Everything runs in one ERC-7821 batch: any
   revert (slippage floor, expired window, paused depository) rolls back the
   inbound leg too — the user's signature nonce is never consumed on failure.

## 2. Roles & trust model

| Role | Account type | Signs | Pays gas | Holds funds |
|---|---|---|---|---|
| **User / payer** | plain EOA | 1 off-chain authorization per flow | never | their own, until pulled |
| **Relayer / executor** | EOA delegated to Calibur | the transaction | always | pass-through only (0 before & after each flow) |
| **Fee wallet / payout EOAs** | plain EOAs | nothing | never | receive payouts |

Trust facts:
- `receiveWithAuthorization` enforces `msg.sender == to` → only our executor can
  redeem the user's signature; leaked signatures are unusable by third parties.
- The executor holds no idle funds, so even standing approvals have nothing to drain.
- The Universal Router must never hold funds *across* transactions (anyone can
  sweep it) — it only holds them *within* the atomic batch.
- The user's exposure per flow = exactly the signed `value`, nothing else.

## 3. Capability matrix

### Inbound (what the user pays with — signatures only, user never delegated)

| Asset | Mechanism | Gasless? | Status |
|---|---|---|---|
| USDC | EIP-3009 `receiveWithAuthorization` | ✅ fully, 1 signature | **proven** (all 4 txs) |
| EIP-2612 tokens (e.g. UNI) | `permit` sig + `transferFrom` in-batch | ✅ fully, 2 signatures | designed, not yet demoed |
| Arbitrary ERC-20 | one-time `approve(Permit2)` tx by user, then Permit2 signatures per flow | ⚠️ gasless after one-time user tx | designed, not yet demoed |
| **Native ETH** | — | ❌ **impossible without delegating the user** | out of scope by design |

> The native-inbound cell is a protocol fact, not a gap: nothing can pull ETH
> out of a plain EOA with only an off-chain signature (no permit exists for
> ETH). Since this architecture forbids user-side 7702, gasless native inbound
> is explicitly excluded. (Native *outbound* is fully supported — TX 3.)

### Mid-steps (inside the atomic batch, all dynamic-amount)

| Step | Primitive | Status |
|---|---|---|
| Multi-pool swap chains | Universal Router `V3_SWAP_EXACT_IN` + `CONTRACT_BALANCE` | **proven** (up to 6 swaps / 5 pools) |
| Native wrap/unwrap | `WRAP_ETH` / `UNWRAP_WETH` | **proven** |
| Real Aave v3 supply+withdraw | `supply(floor)` → `withdraw(MAX, → router)` sandwich | **proven** (TX 2) |

### Outbound (where funds end up)

| Destination | Mechanism | Dust | Status |
|---|---|---|---|
| Layerswap depository | `approve(max)` → `depositERC20All` → `approve(0)` | **0** | **proven** (TX 1, TX 2) |
| Two+ EOAs, ERC-20 | router `TRANSFER` (exact) / `PAY_PORTION` (bips) / `SWEEP` (rest) | 0 | proven pattern (fee legs of TX 1–2) |
| Two+ EOAs, **native ETH** | `UNWRAP_WETH` → `PAY_PORTION` + `SWEEP` with token = `address(0)` | **0** | **proven** (TX 3 — payer received gas money gaslessly) |
| **N-way arbitrary-% split** — EOAs + any contract (incl. the **original** depository), ERC-20 **and** native | `PayoutSplitter.split`: last-leg remainder + calldata amount substitution (call hooks) | **0** (enforced by terminal `DustLeft` check) | **proven** (TX 4 — 12.34/37.66/50 in WETH and ETH, `depositERC20`/`depositNative` hooks) |

## 4. The proven transactions (Sepolia)

| # | What it proves | Tx | Gas |
|---|---|---|---|
| 1 | 4 pools + ETH round-trip → zero-dust depository deposit | [`0x95378e76…`](https://sepolia.etherscan.io/tx/0x95378e760765db56775fb6b6c135f6b08af039aaf5d1f221da8dfcb794bff63b) | 519,836 |
| 2 | 3 EOAs + **real Aave v3** + 6 swaps → zero-dust deposit | [`0x20c49f67…`](https://sepolia.etherscan.io/tx/0x20c49f6796dd12757482adafb5ace4560456702802ae40214ccd29d46645d4b6) | 823,647 |
| 3 | Native-ETH dual-EOA payout, no depository, 3-call batch | [`0xa50e86d8…`](https://sepolia.etherscan.io/tx/0xa50e86d89397ea762eed855b2142a62654ee1caaa776aecf73ad130f1cb2e4c9) | 374,091 |
| 4 | Generic splitter: arbitrary % (12.34/37.66/50), ERC-20 + native, ORIGINAL depository via hooks | [`0xf3fe4ee3…`](https://sepolia.etherscan.io/tx/0xf3fe4ee3acdbfff7ca1da53f92e7cd13b52d88c41a19a46c39a67a4ce0894c76) | 527,556 |
| 0 | Base flow: plain USDC → depository (no DeFi) | see README §2 | ~130k |

Infrastructure: our verified depository
[`0x4fFF…20E8`](https://sepolia.etherscan.io/address/0x4fFFC89c52dD080d1eEEc3Ccd546602c0f1720E8#code);
Calibur singleton `0x0000…8f00`; Universal Router `0x3A9D…F98b`; Aave v3 pool
`0x6Ae4…8951` (WETH reserve — the only one under its supply cap).

## 5. The five key mechanisms (the whole trick)

1. **EIP-3009** — gasless inbound bound to our executor (`msg.sender == to`).
2. **EIP-7702 + ERC-7821 (Calibur)** — one relayer EOA = broadcaster + smart
   account + signature recipient; atomic batches.
3. **`CONTRACT_BALANCE` sentinel** — each router leg consumes the previous
   leg's full output; no intermediate amount needed at sign time.
4. **Dynamic-amount exits** — `SWEEP`/`PAY_PORTION` (router), `withdraw(MAX)`
   (Aave), `depositERC20All` (ours), and `PayoutSplitter.split` (ours: bps
   shares of the live balance, last leg = arithmetic remainder, call hooks with
   run-time amount substitution): every terminal leg reads balances at run
   time → zero dust by construction.
5. **Off-chain pricing, on-chain floors** — QuoterV2 quotes each hop from the
   previous hop's *minimum*; unquotable legs (one-sided bridge pools) get
   analytic floors (`input × (1-fee)²`); floors only guard reverts, never set
   amounts.

## 6. Decision guide

- **USDC → Layerswap, no DeFi** → base flow (`CaliburDeposit.s.sol`), 2–3 calls.
- **USDC → DeFi chain → Layerswap** → `CaliburRouterFlow` (single trip) or
  `CaliburMultiPairFlow` (+ Aave sandwich), zero dust via `depositERC20All`.
- **USDC → DeFi chain → people/EOAs (incl. native ETH)** →
  `CaliburNativeDualFlow`, 3-call batch, router pays everyone directly.
- **Arbitrary-% payouts to any mix of EOAs and contracts (incl. the original
  depository), ERC-20 or native** → `CaliburSplitFlow` with `PayoutSplitter`
  (stateless; verified at `0xd952…91D3`); the router's `PAY_PORTION` only takes
  bips of its own balance, the splitter generalizes that to N legs + call hooks.
- **Non-USDC inbound** → add a Permit2/EIP-2612 leg in place of the EIP-3009
  call; everything downstream is unchanged.
- **Native inbound / "user has only ETH"** → not gasless under this
  architecture (would require delegating the user). Alternatives: the user
  makes one normal `depositNative` tx, or swaps to USDC once and uses the
  gasless flows thereafter.

## 7. Known limits & residual risks

- **Relayer liveness/censorship**: the user's signature is worthless without a
  broadcaster; mitigate with redundant relayers (signature binds `to`, so any
  relayer we control can be the executor only if it's the signed `to`).
- **Slippage window**: floors are quoted pre-broadcast; violent moves between
  quote and inclusion revert the flow (safe: nonce unspent, retry with fresh quote).
- **Sepolia liquidity ≠ mainnet**: pool selection and fee tiers were chosen for
  Sepolia's actual liquidity; mainnet would re-run the same off-chain routing.
- **Depository owner powers**: our depository is `Ownable2Step` + `Pausable` +
  whitelist — standard operational trust in the deposit destination, unchanged
  from Layerswap's original design.
