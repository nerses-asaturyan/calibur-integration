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

---

## Variant: router-native gasless DeFi flow (`CaliburRouterFlow.s.sol`)

The base flow moves USDC straight to Layerswap. This variant proves the same
gasless → **atomic Calibur batch** → **dual payout** pattern with a real DeFi
chain in the middle, and **still zero new contracts** — the dynamic chaining is
delegated to Uniswap's **unowned** Universal Router.

**One atomic 5-call Calibur batch** (relayer pays gas; user only signs EIP-3009):

1. `USDC.receiveWithAuthorization(user → executor)` — gasless inbound.
2. `USDC.transfer(universalRouter, amountIn)` — pre-fund the router.
3. `UniversalRouter.execute(...)` — the whole **dynamic** chain, each leg feeding
   the next via the `CONTRACT_BALANCE` sentinel (no intermediate amount is known
   at sign time):
   - `V3_SWAP_EXACT_IN` USDC→WETH (real Uniswap v3),
   - `UNWRAP_WETH`+`WRAP_ETH` WETH→ETH→WETH — **Aave-supply/withdraw substitute**,
   - `V3_SWAP_EXACT_IN` WETH→USDC — **0x-swap substitute** (2nd Uniswap hop),
   - `TRANSFER` small fee → fee EOA, `SWEEP` remainder → executor.
4. `USDC.approve(depository, floor)`.
5. `LayerswapDepository.depositERC20(id, USDC, receiver, floor)` — emits `Deposited`.

**Why `floor` (the one "partial" leg):** an unowned router can't call
`depositERC20`, and a static ERC-7821 `Call` must name an exact amount. So the
router sweeps the dynamic remainder back to the executor and we deposit a
slippage-computed floor (`minUsdcBack − feeAmount`); any excess stays as tiny dust
in the executor. Swaps are fully dynamic — only this deposit amount is floored.

**Substitutions (flagged — no usable Sepolia route for the originals):**
0x Swap API is mainnet-only; Aave v3 Sepolia's reserves are Aave faucet tokens
(not Circle USDC / not canonical WETH9) with no Uniswap liquidity, so no atomic
route feeds real swap liquidity into real Aave. WETH9 wrap/unwrap is the nearest
real "put asset in, take it back out" analog.

**Extra Sepolia addresses**

| | Address |
|---|---|
| Uniswap Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| Uniswap QuoterV2 (off-chain pricing) | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| WETH9 (canonical) | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

**Run**

```bash
# 0. one-time: delegate the executor to Calibur (cast is TTY-safe; forge --broadcast
#    needs `< /dev/null` in non-interactive shells):
cast send $EXECUTOR --auth $CALIBUR_IMPLEMENTATION \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# 1. run the flow (simulate first by dropping --broadcast):
forge script script/CaliburRouterFlow.s.sol:CaliburRouterFlowScript \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
```

**Required env (beyond the base flow):** `FEE_RECIPIENT`, `FEE_AMOUNT`; optional
overrides `WETH_SEPOLIA`, `UNIVERSAL_ROUTER`, `UNISWAP_QUOTER`, `POOL_FEE_IN`,
`POOL_FEE_OUT`, `SLIPPAGE_BPS` (defaults baked into the script). Note: a working
`SEPOLIA_RPC_URL` is required (a public one such as
`https://ethereum-sepolia-rpc.publicnode.com` works).

**Proven on Sepolia:** tx
[`0x74fb71b5…1c33c4a49`](https://sepolia.etherscan.io/tx/0x74fb71b5a64e44c53f47735a7fc9cb9e0bc496c861d7e146e9b55ae1c33c4a49)
— 10000 in → fee 100 to the EOA + 9630 `depositERC20` to Layerswap (with
`Deposited` event), 198 dust to executor.

### Variant B: three EOAs + three different pairs (`CaliburMultiPairFlow.s.sol`)

Same zero-contract, router-native design, tuned to be visually obvious:
- **Three distinct EOAs** (enforced): payer ≠ relayer/executor ≠ fee recipient.
- **Three different Uniswap v3 pairs**: `USDC/WETH → WETH/UNI → UNI/USDC` (all real
  Sepolia liquidity), so the token path `USDC → WETH → UNI → USDC` is legible on a
  block explorer. Drops the WETH wrap/unwrap leg to keep the multi-pair swap the focus.

Extra env: `UNI_SEPOLIA` (`0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984`), `POOL_FEE_1`
(USDC/WETH, 3000), `POOL_FEE_2` (WETH/UNI, 3000), `POOL_FEE_3` (UNI/USDC, 500).
`FEE_RECIPIENT` must differ from both keys.

**Proven on Sepolia:** tx
[`0xbf22f0ad…a4ed1225`](https://sepolia.etherscan.io/tx/0xbf22f0add3c4db10e3b104df4bc068631deed5f0fa23b14b1b803e08a4ed1225)
— 10000 USDC in, routed through WETH and UNI, back to USDC: 100 to the fee EOA +
9579 `depositERC20` to Layerswap (`Deposited`), 297 dust to executor.

---

# Guide: how the two live Sepolia transactions work

This section walks through the two transactions this repo actually broadcast on
Sepolia, end to end. Both prove the same thesis — **a user moves funds with only an
off-chain signature (no gas, no on-chain tx of their own); a relayer sponsors one
atomic transaction that pulls the funds, runs a real DeFi chain, and pays out to two
places — using ZERO new contracts of our own.**

| | Transaction | Block | Gas |
|---|---|---|---|
| **TX 1** — single pair + WETH wrap/unwrap | [`0x74fb71b5…1c33c4a49`](https://sepolia.etherscan.io/tx/0x74fb71b5a64e44c53f47735a7fc9cb9e0bc496c861d7e146e9b55ae1c33c4a49) | 11327771 | 328,694 |
| **TX 2** — three EOAs + three different pairs | [`0xbf22f0ad…a4ed1225`](https://sepolia.etherscan.io/tx/0xbf22f0add3c4db10e3b104df4bc068631deed5f0fa23b14b1b803e08a4ed1225) | 11327832 | 401,508 |

## The building blocks (why no new contract is needed)

1. **EIP-7702 delegation.** The relayer EOA is delegated to Uniswap's **Calibur**
   smart-account implementation (`cast send $EXECUTOR --auth $CALIBUR_IMPLEMENTATION`).
   After that, the EOA runs Calibur code *at its own address* — its on-chain code
   becomes `0xef0100‖<impl>`. So one EOA is simultaneously the **relayer** (pays gas),
   the **executor** (runs an ERC-7821 batch), and the EIP-3009 **`to`**.
2. **EIP-3009 gasless inbound.** The payer signs `receiveWithAuthorization(from,to,
   value,validAfter,validBefore,nonce)` off-chain. USDC requires `msg.sender == to`,
   and the executor *is* `to`, so only the executor can redeem it. The payer spends no
   gas and sends no transaction.
3. **ERC-7821 batch.** The executor runs a fixed `Call[]` in one transaction via
   `execute(mode, abi.encode(calls))`. Every sub-call runs with `msg.sender == executor`.
   If any call reverts, the whole batch reverts — so the EIP-3009 receive is undone and
   its nonce is never consumed.
4. **Universal Router `CONTRACT_BALANCE`.** A static batch can't carry an amount that
   isn't known until a swap runs. We sidestep that by pre-funding Uniswap's **unowned**
   Universal Router and issuing swap commands with `amountIn = CONTRACT_BALANCE` — the
   router swaps its *entire current balance* of the input token, so each leg consumes
   whatever the previous leg produced. This is what makes the dynamic swap chain work
   with no contract of our own.
5. **The floor (the one "partial" leg).** The Universal Router can't call an arbitrary
   function like `LayerswapDepository.depositERC20`, and a static `Call` must name an
   exact amount. So the router **sweeps** the (dynamic) leftover back to the executor,
   and we deposit a **slippage-computed floor** (`minOut − fee`) that is guaranteed to
   be available. Any excess over the floor stays as tiny **dust** in the executor.
6. **Atomicity.** Inbound + swaps + fee + deposit are all in one transaction. All or
   nothing.

---

## TX 1 — single pair round-trip with a WETH wrap/unwrap

Script: `script/CaliburRouterFlow.s.sol`. Input: **10000** USDC units (0.01 USDC).
Roles in this run: payer **and** fee recipient = `0x719b…BD0d`; relayer/executor =
`0xF651…778D`.

The 5-call Calibur batch, and the USDC movements it produced on-chain:

| # | Call | On-chain USDC transfer |
|---|---|---|
| 1 | `USDC.receiveWithAuthorization(user → executor)` | payer → executor: **10000** |
| 2 | `USDC.transfer(router, 10000)` | executor → router: 10000 |
| 3 | `UniversalRouter.execute(...)` | see below |
| 4 | `USDC.approve(depository, floor)` | — |
| 5 | `depository.depositERC20(id, USDC, receiver, floor)` | executor → LS receiver: **9630** |

Inside call 3, the router ran: `V3_SWAP_EXACT_IN` USDC→WETH (fee-3000 pool), then
`UNWRAP_WETH`+`WRAP_ETH` (WETH→ETH→WETH — the flagged **Aave-supply/withdraw
substitute**), then `V3_SWAP_EXACT_IN` WETH→USDC (fee-500 pool), then `TRANSFER` the
fee and `SWEEP` the remainder:

```
executor        -> router      : 10000   (pre-fund)
router          -> USDC/WETH 0.30% pool : 10000   (swap USDC -> WETH)
WETH/USDC 0.05% pool -> router  : 9928    (swap WETH -> USDC, after wrap/unwrap)
router          -> fee EOA    : 100      (fee payout)
router          -> executor   : 9828     (sweep remainder)
executor        -> LS receiver: 9630     (Layerswap depositERC20 -> emits Deposited)
```

Result: **0.01 USDC in → 100 to the fee EOA + 9630 deposited to Layerswap**
(the depository emitted `Deposited(id, USDC, receiver, 9630)`), and **198 dust**
(9828 swept − 9630 floor) stayed in the executor. The payer paid no gas.

---

## TX 2 — three distinct EOAs, three different pairs

Script: `script/CaliburMultiPairFlow.s.sol`. Input: **10000** USDC units. This run
makes the roles and the DeFi hops visually distinct:

- **payer** `0x719b…BD0d` — signs the EIP-3009 auth.
- **relayer / executor** `0xF651…778D` — Calibur account; pays all gas.
- **fee recipient** `0x0e86…F001` — a fresh EOA that started at 0 (so the fee arriving
  is unmistakable), enforced to differ from both keys.

The swap chain routes through **three different Uniswap v3 pairs** — token path
`USDC → WETH → UNI → USDC` — each hop consuming the previous hop's output via
`CONTRACT_BALANCE`. Full on-chain trace (multi-token):

```
payer   --USDC 10000-->        relayer            (gasless EIP-3009 inbound)
relayer --USDC 10000-->        router             (pre-fund)
router  --USDC 10000-->        USDC/WETH pool     hop 1: USDC -> WETH
        <--WETH 606535350870-- USDC/WETH pool
router  --WETH 606535350870--> WETH/UNI pool      hop 2: WETH -> UNI
        <--UNI  27705561953--- WETH/UNI pool
router  --UNI  27705561953-->  UNI/USDC pool       hop 3: UNI  -> USDC
        <--USDC 9976---------- UNI/USDC pool
router  --USDC 100-->          fee EOA            (fee payout)
router  --USDC 9876-->         relayer            (sweep remainder)
relayer --USDC 9579-->         LS receiver        (Layerswap depositERC20 -> Deposited)
```

Result: **0.01 USDC in, routed through WETH and UNI and back to USDC → 100 to the fee
EOA + 9579 deposited to Layerswap**, with **297 dust** (9876 − 9579) left in the
executor. Three distinct addresses and three distinct pools are all visible in the
transfer log.

---

## Verify it yourself

```bash
RPC=https://ethereum-sepolia-rpc.publicnode.com

# 1. confirm success + gas
cast receipt 0x74fb71b5a64e44c53f47735a7fc9cb9e0bc496c861d7e146e9b55ae1c33c4a49 --rpc-url $RPC
cast receipt 0xbf22f0add3c4db10e3b104df4bc068631deed5f0fa23b14b1b803e08a4ed1225 --rpc-url $RPC

# 2. read the transfer logs / Deposited event on the explorer:
#    open the two links in the table above and view "Logs".

# 3. the executor's Calibur delegation is visible as code 0xef0100 + impl:
cast code 0xF6517026847B4c166AAA176fe0C5baD1A245778D --rpc-url $RPC
```

On Etherscan, the story to point at: **(a)** the `from` of the tx is the *relayer*, not
the payer — yet USDC leaves the *payer's* balance (the gasless EIP-3009 redemption);
**(b)** the token-transfer list shows the funds hopping through the Uniswap pools;
**(c)** two outbound payouts — the fee EOA and the Layerswap receiver — with the
depository's `Deposited` event confirming the credited amount.
