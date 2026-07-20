# Heirloom — off-chain services

> ⚠️ **UNAUDITED TESTNET CODE.** Local development only. Not hardened for
> hosting: no auth on admin routes, no rate limiting, no TLS.

The thin observation layer from PRD §5. The chain is the source of truth.

**Custody, stated precisely.** This service holds no key that can take anything.
It never holds an owner key, and the Telegram bot has no signing path at all.
Since Q11 it *may* hold one optional key — `HELPER_PRIVATE_KEY` — used solely to
trigger `claim(tier)` on an heir's behalf. That key cannot name a destination,
claim early, jump the cascade order, touch config, or pay itself: the contract
reads the payee from storage. Worst case if this whole service is compromised,
an attacker can send a Telegram message asking someone to sign a heartbeat, and
pay gas to send an heir their own inheritance slightly early.

## What's here

| Piece | File | Status |
|---|---|---|
| Event indexer / heartbeat listener | `src/indexer.ts` | ✅ runs against live Arc |
| Ladder state + JSON API | `src/server.ts` | ✅ runs |
| Ordering rules (the Arc timestamp trap) | `src/ordering.ts` | ✅ tested |
| Off-chain ladder mirror | `src/ladder.ts` | ✅ tested |
| Claim-link signing | `src/claims.ts` | ✅ tested |
| Telegram `/alive` bot | `src/telegram.ts` | ⏸ needs `TELEGRAM_BOT_TOKEN` |
| Assisted-claim relayer | `src/relayer.ts` | ⏸ needs `HELPER_PRIVATE_KEY` |
| Circle heir wallets | `src/circle.ts` | ⛔ needs credentials **and** a setup-time flow — see below |

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
curl localhost:8787/vault/0x0CA49eBD6fba33530287cb8eAE9aE565e80e18dA/state
curl localhost:8787/vault/0x0CA49eBD6fba33530287cb8eAE9aE565e80e18dA/events
```

`/health` reports exactly which credentialed features are live.

## Environment

Copy `.env.example` to `.env` (gitignored) and fill in what you need. Every
feature degrades to **disabled and loudly logged**, never to a stub.

| Variable | Needed for | Where it comes from |
|---|---|---|
| `CLAIM_LINK_SECRET` | signing claim links | you: `openssl rand -hex 32` |
| `TELEGRAM_BOT_TOKEN` | the `/alive` bot | @BotFather on Telegram |
| `HELPER_PRIVATE_KEY` | triggering assisted claims | `cast wallet new`, fund with a little Arc testnet USDC |
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
anything in the link (`HeirloomVault.sol:253`), so a forwarded email or a leaked
URL is not a theft. Links are HMAC-signed and time-boxed (30 days).

## The claim flow, after Q11

`claim(tier)` is now callable by **anyone**, with funds still going only to the
pre-registered beneficiary. That removed the heir's need for gas, a wallet app,
or the ability to transact at all — the service triggers the payout for them.

**Proven end to end on Arc testnet** against vault
`0x31eEfc46C61678eBAE2650FC2bF8F3312eebC754`: the heir opened a claim link,
pressed *Receive my funds*, and the service (as helper) called `claim(0)`.

```
heir   0x58003426…  4098566 -> 5598566   gained 1.500000 USDC
helper 0x07bB7a1D…    94800 ->   93222   LOST 1578 to gas, gained nothing
vault                1500000 ->       0   state Claimed
```

Receipt: [`0x41d32de3…7d8c27b9`](https://testnet.arcscan.app/tx/0x41d32de3484002e1e4bf393d789afa8094fed28cd92cb330f64eeb437d8c27b9)

Routes: `GET /claim/:token` renders the page; `POST /claim/:token/receive`
triggers it. Both are safe to expose to whoever holds the link, because the link
is not a bearer token for the money — the destination is fixed in contract
storage.

### ⛔ What Q11 did NOT solve, and why Circle is still inert

Q11 fixed *who can call*. It did **not** change *where the money goes*: the
destination is still `_beneficiaries[tier].payee`, read from storage
(`HeirloomVault.sol:253`) and fixed when the owner registers heirs.

**So a Circle Wallet created at claim time still cannot receive the funds.** Its
address was never registered, so the payout goes to whatever the owner recorded.
The naive flow — *heir clicks link → wallet created → funds land in it* — would
pay the wrong address silently rather than erroring. It remains impossible, and
that is a property worth keeping: it is the same rule that stops a thief
redirecting an inheritance.

The flow that works:

**At setup** (owner alive) — owner supplies each heir's email; we create an
email-bound Circle Wallet per heir *then*; the owner registers those addresses
as beneficiaries through the usual 7-day config timelock.

**At claim** (owner gone) — heir opens the link, presses one button, the service
triggers `claim(tier)`, and funds land in the wallet already registered for
them. The heir authenticates by email to see and move it.

The heir still never sees a seed phrase, needs no crypto knowledge, and now
needs no gas either. The one hard requirement is that heirs are set up with
wallets *in advance* — inherent to a product whose premise is "configure this
before you need it".

`src/circle.ts` implements the client for that and stays inert until credentials
exist. Before wiring it, confirm Circle can hand back an address at setup time;
if an address only exists after the heir first authenticates, this design needs
rethinking.

## Tests

```
npm test        # 40 tests, no credentials required
npm run typecheck
```

Covers event ordering under shared timestamps, cursor semantics, block paging,
the ladder mirror against the same boundaries as the Foundry suite, 6dp money
formatting, claim-link signing/tampering/expiry, and the relayer's credential
gate. The relayer tests are hermetic — they set placeholder credentials before
importing config, so they behave identically on a clean checkout and on a
machine with a real `.env`.

The ladder mirror is cross-checked at runtime too: `readVault` reads `state()`
from the contract *and* recomputes it locally, and logs `MIRROR DRIFT` if they
ever disagree.
