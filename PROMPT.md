# Claude Code kickoff prompt — paste this to start any Heirloom session

Read docs/PRD.md fully — it is the single source of truth. Do not invent features beyond it; MUST items (§4) are the entire v1 scope.

Non-negotiable invariants (from PRD §2 and §6 — encode these in tests FIRST):
1. Any owner signature resets the ladder to Active from ANY state.
2. Every config mutation (heirs, guardians, timings) routes propose → 7-day timelock → execute, with an event on propose and owner veto at any point before execute. No direct setters, ever.
3. Guardians can only propose key rotation — they can never move funds.
4. Claims pay only pre-registered beneficiary addresses; no free-text destinations.
5. Care mode is amount- and category-capped; full transfer happens only via the full ladder.
6. Funds never dead-end: an unclaimed tier cascades; the terminal tier is the charity sink.

Build order (tests before implementation at every step):
1. Foundry scaffold: forge init layout, OpenZeppelin + forge-std, solc 0.8.26. Contracts in src/: HeirloomVault.sol (state machine Active → Nagging → GuardianAlert → CareMode → Claimable → Claimed/Recovered), RecoveryModule.sol, ClaimsModule.sol, ConfigGuard.sol (shared timelock logic). Time math uses block.timestamp with configurable tier durations (defaults 90/180/270/365 days; test values in seconds).
2. Ladder tests: full fuzz over elapsed time and heartbeat sequences — assert the state function is pure over (lastActivity, now, config); assert invariant 1.
3. Recovery: M-of-N approval set, proposeRotation/executeRotation/veto with timelock; test malicious-guardian and stolen-key scenarios from PRD §6 explicitly.
4. Claims: ordered tiers with windows, cascade on expiry, charity terminal; fuzz that no reachable state strands funds (invariant 6).
5. Care mode: per-month cap, category ids, instant revoke on owner activity.
6. Deploy script for Arc testnet (RPC https://rpc.testnet.arc.network, chain 5042002; USDC has 6dp on the ERC-20 surface; transfers to the zero address revert; timestamps are non-decreasing, not strictly increasing — deadline logic must tolerate equal timestamps).
7. Thin off-chain later — contracts first. No dashboard until the contract suite is green.

Working rules:
- Conventional commits in logical units (feat:/test:/docs:/chore:), push to main after each green suite.
- Never commit secrets; testnet keys only via env.
- Label everything unaudited testnet code.
- End each session with: test count, invariants covered, what's next.
