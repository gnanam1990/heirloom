/**
 * Configuration and credential loading.
 *
 * UNAUDITED TESTNET CODE. Do not point this at anything holding real value.
 *
 * Design rule for this whole service: a missing credential is a LOUD, EARLY
 * failure naming exactly what is missing and where to get it. It is never a
 * silent fallback, a stub response, or a fake success. Half of this service
 * talks to other people's money and to a stranger's inbox; pretending to work
 * is worse than refusing to start.
 */
import {readFileSync} from 'node:fs';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, '..');

/** Minimal .env reader — avoids a dependency for ~15 lines of parsing. */
function loadDotEnv(): void {
  try {
    const raw = readFileSync(resolve(ROOT, '.env'), 'utf8');
    for (const line of raw.split('\n')) {
      const t = line.trim();
      if (!t || t.startsWith('#')) continue;
      const eq = t.indexOf('=');
      if (eq === -1) continue;
      const key = t.slice(0, eq).trim();
      let val = t.slice(eq + 1).trim();
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }
      if (process.env[key] === undefined) process.env[key] = val;
    }
  } catch {
    // No .env is fine for the chain-only paths; anything needing a credential
    // will fail explicitly below.
  }
}
loadDotEnv();

/** Thrown when a feature is used without the credential it requires. */
export class MissingCredentialError extends Error {
  constructor(
    readonly varName: string,
    readonly feature: string,
    readonly howToGet: string,
  ) {
    super(
      `Missing ${varName} — required for: ${feature}.\n` +
        `  How to obtain: ${howToGet}\n` +
        `  Add it to services/.env (gitignored). See services/.env.example.`,
    );
    this.name = 'MissingCredentialError';
  }
}

function required(name: string, feature: string, howToGet: string): string {
  const v = process.env[name];
  if (!v || v.startsWith('<') || v === '') {
    throw new MissingCredentialError(name, feature, howToGet);
  }
  return v;
}

function optional(name: string, fallback: string): string {
  const v = process.env[name];
  return !v || v.startsWith('<') ? fallback : v;
}

// ---------------------------------------------------------------------------
// Chain — no credentials needed. These paths always work.
// ---------------------------------------------------------------------------

export const chain = {
  rpcUrl: optional('ARC_TESTNET_RPC_URL', 'https://rpc.testnet.arc.network'),
  chainId: 5042002,
  explorer: 'https://testnet.arcscan.app',
  /** Arc USDC, ERC-20 surface, 6dp. Verified on-chain, see docs/addresses.md. */
  usdc: '0x3600000000000000000000000000000000000000' as const,
} as const;

/** Vaults to watch. Defaults to the deployed pair from docs/addresses.md. */
export const watchedVaults: readonly `0x${string}`[] = optional(
  'HEIRLOOM_VAULTS',
  '0x0CA49eBD6fba33530287cb8eAE9aE565e80e18dA,0x0D884E62B1dE894df1651910849E534aDf4deaDa',
)
  .split(',')
  .map((s) => s.trim().toLowerCase())
  .filter(Boolean) as `0x${string}`[];

export const api = {
  port: Number(optional('PORT', '8787')),
  /** Public base URL, used when minting claim links. */
  publicBaseUrl: optional('PUBLIC_BASE_URL', 'http://localhost:8787'),
};

export const indexer = {
  /** Blocks per getLogs page. Arc is fast; keep this modest to stay under RPC caps. */
  pageSize: Number(optional('INDEXER_PAGE_SIZE', '2000')),
  pollMs: Number(optional('INDEXER_POLL_MS', '5000')),
  /** Where to start if there is no stored cursor. 0 = deployment scan from genesis. */
  startBlock: BigInt(optional('INDEXER_START_BLOCK', '52730264')),
  dbPath: optional('INDEXER_DB', resolve(ROOT, 'heirloom-index.json')),
};

// ---------------------------------------------------------------------------
// Credentialed features — each throws a named error until provisioned.
// ---------------------------------------------------------------------------

export const secrets = {
  /** HMAC key for signing claim links. Generate: openssl rand -hex 32 */
  claimLinkSecret: () =>
    required(
      'CLAIM_LINK_SECRET',
      'signing heir claim links',
      'generate locally: openssl rand -hex 32',
    ),

  telegramBotToken: () =>
    required(
      'TELEGRAM_BOT_TOKEN',
      'the Telegram /alive bot',
      'message @BotFather on Telegram, /newbot, copy the token',
    ),

  /**
   * Key used ONLY to trigger assisted claims. Deliberately separate from any
   * owner key. Per HeirloomVault.sol:253 it cannot name a destination, so the
   * worst a thief could do with it is pay gas to send an heir their own
   * inheritance. Generate a throwaway: `cast wallet new`, fund it with a little
   * Arc testnet USDC for gas.
   */
  helperPrivateKey: () =>
    required(
      'HELPER_PRIVATE_KEY',
      'triggering assisted claims on an heir\'s behalf',
      'cast wallet new, then fund it with a small amount of Arc testnet USDC for gas',
    ),

  circleApiKey: () =>
    required(
      'CIRCLE_API_KEY',
      'creating heir wallets via Circle Programmable Wallets',
      'https://console.circle.com — Developer Controlled Wallets, testnet API key',
    ),

  circleEntitySecret: () =>
    required(
      'CIRCLE_ENTITY_SECRET',
      'Circle developer-controlled wallet operations',
      'https://console.circle.com — register an entity secret ciphertext',
    ),

  smtp: () => ({
    host: required('SMTP_HOST', 'emailing claim links to heirs', 'any SMTP provider'),
    port: Number(optional('SMTP_PORT', '587')),
    user: required('SMTP_USER', 'emailing claim links to heirs', 'your SMTP provider'),
    pass: required('SMTP_PASS', 'emailing claim links to heirs', 'your SMTP provider'),
    from: optional('SMTP_FROM', 'heirloom@example.invalid'),
  }),
};

/** Reports which credentialed features are currently usable. */
export function credentialStatus(): Record<string, boolean> {
  const ok = (f: () => unknown) => {
    try {
      f();
      return true;
    } catch {
      return false;
    }
  };
  return {
    claimLinks: ok(secrets.claimLinkSecret),
    telegramBot: ok(secrets.telegramBotToken),
    assistedClaimRelayer: ok(secrets.helperPrivateKey),
    circleWallets: ok(secrets.circleApiKey) && ok(secrets.circleEntitySecret),
    email: ok(secrets.smtp),
  };
}
