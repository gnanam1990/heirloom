# Open Questions

Ambiguities found while building. Per the standing rule: **implement the most
conservative reading, record the question here, do not guess expansively.**

Status legend: 🔴 blocking · 🟡 answer changes design · 🟢 logged, conservative default fine

---

## Q1 — 🟢 `lib/` was gitignored, breaking Foundry submodule pins

**Found:** STEP 1 / scaffold. The supplied `.gitignore` ignored `lib/`, but
`forge install` records dependencies as git submodules (`.gitmodules` + gitlink
entries under `lib/`). Committing `.gitmodules` while ignoring `lib/` yields a
repo that clones without its dependencies and cannot build.

**Conservative reading taken:** removed `lib/` from `.gitignore` so the submodule
commit pins are tracked. This is stock Foundry convention and makes builds
reproducible from a clean clone. Nothing else in `.gitignore` was touched.

**Question for owner:** if `lib/` was ignored deliberately (vendoring or Soldeer
planned instead of submodules), say so and I will switch dependency management
rather than track `lib/`.

**Pinned versions:** OpenZeppelin `v5.6.1`, forge-std `v1.16.2`.

---

## Q2 — 🟡 PRD status header contradicts an active build

**Found:** STEP 1. `docs/PRD.md` §metadata says *"Vault PRD — future event /
post-Snapfall candidate. Not in active development."* while the session
instruction is to build v1 now.

**Conservative reading taken:** treated the build instruction as the override and
left the PRD text unedited (it is the source of truth; I do not rewrite it).

**Question for owner:** should the PRD status line be updated to reflect active
development, or is this a spike that should stay labelled as not-in-development?

---

## Q3 — 🔴 Care mode category enforcement is undefined onchain

**Found:** PRD §4 SHOULD-6, §6 "Guardian collusion during care mode", and the
PRD's own §9.3. The PRD requires care mode be "category-limited (bills/medical)"
but never says how a category is proven onchain. A `categoryId` passed by the
spending guardian is self-asserted — a colluding guardian simply labels a
personal withdrawal as `MEDICAL`. The amount cap is the only enforceable limit.

**Conservative reading taken (pending answer):** implement `categoryId` as a
*recorded, evented, owner-configurable allowlist* — the cap is what constrains
value, the category is an auditable label, and this is documented honestly in
NatSpec rather than overclaimed as enforcement. Per-category sub-caps are
enforced so the label at least bounds spend per bucket.

**Question for owner:** does v1 need a payee allowlist (guardian may only send to
pre-registered merchant addresses) to make the category claim real? That is the
only way to enforce it without an off-chain policy oracle.

---

## Q4 — 🟡 Does care-mode spending count as a heartbeat?

**Found:** Invariant 1 says *any owner signature* resets the ladder. Care mode is
a **guardian** spending, not the owner. If guardian activity reset the ladder, a
guardian could hold the vault in CareMode indefinitely and block the cascade to
heirs.

**Conservative reading taken:** guardian care-mode spends do **not** reset the
ladder. Only owner-key activity resets. This preserves invariant 6 (funds always
progress toward a claimable terminal state).

---

## Q5 — 🟡 Claim window units and cascade trigger

**Found:** PRD §5 "ordered beneficiary list with windows; unclaimed windows
cascade automatically". "Automatically" is not achievable without a keeper —
nothing executes onchain unprompted.

**Conservative reading taken:** cascade is computed **as a pure function of
elapsed time**, not as stored mutable state. The active tier is derived from
`(claimableSince, now, windows)` on read, so cascade requires no keeper, no
transaction, and cannot be stalled by an absent actor. This also keeps the ladder
state function pure, as STEP 3/4 requires.

---

## Q6 — 🟡 Pause declarations (SHOULD-8) vs. invariant 1 purity

**Found:** PRD §4 SHOULD-8 lets an owner freeze the clock for travel/hospital.
That makes the state function depend on accumulated pause history, not just
`(lastActivity, now, config)`.

**Conservative reading taken:** pause is **out of v1 scope** — it is a SHOULD,
and STEP 3 declares MUST items the entire v1 scope. Not implemented. Recorded so
the purity property is not accidentally broken later by adding it naively.

---

## Q10 — 🟢 `carePeriod` must be shorter than the care-mode span

**Found:** while testing the care budget rollover. If `carePeriod` is longer than
`claimableAfter - careModeAfter` (95 days at the defaults), the budget can never
roll over — the vault cascades to `Claimable` before a second period begins. The
production defaults (30-day period inside a 95-day window) are fine; the test
fixture originally was not, which is how this surfaced.

**Conservative reading taken:** NOT enforced onchain. A too-long care period is
degenerate rather than dangerous — it means the guardian gets exactly one budget
period, which fails safe (less spending, not more). Adding a constructor check
would couple two independently-configurable values for no security gain.

**Question for owner:** worth a deploy-time warning in the script? Currently
silent.

---

## Q8 — 🟡 `Recovered` is a transition, not a resting state

**Found:** PRD §5 lists `Recovered` as a state machine node, but §8 demo step 4
requires that after rotation the vault is fully live under the new key — "same
vault, new key, funds untouched". A vault parked permanently in `Recovered`
could not escalate again, which would silently disable the safety net for the
new owner: rotate once and the vault never protects you again.

**Conservative reading taken:** `executeRotation` stamps `lastActivity = now`, so
the vault returns to `Active` under the new key and the full ladder re-arms.
`Recovered` is retained in the enum for PRD fidelity and emitted as an event
(`OwnerRotated`) plus a `lastRotationAt` field, rather than being an absorbing
state. `Claimed` IS absorbing — distributed funds cannot be un-distributed.

**Question for owner:** confirm this reading. The alternative (a sticky
`Recovered` state) means a recovered vault needs an explicit re-arm step.

---

## Q9 — 🟡 Does invariant 1's "ANY state" include the absorbing terminal?

**Found:** Invariant 1 says an owner signature resets from **any** state. Taken
literally that includes `Claimed` — but the funds are already gone by then, and
"resetting" a claimed vault would imply clawing back a completed inheritance.

**Conservative reading taken:** the ladder library satisfies invariant 1 with no
exceptions — it is pure and always returns `Active` when `lastActivity == now`.
At the vault level, `heartbeat()` is accepted and resets the clock from every
rung including `Claimable` (the anti-false-death path the PRD cares about), but
reverts once `Claimed`, because there is nothing left to protect and the alternative
is a clawback path an heir cannot rely on. Tested explicitly both ways.

**Question for owner:** confirm reverting on `Claimed` is right. Making it a
silent no-op instead is the only other defensible option.

---

## Q7 — 🟢 Arc timestamp equality

**Found:** STEP 4.6 — Arc block timestamps are non-decreasing, not strictly
increasing; two blocks may share a timestamp.

**Conservative reading taken:** every deadline/window comparison uses inclusive
boundaries (`>=` for "has elapsed", `<=` for "still open") and is tested at the
exact boundary timestamp, so equal-timestamp blocks never flip a decision
mid-window. No logic anywhere depends on `t2 > t1` strictly.
