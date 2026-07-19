# Heirloom 🗝️

**The wallet that can't be lost. Not to death, not to forgetting, not to thieves.**

Money today assumes its owner is alive, present, and remembers everything. Heirloom makes money **liveness-aware**: lost keys, lost people, lost agents — funds never get stranded.

One mechanism, five problems solved:
- **Forgot your seed phrase** → M-of-N guardian social recovery rotates the vault to a new key. The lock changes, not the house.
- **Death** → cascading beneficiaries claim in order; a non-crypto heir claims via an email link, never sees a seed phrase.
- **Incapacity** → care mode gives a guardian capped, category-limited spending — not the keys.
- **Founder-key risk** → org treasuries cascade to a co-founder multisig instead of dying (the QuadrigaCX problem).
- **Dead AI agents** → agent-treasury watchdog returns funds to the operator.

The core primitive is the **liveness ladder**: any activity resets the clock; silence escalates through nag → guardian alert → care mode → claimable. Every configuration change takes a 7-day timelock with owner veto — a thief with your key cannot silently redirect your safety net.

**Status:** early build · Arc testnet · unaudited — do not use with real funds.

Source of truth: [`docs/PRD.md`](docs/PRD.md). Build prompt: [`PROMPT.md`](PROMPT.md).
