# Token support guide

Which inbound method to use for which token, in each funding mode — and what
each one costs the user up front.

## Legend

**Prerequisite** (one-time, before any flow):
- 🟢 **none** — signature only, nothing on-chain first
- 🟡 **Permit2** — one `approve(Permit2)` per token; *shared across the whole
  ecosystem* (Uniswap etc.), so often already done
- 🟠 **approve** — classic per-app token approval
- 🔴 **7702** — one-time user account delegation (Calibur); account-level trust

✅ recommended · ▫️ possible alternative · ❌ impossible

## Matrix

| Token type | Gasless (relayer pays gas) | With-gas (user pays gas) |
|---|---|---|
| **EIP-3009**<br>(USDC, EURC…) | ✅ `receiveWithAuthorization` · 🟢 none | ✅ `receiveWithAuthorization` · 🟢 none <br>▫️ Permit2 · 🟡 |
| **EIP-2612**<br>(permit tokens) | ✅ `permit` (spender = executor) · 🟢 none <br>▫️ Permit2 · 🟡 | ✅ `permitAndRun` (self-submit) · 🟢 none <br>▫️ Permit2 · 🟡 |
| **Plain ERC-20**<br>(no permit) | ✅ Permit2 · 🟡 <br>▫️ standing approve → relayer · 🟠 | ✅ Permit2 · 🟡 <br>▫️ approve + call · 🟠 <br>▫️ user 7702 · 🔴 |
| **Native ETH** | ❌ impossible — no signature can move ETH | ✅ user sends `value` · 🟢 none |
| **Any token, one delegation** | ✅ user-side **7702** covers everything · 🔴 | ✅ same · 🔴 |

## How to read it

- **Permit-capable tokens (3009 / 2612) are free** — signature-only, no
  prerequisite, both modes. This is the sweet spot.
- **Plain tokens always cost one approval** — a protocol fact, not a design
  gap. The mildest form is the *shared* Permit2 approve (🟡), not a per-app one.
- **Gasless native ETH is impossible** — nothing moves ETH by signature. Native
  is always user-sent (`value`).
- **user-side 7702 (🔴)** is the only thing that makes *every* token
  prerequisite-free in both modes — at the cost of account-level trust. (It's
  what Relay does in production.)

## Safety note

Every signature method above is bound so a mempool observer cannot redirect
funds: EIP-3009 / EIP-2612 bind `spender` (gasless) or `msg.sender` (self-submit);
Permit2 uses a witness committing to the whole payout plan. **No MEV-protected
RPC is required.**
