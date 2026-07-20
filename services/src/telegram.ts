/**
 * Telegram "/alive" bot and the reminder pipeline.
 *
 * KEY CUSTODY: this bot never holds, requests, or touches an owner's private
 * key, and it has no signing path at all. `heartbeat()` is `onlyOwner`
 * (HeirloomVault.sol:181) and the deployed contract has NO delegated-heartbeat
 * function, so option (b) from the brief — a low-privilege delegate address —
 * is not available without a contract change. See CONTRACT_ENHANCEMENT below.
 *
 * So the bot implements option (a): it returns a PREPARED transaction the owner
 * signs in their own wallet. The bot's job is to know WHEN to nag and to make
 * signing one click, not to be trusted with anything.
 *
 * Non-custodial by construction: if this whole service is compromised, the
 * worst an attacker gets is the ability to send a Telegram message asking
 * someone to sign a heartbeat. There is no key to steal.
 */
import {secrets, chain, api} from './config.js';
import {encodeFunctionData} from 'viem';
import {vaultAbi} from './abi.js';
import {
  VaultState,
  STATE_NAMES,
  formatDuration,
  type LadderConfig,
  rungEntersAt,
} from './ladder.js';

export const CONTRACT_ENHANCEMENT = `
Enhancement worth considering: a delegated heartbeat.

Today heartbeat() is onlyOwner, so proving liveness requires the owner's own
key every time. A "heartbeat delegate" — an address the owner authorises,
through the existing 7-day config timelock, that may ONLY call heartbeat() and
nothing else — would let a phone bot or a watch app prove liveness without the
owner unlocking a wallet.

Why it is defensible: the delegate can only ever DELAY escalation, never move
funds, never change config, never claim. Its worst-case abuse is keeping a vault
Active when the owner is in fact gone, which is exactly what the ladder's other
tiers and the guardians exist to catch.

Why it is NOT free: it weakens the meaning of "the owner signed", which is the
single signal the entire product is built on. A compromised delegate could mask
a real death indefinitely. It would need its own veto path and probably its own
shorter timelock.

Not implemented. Flagged as a design decision for the maintainer, not something
a service layer should introduce on its own.
`.trim();

const API = 'https://api.telegram.org/bot';

async function tg(method: string, body: unknown): Promise<unknown> {
  const token = secrets.telegramBotToken();
  const res = await fetch(`${API}${token}/${method}`, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body),
  });
  if (!res.ok) {
    throw new Error(`Telegram ${method} failed: ${res.status} ${await res.text()}`);
  }
  return res.json();
}

export async function sendMessage(chatId: string, text: string): Promise<void> {
  await tg('sendMessage', {
    chat_id: chatId,
    text,
    parse_mode: 'Markdown',
    disable_web_page_preview: true,
  });
}

export function isConfigured(): boolean {
  try {
    secrets.telegramBotToken();
    return true;
  } catch {
    return false;
  }
}

/**
 * Builds the unsigned heartbeat transaction for an owner to sign themselves.
 * Pure — no key, no network, no side effects. This is the whole of option (a).
 */
export function buildHeartbeatTx(vault: string): {
  to: string;
  data: `0x${string}`;
  value: '0x0';
  chainId: number;
} {
  return {
    to: vault,
    data: encodeFunctionData({abi: vaultAbi, functionName: 'heartbeat'}),
    value: '0x0',
    chainId: chain.chainId,
  };
}

/**
 * A link the owner opens in their own wallet to sign the heartbeat.
 *
 * EIP-681 is the interoperable form. Wallet support for it varies, so the
 * message also carries the raw calldata — an owner with any wallet can always
 * paste that rather than being stuck behind a deep link that their app ignores.
 */
export function heartbeatDeepLink(vault: string): string {
  return `ethereum:${vault}@${chain.chainId}/heartbeat`;
}

export function aliveReply(vault: string): string {
  const tx = buildHeartbeatTx(vault);
  return [
    '*Prove you are here*',
    '',
    'This bot cannot sign for you — it does not have your key, and never will.',
    'Open this in your wallet and approve:',
    '',
    `\`${heartbeatDeepLink(vault)}\``,
    '',
    'If your wallet ignores that link, send a transaction manually:',
    '',
    `  to:     \`${tx.to}\``,
    `  data:   \`${tx.data}\``,
    `  value:  0`,
    `  chain:  ${tx.chainId} (Arc testnet)`,
    '',
    `Once it confirms, your clock resets to zero and every tier is cancelled.`,
    `Track it: ${chain.explorer}/address/${vault}`,
  ].join('\n');
}

export function linkReply(vault: string, state: VaultState, until: bigint): string {
  return [
    `*Linked to vault* \`${vault}\``,
    '',
    `Current state: *${STATE_NAMES[state]}*`,
    state === VaultState.Active
      ? `Next reminder in ${formatDuration(until)} of silence.`
      : `Send /alive to reset the ladder.`,
    '',
    'I will message you when this vault crosses a tier. I hold no key and can',
    'only ever ask you to sign.',
  ].join('\n');
}

/**
 * The reminder the PRD's pipeline sends on crossing into Nagging.
 * States the deadline concretely — "in 90 days" is easier to ignore than a date.
 */
export function reminderMessage(
  vault: string,
  state: VaultState,
  lastActivity: bigint,
  ladder: LadderConfig,
  now: bigint,
): string {
  const nextState = ((state as number) + 1) as VaultState;
  const entersAt = rungEntersAt(lastActivity, nextState, ladder);
  const remaining = entersAt !== null && entersAt > now ? entersAt - now : 0n;

  const headline: Record<number, string> = {
    [VaultState.Nagging]: 'Your vault has not seen you in a while',
    [VaultState.GuardianAlert]: 'Your guardians have been notified',
    [VaultState.CareMode]: 'Care mode is active on your vault',
    [VaultState.Claimable]: 'Your vault is now claimable by your heirs',
  };

  const consequence: Record<number, string> = {
    [VaultState.Nagging]: `In ${formatDuration(remaining)} your guardians are alerted.`,
    [VaultState.GuardianAlert]: `In ${formatDuration(remaining)} care mode begins — a designated guardian gets capped spending.`,
    [VaultState.CareMode]: `In ${formatDuration(remaining)} your beneficiaries can begin claiming.`,
    [VaultState.Claimable]: 'Your beneficiaries can claim now, in the order you set.',
  };

  return [
    `*${headline[state] ?? 'Vault state changed'}*`,
    '',
    `Vault: \`${vault}\``,
    `State: *${STATE_NAMES[state]}*`,
    '',
    consequence[state] ?? '',
    '',
    state === VaultState.Claimable
      ? 'If you are reading this, you can still stop it — one signature cancels everything, until an heir claims.'
      : 'One signature cancels all of it. Send /alive.',
  ].join('\n');
}

/** Long-poll the Bot API and handle /start, /link, /alive, /status. */
export async function pollUpdates(
  offset: number,
  handler: (chatId: string, text: string) => Promise<string>,
): Promise<number> {
  const res = (await tg('getUpdates', {offset, timeout: 25})) as {
    result?: Array<{
      update_id: number;
      message?: {chat: {id: number}; text?: string};
    }>;
  };
  let next = offset;
  for (const u of res.result ?? []) {
    next = u.update_id + 1;
    const chatId = u.message?.chat?.id;
    const text = u.message?.text;
    if (chatId === undefined || !text) continue;
    try {
      const reply = await handler(String(chatId), text.trim());
      if (reply) await sendMessage(String(chatId), reply);
    } catch (err) {
      await sendMessage(String(chatId), `Something went wrong: ${(err as Error).message}`);
    }
  }
  return next;
}

export const HELP = [
  '*Heirloom*',
  '',
  '/link `<vault address>` — watch a vault and get reminders',
  '/alive — get a heartbeat transaction to sign in your own wallet',
  '/status — current rung and time to the next one',
  '',
  'This bot never holds your key.',
].join('\n');

export const publicBaseUrl = api.publicBaseUrl;
