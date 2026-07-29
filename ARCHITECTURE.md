# Architecture

**Proven on-chain** — 13 Sepolia transactions plus real-venue mainnet-fork tests:
a user's funds are pulled (gaslessly by signature, or by the user's own tx),
optionally swapped through **any venue that delivers output to an address**, then
split and deposited into the **original, unmodified Layerswap depository** — all
in one atomic transaction, with zero dust and no MEV-protected-RPC requirement.
The only custom code is one stateless periphery contract, `SplitForwarder`.

## Design principles

1. **The user is always a plain EOA** — never EIP-7702-delegated. Only the
   relayer's executor is a Calibur smart account (gasless mode only).
2. **Exact-in swaps only** — the UI lets users send any amount; quoted floors are
   slippage revert-guards, never amount-shapers.
3. **Zero dust, enforced on-chain** — the forwarder asserts a per-token (and
   always-native) terminal zero-balance, and the last split leg takes the
   arithmetic remainder. Nothing can be stranded, or the tx reverts.
4. **The depository stays 100% original** — no custom on-chain deposit function;
   the dynamic-amount work lives in the caller-side forwarder.
5. **Venue-independent** — the swap is a caller-supplied hook target, not a
   hardcoded dependency. Uniswap, 0x, Fly all drop in with no contract change.
6. **Public infrastructure over new contracts** — Universal Router / 0x / Fly
   (swaps), Permit2 (signature pulls), WETH9. Routers are *executors, not brains*:
   routes are chosen off-chain (QuoterV2 / venue API) and encoded; on-chain
   protection is min-out.

## The contract

```solidity
struct Leg        { address target; uint96 shareBps; uint256 amountOffset; bytes data; }
struct TokenSplit { address token; Leg[] legs; }        // token = address(0) → native

function run(TokenSplit[] calldata splits) external payable;
function runWithPermit(IPermit2.PermitTransferFrom permit, address owner,
                       TokenSplit[] calldata splits, bytes calldata sig) external;
function permitAndRun(address token, uint256 value, uint256 deadline,
                      uint8 v, bytes32 r, bytes32 s, TokenSplit[] calldata splits) external;
```

- **Several tokens AND native ETH in one call** — splits are processed
  *sequentially*, so an earlier split's hook (e.g. a swap paying the forwarder)
  can produce the balance a later split distributes.
- **Each leg** is a plain transfer (empty `data`) or a **calldata hook** — the
  leg's run-time amount is patched into the template at `amountOffset`
  (`NO_SUBSTITUTION` for native hooks, where the amount rides as `msg.value`,
  e.g. `depositNative`). ERC-20 hooks get an exact `approve` + reset; reverts
  bubble. A **zero-bps "call-only" leg** invokes a target without moving an
  amount (e.g. run `router.execute` after a plain leg pre-funded it).
- **Bips must sum to exactly 10000** per split or the tx reverts; the **last leg
  takes the arithmetic remainder** (rounding dust impossible); a terminal
  per-token zero-balance check (`BalanceNotConsumed`), plus an always-checked
  native balance, guarantees nothing stays behind.
- **`runWithPermit`** — intent-bound user entry: Permit2 `permitWitnessTransferFrom`
  with `witness = keccak256(abi.encode(splits))`.
- **`permitAndRun`** — EIP-2612 self-submit: `permit(owner=msg.sender, SF, value)`
  then pull; no Permit2, no standing approve.
- **Trust model = a router**: stateless, no owner, permissionless — funds are
  never parked in it across transactions.

### Terminal-invariant scope
The zero-balance check covers every token **named** in `splits` plus native ETH.
A hook that produces a token *not named* in the plan would leave it in the
forwarder, permissionlessly claimable. A normal swap outputs
exactly the buy token, which the plan names — so this doesn't arise in these
flows; the rule is simply "name every token a hook can output."

## Funding-mode matrix

| Mode | Entry | Inbound mechanism | Safety |
|---|---|---|---|
| **gasless** | relayer's Calibur (EIP-7821) batch | EIP-3009 (USDC) / **Permit2, spender = executor** (any plain token) | signature binds spender = executor; nonce unspent on revert |
| **user-erc20** | one direct `SF.runWithPermit` (default) or `SF.permitAndRun` (`ERC20_AUTH=2612`) | Permit2 witness over the plan / native EIP-2612 | **public-mempool-safe, no MEV assumption** (see below) |
| **user-eth** | one direct `SF.run{value}` | `msg.value` (no signature moves native — protocol fact) | user pays own gas by definition |

## Per-flow execution shapes

`X` = the user's input; `▸amount◂` = patched into calldata by SF at run time.
The four flows (top→bottom = Flow 1→4) are shown in `docs/flow-diagrams.jpg`.

### Flow 1 — all in → swap → deposit full output
```
gasless (Calibur batch; user signed EIP-3009 only):
  [ USDC.receiveWithAuthorization(user→executor, X),
    USDC.transfer(router, X),
    router.execute(swap USDC→WETH, recipient = SF),
    SF.run([ { WETH, [ 100% hook → depositERC20(id, WETH, receiver, ▸amount◂) ] } ]) ]

user-erc20 (ONE SF.runWithPermit; witness = keccak256(splits)):
  SF.runWithPermit(permit{USDC,X}, user, splits, sig), splits =
    [ { USDC, [ 100% → router (plain), call-only → router.execute(swap USDC→WETH → SF) ] },
      { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] } ]

user-eth (ONE SF.run{value}):
  SF.run{value:X}([ { native, [ 100% hook → router.execute{value}(WRAP_ETH, swap → SF) ] },
                    { USDC,   [ 100% hook → depositERC20(id, USDC, receiver, ▸amount◂) ] } ])
```

### Flow 2 — SF splits input (exact fee); venue delivers to user
```
gasless:
  [ USDC.receiveWithAuthorization(user→executor, X),
    USDC.transfer(SF, X),
    SF.run([ { USDC, [ 12.34% → feeEOA, remainder → router ] } ]),
    router.execute(swap CONTRACT_BALANCE → recipient = user) ]

user-erc20:
  SF.runWithPermit(permit{USDC,X}, user, splits, sig), splits =
    [ { USDC, [ 12.34% → feeEOA, remainder → router (plain),
                call-only → router.execute(swap → user) ] } ]

user-eth (the remainder leg IS the swap):
  SF.run{value:X}([ { native, [ 12.34% → feeEOA,
                                remainder hook → router.execute{value}(WRAP_ETH, swap → user) ] } ])
```

### Flow 3 — swap all → SF splits the ACTUAL output (live-exact bips)
```
gasless:
  [ …receive…, USDC.transfer(router, X),
    router.execute(swap USDC→WETH, recipient = SF),
    SF.run([ { WETH, [ 12.34% → feeEOA, remainder → user ] } ]) ]

user-erc20:
  splits = [ { USDC, [ 100% → router (plain), call-only → router.execute(swap → SF) ] },
             { WETH, [ 12.34% → feeEOA, remainder → user ] } ]

user-eth (split[0]'s hook produces split[1]'s balance):
  SF.run{value:X}([ { native, [ 100% hook → router.execute{value}(WRAP_ETH, swap → SF) ] },
                    { USDC,   [ 12.34% → feeEOA, remainder → user ] } ])
```

### Flow 4 — SF splits input (fee); venue swaps rest → SF deposits full output
```
gasless:
  [ …receive…, USDC.transfer(SF, X),
    SF.run([ { USDC, [ 12.34% → feeEOA, remainder → router ] } ]),
    router.execute(swap → SF),
    SF.run([ { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] } ]) ]

user-erc20:
  splits = [ { USDC, [ 12.34% → feeEOA, remainder → router (plain),
                       call-only → router.execute(swap → SF) ] },
             { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] } ]

user-eth:
  SF.run{value:X}([ { native, [ 12.34% → feeEOA,
                                remainder hook → router.execute{value}(WRAP_ETH, swap → SF) ] },
                    { USDC,   [ 100% hook → depositERC20(id, USDC, receiver, ▸amount◂) ] } ])
```

### Native deposit — dynamic msg.value into depositNative
```
[ …receive…, USDC.transfer(router, X),
  router.execute(swap USDC→WETH → router, UNWRAP_WETH → native ETH → SF),
  SF.run([ { native, [ 100% hook → depositNative{value: ▸amount◂}(id, receiver) ] } ]) ]
```
This is a capability a depository-side whole-balance sweep fundamentally cannot
offer: native amounts must ride as `msg.value`, and no contract can pull ETH from
its caller — so the fix has to live caller-side, which is exactly the forwarder.

## Security: user-sent ERC-20 flows are mempool-safe (intent-bound)

Both user-erc20 paths are safe on a public mempool with **no submission
assumption**:

- **`runWithPermit` (Permit2 witness).** The user's `permitWitnessTransferFrom`
  signature commits to `witness = keccak256(abi.encode(splits))` — the entire
  payout plan. A front-runner who copies the pending signature is forced into the
  user's exact intent: funds can only go to the forwarder (`transferDetails.to` is
  hardcoded to `address(this)`, not caller-chosen), and altering any recipient,
  bips, or hook changes the witness → Permit2's `InvalidSigner` rejects it. The
  only thing a replayer can do is execute the user's exact flow, at their own gas.
  Proven: `testFork_Intent_AlteredSplitsReplayReverts`.
- **`permitAndRun` (EIP-2612).** Safe **without** a witness — the binding is
  structural: the pull is `transferFrom(msg.sender, …)`, so the permit owner is
  forced to the caller. A replayer calling with the user's signature runs
  `permit(attacker, …)` (fails to recover the user's sig → caught), then pulls
  from *themselves*. Proven: `testFork_Permit2612_ReplayCannotDrainUser`.

The one residual (true of any signature scheme): a leaked signature for the
*honest* plan can be submitted by anyone — but doing so only executes what the
user authorized, to the recipients the user chose.

**Gasless mode** binds `spender = executor` (EIP-3009 / Permit2 SignatureTransfer)
— a leaked signature is unusable by anyone else, and atomicity means a failed
batch never consumes the nonce. The executor is pass-through (holds 0 before and
after every flow), so even standing approvals have nothing to drain.

## Venue independence (proven against real routers, no mocks)

The swap step is a hook leg, so **any venue drops in with no SF change** — the
venue is the leg's `target`, never a constant. (The hardcoded `PERMIT2` constant
is used *only* by `runWithPermit`'s inbound pull; swap venues are always
caller-supplied.)

- **Uniswap** — live on Sepolia (the matrix).
- **0x** — `test/ZeroxMainnetFork.t.sol` forks Ethereum mainnet, fetches a live
  0x Swap API quote (`script/zerox_quote.sh`, taker = the forked SF), and swaps
  100 USDC → WETH through the **real Settler / AllowanceHolder and real
  liquidity**, then splits the actual output. `testFork_MixedVenue_0xAndUniswap_SameRun`
  swaps half via real 0x and half via real Uniswap in a **single `run()`** — two
  hook legs, different targets, zero dust.
- **Fly (Magpie)** — `test/FlyMainnetFork.t.sol`, same approach: real
  MagpieRouterV3 + live Fly Swap API (`script/fly_quote.sh`, keyless).

**Dust holds across venues.** With the forwarder's native balance zeroed at
setup, the Fly run ends at exactly 0 in USDC / WETH / native — confirming a swap
delivers only the named buy token, which the plan distributes in full (remainder
leg). (A tiny native leftover once seen in a fork run was a fork
address-collision balance at the freshly-deployed SF address, not swap surplus.)

## Gas — the price of venue independence

Roughly, per flow: gasless ~225–298k, user-erc20 ~214–272k, user-eth ~153–213k.
Versus the alternative approach (below), the overhead is the SF hop(s) — an extra
external call, `balanceOf` reads, and approve set/reset per ERC-20 hook — on the
order of **+15–45k per flow**. That buys an untouched depository,
venue-independence, native dynamic deposits, and mempool-safe user-sent ERC-20.

## Alternative approach (`alt/extended-depository-flows` branch)

An earlier, self-contained approach is preserved on the
`alt/extended-depository-flows` branch. It extends the depository with a
`depositERC20All` function (whole-balance forward, read at run time) and drives
payouts through the Universal Router's `PAY_PORTION`/`SWEEP` commands.

| | Alternative (`depositERC20All` + UR commands) | This approach (`SplitForwarder`) |
|---|---|---|
| Depository | modified / redeployed | **100% original** |
| Venue coupling | splits depend on UR `PAY_PORTION`/`SWEEP` | **any venue that delivers to an address (0x-ready)** |
| Native dynamic deposit | ❌ impossible | ✅ proven |
| Multi-token + native in one payout call | ❌ | ✅ |
| user-eth entry | Multicall3 / router | **one direct SF call** |
| user-erc20 entry | router-only (2&3) / Multicall3+permit (1&4, **needs private submission**) | **one direct call — intent-bound, mempool-safe, no MEV assumption** |
| Gas | baseline | +15k … +45k per flow |
| Custom code | 1 function in the depository | 1 standalone ~230-line contract |

**Recommendation:** if any non-Uniswap venue is on the roadmap or the depository
must stay untouched, this is the approach to ship — it costs ~+15–45k gas per
flow; in exchange the payout logic lives in one periphery contract, the venue is
a plug-in, native dynamic deposits work, and user-sent ERC-20 flows need no
MEV-protected submission.

## Hard limits

1. **Gasless native ETH inbound is impossible** for a plain EOA — no signature
   moves ETH. User-sent is the native path (proven).
2. **Plain tokens need one `approve(Permit2)` tx per token, ever** — then
   signature-only. EIP-3009/2612 tokens are signature-only from day one
   (`permitAndRun` needs no approve at all).
3. **Fee-on-transfer / rebasing tokens** — out of scope by design.
