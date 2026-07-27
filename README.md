# Calibur (EIP-7702) · USDC EIP-3009 → LayerswapDepository — Sepolia

A user signs **one** EIP-3009 `receiveWithAuthorization`; a Calibur smart account
(an EOA delegated via EIP-7702) then runs **one atomic batch** that pulls the
USDC and forwards it into the LayerswapDepository. If any step reverts, nothing
moves and the signature's nonce stays unused.

> **[ARCHITECTURE.md](ARCHITECTURE.md)** — the final architecture: design
> principles, roles & trust model, full capability matrix (what's gasless, what
> isn't, and why), all proven transactions, and the decision guide.

The repo now ships **our own `LayerswapDepository` deployment** (same contract,
plus a `depositERC20All` function that forwards the caller's **whole balance**,
read at run time). That one dynamic-amount primitive turns the demo flows from
"deposit a floor, keep dust" into **zero-dust**: whatever the swaps actually
produce is deposited, exactly.

**Addresses (Sepolia, pre-filled in `.env.example` / script defaults)**

| | Address |
|---|---|
| USDC (Circle, EIP-3009) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Calibur singleton (7702 target) | `0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00` |
| **LayerswapDepository (ours, verified, `depositERC20All`)** | [`0x4fFFC89c52dD080d1eEEc3Ccd546602c0f1720E8`](https://sepolia.etherscan.io/address/0x4fFFC89c52dD080d1eEEc3Ccd546602c0f1720E8#code) |
| LayerswapDepository (original, no `depositERC20All`) | `0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4` |
| **PayoutSplitter (ours, verified, stateless N-way splitter)** | [`0xd952dc9C32FBC747232E888034280887B15591D3`](https://sepolia.etherscan.io/address/0xd952dc9C32FBC747232E888034280887B15591D3#code) |
| Uniswap Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| Uniswap QuoterV2 (off-chain pricing) | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| WETH9 (canonical) | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| UNI | `0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984` |
| Aave v3 Pool | `0x6Ae43d3271ff6888e7Fc43Fd7321a503ff738951` |
| aaveWETH (Aave v3 Sepolia WETH reserve, faucet token) | `0xC558DBdd856501FCd9aaF1E62eae57A9F0629a3c` |

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
forge test --fork-url $SEPOLIA_RPC_URL  # incl. real USDC + our live depository
```

**Deploy your own depository** (owner = `addr(PRIVATE_KEY)`, whitelist = `[DEPOSIT_RECEIVER]`):

```bash
forge script script/DeployDepository.s.sol:DeployDepositoryScript \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vv < /dev/null
# then point LAYERSWAP_DEPOSITORY in .env at the printed address
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
- **`value` is consistent.** The amount used downstream must be bound to the
  signed `value` (the base script uses one field for all three calls; the DeFi
  flows guard every dynamic leg with a slippage floor).

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
src/LayerswapDepository.sol          # our deployment: original contract + depositERC20All (whole-balance deposit)
src/PayoutSplitter.sol               # stateless N-way % splitter + generic call hooks (ERC-20 & native), zero dust
src/CaliburDepositBatch.sol          # pure lib: builds the 3-call batch (inlined, not deployed)
src/interfaces/*                     # IERC3009USDC, ILayerswapDepository, IERC7821(+Call), IERC20,
                                     #   IUniversalRouter, IQuoterV2, IAaveV3Pool, IPayoutSplitter(+Leg)
script/DeployDepository.s.sol        # deploys + whitelists src/LayerswapDepository.sol
script/DeploySplitter.s.sol          # deploys src/PayoutSplitter.sol (no args, no owner)
script/EnableDelegation.s.sol        # EIP-7702 enable (executor → Calibur impl)
script/DisableDelegation.s.sol       # EIP-7702 disable (→ plain EOA)
script/ApproveDepository.s.sol       # optional one-time approve → enables 2-call batch
script/CaliburDeposit.s.sol          # signs + builds + submits the batch via Calibur.execute
script/CaliburRouterFlow.s.sol       # TX 1: 4 Uniswap pools + ETH round-trip + zero-dust deposit
script/CaliburMultiPairFlow.s.sol    # TX 2: 3 EOAs + REAL Aave v3 supply/withdraw + 6 swaps, zero dust
script/CaliburNativeDualFlow.s.sol   # TX 3: 3 swaps -> native ETH split to two EOAs, no depository
script/CaliburSplitFlow.s.sol        # TX 4: arbitrary-% splits (ERC-20 + native) + ORIGINAL depository hooks
script/NativeMulticall3Flow.s.sol    # TX 5: USER-invoked native-ETH flow via Multicall3 (known contracts only)
script/SignReceiveAuthorization.s.sol# optional: sign out-of-band, prints v/r/s
test/CaliburDepositLocal.t.sol       # deterministic full-flow + atomicity
test/PayoutSplitter.t.sol            # splitter units: bps math, hooks, reverts, atomicity, reentrancy
test/CaliburDepositSepoliaFork.t.sol # live Sepolia: real USDC + our live depository
test/PayoutSplitterSepoliaFork.t.sol # live Sepolia: splitter + real USDC + ORIGINAL depository
```

---

# Guide: how the two live Sepolia transactions work

Both transactions prove the same thesis — **a user moves funds with only an
off-chain signature (no gas, no on-chain tx of their own); a relayer sponsors one
atomic transaction that pulls the funds, runs a real multi-protocol DeFi chain, and
pays out to two places — with ZERO DUST: every input unit ends up in a payout.**
The only contract of our own is the depository itself (deployed + verified above);
all dynamic orchestration is done by **unowned** infrastructure (Uniswap's
Universal Router, Aave v3).

| | Transaction | Block | Gas |
|---|---|---|---|
| **TX 1** — 4 Uniswap pools + native ETH round-trip, zero dust | [`0x95378e76…4bff63b`](https://sepolia.etherscan.io/tx/0x95378e760765db56775fb6b6c135f6b08af039aaf5d1f221da8dfcb794bff63b) | 11341683 | 519,836 |
| **TX 2** — 3 EOAs + **real Aave v3 supply/withdraw** + 6 swaps, zero dust | [`0x20c49f67…645d4b6`](https://sepolia.etherscan.io/tx/0x20c49f6796dd12757482adafb5ace4560456702802ae40214ccd29d46645d4b6) | 11341687 | 823,647 |
| **TX 3** — **native ETH** split to two EOAs, no depository, zero dust | [`0xa50e86d8…cb2e4c9`](https://sepolia.etherscan.io/tx/0xa50e86d89397ea762eed855b2142a62654ee1caaa776aecf73ad130f1cb2e4c9) | 11341930 | 374,091 |
| **TX 4** — **generic splitter**: arbitrary % (12.34/37.66/50), ERC-20 **and** native, ORIGINAL depository via call hooks | [`0xf3fe4ee3…894c76`](https://sepolia.etherscan.io/tx/0xf3fe4ee3acdbfff7ca1da53f92e7cd13b52d88c41a19a46c39a67a4ce0894c76) | 11361201 | 527,556 |
| **TX 5** — **user-invoked native-ETH** flow via **Multicall3**, known contracts only (no custom code) | [`0x21f1a9d2…5fa2885`](https://sepolia.etherscan.io/tx/0x21f1a9d2cbb4a9f6b50096cd6511f60cd90fcb0c9ea6c4cc83f3fba435fa2885) | 11361465 | 206,256 |

*(The earlier floor-based v1 runs — `0x74fb71b5…` and `0xbf22f0ad…` — used the
original depository and left 198/297 units of dust; kept here only for history.)*

## The building blocks (why almost no new code is needed)

1. **EIP-7702 delegation.** The relayer EOA is delegated to Uniswap's **Calibur**
   smart-account implementation (`cast send $EXECUTOR --auth $CALIBUR_IMPLEMENTATION`).
   Its on-chain code becomes `0xef0100‖<impl>`, so one EOA is simultaneously the
   **relayer** (pays gas), the **executor** (runs an ERC-7821 batch), and the
   EIP-3009 **`to`**.
2. **EIP-3009 gasless inbound.** The payer signs `receiveWithAuthorization` off-chain.
   USDC requires `msg.sender == to`, and the executor *is* `to`, so only the executor
   can redeem it. The payer spends no gas and sends no transaction.
3. **ERC-7821 batch.** The executor runs a fixed `Call[]` in one transaction via
   `execute(mode, abi.encode(calls))`. If any call reverts, the whole batch reverts —
   the EIP-3009 receive is undone and its nonce is never consumed.
4. **Universal Router `CONTRACT_BALANCE`.** A static batch can't carry an amount that
   isn't known until a swap runs. We pre-fund Uniswap's **unowned** Universal Router
   and issue swap commands with `amountIn = CONTRACT_BALANCE` — each leg consumes
   whatever the previous leg produced.
5. **`depositERC20All` — the zero-dust finisher.** The v1 flows had one "partial"
   leg: a static `Call` must name an exact amount, so they deposited a
   slippage-computed floor and kept the excess as dust. `depositERC20All` reads the
   executor's **whole balance at run time** and forwards it — the deposit itself
   becomes dynamic-amount, and the executor always ends at exactly **0**.
6. **Aave's own dynamic-amount primitive (TX 2).**
   `AavePool.withdraw(asset, type(uint256).max, to)` withdraws the caller's entire
   aToken balance and can pay it **directly to the Universal Router** — so the chain
   re-enters the router with no static-amount hop. Supply+withdraw in the same
   transaction round-trips the exact amount (no time passes → no interest accrues).
7. **Atomicity.** Inbound + swaps + Aave + fee + deposit: all or nothing.

## TX 1 — four Uniswap pools + a native ETH round-trip, zero dust

Script: `script/CaliburRouterFlow.s.sol`. Input: **10000** USDC units (0.01 USDC).
Roles: payer `0x719b…BD0d`; relayer/executor `0xF651…778D`; fee EOA `0x0e86…F001`.

The 6-call Calibur batch:

| # | Call |
|---|---|
| 1 | `USDC.receiveWithAuthorization(user → executor)` — gasless inbound |
| 2 | `USDC.transfer(router, 10000)` — pre-fund |
| 3 | `UniversalRouter.execute(...)` — the dynamic chain (below) |
| 4 | `USDC.approve(depository, max)` |
| 5 | `depository.depositERC20All(id, USDC, receiver)` — **whole balance** |
| 6 | `USDC.approve(depository, 0)` — hygiene |

Inside call 3 the router ran **4 swaps across 4 different pools** plus a native
WETH9 unwrap→rewrap, every leg on `CONTRACT_BALANCE`:

```
executor -> router          : 10000 USDC        (pre-fund)
router   -> USDC/WETH 0.30% : 10000 USDC        -> 434462159843 WETH
         (WETH -> ETH -> WETH: native WETH9 round-trip)
router   -> WETH/UNI  0.30% : 434462159843 WETH -> 19661320759 UNI
router   -> UNI/WETH  0.05% : 19661320759 UNI   -> 431462048533 WETH
router   -> WETH/USDC 0.05% : 431462048533 WETH -> 9868 USDC
router   -> fee EOA         : 100 USDC           (fee payout)
router   -> executor        : 9768 USDC          (sweep: everything left)
executor -> LS receiver     : 9768 USDC          (depositERC20All -> Deposited(9768))
```

Result: **0.01 USDC in → 100 to the fee EOA + 9768 deposited to Layerswap —
executor ends at exactly 0 USDC. Zero dust.** The payer paid no gas.

## TX 2 — three EOAs, six swaps, REAL Aave v3 in the middle, zero dust

Script: `script/CaliburMultiPairFlow.s.sol`. Input: **10000** USDC units.

- **payer** `0x719b…BD0d` — signs the EIP-3009 auth; pays nothing else.
- **relayer / executor** `0xF651…778D` — Calibur account; pays all gas.
- **fee recipient** `0x0e86…F001` — a third EOA, enforced distinct from both keys.

**How real Aave became reachable** (the v1 README said it wasn't): Aave v3
Sepolia's reserves are Aave's own faucet tokens, but a real Uniswap v3 pool
(canonical **WETH9 / aaveWETH**, 0.30%) bridges them. We use the **WETH reserve
because its supply cap is unlimited** — the aaveUSDC/aaveDAI reserves sit *above*
their caps, so `supply` there reverts `SUPPLY_CAP_EXCEEDED` (found the hard way in
simulation). Two more tricks make it atomic and dust-free:

- the bridge pool's reverse leg can't be quoted at pre-trade state (the pool may
  hold ~no WETH until *our* forward leg deposits it), so its floor is computed
  analytically: a same-pool round trip always returns ≥ `input × (1-fee)²`;
- trip 1 hands Aave exactly `floorA` (the guaranteed minimum) and **deliberately
  leaves the excess in the router** — trip 2's `CONTRACT_BALANCE` swap consumes
  it, so even the bridge-token excess is never dust.

The 10-call Calibur batch, with the actual on-chain amounts:

```
1  USDC.receiveWithAuthorization     payer -> executor : 10000 USDC   (gasless)
2  USDC.transfer(router)             executor -> router: 10000 USDC
3  router trip 1 (4 swaps, 4 pools):
     USDC/WETH  0.30% : 10000 USDC          -> 434462158020 WETH
     WETH/UNI   0.30% : 434462158020 WETH   -> 19661320658 UNI
     UNI/WETH   0.05% : 19661320658 UNI     -> 431462042624 WETH
     WETH/aaveWETH 0.30% (bridge): 431462042624 WETH -> 242402716761 aaveWETH
     TRANSFER 232851084895 aaveWETH -> executor   (floorA; excess 9551631866 stays in router)
4  aaveWETH.approve(aavePool, floorA)
5  AavePool.supply(aaveWETH, 232851084895, executor)      << REAL AAVE: aTokens minted
6  AavePool.withdraw(aaveWETH, MAX, router)               << REAL AAVE: 232851084895 straight to router
7  router trip 2 (2 swaps):
     aaveWETH/WETH 0.30%: 242402716761 aaveWETH (withdraw + excess, EXACTLY all) -> 428877153962 WETH
     WETH/USDC  0.05%   : 428877153962 WETH -> 9809 USDC
     TRANSFER 100 USDC -> fee EOA                          (payout 1)
     SWEEP    9709 USDC -> executor
8  USDC.approve(depository, max)
9  depository.depositERC20All(id, USDC, receiver)          (payout 2: Deposited(9709))
10 USDC.approve(depository, 0)
```

Result: **0.01 USDC in → 6 swaps across 5 distinct pools + a genuine Aave v3
supply & withdraw → 100 to the fee EOA + 9709 deposited to Layerswap. Zero dust
in every token**: the executor ends at 0 USDC and 0 aaveWETH, and the router's
aaveWETH excess was consumed to the last unit (232851084895 + 9551631866 =
242402716761). Three distinct EOAs, the aToken mint/burn, and the `Deposited`
event are all visible in the explorer logs.

## TX 3 — native ETH to two EOAs, no depository

Script: `script/CaliburNativeDualFlow.s.sol`. Input: **10000** USDC units (0.01 USDC).
Roles: payer `0x719b…BD0d`; relayer/executor `0xF651…778D`; payout EOA 1 (fee, 10%)
`0x0e86…F001`; payout EOA 2 (remainder) = **the payer itself**.

The 3-call Calibur batch:

| # | Call |
|---|---|
| 1 | `USDC.receiveWithAuthorization(user → executor)` — gasless inbound |
| 2 | `USDC.transfer(router, 10000)` — pre-fund |
| 3 | `UniversalRouter.execute(...)` — 3 swaps + `UNWRAP_WETH` + `PAY_PORTION` + `SWEEP` |

The on-chain trace (all swap legs on `CONTRACT_BALANCE`):

```
payer    -> executor        : 10000 USDC          (gasless EIP-3009)
executor -> router          : 10000 USDC          (pre-fund)
router   -> USDC/WETH 0.30% : 10000 USDC          -> 437801048471 WETH
router   -> WETH/UNI  0.30% : 437801048471 WETH   -> 19812420095 UNI
router   -> UNI/WETH  0.05% : 19812420095 UNI     -> 434777872691 WETH
router   UNWRAP_WETH        : 434777872691 WETH   -> 434777872691 native ETH
router   -> payout EOA 1    : 43477787269 wei     (PAY_PORTION, exactly 10%)
router   -> payout EOA 2    : 391300085422 wei    (SWEEP: everything left)
```

`PAY_PORTION` and `SWEEP` are the Universal Router's own payment commands — one
takes a bps share of the router's live balance, the other takes everything that
remains — so **both payouts are native ETH straight from the router** and the
executor never holds the output (it ends this tx at 0 USDC/WETH/UNI, the router
at 0 everything). And because payout EOA 2 defaults to the payer, the user
literally **buys gas with USDC by signature**: their ETH balance went from
26186877570000 to 26578177655422 wei (+391300085422) while sending no
transaction and paying nothing.

## TX 4 — the generic PayoutSplitter: any %, any destination, ERC-20 and native

Script: `script/CaliburSplitFlow.s.sol`. Contract:
[`PayoutSplitter`](https://sepolia.etherscan.io/address/0xd952dc9C32FBC747232E888034280887B15591D3#code)
(`0xd952…91D3`, verified) — **stateless & permissionless** (router-like trust
model: it splits its own live balance and must end every tx empty; a terminal
`DustLeft` check enforces it). Legs are `(target, shareBps, amountOffset, data)`:
empty `data` = plain transfer; non-empty = **generic call hook** with the
run-time amount substituted into the calldata at `amountOffset`. Shares must sum
to exactly 10000 and the **last leg takes the arithmetic remainder** — zero dust
by construction, at any percentages.

This tx proves everything at once — arbitrary non-round shares
(**12.34% / 37.66% / 50%**), an ERC-20 split AND a native-ETH split, and the
**ORIGINAL unextended depository** (`0xbc51…D0b4`, no `depositERC20All`) fed a
fully dynamic amount via hooks:

| # | Call |
|---|---|
| 1 | `USDC.receiveWithAuthorization(user → executor)` — gasless inbound |
| 2 | `USDC.transfer(router, 10000)` — pre-fund |
| 3 | `UniversalRouter.execute(...)` — 3 swaps, then `PAY_PORTION` 50% of the WETH → splitter (ERC-20 half) + `UNWRAP_WETH` the rest → splitter (native half) |
| 4 | `splitter.split(WETH, …)` — 12.34% → EOA-A, 37.66% → payer, remainder → `depositERC20` **hook** (amount patched at offset 100) |
| 5 | `splitter.split(ETH, …)` — same shares, remainder → `depositNative` **hook** (amount = msg.value) |

On-chain result (WETH half 204094252081, native half 204094252082):

```
split(WETH): 25185230706 -> EOA-A        (exactly 12.34%)
             76861895333 -> payer        (exactly 37.66%)
            102047126042 -> ORIGINAL depository depositERC20 -> Deposited(WETH)
split(ETH):  25185230706 -> EOA-A
             76861895334 -> payer
            102047126042 -> ORIGINAL depository depositNative -> Deposited(native)
```

Both `Deposited` events came from the **original** depository — the call hook
(not a contract extension) is what made the dynamic amount possible. Splitter
and router end at 0 in ETH/USDC/WETH/UNI: zero dust, enforced on-chain.

## TX 5 — native ETH inbound, invoked by the user, known contracts only

Script: `script/NativeMulticall3Flow.s.sol`. Native ETH cannot be pulled from a
plain EOA by signature (no permit exists for ETH), so for native inbound **the
user sends the one transaction themselves** — and it turns out no custom
contract is needed anywhere, not even the `PayoutSplitter`:

- the user chooses the ETH amount, so the inbound split is **exact values known
  upfront** → **Multicall3** (`0xcA11…CA11`) with `aggregate3Value` acts as the
  splitter — value-bearing calls with arbitrary calldata;
- amounts are only *dynamic* after a swap, and there the **Universal Router's
  own `PAY_PORTION`/`SWEEP`** split dynamically.

One user tx, `aggregate3Value{value: 0.002 ETH}` (all-or-revert):

| # | Leg | Value |
|---|---|---|
| 1 | plain ETH send → fee EOA | exactly 12.34% = 246800000000000 wei |
| 2 | `depositNative(id, receiver)` → **ORIGINAL depository** (emits `Deposited`) | exactly 37.66% = 753200000000000 wei |
| 3 | `router.execute{value}`: `WRAP_ETH` → swap WETH→USDC (0.05%) → `PAY_PORTION` 25% USDC → fee EOA, `SWEEP` rest → user | remainder 50% = 1000000000000000 wei |

On-chain result: 24035914 USDC out of the swap → 6008978 (25%) to the fee EOA +
18026936 (75%) back to the user; router ends at 0 in everything; **Multicall3's
balance delta is exactly 0**. Every contract touched — Multicall3, WETH9, the
Uniswap pool, the Universal Router, the original depository — is pre-existing
public infrastructure.

> Evaluated known splitter alternatives: **0xSplits** (v2 is on Sepolia) can't
> feed the depository — its recipients get plain transfers and the depository
> has no `receive()`; **Disperse** sends exact amounts to EOAs only. Multicall3
> value-legs + router `PAY_PORTION`/`SWEEP` cover both roles. Safety note:
> passing your own ETH through Multicall3 atomically is safe; handing an
> EIP-3009 *signature* to a public multicall is NOT (see §3) — the difference
> is that here nothing can be replayed or redirected.

## Run them yourself

```bash
set -a; source .env; set +a; export PRIVATE_KEY=$OPERATOR_PRIVATE_KEY

# TX 1 (drop --broadcast to simulate first):
forge script script/CaliburRouterFlow.s.sol:CaliburRouterFlowScript \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null

# TX 2:
forge script script/CaliburMultiPairFlow.s.sol:CaliburMultiPairFlowScript \
  --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
```

Required env: the base vars plus `FEE_RECIPIENT`, `FEE_AMOUNT`, `AMOUNT_IN`;
optional overrides `WETH_SEPOLIA`, `UNI_SEPOLIA`, `UNIVERSAL_ROUTER`,
`UNISWAP_QUOTER`, `AAVE_POOL_SEPOLIA`, `AAVE_WETH_SEPOLIA`, `POOL_FEE_1..4`,
`POOL_FEE_A..D`, `POOL_FEE_AAVE`, `SLIPPAGE_BPS` (sane Sepolia defaults baked in).

## Verify it yourself

```bash
RPC=https://ethereum-sepolia-rpc.publicnode.com

# 1. confirm success + gas
cast receipt 0x95378e760765db56775fb6b6c135f6b08af039aaf5d1f221da8dfcb794bff63b --rpc-url $RPC
cast receipt 0x20c49f6796dd12757482adafb5ace4560456702802ae40214ccd29d46645d4b6 --rpc-url $RPC

# 2. our verified depository (source + Deposited events on Etherscan):
#    https://sepolia.etherscan.io/address/0x4fFFC89c52dD080d1eEEc3Ccd546602c0f1720E8

# 3. the executor's Calibur delegation is visible as code 0xef0100 + impl:
cast code 0xF6517026847B4c166AAA176fe0C5baD1A245778D --rpc-url $RPC

# 4. zero dust: executor's USDC balance is 0 after both runs
cast call 0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238 "balanceOf(address)(uint256)" \
  0xF6517026847B4c166AAA176fe0C5baD1A245778D --rpc-url $RPC
```

On Etherscan, the story to point at: **(a)** the `from` of the tx is the *relayer*,
not the payer — yet USDC leaves the *payer's* balance (gasless EIP-3009);
**(b)** the token-transfer list shows the funds hopping through four/five Uniswap
pools — and in TX 2, entering and leaving **Aave v3** (aToken mint + burn);
**(c)** two outbound payouts — the fee EOA and the Layerswap receiver — with the
depository's `Deposited` event confirming the credited amount; **(d)** the
executor's balances end at exactly zero: **no dust anywhere**.
