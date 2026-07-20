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
has its own address by design.

> **Redeployed 20 July 2026** for the permissionless assisted claim (Q11).
> `claim()` is now callable by anyone, with funds still going only to the
> pre-registered beneficiary. The previous pair is listed under *Superseded*
> below and should not be used.

### 1. Production vault — real ladder

| Field | Value |
|---|---|
| Address | [`0x0CA49eBD6fba33530287cb8eAE9aE565e80e18dA`](https://testnet.arcscan.app/address/0x0CA49eBD6fba33530287cb8eAE9aE565e80e18dA) |
| Deploy tx | [`0x202157ab…0bea6db5`](https://testnet.arcscan.app/tx/0x202157abe3254caeaac25ef369a340f86b25d5b7c3d2e1ec3415b2fc0bea6db5) |
| Block | `52730264` |
| Gas used | `4,238,770` |
| Source verified | ✅ on testnet.arcscan.app |
| Ladder | 90 / 180 / 270 / 365 days |
| Config timelock | `604800` s (7 days) |
| Guardians | 3, threshold 2-of-3 |

### 2. Demo vault — **DEMO-ONLY, short durations**

> **Not a safety net.** Tiers are seconds, not months. Anyone can walk it to
> `Claimable` in four minutes and trigger the payout. It exists purely as a live
> proof of the state machine.

| Field | Value |
|---|---|
| Address | [`0x0D884E62B1dE894df1651910849E534aDf4deaDa`](https://testnet.arcscan.app/address/0x0D884E62B1dE894df1651910849E534aDf4deaDa) |
| Deploy tx | [`0xf25d5bbc…64cbd113`](https://testnet.arcscan.app/tx/0xf25d5bbcdd4ff18f0f99936305cfabf385a958cc886622a5f480b8da64cbd113) |
| Block | `52730325` |
| Gas used | `4,238,650` |
| Source verified | ✅ on testnet.arcscan.app |
| Ladder | **60 / 120 / 180 / 240 seconds** |
| Claim windows | tier 0: 180 s · tier 1: 120 s · tier 2: terminal |

### Superseded — pre-Q11, do not use

These enforced the old rule that only the registered beneficiary could call
`claim()`. Left on-chain and recorded rather than quietly dropped.

| Role | Address | Retired because |
|---|---|---|
| Production | [`0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8`](https://testnet.arcscan.app/address/0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8) | superseded by Q11 redeploy |
| Demo | [`0x12dbb68F3c68BD47BF9799db7112f03ac37f6042`](https://testnet.arcscan.app/address/0x12dbb68F3c68BD47BF9799db7112f03ac37f6042) | superseded by Q11 redeploy |
| Abandoned | [`0x929e841ee1a443bef332ca51ac9e7954c935cc48`](https://testnet.arcscan.app/address/0x929e841ee1a443bef332ca51ac9e7954c935cc48) | deployed with production durations by mistake; an edit to `_defaultLadder()` had silently no-op'd after `forge fmt` reflowed the replacement target |

---

## Assisted-claim proof (Q11) — on the NEW demo vault

The property: a **helper with no role whatsoever** triggers the payout, and the
funds land at the registered heir. The helper is never paid, and pays the gas.

| # | Step | Tx | Block | Gas |
|---|---|---|---|---|
| 1 | `approve` 2 USDC | [`0x57283087…996d14d4`](https://testnet.arcscan.app/tx/0x57283087f858c3bdb49858d271575280b9920a61af0935cb00705b47996d14d4) | 52730434 | 55,438 |
| 2 | `deposit(2000000)` → `Active` | [`0x921d1c0b…68d0786f`](https://testnet.arcscan.app/tx/0x921d1c0beac4d42c3c136ca9516b50e69b75c61693124f8b5afa085068d0786f) | 52730443 | 73,383 |
| 3 | **+240 s → `Claimable`**, `activeTier() == 0` | — | — | — |
| 4 | **`claim(0)` called by the HELPER** `0x07bB7a1D…` | [`0x10937bae…06c8a14e`](https://testnet.arcscan.app/tx/0x10937bae7014fa7d3f2cd972b46d6b69b49adb2744dfae804bd5dbfe06c8a14e) | 52730923 | 75,620 |

Measured balances around step 4:

```
heir   0x58003426…  2098566 -> 4098566   gained 2.000000 USDC
helper 0x07bB7a1D…    96379 ->   94800   LOST 1579 (gas), gained nothing
vault                2000000 ->       0   state Claimed
```

The helper is not a beneficiary of this vault and never becomes one. It could
not name a destination — `claim` takes a tier index — and it walked away
strictly poorer for having helped. That is invariant 4 intact and invariant 6
strengthened, demonstrated on-chain rather than only in tests.

## On-chain lifecycle proof — original run, on the SUPERSEDED vaults

Every transaction below is real and still on-chain, but it ran against the
pre-Q11 pair listed under *Superseded* above. It is kept because the properties
it demonstrated (the 7-day timelock, the full ladder, care-mode capping,
guardian spending not resetting the clock) are unchanged by the Q11 redeploy.

### Production vault — what a live vault can show today

The time-gated tiers cannot be demonstrated on the production vault: reaching
`Nagging` takes 90 days and `Claimable` 365. Those are covered by the demo vault
below, the 126-test Foundry suite, and the simulated walkthrough at `/demo.html`.

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
| Balance after original run | 11.322577 USDC |
| Balance after Q11 redeploy | 9.142928 USDC |
| **Total spent** | **10.857072 USDC** |

Of which ~8.0 USDC is *not* gas — 5 USDC sits in the production vault, 3 USDC
went through the demo vault (1 to the care payee, 2 to the heir), and 0.4 USDC
funded the four actor accounts. **Actual gas across all 16 transactions was
roughly 0.28 USDC**, at ~20.9 gwei; the vault deployments dominate it at ~4.23M
gas each (~0.088 USDC apiece).

The Q11 redeploy added 2.179649 USDC of spend: two more deployments, 2 USDC of
principal through the new demo vault (all of which reached the heir), and the
assisted-claim proof transactions.

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
