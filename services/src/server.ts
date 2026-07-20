/**
 * JSON API + claim pages + Telegram poller.
 *
 * Uses node:http rather than a framework — the surface is six routes and the
 * dependency budget is better spent elsewhere.
 *
 * UNAUDITED TESTNET CODE. Local run only; not hardened for public hosting
 * (no rate limiting, no TLS termination, no auth on the admin-ish routes).
 */
import {createServer, type IncomingMessage, type ServerResponse} from 'node:http';
import {api, chain, credentialStatus, secrets, watchedVaults} from './config.js';
import {Indexer} from './indexer.js';
import {
  STATE_NAMES,
  VaultState,
  formatDuration,
  formatUsdc,
  nextRung,
  rungEntersAt,
} from './ladder.js';
import * as telegram from './telegram.js';
import {mintClaimLink, verifyClaimToken} from './claims.js';
import * as circle from './circle.js';
import * as relayer from './relayer.js';

const ix = new Indexer();

function json(res: ServerResponse, code: number, body: unknown): void {
  const payload = JSON.stringify(
    body,
    (_k, v) => (typeof v === 'bigint' ? v.toString() : v),
    2,
  );
  res.writeHead(code, {'Content-Type': 'application/json'});
  res.end(payload);
}

function html(res: ServerResponse, code: number, body: string): void {
  res.writeHead(code, {'Content-Type': 'text/html; charset=utf-8'});
  res.end(body);
}

/** GET /vault/:address/state */
function vaultState(res: ServerResponse, address: string): void {
  const snap = ix.snapshot(address);
  if (!snap) {
    json(res, 404, {
      error: 'vault not indexed',
      hint: 'add it to HEIRLOOM_VAULTS and restart',
      watched: watchedVaults,
    });
    return;
  }

  const next = nextRung(snap.lastActivity, snap.blockTimestamp, snap.ladder);
  const entersAt =
    next !== null ? rungEntersAt(snap.lastActivity, next, snap.ladder) : null;

  json(res, 200, {
    address: snap.address,
    chainId: chain.chainId,
    explorer: `${chain.explorer}/address/${snap.address}`,
    state: {code: snap.state, name: STATE_NAMES[snap.state]},
    owner: snap.owner,
    isClaimed: snap.isClaimed,
    balance: {raw: snap.totalAssets, usdc: formatUsdc(snap.totalAssets), decimals: 6},
    lastActivity: snap.lastActivity,
    ladder: snap.ladder,
    nextRung:
      next === null
        ? null
        : {
            code: next,
            name: STATE_NAMES[next],
            entersAt,
            inSeconds: snap.secondsUntilNextRung,
            human: formatDuration(snap.secondsUntilNextRung),
          },
    activeTier: snap.activeTier,
    beneficiaries: snap.beneficiaries,
    guardians: {threshold: snap.guardianThreshold, members: snap.guardians},
    observedAt: {blockNumber: snap.blockNumber, blockTimestamp: snap.blockTimestamp},
  });
}

function claimPage(res: ServerResponse, token: string): void {
  let secret: string;
  try {
    secret = secrets.claimLinkSecret();
  } catch (err) {
    html(res, 503, `<h1>Not configured</h1><pre>${(err as Error).message}</pre>`);
    return;
  }

  const v = verifyClaimToken(token, secret);
  if (!v.ok) {
    html(
      res,
      400,
      `<h1>This link is not valid</h1><p>${
        v.reason === 'expired'
          ? 'It has expired. Ask for a fresh one.'
          : 'It could not be verified.'
      }</p>`,
    );
    return;
  }

  const snap = ix.snapshot(v.claims.vault);
  const amount = snap ? formatUsdc(snap.totalAssets) : 'unknown';
  const claimable = snap?.state === VaultState.Claimable;
  const alreadyClaimed = snap?.state === VaultState.Claimed;
  const canTrigger = claimable && relayer.isConfigured();

  const action = alreadyClaimed
    ? '<p><strong>This has already been received.</strong></p>'
    : !claimable
      ? `<p>Not available yet — the vault is <strong>${
          snap ? STATE_NAMES[snap.state] : 'unknown'
        }</strong>. You will be emailed when it is.</p>`
      : canTrigger
        ? `<form method="POST" action="/claim/${token}/receive">
             <button type="submit" style="font-size:1.1rem;padding:.8rem 1.6rem;cursor:pointer">
               Receive my funds
             </button>
           </form>
           <p style="color:#666;font-size:.9rem">You will not be asked to pay anything,
           install anything, or approve a transaction. We send it for you.</p>`
        : `<p style="color:#666">The receive step needs a helper key
           (<code>HELPER_PRIVATE_KEY</code>), which is not provisioned here, so the
           button is disabled rather than pretending to work.</p>`;

  html(
    res,
    200,
    `<!doctype html><meta charset="utf-8">
<title>A claim has been left to you</title>
<body style="font-family:system-ui;max-width:38rem;margin:4rem auto;padding:0 1rem;line-height:1.6">
<h1>Something was left to you</h1>
<p>Amount: <strong>${amount} USDC</strong></p>
<p>It can only ever be sent to the account already recorded for you:<br>
<code>${v.claims.payee}</code></p>
${action}
<hr>
<p style="color:#666">Testnet only. Unaudited software.</p>
</body>`,
  );
}

/**
 * POST /claim/:token/receive — the assisted claim (Q11).
 *
 * The service pays the gas and triggers the payout. It cannot redirect the
 * funds: `claim` takes a tier index and the contract reads the payee from
 * storage, so this endpoint is safe to expose to whoever holds the link.
 */
async function claimExecute(res: ServerResponse, token: string): Promise<void> {
  let secret: string;
  try {
    secret = secrets.claimLinkSecret();
  } catch (err) {
    json(res, 503, {error: (err as Error).message});
    return;
  }

  const v = verifyClaimToken(token, secret);
  if (!v.ok) {
    json(res, 400, {error: `claim link ${v.reason}`});
    return;
  }

  try {
    const result = await relayer.triggerClaim(
      v.claims.vault as `0x${string}`,
      v.claims.tier,
    );
    await ix.refreshStates();
    html(
      res,
      200,
      `<!doctype html><meta charset="utf-8">
<title>Received</title>
<body style="font-family:system-ui;max-width:38rem;margin:4rem auto;padding:0 1rem;line-height:1.6">
<h1>It's yours</h1>
<p><strong>${formatUsdc(result.amount)} USDC</strong> has been sent to your account:<br>
<code>${result.beneficiary}</code></p>
<p>Receipt: <a href="${result.explorer}">${result.txHash}</a></p>
<hr>
<p style="color:#666">Nothing was taken from you and nothing was charged.
Testnet only. Unaudited software.</p>
</body>`,
    );
  } catch (err) {
    json(res, 503, {error: (err as Error).message});
  }
}

const server = createServer(async (req: IncomingMessage, res: ServerResponse) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
  const p = url.pathname;

  if (p === '/health') {
    json(res, 200, {
      ok: true,
      chainId: chain.chainId,
      rpc: chain.rpcUrl,
      watched: watchedVaults,
      indexed: ix.allSnapshots().map((s) => s.address),
      credentials: credentialStatus(),
    });
    return;
  }

  if (p === '/vaults') {
    json(
      res,
      200,
      ix.allSnapshots().map((s) => ({
        address: s.address,
        state: STATE_NAMES[s.state],
        balanceUsdc: formatUsdc(s.totalAssets),
      })),
    );
    return;
  }

  const m = p.match(/^\/vault\/(0x[a-fA-F0-9]{40})\/state$/);
  if (m && m[1]) {
    vaultState(res, m[1]);
    return;
  }

  const ev = p.match(/^\/vault\/(0x[a-fA-F0-9]{40})\/events$/);
  if (ev && ev[1]) {
    json(res, 200, ix.store.recentFor(ev[1]));
    return;
  }

  const exec = p.match(/^\/claim\/(.+)\/receive$/);
  if (exec && exec[1] && req.method === 'POST') {
    await claimExecute(res, exec[1]);
    return;
  }

  const cl = p.match(/^\/claim\/(.+)$/);
  if (cl && cl[1]) {
    claimPage(res, cl[1]);
    return;
  }

  // Mints a claim link for a tier. Local convenience; would need auth before hosting.
  const mint = p.match(/^\/admin\/claim-link\/(0x[a-fA-F0-9]{40})\/(\d+)$/);
  if (mint && mint[1] && mint[2]) {
    try {
      const snap = ix.snapshot(mint[1]);
      const tier = Number(mint[2]);
      const payee = snap?.beneficiaries[tier]?.payee;
      if (!payee) {
        json(res, 404, {error: 'unknown vault or tier'});
        return;
      }
      const link = mintClaimLink(
        api.publicBaseUrl,
        mint[1],
        tier,
        payee,
        secrets.claimLinkSecret(),
      );
      json(res, 200, link);
    } catch (err) {
      json(res, 503, {error: (err as Error).message});
    }
    return;
  }

  json(res, 404, {error: 'not found'});
});

// --- Telegram poller (only if a token is provisioned) ----------------------
async function runBot(): Promise<void> {
  if (!telegram.isConfigured()) {
    console.log('[telegram] no TELEGRAM_BOT_TOKEN — bot disabled');
    return;
  }
  console.log('[telegram] bot polling');
  let offset = 0;
  for (;;) {
    try {
      offset = await telegram.pollUpdates(offset, async (chatId, text) => {
        if (text.startsWith('/start') || text.startsWith('/help')) return telegram.HELP;

        if (text.startsWith('/link')) {
          const addr = text.split(/\s+/)[1];
          if (!addr || !/^0x[a-fA-F0-9]{40}$/.test(addr)) {
            return 'Usage: /link 0xYourVaultAddress';
          }
          const snap = ix.snapshot(addr);
          if (!snap) return 'I am not watching that vault. Ask the operator to add it.';
          ix.store.updateVault(addr, {ownerChatId: chatId});
          return telegram.linkReply(snap.address, snap.state, snap.secondsUntilNextRung);
        }

        const rec = ix.store.vaultByChatId(chatId);
        if (text.startsWith('/alive')) {
          if (!rec) return 'Link a vault first: /link 0xYourVaultAddress';
          return telegram.aliveReply(rec.address);
        }

        if (text.startsWith('/status')) {
          if (!rec) return 'Link a vault first: /link 0xYourVaultAddress';
          const snap = ix.snapshot(rec.address);
          if (!snap) return 'No data for that vault yet.';
          return telegram.linkReply(snap.address, snap.state, snap.secondsUntilNextRung);
        }

        return telegram.HELP;
      });
    } catch (err) {
      console.error('[telegram] poll failed:', (err as Error).message);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

const creds = credentialStatus();
console.log('Heirloom services — UNAUDITED TESTNET CODE');
console.log('credentials:', creds);
if (!creds.circleWallets) console.log('[circle] disabled — no CIRCLE_API_KEY/CIRCLE_ENTITY_SECRET');
if (!creds.assistedClaimRelayer) {
  console.log('[relayer] disabled — no HELPER_PRIVATE_KEY; the receive button will be inert');
} else {
  console.log('[relayer] assisted claims enabled, helper', relayer.helperAddress());
}
void circle.isConfigured();

await ix.refreshStates();
server.listen(api.port, () => {
  console.log(`[api] http://localhost:${api.port}`);
  console.log(`  GET /health`);
  console.log(`  GET /vaults`);
  console.log(`  GET /vault/:address/state`);
  console.log(`  GET /vault/:address/events`);
});
void ix.start();
void runBot();
