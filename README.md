# Calibur (EIP-7702) · USDC EIP-3009 → LayerswapDepository — Sepolia

A user signs **one** EIP-3009 `receiveWithAuthorization`; a Calibur smart account
(an EOA delegated via EIP-7702) then runs **one atomic batch** that pulls the
USDC and forwards it into the LayerswapDepository. No swap, no new contract — the
flow is pre-encoded calldata. If any step reverts, nothing moves and the
signature's nonce stays unused.

**Addresses (Sepolia, pre-filled in `.env.example`)**

| | Address |
|---|---|
| USDC (Circle, EIP-3009) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Calibur singleton (7702 target) | `0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00` |
| LayerswapDepository | `0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4` |

> Requires the **Prague** EVM (EIP-7702) — already set in `foundry.toml`.

**Three distinct things — don't confuse them:**

| | What it is | Role |
|---|---|---|
| **Calibur implementation** `0x0000…8f00` | the *code* contract | EIP-7702 delegation **target** only — **never** the EIP-3009 `to` |
| **Executor** (= broadcaster EOA) | your operator account, delegated to the implementation | runs the batch, pays gas, and **is the EIP-3009 `to`** (`CALIBUR_EXECUTOR`, defaults to `addr(PRIVATE_KEY)`) |
| **Payer** (user) | holds USDC, signs the authorization | the EIP-3009 `from` (`USER_PRIVATE_KEY`) — must differ from the executor |

So `to == the executor's own address` (your broadcaster), **not** `0x0000…8f00`.

---

## 1. Configure env & test manually

Dependencies are git submodules. On a fresh clone:

```bash
git clone --recurse-submodules <repo-url>     # or, if already cloned:
git submodule update --init --recursive
```

```bash
cp .env.example .env
# Fill: OPERATOR_PRIVATE_KEY (executor), USER_PRIVATE_KEY (payer, holds USDC),
#       DEPOSIT_RECEIVER (must be whitelisted in the depository).
# Public addresses are already filled. Operator and payer MUST be different accounts.
set -a; source .env; set +a
export PRIVATE_KEY=$OPERATOR_PRIVATE_KEY        # the delegated account self-calls execute
```

**Automated tests** (8 local + 5 live-fork; fork tests skip if `SEPOLIA_RPC_URL` is unset):

```bash
forge test -vvv                         # all
forge test --fork-url $SEPOLIA_RPC_URL  # incl. real USDC + real depository
```

**Manual run on Sepolia** — enable once, deposit as many times as you want,
disable only when done:

```bash
# enable EIP-7702 delegation (once)
forge script script/EnableDelegation.s.sol:EnableDelegation --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
cast code $(cast wallet address --private-key $OPERATOR_PRIVATE_KEY) --rpc-url $SEPOLIA_RPC_URL
#   expect 0xef0100…9b8f00

# (optional, once) approve the depository so deposits use the cheaper 2-call batch
forge script script/ApproveDepository.s.sol:ApproveDepository --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv

# deposit (repeat per deposit; signs + randomizes nonce/depositId itself)
forge script script/CaliburDeposit.s.sol:CaliburDepositScript --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv

# disable when retiring the operator
forge script script/DisableDelegation.s.sol:DisableDelegation --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv
```

---

## 2. The flow — what the user signs, what happens next

**The user (payer) signs exactly one thing:** an EIP-712 `ReceiveWithAuthorization`
typed message over USDC. The deposit script does this automatically from
`USER_PRIVATE_KEY`; a real user signs it in their wallet.

```
ReceiveWithAuthorization {
  from        = payer (the user)
  to          = executor                // = your broadcaster EOA (delegated to Calibur), NOT 0x0000…8f00
  value       = amount
  validAfter  = 0
  validBefore = now + 10 min            // the deadline
  nonce       = random bytes32          // single-use
}
```

That signature authorizes only **moving `value` USDC from the payer to the
executor account** — nothing else.

**What the executor (broadcaster) does next** — one atomic Calibur ERC-7821
batch, every call running with `msg.sender == executor`:

1. `USDC.receiveWithAuthorization(payer, executor, value, …, v, r, s)` → payer → executor
   (USDC requires `msg.sender == to`, so the funds are bound to the executor)
2. `USDC.approve(depository, value)` → executor approves the depository
3. `LayerswapDepository.depositERC20(depositId, USDC, receiver, value)` → executor → whitelisted receiver

Net: **payer → executor → receiver**, atomically. Any revert (bad sig, expired,
receiver not whitelisted, paused) rolls back the receive too — the user keeps
their USDC and the nonce is not spent.

**Dropping the approve (2-call batch).** Step 2 only exists because `depositERC20`
pulls via `transferFrom`. If you grant the depository a one-time standing
allowance (`ApproveDepository.s.sol`), the batch becomes just steps 1 & 3 and is
cheaper per deposit. This is safe here because the **executor holds no idle USDC**
— funds only pass through it inside the atomic batch — so even a max approval has
nothing to drain when idle. `CaliburDeposit` auto-detects the allowance and picks
the 2- or 3-call batch. (The allowance is account state and persists after you
disable delegation — revoke it with `APPROVE_AMOUNT=0` when retiring the executor.)

---

## 3. Broadcaster checklist: validating the EIP-3009 signature

Before submitting a user's signature, the broadcaster should validate the
following. The first group prevents **theft/abuse**; the second prevents
**wasted-gas reverts** (always dry-run the batch first).

**Security (do not skip):**
- **`to` is YOUR executor account.** Only accept a signature whose `to` is the
  executor EOA you control (delegated to Calibur) and whose post-receipt behavior
  is bound (this batch) — not the Calibur implementation, and never a public,
  behavior-agnostic contract (e.g. a shared multicall), where anyone holding the
  signature could pull the funds and sweep them elsewhere in the same tx.
- **Use `receiveWithAuthorization`, not `transferWithAuthorization`.** The
  `receive` variant enforces `msg.sender == to`, so no third party can replay the
  signature against a `to` they don't control.
- **`from != to`.** Reject payer == executor (a no-op self-transfer).
- **Recovers to `from` against the right domain.** `ecrecover(digest) == from`,
  where the digest uses USDC's live `DOMAIN_SEPARATOR()` (chainId 11155111,
  verifyingContract = USDC). Guarantees authenticity and prevents cross-chain /
  wrong-token replay.
- **Nonce unused.** `usdc.authorizationState(from, nonce) == false` (single-use;
  detects replay).
- **`value` is consistent.** The amount used in `approve`/`depositERC20` must
  equal the signed `value` (the script uses one field for all three).

**Liveness (avoid guaranteed reverts):**
- **Window valid with margin.** `validAfter < now` and `validBefore > now + inclusion buffer`
  (don't sign a 2-second window); price the tx to be mined before `validBefore`.
- **Payer can pay.** `from` USDC balance ≥ `value` and `from` is **not USDC-blacklisted**.
- **Destination ready.** `depository.isWhitelisted(receiver)` and `!depository.paused()`.
- **Simulate first.** Dry-run the full batch (`forge script` without `--broadcast`,
  or `eth_call`) and only broadcast if it succeeds.

> **Why these are enough against front-running:** because `to` is your Calibur
> account and `receiveWithAuthorization` requires `msg.sender == to`, nobody else
> can execute the authorization, and the single-use nonce + atomic batch mean a
> leaked signature can't be replayed or partially executed to steal funds.

---

### Layout

```
src/CaliburDepositBatch.sol          # pure lib: builds the 3-call batch (inlined, not deployed)
src/interfaces/*                     # IERC3009USDC, ILayerswapDepository, IERC7821(+Call), IERC20
script/EnableDelegation.s.sol        # EIP-7702 enable (executor → Calibur impl)
script/DisableDelegation.s.sol       # EIP-7702 disable (→ plain EOA)
script/ApproveDepository.s.sol       # optional one-time approve → enables 2-call batch
script/CaliburDeposit.s.sol          # signs + builds + submits the batch via Calibur.execute
script/SignReceiveAuthorization.s.sol# optional: sign out-of-band, prints v/r/s
test/CaliburDepositLocal.t.sol       # deterministic full-flow + atomicity
test/CaliburDepositSepoliaFork.t.sol # live Sepolia: real USDC + real depository
```
