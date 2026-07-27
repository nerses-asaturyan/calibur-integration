# Experiment: SplitForwarder — untouched depository + venue-independent payouts

**Two questions, both answered yes, all proven on Sepolia:**

1. Can the Layerswap depository stay **100% original** (no `depositERC20All`
   extension) with fully-dynamic, zero-dust deposits — including **native ETH**?
2. Can the payout splitting stop depending on the Universal Router's payment
   commands (`PAY_PORTION`/`SWEEP`), so the whole system works with **any swap
   venue** — 0x Settler included — that can merely *swap and deliver output to
   an address*?

Both are solved by **one** stateless contract:
[`SplitForwarder`](https://sepolia.etherscan.io/address/0x9B93dd9Ac871bFfAb3FeEf16f28174700349017a#code)
(`0x9B93…017a`, verified, ~170 lines).

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
  nothing stays behind.
- Trust model = router/Multicall3: stateless, no owner, permissionless —
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
**user-erc20** (one Multicall3 tx from the user):
```
Multicall3: [
  USDC.permit(user, MC3, X)  (allowFailure = true),
  USDC.transferFrom(user → router, X),
  router.execute( swap → SF ),
  SF.run([ { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] } ])
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
**user-erc20**:
```
Multicall3: [
  USDC.permit(user, MC3, X)  (allowFailure = true),
  USDC.transferFrom(user → SF, X),
  SF.run([ { USDC, [ 12.34% → feeEOA, remainder → router ] } ]),
  router.execute( swap → user )
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
**user-erc20**:
```
Multicall3: [
  USDC.permit(user, MC3, X)  (allowFailure = true),
  USDC.transferFrom(user → router, X),
  router.execute( swap → SF ),
  SF.run([ { WETH, [ 12.34% → feeEOA, remainder → user ] } ])
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
**user-erc20**:
```
Multicall3: [
  USDC.permit(user, MC3, X)  (allowFailure = true),
  USDC.transferFrom(user → SF, X),
  SF.run([ { USDC, [ 12.34% → feeEOA, remainder → router ] } ]),
  router.execute( swap → SF ),
  SF.run([ { WETH, [ 100% hook → depositERC20(…, ▸amount◂) ] } ])
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

## The 13 proven transactions (original depository `0xbc51…D0b4`)

| Flow | gasless | user-erc20 (Multicall3+permit) | user-eth (direct SF call) |
|---|---|---|---|
| **1** all → swap → deposit full output | [`0x189e7cc0…`](https://sepolia.etherscan.io/tx/0x189e7cc01fc9e8f21e9c2f6f461c377f79055a6380d4b194d6078aea054c4828) 248,082 | [`0x1e31d07c…`](https://sepolia.etherscan.io/tx/0x1e31d07cbd4463df66bab99ffb9a0757c1c11f95c8ba210a1dac9822fb43ffb0) 230,033 | [`0xa763a10e…`](https://sepolia.etherscan.io/tx/0xa763a10e029f0d35b73c7a750bde653b32f2f7162abd3321232e12e405424e94) 198,353 |
| **2** SF splits input (exact fee); venue → user | [`0x7f748e52…`](https://sepolia.etherscan.io/tx/0x7f748e52f5948937a0d5f4d36b3fbf31aa2de12f8b768b4c60579cf3a60d5831) 233,652 | [`0xe026710c…`](https://sepolia.etherscan.io/tx/0xe026710ca5b94916a997cae647e29f37d2e25e7e7dad93208e105d2fa0f9c155) 208,709 | [`0xe76ff868…`](https://sepolia.etherscan.io/tx/0xe76ff868e7eaa12a6438ac8f126a1d807b5f959b95661101fb3bad6375bb3ff4) 159,098 |
| **3** swap all → SF splits ACTUAL output | [`0xdc538045…`](https://sepolia.etherscan.io/tx/0xdc538045d3cb3af4143da564d23deea6d69a4a1a132b04b25437c914b2485070) 222,224 | [`0xc32348c4…`](https://sepolia.etherscan.io/tx/0xc32348c49e2fc0e4e7f89d35b189e8a95c787d10e0f00f9f33a746c4f73298c3) 204,186 | [`0x492986b9…`](https://sepolia.etherscan.io/tx/0x492986b9069fb19207ae3bd275e91659d282138c33e25010963c277ac7a62e2e) 171,442 |
| **4** SF splits input; venue → SF deposits full output | [`0x897ab691…`](https://sepolia.etherscan.io/tx/0x897ab691f9c6b73b2f50ac93b08ca17c5faca64eb686f2cebe178855742b7b2f) 296,474 | [`0xacdeedca…`](https://sepolia.etherscan.io/tx/0xacdeedcac8162ead7a355048cf6288e0e5c37acb6ede7ed505e680b57f7e2ab0) 278,382 | [`0xac39c890…`](https://sepolia.etherscan.io/tx/0xac39c8907ae4f4e083658a52deb58f87ad64591efab472ea6b64b5968d9e5b48) 218,162 |

**Native dynamic deposit** — the capability the extended depository
*fundamentally cannot offer* (native amounts must ride as `msg.value`; no
contract can pull ETH from its caller):
swap → `UNWRAP_WETH` → native ETH to SF → `depositNative` with **dynamic
msg.value** → `Deposited(id, address(0), receiver, amount)`:
[`0x171edd7d…`](https://sepolia.etherscan.io/tx/0x171edd7da6b332f5d19038166085858a81eb0da98279e74e38beea8685454d98) 248,711.

Audited after all 13: SplitForwarder and router at **exactly 0** in
ETH/USDC/WETH.

## The price of venue independence (honest gas accounting)

vs the main branch (extended depository + UR-native `PAY_PORTION`/`SWEEP`):

| Flow | gasless | user-erc20 | user-eth |
|---|---|---|---|
| 1 | +20k | +6.7k | +7.1k |
| 2 | +39k | +36.6k | +32.0k |
| 3 | +14.1k | +44.6k | +19.6k |
| 4 | +44.3k | +43.2k | +17.5k |

The overhead is the SF hop(s): an extra external call, `balanceOf` reads,
approve set/reset per ERC-20 hook, and transfers that the UR previously did
in-place. **That's the cost of being able to swap the venue for 0x with zero
contract changes.** Where the deposit already required a collector (flows 1 & 4)
the delta is smallest; where the UR's own payment commands were free (flows
2 & 3 splits) it's ~+35–45k.

## Trade-off summary vs the main branch

| | Main branch (`depositERC20All` + UR commands) | This branch (`SplitForwarder`) |
|---|---|---|
| Depository | modified/redeployed | **100% original** |
| Venue coupling | splits depend on UR `PAY_PORTION`/`SWEEP` | **any venue that delivers to an address (0x-ready)** |
| Native dynamic deposit | ❌ impossible | ✅ proven |
| Multi-token + native in one payout call | ❌ | ✅ |
| user-eth entry | Multicall3 / router | **one direct SF call** |
| user-erc20 flows 2 & 3 | router-only, mempool-safe | Multicall3 + permit — **MEV-protected submission required on mainnet** (the caveat now covers all four flows) |
| Gas | baseline | +7k … +45k per flow |
| Custom code | 1 function in the depository | 1 standalone ~170-line contract |

**Conclusion:** if 0x (or any non-Uniswap venue) is on the roadmap or the
depository must stay untouched, the SplitForwarder branch is the shape to ship —
you pay ~+15–45k gas per flow and extend the private-submission requirement to
all user-sent ERC-20 flows; in exchange the entire payout logic lives in one
audited-once periphery and the venue becomes a plug-in.
