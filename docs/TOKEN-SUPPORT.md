# Token support — what this branch actually implements

Inbound methods that exist in the code today (`experiment/deposit-forwarder`).
Nothing aspirational — see "Not implemented" at the bottom for what is *not* here.

## Legend
- 🟢 no prerequisite — signature only
- 🟡 one-time `approve(Permit2)` per token (shared across the ecosystem)
- ✅ implemented · ❌ not possible

## Matrix (implemented)

| Token type | Gasless (relayer pays) | With-gas (user pays) |
|---|---|---|
| **USDC (EIP-3009)** | ✅ `receiveWithAuthorization`, spender = executor · 🟢 | ✅ `permitAndRun` (EIP-2612) · 🟢 &nbsp;·&nbsp; or `runWithPermit` (Permit2) · 🟡 |
| **EIP-2612 tokens** | ▫️ via Permit2 · 🟡 *(no native-2612 gasless leg yet)* | ✅ `permitAndRun` (EIP-2612, no Permit2) · 🟢 &nbsp;·&nbsp; or `runWithPermit` · 🟡 |
| **Plain ERC-20** (e.g. WETH) | ✅ Permit2 `permitWitnessTransferFrom`, spender = executor · 🟡 *(`BonusPermit2Flow`)* | ✅ `runWithPermit` (Permit2 witness) · 🟡 |
| **Native ETH** | ❌ impossible (no signature moves ETH) | ✅ user sends `value` (direct `SF.run{value}`) · 🟢 |

Selected at runtime: `FUNDING_MODE = gasless | user-erc20 | user-eth`, and for
user-erc20 `ERC20_AUTH = permit2 (default) | 2612`.

## Where each lives
- **Gasless** = relayer's Calibur (EIP-7702) ERC-7821 batch. USDC inbound =
  EIP-3009 (`_pull3009`); plain-token inbound = Permit2 SignatureTransfer
  (`BonusPermit2Flow`).
- **With-gas, `ERC20_AUTH=2612`** = user calls `SF.permitAndRun(...)` directly —
  native EIP-2612 permit, **no Permit2, no approve**. Permit-capable tokens only.
- **With-gas, `ERC20_AUTH=permit2`** = user calls `SF.runWithPermit(...)` —
  Permit2 witness bound to the plan; any token after one `approve(Permit2)`.
- **With-gas native** = user calls `SF.run{value}(...)`.

## Prerequisites, precisely
- USDC / EIP-2612 tokens, with-gas via `2612`: **none** (signature only).
- USDC gasless: **none** (EIP-3009).
- Anything through Permit2 (plain tokens; the `permit2` option): **one
  `approve(Permit2)`** per token, ever (shared across the ecosystem).
- Native: none.

## Safety
No MEV-protected RPC required, on any path:
- gasless EIP-3009 / Permit2 SignatureTransfer bind **spender = executor**;
- `runWithPermit` binds a **witness** over the whole payout plan;
- `permitAndRun` binds **owner = msg.sender** (self-submit) — a replayer can
  only pull their own funds.

Proven: `testFork_Intent_AlteredSplitsReplayReverts` (witness) and
`testFork_Permit2612_ReplayCannotDrainUser` (2612 owner-binding).

## NOT implemented (discussed, not in code)
- **Native-2612 *gasless* leg** — EIP-2612 tokens still route through Permit2 in
  gasless mode. Only the *with-gas* 2612 path (`permitAndRun`) exists.
- **User-side EIP-7702** — would remove all per-token prerequisites. Not used
  (only the relayer is 7702-delegated, for gasless).
- **Fee-on-transfer / rebasing tokens** — out of scope by design.
