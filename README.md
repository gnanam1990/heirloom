# Heirloom 🗝️

**The wallet that can't be lost. Not to death, not to forgetting, not to thieves.**

Money today assumes its owner is alive, present, and remembers everything. Heirloom makes money **liveness-aware**: lost keys, lost people, lost agents — funds never get stranded.

One mechanism, five problems solved:
- **Forgot your seed phrase** → M-of-N guardian social recovery rotates the vault to a new key. The lock changes, not the house.
- **Death** → cascading beneficiaries claim in order; a non-crypto heir claims via an email link, never sees a seed phrase.
- **Incapacity** → care mode lets a guardian pay *pre-approved addresses only*, within caps — not the keys.
- **Founder-key risk** → org treasuries cascade to a co-founder multisig instead of dying (the QuadrigaCX problem).
- **Dead AI agents** → agent-treasury watchdog returns funds to the operator.

The core primitive is the **liveness ladder**: any activity resets the clock; silence escalates through nag → guardian alert → care mode → claimable. Every configuration change takes a 7-day timelock with owner veto — a thief with your key cannot silently redirect your safety net.

**Status:** early build · Arc testnet · unaudited — do not use with real funds.

> ⚠️ **UNAUDITED TESTNET CODE.** Every contract in `src/` is labelled as such in
> its NatSpec. Nothing here has been audited or externally reviewed. It is
> intended for Arc **testnet** only. Do not send real funds to it.

## Contracts

| Contract | Role |
|---|---|
| [`LivenessLadder.sol`](src/LivenessLadder.sol) | Pure library: silence → rung. No storage, no keeper. |
| [`ConfigGuard.sol`](src/ConfigGuard.sol) | `propose → 7-day timelock → execute`, owner-vetoable. No direct setters. |
| [`RecoveryModule.sol`](src/RecoveryModule.sol) | M-of-N guardian key rotation. Guardians cannot move funds. |
| [`ClaimsModule.sol`](src/ClaimsModule.sol) | Ordered heirs, claim windows, cascade, terminal charity sink. |
| [`HeirloomVault.sol`](src/HeirloomVault.sol) | Holds USDC; wires the above; care mode with per-category payee allowlists. |

### The six invariants, and where they are pinned

| # | Invariant | Tests |
|---|---|---|
| 1 | Any owner signature resets the ladder to Active from any state | `LivenessLadder.t.sol`, `Vault.t.sol` |
| 2 | Every config mutation is proposed, delayed 7 days, and vetoable. No direct setters | `ConfigGuard.t.sol` |
| 3 | Guardians can only propose key rotation — never move funds | `Recovery.t.sol` |
| 4 | Claims pay only pre-registered payees; no free-text destinations | `Claims.t.sol` |
| 5 | Care mode is destination-enforced and amount-capped, revoked instantly by owner activity | `Vault.t.sol`, `CareAllowlist.t.sol` |
| 6 | Funds never dead-end: tiers cascade, the terminal tier never expires | `Claims.t.sol` |

### Stateful invariant testing

The per-function fuzz tests above check one call at a time. `test/invariant/`
additionally drives random **sequences** of calls from every actor at once
(owner, three guardians, care guardian, heirs, a no-rights thief) against a
bounded handler, and asserts the same six properties hold after any ordering —
which is where interaction bugs live.

```
forge test --match-path "test/invariant/*" -vv
```

Defaults are 256 runs x 100 depth (`[invariant]` in `foundry.toml`). Raise for CI
without editing the file:

```
FOUNDRY_INVARIANT_RUNS=1000 FOUNDRY_INVARIANT_DEPTH=250 forge test --match-path "test/invariant/*"
```

The suite prints a coverage summary after each run (deepest rung reached,
rotations, claims, care spends). **Read it.** If a sequence never reaches
`Claimable`, the invariants guarding the claim path passed vacuously.

## Build

Dependencies are git submodules, so clone recursively:

```
git clone --recurse-submodules https://github.com/gnanam1990/heirloom.git
cd heirloom
forge build
forge test
```

If you already cloned without submodules: `forge install`

## Deploy (Arc testnet)

Arc testnet is chain id **5042002**, RPC `https://rpc.testnet.arc.network`.

```
cp .env.example .env
```

Fill in `.env`, then:

```
forge script script/DeployHeirloom.s.sol:DeployHeirloom --rpc-url "$ARC_TESTNET_RPC_URL" --broadcast
```

The deployer key is read from `PRIVATE_KEY` in the environment and is never
written to disk or logged. `.env` is gitignored — use testnet keys only.

The script pre-flights before spending gas: it reads `decimals()` off the
configured USDC and aborts unless it is **6**, rejects any zero-address payee
(Arc reverts on transfers to zero), and rejects an unreachable guardian
threshold.

Source of truth: [`docs/PRD.md`](docs/PRD.md). Build prompt: [`PROMPT.md`](PROMPT.md).
Ambiguities and the conservative readings taken: [`docs/OPEN-QUESTIONS.md`](docs/OPEN-QUESTIONS.md).
