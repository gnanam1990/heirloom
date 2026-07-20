# Heirloom — off-chain services

> ⚠️ **UNAUDITED TESTNET CODE.** Local development only. Not hardened for
> hosting: no auth on admin routes, no rate limiting, no TLS.

The thin observation layer from PRD §5. The chain is the source of truth;
**nothing here custodies anything.** This service holds no private key, has no
signing path, and cannot move funds. If it were fully compromised, the worst an
attacker could do is send a Telegram message asking someone to sign a heartbeat.

## What's here

| Piece | File | Status |
|---|---|---|
| Event indexer / heartbeat listener | `src/indexer.ts` | ✅ runs against live Arc |
| Ladder state + JSON API | `src/server.ts` | ✅ runs |
| Ordering rules (the Arc timestamp trap) | `src/ordering.ts` | ✅ tested |
| Off-chain ladder mirror | `src/ladder.ts` | ✅ tested |
| Claim-link signing | `src/claims.ts` | ✅ tested |
| Telegram `/alive` bot | `src/telegram.ts` | ⏸ needs `TELEGRAM_BOT_TOKEN` |
| Circle heir wallets | `src/circle.ts` | ⛔ needs credentials **and** a decision — see below |

## Run it

```
cd services
npm install
npm test
npm start
```

No credentials are needed for the indexer or the API — those paths work against
public Arc testnet RPC out of the box.

```
curl localhost:8787/health
curl localhost:8787/vaults
curl localhost:8787/vault/0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8/state
curl localhost:8787/vault/0xaef39a00cdd1d9b240bde4e08f7b6f9915a386e8/events
```

`/health` reports exactly which credentialed features are live.

## Environment

Copy `.env.example` to `.env` (gitignored) and fill in what you need. Every
feature degrades to **disabled and loudly logged**, never to a stub.

| Variable | Needed for | Where it comes from |
|---|---|---|
| `CLAIM_LINK_SECRET` | signing claim links | you: `openssl rand -hex 32` |
| `TELEGRAM_BOT_TOKEN` | the `/alive` bot | @BotFather on Telegram |
| `CIRCLE_API_KEY` | heir wallet creation | console.circle.com, testnet key |
| `CIRCLE_ENTITY_SECRET` | Circle wallet operations | console.circle.com |
| `SMTP_*` | emailing claim links | any SMTP provider |

## The Arc timestamp rule

Arc block timestamps are **non-decreasing, not strictly increasing** — two
blocks can share a timestamp. Two consequences, both of which corrupt an indexer
silently rather than loudly:

1. **Never order events by timestamp.** Order by `(blockNumber, logIndex)`.
2. **Never use `timestamp > lastSeen` as a resume cursor.** A strict comparison
   drops every event in a block sharing the previous block's timestamp.

`src/ordering.ts` is a separate module for exactly this reason, and
`test/ordering.test.ts` has a named regression test for the dropped-events case.
Per docs.arc.io/arc/tutorials/monitor-contract-events.

A second Arc note: the public RPC rate-limits by **request rate**, and returns
its refusal as a JSON-RPC error inside a `200`, so viem's transport-level retry
does not catch it. `withRateLimitRetry` in `src/chain.ts` handles it, and each
vault snapshot is fetched as **one** Multicall3 batch rather than ~14 calls.

## Telegram bot — key custody

`heartbeat()` is `onlyOwner` and the deployed contract has **no delegated
heartbeat**, so option (b) from the brief (a low-privilege delegate address) is
not possible without a contract change. The bot implements **option (a)**: it
returns a prepared, unsigned transaction plus an EIP-681 deep link that the
owner signs in their own wallet. The raw calldata is included too, since wallet
support for EIP-681 varies.

Commands: `/link <vault>`, `/alive`, `/status`.

Reminders are pushed automatically when a watched vault crosses into Nagging,
GuardianAlert, CareMode or Claimable — once per transition, persisted across
restarts so nobody gets re-notified about a tier they already heard about.

`CONTRACT_ENHANCEMENT` in `src/telegram.ts` documents what a delegated heartbeat
would buy and cost, as a decision for the maintainer rather than something a
service layer should introduce.

## Claim links

A claim link is a signed capability to **see** a claim page — not a bearer token
for the money. The contract pays `beneficiaries[tier].payee` regardless of
anything in the link (`HeirloomVault.sol:219`), so a forwarded email or a leaked
URL is not a theft. Links are HMAC-signed and time-boxed (30 days).

## ⛔ Before Circle Wallets can be wired: a sequencing problem

The PRD imagines *"heir clicks link → wallet is created → funds land."* **That
cannot work against the deployed contract.**

`claim()` reverts with `NotBeneficiary` unless `msg.sender` is the address the
owner **pre-registered**. A wallet created at claim time has a fresh address
that was never registered, so its claim always reverts.

Two ways forward:

**(A) Provision at setup — works with the contract as deployed.**
When the owner configures heirs, create an email-bound Circle Wallet per heir
*then*, and register those addresses as beneficiaries through the normal 7-day
config timelock. At claim time the heir signs into a wallet that already exists
and already is the registered payee. Still a no-seed-phrase experience.

**(B) Permissionless assisted claim — needs a contract change.**
Let anyone call `claim(tier)` while funds still go only to the registered payee.
Invariant 4 is untouched (the caller still cannot name a destination) and
invariant 6 gets *stronger*, since an heir who can never transact cannot strand
their tier. Already flagged as a possible strengthening in
`docs/OPEN-QUESTIONS.md`.

`src/circle.ts` implements the client for (A). (B) is a contract decision.

Also unresolved: an heir's fresh wallet needs Arc gas to send the claim, and on
Arc gas is USDC. Either Circle sponsors it or something pre-funds the wallet —
`estimateGasFundingNeeded()` makes the requirement explicit rather than letting
it surface as a failed claim at the worst possible moment.

## Tests

```
npm test        # 35 tests, no credentials required
npm run typecheck
```

Covers event ordering under shared timestamps, cursor semantics, block paging,
the ladder mirror against the same boundaries as the Foundry suite, 6dp money
formatting, and claim-link signing/tampering/expiry.

The ladder mirror is cross-checked at runtime too: `readVault` reads `state()`
from the contract *and* recomputes it locally, and logs `MIRROR DRIFT` if they
ever disagree.
