# CLAUDE.md

Guide for Claude Code (and humans) working in this repo.

## What this repo is

`swap-split-deposit` — zero-dust, venue-independent DeFi deposit / swap / split
flows. A user's funds are pulled (gaslessly by signature, or by the user's own
tx), optionally swapped through **any venue that delivers output to an address**
(Uniswap, 0x, Fly), then split and deposited into the **original, unmodified
Layerswap depository** — atomically, with zero dust, and with no
MEV-protected-RPC requirement.

The only custom contract is `src/SplitForwarder.sol` — stateless, ownerless,
holds no funds across transactions. Everything else is public infrastructure.

Read **README.md** for the overview + proven tx matrix, and **ARCHITECTURE.md**
for the full design (contract mechanics, per-flow execution shapes, security,
venue independence, trust model).

## Build / test / format

Foundry project. Solidity `0.8.29`, **`evm_version = "prague"`** (required —
EIP-7702 type-4 txs; do not change it). Dependencies are git submodules in
`lib/` (`forge install` / `git submodule update --init --recursive` if missing).

```bash
forge build
forge fmt                 # config in foundry.toml [fmt]: line 120, tab 4, no bracket spacing
forge test                # local only; the fork tests self-skip without an RPC

# Sepolia fork — drives the actual flow scripts end-to-end, every funding mode:
forge test --fork-url $SEPOLIA_RPC_URL --match-contract FlowsSepoliaFork -vv

# Real-venue mainnet-fork proofs (no mocks; need --ffi + a mainnet RPC):
export MAINNET_RPC_URL=https://ethereum-rpc.publicnode.com
forge test --ffi --match-contract FlyMainnetFork  -vv       # Fly/Magpie — KEYLESS
forge test --ffi --match-contract ZeroxMainnetFork -vv      # 0x — needs ZEROX_API_KEY
```

`--ffi` lets the venue tests shell out to `script/zerox_quote.sh` /
`script/fly_quote.sh` for a live quote. Fork tests read env via `fs_permissions`.

## Running a flow

Scripts read config from env (see `.env.example`). Copy it to `.env` (gitignored)
and fill keys. Two EOAs: OPERATOR/RELAYER (delegated to Calibur, pays gasless
gas) and a separate USER/PAYER (holds funds, signs).

```bash
set -a; source .env; set +a; export PRIVATE_KEY=$OPERATOR_PRIVATE_KEY
# one-time: DeploySplitForwarder.s.sol, then EnableDelegation.s.sol (relayer → Calibur)
FUNDING_MODE=gasless forge script script/Flow1.s.sol:Flow1Script --rpc-url $SEPOLIA_RPC_URL --broadcast -vv < /dev/null
```

Selectors: `FUNDING_MODE = gasless | user-erc20 | user-eth`; for user-erc20,
`ERC20_AUTH = permit2 (default) | 2612`.

## Architecture in one screen

- **`SplitForwarder`** entrypoints: `run(splits)`, `runWithPermit(permit, owner,
  splits, sig)` (Permit2 witness = `keccak256(abi.encode(splits))`),
  `permitAndRun(token, value, deadline, v, r, s, splits)` (EIP-2612 self-submit).
- **`TokenSplit { token; Leg[] }`**, **`Leg { target; shareBps; amountOffset; data }`**.
  Splits run **sequentially** (an earlier hook can fund a later split). A leg is a
  plain transfer (empty `data`) or a calldata **hook** (amount patched at
  `amountOffset`; `NO_SUBSTITUTION` for native hooks where amount = `msg.value`).
- **Four flows × three funding modes = the matrix** (`script/Flow1..4.s.sol`,
  `FUNDING_MODE` selects the cell). `FlowBase.s.sol` holds shared config, signing
  (EIP-3009 / EIP-2612 / Permit2 witness), and the split/leg builders.
- **Venue = a hook target**, never a hardcoded constant → new venues need zero
  contract change (proven: Uniswap live, 0x + Fly on mainnet forks).

## Invariants — do not break these

- **Zero dust:** `run` asserts a per-token terminal zero-balance (for every token
  named in `splits`) **and always native**; the last leg of each split takes the
  arithmetic remainder. If you add a hook that can output a token, that token
  **must** be named in the plan or the tx reverts (`BalanceNotConsumed`) — and if
  it's *not* named it would be strandable (audit finding I-01).
- **Bips per split sum to exactly 10000**, or revert.
- **Intent-binding / mempool safety:** `runWithPermit` binds the whole plan via a
  Permit2 witness; `permitAndRun` binds `owner = msg.sender`. Never introduce a
  user-sent path whose signature isn't bound to intent — that reintroduces the
  MEV-front-running risk this design removed. Gasless signatures bind
  `spender = executor`.
- **Exact-in only:** quoted floors are slippage revert-guards, never used to shape
  amounts. The user always sends the full amount they intend.
- **The depository stays original** — no on-chain deposit function is added; the
  forwarder does the dynamic-amount work caller-side.

## Key Sepolia addresses

- SplitForwarder (ours, verified): `0x28E815496471724e7DBA95D1a11b014110Cdb2FC`
- Layerswap depository (original, deposit target): `0xbc519fde36D45bF402d6FF40D4968AAf2ad3D0b4`
- USDC (EIP-3009 + EIP-2612): `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238`
- Calibur singleton (EIP-7702, gasless relayer only): `0x000000009B1D0aF20D8C6d0A44e162d11F9b8f00`
- Uniswap Universal Router: `0x3A9D48AB9751398BbFa63ad67599Bb04e4BdF98b` · Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3` · WETH9: `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14`

## Conventions

- Match the surrounding code and keep the existing Natspec density and the
  `interfaces/` split. Note: the codebase uses some hand-wrapping that `forge fmt`
  would collapse, so it is **not** fully `forge fmt`-clean — don't blanket-format
  the repo (it churns the audited, Etherscan-verified `SplitForwarder.sol`); match
  local style instead.
- Do not commit `.env` (gitignored). `.env.example` is the tracked template.
- Fork/venue tests are opt-in (self-skip without an RPC) — keep them that way so
  `forge test` stays green offline.

## Alternative approach

The `alt/extended-depository-flows` branch preserves an earlier, self-contained
approach: it extends the depository with `depositERC20All` and drives payouts via
the Universal Router's `PAY_PORTION`/`SWEEP` (Uniswap-coupled). `main` (this
branch) is the recommended shape. See the trade-off table in ARCHITECTURE.md.
