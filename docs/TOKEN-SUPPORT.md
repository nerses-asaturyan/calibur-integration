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
| **USDC (EIP-3009)** | ✅ `receiveWithAuthorization`, spender = executor · 🟢 | ✅ `runWithPermit` (Permit2 witness) · 🟡 |
| **Plain ERC-20** (e.g. WETH) | ✅ Permit2 `permitWitnessTransferFrom`, spender = executor · 🟡 *(`BonusPermit2Flow`)* | ✅ `runWithPermit` (Permit2 witness) · 🟡 |
| **Native ETH** | ❌ impossible (no signature moves ETH) | ✅ user sends `value` (direct `SF.run{value}`) · 🟢 |

Where each lives:
- **Gasless** = relayer's Calibur (EIP-7702) ERC-7821 batch. USDC inbound leg is
  EIP-3009 (`_pull3009`); plain-token inbound is Permit2 SignatureTransfer
  (`BonusPermit2Flow`).
- **With-gas ERC-20** = user calls `SF.runWithPermit(...)` directly; the Permit2
  signature carries a witness = `keccak256(splits)` (intent-bound).
- **With-gas native** = user calls `SF.run{value}(...)` directly.

## Prerequisites, precisely
- USDC gasless: **none** (EIP-3009 signature only).
- Everything else ERC-20: **one `approve(Permit2)`** per token, ever.
- Native: none.

## Safety
No MEV-protected RPC required. Gasless signatures bind `spender = executor`;
`runWithPermit` binds a witness over the whole payout plan, so a mempool
observer can only execute the user's exact intent (proven:
`testFork_Intent_AlteredSplitsReplayReverts`).

## NOT implemented (discussed, not in code)
- **EIP-2612 native path** (`permit` / `permitAndRun`) — would remove the
  Permit2 approve for permit tokens. Not present.
- **User-side EIP-7702** — would remove all per-token prerequisites. Not used
  (only the relayer is 7702-delegated, for gasless).
- **Fee-on-transfer / rebasing tokens** — out of scope by design.
