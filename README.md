# swap-split-deposit

**Zero-dust, venue-independent DeFi deposit / swap / split flows** for Sepolia,
built around one stateless periphery contract — `SplitForwarder`.

A user's funds are pulled (gaslessly by signature, or by the user's own tx),
optionally swapped through **any venue that delivers output to an address**
(Uniswap, 0x, Fly/Magpie — the venue is just a call target, not a hardcoded
dependency), then split and deposited into the **original, unmodified Layerswap
depository** — with **zero dust** and **no MEV-protected-RPC requirement**.

Every flow shares the same guarantees:

- **atomic** — one transaction; any leg reverting rolls back everything (a
  gasless user's signature nonce is never consumed on failure);
- **zero dust** — the forwarder asserts a per-token (and always-native) terminal
  zero-balance, and the last split leg takes the arithmetic remainder, so nothing
  can be stranded;
- **exact-in swaps only** — the user sends what they want; quoted floors are
  slippage *revert guards*, never amount-shapers;
- **one small contract** — `SplitForwarder` is stateless, ownerless, holds no
  funds across transactions; everything else is public infrastructure.

## The contract

```solidity
struct Leg        { address target; uint96 shareBps; uint256 amountOffset; bytes data; }
struct TokenSplit { address token; Leg[] legs; }        // token = address(0) → native

function run(TokenSplit[] calldata splits) external payable;
function runWithPermit(IPermit2.PermitTransferFrom permit, address owner,
                       TokenSplit[] calldata splits, bytes calldata sig) external;   // Permit2 witness = keccak256(splits)
function permitAndRun(address token, uint256 value, uint256 deadline,
                      uint8 v, bytes32 r, bytes32 s, TokenSplit[] calldata splits) external;   // EIP-2612 self-submit
```

Splits are processed **sequentially**, so an earlier split's hook (e.g. a swap
paying the forwarder) can produce the balance a later split distributes. Each
leg is either a plain transfer (empty `data`) or a **calldata hook** — the leg's
run-time amount is patched into the template at `amountOffset`
(`NO_SUBSTITUTION` for native hooks, where the amount rides as `msg.value`).
See [ARCHITECTURE.md](ARCHITECTURE.md) for the full mechanics and per-flow
execution shapes.

## The proven matrix — 12 + 1 flows on Sepolia

All on the deployed `SplitForwarder` [`0x28E8…b2FC`](https://sepolia.etherscan.io/address/0x28E815496471724e7DBA95D1a11b014110Cdb2FC#code),
depositing into the **original** depository [`0xbc51…D0b4`](https://sepolia.etherscan.io/address/0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4).
`user-erc20` = one direct `SF.runWithPermit` tx (public-mempool-safe, intent-bound);
`user-eth` = one direct `SF.run{value}` tx.

![The four flows](docs/flow-diagrams.jpg)

| Flow | gasless | user-erc20 (intent-bound) | user-eth |
|---|---|---|---|
| **1** all → swap → deposit full output | [`0xca5cf09f…`](https://sepolia.etherscan.io/tx/0xca5cf09f8dd0c24709a615a7bf523c3931c0b8b4c5d2a09bff3120aa71006fe9) 248,693 | [`0xd6da7659…`](https://sepolia.etherscan.io/tx/0xd6da765931c396d00b9baecd6cd2a7fc049a0282ebee2aeea2d6a9594270ab65) 258,213 | [`0xed683e7e…`](https://sepolia.etherscan.io/tx/0xed683e7eaf5ad74056c1a0d79d6de8c13b55fd08a5f7d7a0c6798793ffa90cd3) 199,474 |
| **2** SF splits input (exact fee); venue → user | [`0x204fd22e…`](https://sepolia.etherscan.io/tx/0x204fd22ef8fd7103e71325fcb03b545ee2f34174707667752dc16427d0334c7d) 234,790 | [`0xb2a9793b…`](https://sepolia.etherscan.io/tx/0xb2a9793b6b82b3b11b5fdfd17b1366c08c8c10f2efbb9a783cbe4af57328d183) 216,092 | [`0x460b630b…`](https://sepolia.etherscan.io/tx/0x460b630bb7df53ba7f5feb42de89d447ced65f106d8c6e253cb6a8182f9ec286) 161,436 |
| **3** swap all → SF splits ACTUAL output | [`0xa452e244…`](https://sepolia.etherscan.io/tx/0xa452e2447ed94dfa7fa3161400d995c51cd2ff2b33b4c22d0b273b19204295e6) 223,340 | [`0xf4100c0b…`](https://sepolia.etherscan.io/tx/0xf4100c0b662237d596893564d99d89c4a17fca3d6f544c944410df00c485d94f) 233,432 | [`0xc8f76971…`](https://sepolia.etherscan.io/tx/0xc8f76971c75441e68162fc353eb8bebc042c68ecece7b3bcdb91d42c5dcb285c) 174,510 |
| **4** SF splits input; venue → SF deposits full output | [`0xa7354c86…`](https://sepolia.etherscan.io/tx/0xa7354c86f6e46614090e4acb18100988af518ade465cf728c8ef582c0d9cf4a1) 298,271 | [`0xd551cea5…`](https://sepolia.etherscan.io/tx/0xd551cea5577de8c7330b239831612c71ea3b2f7ae6a518aefc63936ac5b00c6a) 273,328 | [`0x0bb1ee4b…`](https://sepolia.etherscan.io/tx/0x0bb1ee4b4d35bb4f07870d3697da6c21a4c58543fd5954c82d7ab5bf34e2dad6) 212,884 |

**Native dynamic deposit** — swap → `UNWRAP_WETH` → native ETH to SF →
`depositNative` with **dynamic `msg.value`**:
[`0x6ff9caf5…`](https://sepolia.etherscan.io/tx/0x6ff9caf5dc5078e57d158b2e3be16df77a31823c69b23e054a1a841d3f75486c) 243,237.

**Bonus** — `permitAndRun` (EIP-2612 self-submit, no Permit2, no approve),
selector `0x4fe50e40`, sender = the payer:
Flow 1 [`0x147a06e6…`](https://sepolia.etherscan.io/tx/0x147a06e6fabf9ce0864b29059871e08b5f8a1727b465a27e987ad22ab10063be) 256,701 ·
Flow 4 [`0x6751533b…`](https://sepolia.etherscan.io/tx/0x6751533b985f69b29b3bdea939210f8e5628c3dc01a26aeded84272bc3f6fa4e) 271,212.

Demo parameters: 10 USDC / 0.002 ETH in, fee = 12.34% (`FEE_BPS=1234` — any bips
works). ERC-20 flows swap USDC→WETH; ETH flows wrap and swap WETH→USDC.

## Venue independence (proven against real routers)

The swap step is a hook leg, so any venue that swaps and delivers to an address
drops in with **no contract change** (the venue is the leg's `target`, never a
hardcoded constant). Proven on Ethereum-mainnet forks with **no mocks**:

- **Uniswap** — live on Sepolia (the matrix above).
- **0x** — `test/ZeroxMainnetFork.t.sol`: real Settler / AllowanceHolder + live
  0x Swap API; plus a mixed 0x-and-Uniswap swap in a single `run()`.
- **Fly (Magpie)** — `test/FlyMainnetFork.t.sol`: real MagpieRouterV3 + live
  (keyless) Fly Swap API.

## Addresses (Sepolia)

| | Address |
|---|---|
| **SplitForwarder** (ours, verified — `runWithPermit` + `permitAndRun`) | [`0x28E815496471724e7DBA95D1a11b014110Cdb2FC`](https://sepolia.etherscan.io/address/0x28E815496471724e7DBA95D1a11b014110Cdb2FC#code) |
| **Layerswap depository** (original, unmodified — deposit target) | [`0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4`](https://sepolia.etherscan.io/address/0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4) |
| USDC (Circle: EIP-3009 **and** EIP-2612) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |
| Calibur singleton (EIP-7702 target, gasless relayer only) | `0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00` |
| Uniswap Universal Router | `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` |
| Uniswap QuoterV2 (off-chain floors) | `0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |
| WETH9 (canonical, the "plain token" demo) | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |

> Requires the **Prague** EVM (EIP-7702) — set in `foundry.toml`.

## The three funding modes

- **`gasless`** — the user signs one off-chain authorization; the relayer's
  Calibur (EIP-7702) account runs an atomic ERC-7821 batch and pays all gas.
  Inbound: **USDC** → EIP-3009 `receiveWithAuthorization` (bound to
  `msg.sender == to` = the executor); **any plain token** → Permit2
  `permitTransferFrom` with **spender = executor** (one-time `approve(Permit2)`
  per token, then signature-only — see `BonusPermit2Flow`).
- **`user-erc20`** — the user sends ONE tx: `SF.runWithPermit` (Permit2
  `permitWitnessTransferFrom`, witness = `keccak256(abi.encode(splits))`), or
  `SF.permitAndRun` (`ERC20_AUTH=2612`, native EIP-2612, no Permit2/approve).
  Both are **public-mempool-safe with no submission assumptions** — a replayer
  is forced into the user's exact intent (see [ARCHITECTURE.md](ARCHITECTURE.md)).
- **`user-eth`** — the user sends ONE tx with native ETH: `SF.run{value}` (a
  native hook carries the amount as `msg.value` into the swap venue). Gasless
  native inbound doesn't exist — no signature can move ETH from a plain EOA.

For a per-token decision guide, see [docs/CHOOSING-A-FLOW.md](docs/CHOOSING-A-FLOW.md)
and [docs/TOKEN-SUPPORT.md](docs/TOKEN-SUPPORT.md).

## Run them yourself

```bash
cp .env.example .env    # fill keys; see .env.example comments
set -a; source .env; set +a; export PRIVATE_KEY=$OPERATOR_PRIVATE_KEY

# one-time setup:
forge script script/DeploySplitForwarder.s.sol:DeploySplitForwarderScript --rpc-url $SEPOLIA_RPC_URL --broadcast --verify -vv < /dev/null
forge script script/EnableDelegation.s.sol:EnableDelegation --rpc-url $SEPOLIA_RPC_URL --broadcast -vvv   # relayer → Calibur
# user-erc20 (permit2) + bonus need one-time approvals from the USER's key:
#   cast send $USDC_SEPOLIA "approve(address,uint256)" 0x000000000022D473030F116dDEE9F6B43aC78BA3 $(cast max-uint) --private-key $USER_PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# any cell of the matrix (drop --broadcast to simulate):
FUNDING_MODE=gasless                     forge script script/Flow1.s.sol:Flow1Script --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
FUNDING_MODE=user-erc20 ERC20_AUTH=2612  forge script script/Flow3.s.sol:Flow3Script --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
FUNDING_MODE=user-eth                    forge script script/Flow4.s.sol:Flow4Script --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
```

Key env: `FUNDING_MODE`, `ERC20_AUTH` (`permit2` | `2612`), `AMOUNT_IN` (USDC
units), `AMOUNT_ETH` (wei), `FEE_BPS`, `SLIPPAGE_BPS`, plus the addresses/keys in
`.env.example`.

## Tests

```bash
# Sepolia fork — drives the ACTUAL flow scripts end-to-end, every mode:
forge test --fork-url $SEPOLIA_RPC_URL --match-contract FlowsSepoliaFork -vv

# Real-venue mainnet-fork proofs (no mocks):
export MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com
forge test --ffi --match-contract FlyMainnetFork  -vv          # Fly/Magpie — keyless
forge test --ffi --match-contract ZeroxMainnetFork -vv          # 0x — needs ZEROX_API_KEY
```

`FlowsSepoliaFork` executes `Flow1..Flow4 + BonusPermit2Flow + NativeDepositDemo`
per funding mode against real USDC / router / Permit2 / original depository,
asserting exact fees, full-output deposits, live-exact splits, the zero-dust
invariant, atomicity (paused depository → user funds untouched, nonce unused),
and the intent-bound replay revert.

## Layout

```
src/SplitForwarder.sol           # the one contract: run / runWithPermit / permitAndRun
src/interfaces/*                 # IERC20, IERC20Permit, IERC3009USDC, IERC7821(+Call),
                                 #   IPermit2, IWETH9, ILayerswapDepository, IUniversalRouter, IQuoterV2
script/FlowBase.s.sol            # shared: config, signing (3009 / 2612 / Permit2 witness), split/leg builders
script/Flow1.s.sol .. Flow4.s.sol# the matrix (FUNDING_MODE selects the cell)
script/BonusPermit2Flow.s.sol    # plain-token (WETH) gasless inbound via Permit2
script/NativeDepositDemo.s.sol   # dynamic msg.value → depositNative
script/DeploySplitForwarder.s.sol# deploy the forwarder
script/EnableDelegation.s.sol    # EIP-7702 enable (relayer → Calibur); DisableDelegation.s.sol reverses it
script/{zerox,fly}_quote.sh      # live venue quotes for the mainnet-fork tests (vm.ffi)
test/FlowsSepoliaFork.t.sol      # the matrix, end-to-end on real Sepolia state
test/ZeroxMainnetFork.t.sol      # real 0x Settler swap (+ mixed 0x/Uniswap)
test/FlyMainnetFork.t.sol        # real MagpieRouterV3 swap
test/external/LayerswapDepository.sol  # verbatim copy of the original depository (local test deploy)
test/mocks/MockERC7821Executor.sol     # stands in for the Calibur account in tests
```

## Design & alternative approach

[ARCHITECTURE.md](ARCHITECTURE.md) has the full design: contract mechanics,
per-flow execution shapes, funding-mode matrix, intent-binding security, venue
independence, and the trust model.

An earlier, self-contained **alternative approach** lives on the
`alt/extended-depository-flows` branch: it extends the depository with a
`depositERC20All` function and drives payouts through the Universal Router's
`PAY_PORTION`/`SWEEP` commands (Uniswap-coupled). This branch — `SplitForwarder`,
original depository, venue-independent — is the recommended shape;
[ARCHITECTURE.md](ARCHITECTURE.md) includes the trade-off comparison.
