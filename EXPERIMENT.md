# Experiment: SplitForwarder — untouched depository + venue-independent payouts

**Two questions, both answered yes, all proven on Sepolia:**

1. Can the Layerswap depository stay **100% original** (no `depositERC20All`
   extension) with fully-dynamic, zero-dust deposits — including **native ETH**?
2. Can the payout splitting stop depending on the Universal Router's payment
   commands (`PAY_PORTION`/`SWEEP`), so the whole system works with **any swap
   venue** — 0x Settler included — that can merely *swap and deliver output to
   an address*?

Both are solved by **one** stateless contract:
[`SplitForwarder`](https://sepolia.etherscan.io/address/0x28E815496471724e7DBA95D1a11b014110Cdb2FC#code)
(`0x28E8…b2FC`, verified — current deploy, includes `permitAndRun`).

> **Deployments:** the current `SplitForwarder` is `0x28E8…b2FC` (adds
> `permitAndRun`). The 12-flow matrix table below was proven on the **prior**
> deploy [`0x9bc9…84B2`](https://sepolia.etherscan.io/address/0x9bc92417f116dcfBbf107cbb827e3a0AC8CE84B2#code)
> — identical except the additive `permitAndRun` (existing functions unchanged),
> so those flows behave the same on the current one. The two `permitAndRun` txs
> (add-on section) ran on `0x28E8…b2FC`.

**Update — intent-bound user-sent flows (no MEV assumption).** The contract now
also exposes `runWithPermit`, which pulls the user's ERC-20 via Permit2's
**`permitWitnessTransferFrom`** with a witness committing to
`keccak256(abi.encode(splits))` — the entire payout plan. This makes every
user-sent ERC-20 flow a **single direct SF call that is safe on a public
mempool with NO submission assumptions**: a front-runner who copies the pending
signature can only execute the user's exact plan (funds are forced to the
forwarder; altering any split changes the witness and invalidates the
signature) — i.e. they would merely pay the user's gas. This removes the
previous "MEV-protected submission required" caveat and drops Multicall3 from
the system entirely.

## The contract

```solidity
struct Leg  { address target; uint96 shareBps; uint256 amountOffset; bytes data; }
struct TokenSplit { address token; Leg[] legs; }        // token = address(0) → native
function run(TokenSplit[] calldata splits) external payable
```

- **Several tokens AND native ETH in one call** — splits are processed
  *sequentially*, so an earlier split's hook (e.g. a swap paying this contract)
  can produce the balance a later split distributes.
- Each leg: plain transfer (empty `data`) or **calldata hook** — the leg's
  run-time amount is patched into the template at `amountOffset`
  (`NO_SUBSTITUTION` for native hooks where the amount rides as `msg.value`,
  e.g. `depositNative`). ERC-20 hooks get exact approve + reset; reverts bubble.
- Bips of one split must sum to exactly 10000 or the whole tx **reverts**;
  the **last leg takes the arithmetic remainder** (rounding dust impossible);
  terminal per-token zero-balance check (`BalanceNotConsumed`) enforces that
  nothing stays behind. A **zero-bps "call-only" leg** invokes a target without
  moving an amount (e.g. run `router.execute` after a plain leg pre-funded it).
- `runWithPermit(permit, owner, splits, sig)` — intent-bound user entry:
  Permit2 `permitWitnessTransferFrom` with `witness = keccak256(splits)`.
- Trust model = router: stateless, no owner, permissionless —
  **never park funds in it across transactions**.

## The flows re-proven here

![The four flows](docs/flow-diagrams.jpg)

Every split and every deposit now happens in `SF.run`; the swap venue only
swaps and delivers to an address (that's the entire venue contract surface —
0x-swappable). Two structural wins along the way:

- **user-eth flows became ONE direct `SF.run{value}` call** — no Multicall3:
  a native hook leg carries its amount as `msg.value` straight into
  `router.execute` (the UR rejects plain ETH sends, so value must ride with
  the call), and the next TokenSplit distributes the swap output.
- Flow 3's split is **live-exact bips of the actual output** — computed by SF
  on its real balance, venue-agnostic.

## Execution shapes, cell by cell

`X` = the user's input; `▸amount◂` = patched into the calldata by SF at run
time; hooks marked with `→` carry the leg's amount (calldata patch for ERC-20,
`msg.value` for native).

### Flow 1 — all in → swap → deposit full output

**gasless** (relayer's Calibur batch; user signed EIP-3009 only):
```
Calibur batch: [
  USDC.receiveWithAuthorization(user → executor, X),
  USDC.transfer(router, X),
  router.execute( swap USDC→WETH, recipient = SF ),
  SF.run([ { WETH, [ 100% hook → depositERC20(id, WETH, receiver, ▸amount◂) ] } ])
]
```
**user-erc20** (ONE direct SF.runWithPermit tx — witness = keccak256(splits),
public-mempool-safe):
```
SF.runWithPermit(permit{USDC, X}, user, splits, sig) where splits = [
  split[0] = { USDC, [ 100% → router (plain),
                       call-only → router.execute(swap USDC→WETH → SF) ] },
  split[1] = { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] }
]
```
**user-eth** (ONE direct SF call):
```
SF.run{value: X}([
  split[0] = { native, [ 100% hook → router.execute{value}(WRAP_ETH, swap → SF) ] },
  split[1] = { USDC,   [ 100% hook → depositERC20(id, USDC, receiver, ▸amount◂) ] }
])
```

### Flow 2 — SF splits input (exact fee); venue delivers to user

**gasless**:
```
Calibur batch: [
  USDC.receiveWithAuthorization(user → executor, X),
  USDC.transfer(SF, X),
  SF.run([ { USDC, [ 12.34% → feeEOA, remainder → router ] } ]),
  router.execute( swap CONTRACT_BALANCE → recipient = user )
]
```
**user-erc20** (ONE direct SF.runWithPermit tx, public-mempool-safe):
```
SF.runWithPermit(permit{USDC, X}, user, splits, sig) where splits = [
  { USDC, [ 12.34% → feeEOA, remainder → router (plain),
            call-only → router.execute(swap → user) ] }
]
```
**user-eth** (ONE direct SF call — the remainder leg IS the swap):
```
SF.run{value: X}([
  { native, [ 12.34% → feeEOA,
              remainder hook → router.execute{value}(WRAP_ETH, swap → user) ] }
])
```

### Flow 3 — swap all → SF splits the ACTUAL output

**gasless**:
```
Calibur batch: [
  USDC.receiveWithAuthorization(user → executor, X),
  USDC.transfer(router, X),
  router.execute( swap USDC→WETH, recipient = SF ),
  SF.run([ { WETH, [ 12.34% → feeEOA, remainder → user ] } ])   // live-exact bips
]
```
**user-erc20** (ONE direct SF.runWithPermit tx, public-mempool-safe):
```
SF.runWithPermit(permit{USDC, X}, user, splits, sig) where splits = [
  split[0] = { USDC, [ 100% → router (plain),
                       call-only → router.execute(swap → SF) ] },
  split[1] = { WETH, [ 12.34% → feeEOA, remainder → user ] }   // live-exact bips
]
```
**user-eth** (ONE direct SF call — split[0]'s hook produces split[1]'s balance):
```
SF.run{value: X}([
  split[0] = { native, [ 100% hook → router.execute{value}(WRAP_ETH, swap → SF) ] },
  split[1] = { USDC,   [ 12.34% → feeEOA, remainder → user ] }
])
```

### Flow 4 — SF splits input (fee); venue swaps rest → SF deposits full output

**gasless**:
```
Calibur batch: [
  USDC.receiveWithAuthorization(user → executor, X),
  USDC.transfer(SF, X),
  SF.run([ { USDC, [ 12.34% → feeEOA, remainder → router ] } ]),
  router.execute( swap → SF ),
  SF.run([ { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] } ])
]
```
**user-erc20** (ONE direct SF.runWithPermit tx, public-mempool-safe):
```
SF.runWithPermit(permit{USDC, X}, user, splits, sig) where splits = [
  split[0] = { USDC, [ 12.34% → feeEOA, remainder → router (plain),
                       call-only → router.execute(swap → SF) ] },
  split[1] = { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] }
]
```
**user-eth** (ONE direct SF call):
```
SF.run{value: X}([
  { native, [ 12.34% → feeEOA,
              remainder hook → router.execute{value}(WRAP_ETH, swap → SF) ] },
  { USDC,   [ 100% hook → depositERC20(id, USDC, receiver, ▸amount◂) ] }
])
```

### Native deposit demo — dynamic msg.value into depositNative

```
Calibur batch: [
  USDC.receiveWithAuthorization(user → executor, X),
  USDC.transfer(router, X),
  router.execute( swap USDC→WETH → router, UNWRAP_WETH → native ETH → SF ),
  SF.run([ { native, [ 100% hook → depositNative{value: ▸amount◂}(id, receiver) ] } ])
]
```

## Security: user-sent ERC-20 flows are mempool-safe (intent-bound)

On this branch **every** user-erc20 flow (1–4) uses the Multicall3 + in-batch
EIP-2612 permit shape, so this caveat now covers all of them (on the main
branch it applied only to flows 1 & 4).

**✅ RESOLVED — the intent-bound `runWithPermit` closes this entirely.** The
earlier version of this branch pulled the user's ERC-20 via Multicall3 + a bare
EIP-2612 permit, which was front-runnable on a public mempool (the permit was
bound only to `spender = Multicall3`, which anyone can drive) and therefore
required MEV-protected submission on mainnet. That is gone. All user-erc20
flows now use `SF.runWithPermit`, where the user's Permit2
`permitWitnessTransferFrom` signature commits to
`witness = keccak256(abi.encode(splits))` — the entire payout plan.

**Why it's now public-mempool-safe with no submission assumption:** a
front-runner who copies the pending signature is forced into your exact intent —
- the funds can only go to the SplitForwarder (`transferDetails.to` is
  hardcoded to `address(this)` in `runWithPermit`, not caller-chosen);
- the splits are pinned by the witness — change any recipient, bips, or hook
  and the witness changes, so Permit2's `InvalidSigner` rejects the signature;
- so the *only* thing a replayer can do is execute the user's exact flow, at
  their own gas expense.

**Proven on-chain:** `testFork_Intent_AlteredSplitsReplayReverts` — an attacker
replays a valid signature with a malicious "100% → me" split; Permit2 reverts,
user funds untouched, attacker gets nothing.

The one residual (unchanged, and true of any signature scheme): a leaked
signature for the *honest* plan can be submitted by anyone — but doing so only
executes what the user authorized, to the recipients the user chose.

## The 13 proven transactions (original depository `0xbc51…D0b4`)

user-erc20 = ONE direct `SF.runWithPermit` tx from the user (public-mempool-safe);
user-eth = ONE direct `SF.run{value}` tx.

| Flow | gasless | user-erc20 (intent-bound) | user-eth |
|---|---|---|---|
| **1** all → swap → deposit full output | [`0x4be760ab…`](https://sepolia.etherscan.io/tx/0x4be760ab001369c970f60ec8f7f4748fb4803111d16f51eb5033f0c5d04f1583) 248,728 | [`0xea7a2381…`](https://sepolia.etherscan.io/tx/0xea7a2381f466ace7c0ea8e1a2111eb7a2ea27c2b3c2c29a8ae8b47d93fa258fa) 256,776 | [`0xadb8e676…`](https://sepolia.etherscan.io/tx/0xadb8e676b2c2592fd20afa45163ca075591126105246ee3f31daf552bb60f818) 206,374 |
| **2** SF splits input (exact fee); venue → user | [`0x1db4e92d…`](https://sepolia.etherscan.io/tx/0x1db4e92da221ac8b9a526014274fd0da6c9cdecdfa31a2f4eb6355f65e7c4123) 227,870 | [`0x7ba422b9…`](https://sepolia.etherscan.io/tx/0x7ba422b9b5a202c86b40fb025d1bd439ea684ac21521e4dcfb88a6c42404f7fe) 214,262 | [`0xd9a3f03b…`](https://sepolia.etherscan.io/tx/0xd9a3f03b6f057c849032990b2c4780455bc3a3fa9f92757d26c59e20ec78a79a) 152,707 |
| **3** swap all → SF splits ACTUAL output | [`0x584f7623…`](https://sepolia.etherscan.io/tx/0x584f7623b23a8f7e0cf2ccd26495784bed9b88941d2c1ca91a6e1d95fbcf1662) 223,356 | [`0x5a9fc921…`](https://sepolia.etherscan.io/tx/0x5a9fc921158b1a574ef6db8e623a90a54a20a42773bc0586cb2909e7850d583f) 231,960 | [`0xc7293a70…`](https://sepolia.etherscan.io/tx/0xc7293a70c9127d6462459146ac72245d1d4416a88444f05e502cf2c49063db09) 183,091 |
| **4** SF splits input; venue → SF deposits full output | [`0xec67b14a…`](https://sepolia.etherscan.io/tx/0xec67b14aa95e38516bbe85aaaadf36bf2a1503786787b907bd5e18f593d75ecb) 298,249 | [`0x59fd3a71…`](https://sepolia.etherscan.io/tx/0x59fd3a713da8a8abc184e62e4c89eb79fe1eee8636a24b9854873cd127b91e0a) 271,855 | [`0xcc46f387…`](https://sepolia.etherscan.io/tx/0xcc46f38759b18544902f8ccc282e57a68def9b58a66283fae6864f21c4248976) 212,820 |

**Native dynamic deposit** — the capability the extended depository
*fundamentally cannot offer* (native amounts must ride as `msg.value`; no
contract can pull ETH from its caller):
swap → `UNWRAP_WETH` → native ETH to SF → `depositNative` with **dynamic
msg.value** → `Deposited(id, address(0), receiver, amount)`:
[`0xe496f555…`](https://sepolia.etherscan.io/tx/0xe496f555e160b06b8e9457cf19448f82c3944563e63ce4c21ea3100ead0c6b09) 243,237.

Audited after all 13: SplitForwarder and router at **exactly 0** in
ETH/USDC/WETH.

## Add-on: EIP-2612 self-submit (`permitAndRun`) — no Permit2, no approve

For **permit-capable tokens in the with-gas (user-pays) mode**, `permitAndRun`
removes the one-time `approve(Permit2)` entirely: the user signs a native
EIP-2612 `permit(user, SF, value)` and calls
`SF.permitAndRun(token, value, deadline, v, r, s, splits)` directly.

Safe on a public mempool **without a witness** — the binding is structural:
the pull is `transferFrom(msg.sender, …)`, so the permit owner is forced to the
caller. A replayer calling with the user's signature does `permit(attacker, …)`
(fails to recover the user's sig → caught), then pulls from *themselves*. Proven:
`testFork_Permit2612_ReplayCannotDrainUser`.

Selected with `ERC20_AUTH=2612` (default `permit2`). Proven on Sepolia
(sender = the payer, USDC's native permit, Permit2 never touched):

| Flow | user-erc20 · `ERC20_AUTH=2612` |
|---|---|
| **1** all → swap → deposit | [`0x80a7637b…`](https://sepolia.etherscan.io/tx/0x80a7637b50af0a4065c261fa5f5ec4a62689ea7442e6de11a7e8d1f81d3e23fe) 255,308 |
| **4** fee → EOA + swap → deposit | [`0xeff12e65…`](https://sepolia.etherscan.io/tx/0xeff12e65b4ec19f98ef51df07c800c2b7365adf7e8a9d2020d5147f6e6e953e4) 269,810 |

(Direct `SF.permitAndRun` calls — selector `0x4fe50e40`; SF ends at 0.)

## Gas — the price of venue independence

user-erc20 and user-eth are now ONE self-contained tx each (no Multicall3, no
outer batch). Roughly, per flow: gasless ~225–298k, user-erc20 ~214–272k,
user-eth ~153–213k. The overhead vs the main branch (extended depository +
UR-native `PAY_PORTION`/`SWEEP`) is the SF hop(s) — an extra external call,
`balanceOf` reads, approve set/reset per ERC-20 hook, and transfers the UR
previously did in-place — on the order of **+15–45k per flow**. That is the
cost of (a) an untouched depository, (b) venue-independence (swap in 0x with
zero contract changes), and (c) mempool-safe user-sent ERC-20 with no MEV
assumption.

## Trade-off summary vs the main branch

| | Main branch (`depositERC20All` + UR commands) | This branch (`SplitForwarder`) |
|---|---|---|
| Depository | modified/redeployed | **100% original** |
| Venue coupling | splits depend on UR `PAY_PORTION`/`SWEEP` | **any venue that delivers to an address (0x-ready)** |
| Native dynamic deposit | ❌ impossible | ✅ proven |
| Multi-token + native in one payout call | ❌ | ✅ |
| user-eth entry | Multicall3 / router | **one direct SF call** |
| user-erc20 entry | router-only (2&3) / Multicall3+permit (1&4, **needs private submission**) | **one direct `SF.runWithPermit` — intent-bound, mempool-safe, NO MEV assumption** |
| Gas | baseline | +15k … +45k per flow |
| Custom code | 1 function in the depository | 1 standalone ~230-line contract |

**Conclusion:** if 0x (or any non-Uniswap venue) is on the roadmap or the
depository must stay untouched, the SplitForwarder branch is the shape to ship —
you pay ~+15–45k gas per flow; in exchange the entire payout logic lives in one
audited-once periphery, the venue becomes a plug-in, native dynamic deposits
work, and user-sent ERC-20 flows are safe on a public mempool with **no
MEV-protected-submission requirement** (the intent-bound `runWithPermit`
supersedes the earlier Multicall3+permit caveat entirely).
