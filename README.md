# Bransfer flows — gasless & user-sent DeFi deposits (Sepolia PoC)

Four payment flows × three funding modes = **12 proven on-chain transactions**
(+1 bonus), all sharing the same guarantees:

- **atomic** — one transaction per flow; any leg reverting rolls back everything
  (a gasless user's signature nonce is never consumed on failure);
- **zero dust** — every intermediary (Universal Router, Multicall3, the
  relayer's executor) exits every transaction at exactly 0;
- **exact-in swaps only** — the user sends what they want; quoted floors are
  slippage *revert guards*, never amount-shapers;
- **no orchestration contracts** — the only contract of ours is the
  [LayerswapDepository](https://sepolia.etherscan.io/address/0x4fFFC89c52dD080d1eEEc3Ccd546602c0f1720E8#code)
  (original Layerswap contract + one added function, `depositERC20All`, which
  forwards the **caller's whole balance read at run time** — the primitive that
  makes fully-dynamic deposits possible). Everything else is public
  infrastructure: Uniswap Universal Router, Permit2, Multicall3, WETH9.

## The proven matrix

The four flows, top to bottom = Flow 1 → Flow 4 (same order as the table rows):

![The four flows: 1) user → uniswap → depository; 2) user → fee EOA + uniswap → value to user; 3) user → uniswap → value to user + fee EOA; 4) user → fee EOA + uniswap → depository](docs/flow-diagrams.jpg)

| Flow | gasless (relayer pays) | user-sent ERC-20 | user-sent ETH |
|---|---|---|---|
| **1** all in → swap → **depository** (fee on destination chain) | [`0xe98818d8…`](https://sepolia.etherscan.io/tx/0xe98818d8d41f0a59ba7832024c25557211a42e267e2c0a4cef5d3e2a7f105159) 227,706 | [`0x1868fa68…`](https://sepolia.etherscan.io/tx/0x1868fa68e2f2d2b8b1589fe927c9b3e495324c418c1224bc0cbc2ce8e3386756) 223,291 | [`0x473ba841…`](https://sepolia.etherscan.io/tx/0x473ba8412e25058dd4edd502e9ccd9f730f81026de7592b01a6c13dd4453f60c) 191,296 |
| **2** fee (bips of input) → EOA; rest → swap → **user** | [`0x41db0488…`](https://sepolia.etherscan.io/tx/0x41db0488ad97a9f2e062ec24b9c43568d6160e980c6dd776c45c28e05ff35d91) 194,166 | [`0x72dbcf29…`](https://sepolia.etherscan.io/tx/0x72dbcf29f851de8b30c3b716d375b494b54d48ebf576ac41b28ab1970c2bc930) 172,097 | [`0x31648d26…`](https://sepolia.etherscan.io/tx/0x31648d26400abfd1035b5e1567db96468a4b1c75a25ba82375d365f270119db0) 127,146 |
| **3** swap all → **live-exact split**: user + fee EOA | [`0x281cb73c…`](https://sepolia.etherscan.io/tx/0x281cb73c47ef0000651995a445ddfc3d43a0e95b8c74e7f730798dcce4d604c9) 208,168 | [`0x8e41563e…`](https://sepolia.etherscan.io/tx/0x8e41563e9eccce0688f6dddf7676de02cce23cf85f180e79b94d0ba8cf4edb5a) 159,627 | [`0xfc784921…`](https://sepolia.etherscan.io/tx/0xfc78492100ceba3a4331b1384c8a29b4e9f35166a4a2457e86b0aaf78dc7a70d) 151,793 |
| **4** fee (bips of input) → EOA; rest → swap → **depository** | [`0x8a980f4d…`](https://sepolia.etherscan.io/tx/0x8a980f4d1325dc5a01ecfc6bda6ac2b16d1ac1f917b592aec9880c00c01de057) 252,220 | [`0x0b0afe85…`](https://sepolia.etherscan.io/tx/0x0b0afe854d172af24f5e8343998c084ea51cc50984c7a9f65fd7c0cdd1629356) 235,191 | [`0xb23b075d…`](https://sepolia.etherscan.io/tx/0xb23b075d339b832585387874b3467cc7eb76016cc269f5af19cbedeb6e080120) 200,614 |

**Bonus** — plain-token gasless (WETH has **no** permit function → Permit2
SignatureTransfer): [`0x7acf042f…`](https://sepolia.etherscan.io/tx/0x7acf042f6f2c191b6aadd3e9292ddb8b7c92b3c0cb6cc8de4f09502a9c5f05e1) 218,329.

Demo parameters: 10 USDC / 0.002 ETH in, fee = 12.34% (`FEE_BPS=1234` — any
bips works), ERC-20 flows swap USDC→WETH, ETH flows wrap and swap WETH→USDC.

## Addresses (Sepolia)

| | Address |
|---|---|
| USDC (Circle: EIP-3009 **and** EIP-2612) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Calibur singleton (EIP-7702 target) | `0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00` |
| **LayerswapDepository (ours, verified, `depositERC20All`)** | [`0x4fFFC89c52dD080d1eEEc3Ccd546602c0f1720E8`](https://sepolia.etherscan.io/address/0x4fFFC89c52dD080d1eEEc3Ccd546602c0f1720E8#code) |
| Uniswap Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| Uniswap QuoterV2 (off-chain floors) | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| Multicall3 (canonical) | `0xcA11bde05977b3631167028862bE2a173976CA11` |
| WETH9 (canonical, the "plain token" demo) | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

> Requires the **Prague** EVM (EIP-7702) — set in `foundry.toml`.

## Roles & trust model

| Role | Account | Signs | Pays gas |
|---|---|---|---|
| **User / payer** | plain EOA — **never** 7702-delegated | gasless: 1 off-chain authorization per flow; user-sent: their own tx | only in user-sent modes |
| **Relayer / executor** | EOA delegated to Calibur (EIP-7702) | the tx (gasless modes) | gasless modes |
| **Fee EOA / receiver** | plain EOAs | nothing | never |

The executor is pass-through only — it holds 0 before and after every flow, so
even standing approvals have nothing to drain.

## The three funding modes

**`gasless`** — the user signs one off-chain authorization; the relayer's
Calibur account runs an atomic ERC-7821 batch and pays all gas. Inbound per
token type: **USDC** → EIP-3009 `receiveWithAuthorization` (bound to
`msg.sender == to` = our executor); **EIP-2612 tokens** → permit +
transferFrom; **any plain token** → Permit2 `permitTransferFrom` with
**spender = executor** (one-time `approve(Permit2)` tx per token, then
signature-only forever — see the bonus tx).

**`user-erc20`** — the user sends ONE tx themselves. Flows 2 & 3 (no depository
leg) go **straight through the Universal Router** (`PERMIT2_PERMIT` in-router;
the permit binds to the router's `msg.sender`, so it's **public-mempool-safe**).
Flows 1 & 4 (depository leg) go through **Multicall3 with an in-batch EIP-2612
permit** — `permit` is `msg.sender`-agnostic, so the allowance is created and
consumed inside the user's own atomic tx. ⚠️ **On mainnet this shape REQUIRES
MEV-protected submission** (Flashbots Protect / MEV Blocker): in a public
mempool the permit signature is visible and bound only to spender = Multicall3,
which anyone can drive. The permit leg uses `allowFailure=true` so a
front-run/replayed permit (nonce grief) cannot brick the batch.

**`user-eth`** — the user sends ONE tx with native ETH (nothing can pull ETH
from a plain EOA by signature, so gasless native inbound doesn't exist —
that's a protocol fact, not a design gap). Flows 2 & 3: router-only
(`msg.value` → fee `TRANSFER` → `WRAP_ETH` → swap). Flows 1 & 4: Multicall3
value-legs.

## The four flows

**Flow 1 — all in → swap → depository.** The full input swaps exact-in; the
router pays the output to the *collector* (executor in gasless, Multicall3 in
user-sent); the collector runs `approve(max)` → `depositERC20All` →
`approve(0)`. The **entire dynamic output** is deposited with a `Deposited`
event. Fee is charged on the destination chain, not here.

**Flow 2 — split first: fee → EOA, rest → swap → user.** Fee is an **exact**
bips cut of the known input; the swap output goes straight to the user (swap
`recipient` = user — no intermediate hop at all).

**Flow 3 — swap all → split output: user + fee EOA.** Both payout legs are
EOAs, so the split is **live-exact** on the actual output: `PAY_PORTION`
(fee bips of the real balance) + `SWEEP` (every remaining wei to the user).

**Flow 4 — split first: fee → EOA, rest → swap → depository.** Exact fee from
the input, then the Flow-1 tail: the full dynamic output is deposited.

## Security notes

- **EIP-3009 checklist (gasless):** only accept signatures whose `to` is your
  executor; use `receiveWithAuthorization` (enforces `msg.sender == to`);
  verify recovery against USDC's live `DOMAIN_SEPARATOR()`; check
  `authorizationState` (single-use nonce); dry-run the batch before
  broadcasting. A leaked signature is unusable by anyone else, and atomicity
  means failure never consumes the nonce.
- **Permit2 spender binding:** gasless plain-token signatures bind
  **spender = executor** — same safety property as EIP-3009. Never sign
  Permit2/2612 messages with a public contract as spender unless the tx is
  privately submitted (the Flow 1/4 user-erc20 caveat above).
- **Multicall3 side effect:** `depositERC20All` from Multicall3 deposits MC3's
  *whole* balance of that token — including any stranded tokens strangers left
  in the public contract. They ride into the deposit (receiver gains). Never
  park funds in MC3/the router between transactions.
- **Why an allowance to Multicall3 is never safe** (and why flows 1 & 4 use an
  in-batch permit instead): MC3 executes arbitrary calldata for anyone, so a
  standing allowance to it belongs to the whole world.

## Run them yourself

```bash
cp .env.example .env    # fill keys; see .env.example comments
set -a; source .env; set +a; export PRIVATE_KEY=$OPERATOR_PRIVATE_KEY

# one-time setup:
forge script script/DeployDepository.s.sol:DeployDepositoryScript --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vv < /dev/null
forge script script/EnableDelegation.s.sol:EnableDelegation --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv   # relayer -> Calibur
# user-erc20 flows 2&3 + bonus need one-time approvals from the USER's key:
#   cast send $USDC_SEPOLIA "approve(address,uint256)" 0x000000000022D473030F116dDEE9F6B43aC78BA3 $(cast max-uint) --private-key $USER_PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# any cell of the matrix (drop --broadcast to simulate):
FUNDING_MODE=gasless    forge script script/Flow1.s.sol:Flow1Script --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
FUNDING_MODE=user-erc20 forge script script/Flow3.s.sol:Flow3Script --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
FUNDING_MODE=user-eth   forge script script/Flow4.s.sol:Flow4Script --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
```

Key env: `FUNDING_MODE`, `AMOUNT_IN` (USDC units), `AMOUNT_ETH` (wei),
`FEE_BPS`, `SLIPPAGE_BPS`, plus the addresses/keys in `.env.example`.

## Tests

```bash
forge test                              # 13 local (base deposit flow)
forge test --fork-url $SEPOLIA_RPC_URL  # + 14 fork tests that drive the ACTUAL
                                        #   flow scripts in every mode (27 total)
```

The fork tests execute `Flow1..Flow4 + BonusPermit2Flow` end-to-end per funding
mode against real USDC/router/Permit2/Multicall3/depository, asserting exact
fees, full-output deposits, live-exact splits, the zero-dust invariant, and
atomicity (paused depository → user funds untouched, nonce unused).

## Layout

```
src/LayerswapDepository.sol          # original Layerswap contract + depositERC20All
src/CaliburDepositBatch.sol          # pure lib for the base (no-swap) deposit flow
src/interfaces/*                     # IERC7821(+Call), IERC20, IERC3009USDC, IERC20Permit,
                                     #   IPermit2, IWETH9, ILayerswapDepository, IUniversalRouter, IQuoterV2
script/FlowBase.s.sol                # shared: config, signing (3009/2612/Permit2), program builders
script/Flow1.s.sol .. Flow4.s.sol    # the matrix (FUNDING_MODE selects the cell)
script/BonusPermit2Flow.s.sol        # plain-token gasless inbound (Permit2)
script/DeployDepository.s.sol        # deploy + whitelist our depository
script/EnableDelegation.s.sol        # EIP-7702 enable (relayer -> Calibur)
script/DisableDelegation.s.sol       # EIP-7702 disable
script/ApproveDepository.s.sol       # optional: cheaper 2-call base batch
script/CaliburDeposit.s.sol          # base flow: gasless USDC -> depository, no swap
script/SignReceiveAuthorization.s.sol# optional: sign EIP-3009 out-of-band
test/CaliburDepositLocal.t.sol       # base flow unit tests (mock USDC/executor)
test/CaliburDepositSepoliaFork.t.sol # base flow on real Sepolia state
test/FlowsSepoliaFork.t.sol          # the matrix: 14 end-to-end fork tests
```

## History

Earlier iterations of this repo proved the building blocks separately —
router-native swap chains with floor-based deposits (`0x74fb71b5…`,
`0xbf22f0ad…`), zero-dust v2 flows incl. a real Aave v3 supply/withdraw
sandwich (`0x95378e76…`, `0x20c49f67…`), native dual-EOA payouts
(`0xa50e86d8…`), a generic N-way splitter contract (`0xf3fe4ee3…`, since
removed by design decision), and the first user-invoked Multicall3 flow
(`0x21f1a9d2…`). See git history for the full evolution; the matrix above
supersedes all of them.
