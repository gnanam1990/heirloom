# Deployed addresses — Arc testnet

> ⚠️ **UNAUDITED TESTNET CODE.** Do not send real funds to any address on this
> page. Everything here is Arc **testnet** (chain id `5042002`).

| Field | Value |
|---|---|
| Network | Arc testnet |
| Chain ID | `5042002` |
| RPC | `https://rpc.testnet.arc.network` |
| Explorer | `https://testnet.arcscan.app` |
| USDC (ERC-20 surface, 6dp) | [`0x3600000000000000000000000000000000000000`](https://testnet.arcscan.app/address/0x3600000000000000000000000000000000000000) |
| Deployer | [`0xe51470Bc0C25623320Bc173025e4aa6B8bbd1F09`](https://testnet.arcscan.app/address/0xe51470Bc0C25623320Bc173025e4aa6B8bbd1F09) |
| Deployed | 20 July 2026 |
| Compiler | solc `0.8.26`, optimizer on (200 runs) |

The USDC address was resolved from the docs.arc.io contract-addresses reference
page and then **confirmed on-chain** before deploying: it has bytecode,
`symbol() == "USDC"` and `decimals() == 6`. It was not hardcoded from memory.

---

## Contracts

`HeirloomVault` is the only deployed artifact. `ConfigGuard`, `RecoveryModule`
and `ClaimsModule` are abstract contracts inherited by the vault, and
`LivenessLadder` is an internal library inlined at compile time — none of them
has its own address by design. Keeping the funds and the state machine in one
contract is what lets the vault use plain checks-effects-interactions instead of
cross-contract authorisation.

### 1. Production vault — real ladder

| Field | Value |
|---|---|
| Address | [`0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8`](https://testnet.arcscan.app/address/0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8) |
| Deploy tx | [`0xf451efe7…cfb46cc`](https://testnet.arcscan.app/tx/0xf451efe7d78a734158f76e771d524145144602f4353b8e92f1d402a1ccfb46cc) |
| Block | `52719229` |
| Gas used | `4,230,397` |
| Source verified | ✅ on testnet.arcscan.app |
| Ladder | 90 / 180 / 270 / 365 days (`7776000` / `15552000` / `23328000` / `31536000` s) |
| Config timelock | `604800` s (7 days) |
| Guardians | 3, threshold 2-of-3 |

### 2. Demo vault — **DEMO-ONLY, short durations**

> **This vault is not a safety net.** Its tiers are seconds, not months, so the
> full cascade can be demonstrated on-chain without waiting a year. Anyone can
> walk it to `Claimable` in four minutes and take the funds. It exists purely as
> a live proof of the state machine.

| Field | Value |
|---|---|
| Address | [`0x12dbb68F3c68BD47BF9799db7112f03ac37f6042`](https://testnet.arcscan.app/address/0x12dbb68F3c68BD47BF9799db7112f03ac37f6042) |
| Deploy tx | [`0xa8849b57…be3569f`](https://testnet.arcscan.app/tx/0xa8849b576e9b5365acb07b33075460a8cb5712bf6d510be51af9c6fa1be3569f) |
| Block | `52719574` |
| Gas used | `4,230,277` |
| Source verified | ✅ on testnet.arcscan.app |
| Ladder | **60 / 120 / 180 / 240 seconds** |
| Claim windows | tier 0: 180 s · tier 1: 120 s · tier 2: terminal, never expires |
| Care period | 120 s |

### Abandoned deploy — do not use

| Field | Value |
|---|---|
| Address | [`0x929e841ee1a443bef332ca51ac9e7954c935cc48`](https://testnet.arcscan.app/address/0x929e841ee1a443bef332ca51ac9e7954c935cc48) |
| Deploy tx | [`0x096daec1…a550017`](https://testnet.arcscan.app/tx/0x096daec11249942f47ad0ac53ce1d5e1d3076e24020b73f081eea0579a550017) |
| Block | `52719368` |
| Why abandoned | Intended as the demo vault, but deployed with **production** ladder durations. An earlier edit to `_defaultLadder()` had silently no-op'd — `forge fmt` had reflowed the target onto one line, so the string replacement matched nothing and the env overrides were never wired in. Caught by reading the ladder back off-chain rather than trusting the deploy log. Cost ~0.088 USDC in gas. Left on-chain and recorded here rather than quietly ignored. |

---

## On-chain lifecycle proof

Every transaction below is real, on Arc testnet, in order.

### Production vault — what a live vault can show today

The time-gated tiers cannot be demonstrated on the production vault: reaching
`Nagging` takes 90 days and `Claimable` 365. Those are covered by the demo vault
below, the 119-test Foundry suite, and the simulated walkthrough at `/demo.html`.

| # | Step | Tx | Block | Gas |
|---|---|---|---|---|
| 1 | `approve` 5 USDC to vault | [`0x3ae0d88b…d0bfcbc`](https://testnet.arcscan.app/tx/0x3ae0d88bf99b301b1a3bf6de72225a968e42e3f90c87ba95e20bcc428d0bfcbc) | 52719708 | 55,426 |
| 2 | `deposit(5000000)` — 5.000000 USDC, 6dp | [`0xc7a72b11…b29d614421`](https://testnet.arcscan.app/tx/0xc7a72b1133567d2d15955b5f0d528d0d24374bb7dcf6a9c2f4e9cfb29d614421) | 52719714 | 73,368 |
| 3 | `heartbeat()` → state `Active`, clock reset | [`0xefcaad0c…b959dba30c`](https://testnet.arcscan.app/tx/0xefcaad0c11e256dfe71d347747e1d6d9fe47d86f3cb34f6acafa85b959dba30c) | 52719725 | 41,557 |
| 4 | `proposeCarePayees(BILLS, [...])` → 7-day timelock starts | [`0x3727bb32…c68e0324ed`](https://testnet.arcscan.app/tx/0x3727bb3251aa8937545b893d942b02f3acc5cd3fa9ec1eacf9d89dc68e0324ed) | 52719781 | 249,483 |
| 5 | `proposeRotation(0x…dEaD)` by guardian 1 | [`0xbf034c2d…f6428b3899`](https://testnet.arcscan.app/tx/0xbf034c2d52489f5fac7c7aa2d0e23145b2823ed685ee4112956c6bf6428b3899) | 52719800 | 168,198 |
| 6 | `approveRotation(1)` by guardian 2 → **2 of 2** | [`0xd43595cd…a38b72feb73`](https://testnet.arcscan.app/tx/0xd43595cd86b3a07b120e2e1b59abadae29e2a3629668198f57e24a38b72feb73) | 52719806 | 57,876 |

**The timelock is real, and observable on-chain.** After step 6 the rotation has
its full 2-of-3 approval, yet `isRipe(1)` returns `false`, `owner()` is unchanged
and `totalAssets()` is still `5000000`. A rotation cannot execute for 7 days, and
the owner can veto at any point in that window. `TIMELOCK` is a hard `constant`
and was deliberately **not** made overridable for the demo — a timelock a
deployer can shorten is not a timelock. That is why step 7 (execute) is absent
rather than faked.

### Demo vault — the full ladder, end to end

Ladder measured from `lastActivity` (set by the `deposit` in step 2).

| # | Step | Tx / observation | Block | Gas |
|---|---|---|---|---|
| 1 | `approve` 3 USDC | [`0x0e8f3092…51df184da`](https://testnet.arcscan.app/tx/0x0e8f309248002bbf427c217c574ec4ac27b9e8a2b8c90b9337ccb9751df184da) | 52719933 | 55,438 |
| 2 | `deposit(3000000)` → `Active` | [`0x457561a5…928bc9856c`](https://testnet.arcscan.app/tx/0x457561a58d1fbb5f0446201a92ca6ac19f924b447d9d58da552b58928bc9856c) | 52719939 | 74,381 |
| 3 | **+60 s → `Nagging`** | block ts `1784521473` | — | — |
| 4 | **+120 s → `GuardianAlert`** | block ts `1784521527` | — | — |
| 5 | **+180 s → `CareMode`** | block ts `1784521589` | — | — |
| 6 | `careSpend(approvedPayee, BILLS, 1000000)` | [`0xb000d150…eb5e14328d`](https://testnet.arcscan.app/tx/0xb000d15049e76fa190dd602e025e9904476f345d83a9e5a149e272eb5e14328d) | 52720295 | 174,106 |
| 7 | **+240 s → `Claimable`**, `activeTier() == 0` | block ts `1784521646` | — | — |
| 8 | `claim(0)` by the registered tier-0 payee | [`0x2bb9fa99…aea8c75fbbb`](https://testnet.arcscan.app/tx/0x2bb9fa99fc1aadb2dca3aa4aa4e09cd72c0520f9be9ce71d6e612aea8c75fbbb) | 52720412 | 68,918 |
| 9 | Final: vault `0`, state `Claimed` | — | — | — |

Two design decisions were confirmed **on-chain**, not just in tests:

- **Guardian spending does not reset the ladder** (`docs/OPEN-QUESTIONS.md` Q4).
  After step 6, `lastActivity` was still `1784521406` — unchanged from the
  deposit — and the vault stayed in `CareMode` and went on to `Claimable` on
  schedule. Had care spending counted as activity, a care guardian could hold a
  vault in `CareMode` forever and block the cascade to the heirs.
- **The cascade paid only the registered payee.** `claim` takes a tier index and
  has no destination parameter; the 2.000000 USDC left after the care payment
  went to the tier-0 address the owner registered at construction.

Reproduce with `script/arc-demo-lifecycle.sh` (needs a funded `.env`).

---

## Gas

| | |
|---|---|
| Deployer funded with | 20.000000 USDC |
| Balance after | 11.322577 USDC |
| **Total spent** | **8.677423 USDC** |

Of which ~8.0 USDC is *not* gas — 5 USDC sits in the production vault, 3 USDC
went through the demo vault (1 to the care payee, 2 to the heir), and 0.4 USDC
funded the four actor accounts. **Actual gas across all 16 transactions was
roughly 0.28 USDC**, at ~20.9 gwei; the three vault deployments dominate it at
~4.23M gas each (~0.088 USDC apiece).

---

## Arc-specific notes

1. **Native and ERC-20 USDC are the same balance, not two.** Verified on a funded
   address: native `458416249001801550781` (18dp) ÷ `1e12` == ERC-20
   `balanceOf` `458416249` (6dp), exactly. One faucet claim funds both gas and
   vault deposits — no need to split funds across wallets.
2. **6 decimals confirmed live.** The deploy script reads `decimals()` off the
   configured token and aborts unless it is 6. It passed against the real
   predeploy; an 18dp token would have mispriced every cap by a factor of a
   trillion.
3. **Non-decreasing timestamps caused no trouble.** Every threshold in the
   contracts is inclusive (`>=`), and each rung was entered on the first block
   at or past its boundary. No tier was skipped or stalled.
4. **Explorer is Blockscout-based.** `forge verify-contract --verifier blockscout
   --verifier-url https://testnet.arcscan.app/api` works; both vaults verified.
5. **Gas price observed ~20.9 gwei effective** against a ~40.9 gwei estimate, so
   forge's estimate was roughly 2x conservative.
