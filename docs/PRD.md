# Heirloom — Product Requirements Document (v1.0)

**The wallet that can't be lost. Not to death, not to forgetting, not to thieves.**

| Field | Value |
|---|---|
| Product | Heirloom — a liveness-aware safety net for onchain money |
| Category | Wallet resilience layer: recovery + inheritance + continuity, one mechanism |
| Status | Vault PRD — future event / post-Snapfall candidate. Not in active development. |
| Chain | Arc (USDC-native); design is EVM-portable |
| One-liner | Money today assumes its owner is alive, present, and remembers everything. Heirloom makes money liveness-aware: lost keys, lost people, lost agents — funds never get stranded. |

---

## 1. Problem

Onchain assets have a single, silent failure mode: **the owner stops being able to sign.** The cause doesn't matter — death, a forgotten seed phrase, incapacity, a stolen device, a deprecated AI agent, a founder who was the only keyholder. The outcome is identical: funds strand forever.

The damage is not hypothetical:
- An estimated 20%+ of all Bitcoin is permanently lost to key loss.
- QuadrigaCX: ~$190M of customer funds locked when the sole keyholder died — the founder-key single point of failure that still exists in most startups, DAOs, and small funds.
- India alone holds tens of thousands of crores in unclaimed bank/insurance/EPF assets — money that never learned its owner was gone. Onchain assets inherit the same fate by default.
- Families of deceased holders face an impossible task: they don't know what exists, where it is, or how to claim it — and often don't have a wallet at all.

Existing tools each solve a fragment: hardware wallets protect against theft but not loss; social-recovery wallets (Argent, Safe modules) protect against key loss but not death or incapacity; dead-man's-switch tools (Sarcophagus) handle death but not recovery. **Nobody unifies them — yet the contract-level trigger for all of them is the same: "the owner can't sign anymore."**

## 2. Insight & core mechanism

One primitive powers everything — the **liveness ladder**:

```
activity (any tx / dashboard login / Telegram "/alive")  →  clock resets
3 months silent   →  nag: email + Telegram reminders
6 months silent   →  guardians notified; fast-track vote available
9 months silent   →  care mode: designated guardian gets LIMITED monthly
                     spending rights (bills/medical categories only)
12 months silent  →  cascade: beneficiaries may claim, in priority order
any time          →  one signature from the owner key cancels everything
```

**Cascading beneficiaries** make it recovery AND inheritance:
- Heir #1 = the owner's own cold-backup wallet → key loss becomes *self-recovery*
- Heir #2 = spouse/family → death becomes inheritance
- Heir #3 = charity/DAO → funds never dead-end even if heirs are unreachable
Each tier gets a claim window; unclaimed → cascade continues.

**Anti-theft invariant:** every configuration change (heirs, guardians, timings) takes a **7-day timelock with owner notification and veto**. A thief with the key cannot silently redirect the safety net; the real owner always has a window to cancel. Without this rule the product is broken — it is the load-bearing security property.

## 3. Users & jobs

| Persona | Job to be done |
|---|---|
| Individual holder | "If I forget my seed or die, my money must reach me-with-a-new-key, or my family — automatically." |
| Non-crypto heir | "Claim what was left to me without understanding wallets." |
| Founder / small fund / DAO | "Treasury must survive any single person — continuity as a contract." |
| Aging owner / family | "If I decline, let my son pay my bills — without handing him everything." |
| Agent operator (Snapfall tie-in) | "If my AI agent dies or is deprecated, its treasury returns to me automatically." |

## 4. Scope (MoSCoW)

**MUST (the product):**
1. **Social recovery** — M-of-N guardians approve rotating vault control to a NEW owner key. No seed phrase required. 7-day timelock; old key can veto. Funds never move; the lock changes, not the house.
2. **Liveness ladder** — tiered inactivity flow exactly as §2; any transaction counts as heartbeat; Telegram "/alive" heartbeat; reminder pipeline.
3. **Cascading claims** — ordered beneficiaries, per-tier claim windows, automatic cascade, charity terminal tier.
4. **Easy heir claim** — claim link → email-based wallet creation (Circle Wallets) → funds land. A non-crypto spouse completes a claim without ever seeing a seed phrase. *The killer feature.*
5. **Config timelock + veto** — 7-day delay + notification on every heir/guardian/timing change.

**SHOULD:**
6. Care mode — category-limited monthly allowance for a guardian at tier 3 (bills/medical), instantly revoked by owner activity.
7. Encrypted legacy notes — messages decryptable only on successful claim (practical: off-chain asset map; personal: goodbyes).
8. Pause declarations — pre-announced unreachable periods (travel, hospital) freeze the clock.
9. Fast-track — M-of-N guardian vote triggers early release with a 7-day delay, always owner-vetoable.
10. Agent watchdog — agent-wallet heartbeat stops → treasury auto-returns to operator; fleet cleanup for AI-agent operators.

**COULD:** Shamir shard registry (3-of-5 backup integration) · duress PIN with decoy balance + freeze · multi-wallet asset inventory for heirs · org mode (founder → co-founder multisig → board cascade) · reverse-Heirloom pension streams (heartbeat continues payments; silence stops them and starts survivor benefits).

**WON'T (v1):** custody of keys (non-custodial always) · legal-will integration or probate claims · identity/KYC of heirs beyond wallet+email · non-EVM chains · insurance underwriting.

## 5. Architecture

**HeirloomVault.sol (per owner):** holds USDC (+ registered ERC-20s); owner key = controller; state machine `Active → Nagging → GuardianAlert → CareMode → Claimable → Claimed/Recovered`; every owner signature resets to Active. Emits full event trail.

**Recovery module:** guardian registry (M-of-N), `proposeRotation(newOwner)` → 7-day timelock → `executeRotation()`; `veto()` by current owner key at any stage.

**Claims module:** ordered beneficiary list with windows; `claim(tier)` valid only in Claimable and within that tier's window; unclaimed windows cascade automatically; terminal charity sink.

**Config guard:** all mutations route through `propose → 7d timelock (event + notification) → execute`, owner-vetoable.

**Off-chain services (thin):** heartbeat listener (chain activity indexer + Telegram bot + dashboard), reminder pipeline (email/Telegram), claim-link service wiring Circle Wallet creation for heirs. All non-custodial; the chain is the source of truth — services only observe and notify.

**Why Arc:** balances are USDC (heirs receive dollars, not volatile tokens); gas in USDC keeps claim costs legible to non-crypto users; sub-second finality makes the claim UX feel like a bank transfer; Circle Wallets provide the email-first heir onboarding; Arc's compliance posture suits a product that touches inheritance.

## 6. Security & attack model

| Attack | Defense |
|---|---|
| Thief with owner key redirects heirs | 7-day config timelock + notification + owner veto (invariant #5) |
| Malicious guardians rotate ownership | M-of-N threshold + timelock + old-key veto; guardians can't move funds, only propose rotation |
| False death trigger (owner on trek) | Long ladder, nags at tier 1, pause declarations, any-tx heartbeat, owner cancel at every tier |
| Heir impersonation | Claims pay only to pre-registered addresses or email-bound Circle Wallet flows; no free-text destinations |
| Guardian collusion during care mode | Care mode is category- and amount-capped; full transfer only via the full ladder |
| Contract risk | Minimal state machine, OZ libraries, CEI, full event emission, fuzz on ladder/cascade invariants; unaudited-testnet label until audited |

## 7. Honest limits & prior art

- **Insurance, not a time machine:** keys lost *before* setup are unrecoverable. Heirloom is a setup-first product; distribution must target wallet-creation moments.
- Prior art acknowledged: Argent social recovery, Safe recovery modules, Sarcophagus dead-man's switch. Differentiation: **one unified liveness primitive** covering recovery + inheritance + incapacity + continuity; **stablecoin-native**; **non-crypto heir onboarding**; **cascading (never-strand) claims**; **agent-treasury watchdog** — no existing product ships that combination.

## 8. Demo script (3 min, future event)

1. (0:00) "This wallet's owner just vanished. Watch the money find its way home."
2. Setup view: heirs (own backup → spouse → charity), guardians, ladder.
3. Fast-forward sim: nag fires → guardians alerted → care mode pays one capped 'electricity bill' → Claimable.
4. **Key-loss path:** owner's new device + 2 guardians approve → 7-day timelock (simulated) → rotation → same vault, new key, funds untouched.
5. **Inheritance path:** spouse clicks claim link → email wallet created → USDC lands → encrypted note decrypts on screen. (The emotional beat.)
6. Thief attempt: stolen key proposes new heir → notification fires → owner veto. "The lock changed. The house didn't."
7. Close: "Lost keys, lost people, lost agents — Heirloom. Money that finds its way home."

## 9. Open questions (resolve before build)

1. Heartbeat privacy — does an onchain "alive" signal leak that a vault exists? (Mitigation: any-tx heartbeat needs no dedicated signal; explore Arc opt-in privacy for vault balances.)
2. Legal posture — inheritance without probate varies by jurisdiction; v1 frames as *beneficiary designation* (like insurance nominees), not a will. Needs counsel review before mainnet.
3. Care-mode category enforcement — merchant allowlists onchain vs. off-chain policy service; decide against the Snapfall policy-engine pattern.
4. Reminder deliverability — email/Telegram are off-chain trust points; how much of the ladder must remain observable purely onchain?
5. Guardian UX — how do non-crypto guardians sign approvals? (Circle Wallets for guardians too?)

---
*Heirloom v1.0 — vault PRD. Sequenced after Snapfall (Aug 8). The mechanism is one contract family: inheritance, recovery, continuity, pensions, deposits — all downstream of "money that knows whether you're there."*
