# Choosing a flow — the effective path per token & goal

A decision guide: given the token the user pays with and whether the relayer
sponsors gas, pick the inbound method with the fewest prerequisites. All paths
are zero-dust, atomic, and public-mempool-safe (no MEV-protected RPC needed).

## Step 1 — who pays gas?

- **Relayer sponsors (gasless)** → the user only signs; the relayer's Calibur
  (EIP-7702) account runs the batch. Go to Step 2A.
- **User pays** → the user sends one direct `SplitForwarder` tx. Go to Step 2B.

## Step 2A — gasless: pick by token

| Token | Method | Prereq |
|---|---|---|
| **USDC / EIP-3009** | `receiveWithAuthorization` (spender = executor) | **none** ✅ best |
| **anything else** (2612 or plain) | Permit2 SignatureTransfer (spender = executor) | one `approve(Permit2)` |
| **native ETH** | — | ❌ impossible (no signature moves ETH) |

Rule of thumb: **if the token is USDC-class (EIP-3009), gasless is free.**
Everything else gasless costs the one shared Permit2 approve.

## Step 2B — user pays: pick by token

| Token | Method | Prereq |
|---|---|---|
| **EIP-2612** (incl. USDC) | `permitAndRun` (`ERC20_AUTH=2612`) | **none** ✅ best |
| **plain ERC-20** (no permit) | `runWithPermit` (`ERC20_AUTH=permit2`) | one `approve(Permit2)` |
| **native ETH** | `run{value}` | **none** ✅ |

Rule of thumb: **permit-capable token → `2612` (no approve at all); plain
token → Permit2; native → just send value.**

## One-line decision tree

```
gas sponsored?
├─ yes (gasless)
│    USDC/3009 ....... receiveWithAuthorization      (no prereq)   ← best
│    other token ..... Permit2 SignatureTransfer     (1 approve)
│    native ETH ...... impossible
└─ no (user pays)
     EIP-2612 token ... permitAndRun / ERC20_AUTH=2612 (no prereq) ← best
     plain token ...... runWithPermit / ERC20_AUTH=permit2 (1 approve)
     native ETH ....... run{value}                    (no prereq)
```

## Why each is safe (no MEV RPC required)
- **EIP-3009 / Permit2 SignatureTransfer (gasless):** signature binds
  `spender = executor` — only the relayer can redeem it.
- **`runWithPermit` (Permit2 witness):** signature binds a witness over the
  entire payout plan — a replayer can only execute the user's intent.
- **`permitAndRun` (EIP-2612):** pull is `transferFrom(msg.sender, …)`, so a
  replayer can only pull their own funds.

## Hard limits
- **Gasless native ETH** — impossible; nothing moves ETH by signature.
- **Plain tokens with zero prerequisite** — impossible; a plain token needs one
  `approve` (mildest form: the shared Permit2 approve).
- **Fee-on-transfer / rebasing tokens** — out of scope by design.

> To erase the remaining approve for plain tokens entirely, the only lever is
> **user-side EIP-7702** (one account delegation → every token, both modes, no
> per-token setup). It is not used here — it trades a per-token approve for
> account-level trust. See [ARCHITECTURE.md](../ARCHITECTURE.md).
