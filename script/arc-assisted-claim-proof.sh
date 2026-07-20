#!/usr/bin/env bash
# Heirloom - on-chain proof of the ASSISTED CLAIM path (Q11).
#
# The point: a HELPER account with no role whatsoever triggers claim(), and the
# funds land at the registered heir. The helper is never paid and pays the gas.
#
# Runs against the seconds-scale DEMO vault so the full ladder fits in minutes.
# UNAUDITED TESTNET CODE.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

DEMO="${DEMO_VAULT:?set DEMO_VAULT}"
USDC=0x3600000000000000000000000000000000000000
RPC="$ARC_TESTNET_RPC_URL"
LOG=/tmp/heirloom-assisted.log
: > "$LOG"

# The helper is the care guardian's key reused as a no-role caller on THIS
# vault's claim path - it is not a beneficiary, so it must gain nothing.
HELPER_KEY=$(cast wallet private-key --mnemonic "$DEMO_MNEMONIC" --mnemonic-index 3)
HELPER=$(cast wallet address --mnemonic "$DEMO_MNEMONIC" --mnemonic-index 3)
HEIR=$(cast wallet address --mnemonic "$DEMO_MNEMONIC" --mnemonic-index 4)

log(){ echo "$*" | tee -a "$LOG"; }
bal(){ cast call "$USDC" 'balanceOf(address)(uint256)' "$1" --rpc-url "$RPC" | awk '{print $1}'; }
state(){ cast call "$DEMO" 'state()(uint8)' --rpc-url "$RPC" | awk '{print $1}'; }
assets(){ cast call "$DEMO" 'totalAssets()(uint256)' --rpc-url "$RPC" | awk '{print $1}'; }

send(){ # send <label> <to> <sig> <key> [args...]
  local label="$1" to="$2" sig="$3" key="$4"; shift 4
  local out h b g
  out=$(cast send "$to" "$sig" "$@" --private-key "$key" --rpc-url "$RPC" --json 2>/dev/null)
  h=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
  b=$(echo "$out" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
  g=$(echo "$out" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['gasUsed'],16))")
  log "TX|$label|$h|$b|$g"
}

NAMES=(Active Nagging GuardianAlert CareMode Claimable Claimed Recovered)

log "=== assisted-claim proof (Q11) ==="
log "vault  $DEMO"
log "helper $HELPER  (no role on this vault)"
log "heir   $HEIR  (registered tier-0 beneficiary)"

send "approve" "$USDC" "approve(address,uint256)" "$PRIVATE_KEY" "$DEMO" 2000000
send "deposit" "$DEMO" "deposit(uint256)"         "$PRIVATE_KEY" 2000000
T0=$(cast call "$DEMO" 'lastActivity()(uint64)' --rpc-url "$RPC" | awk '{print $1}')
log "funded $(assets) (6dp)  state=${NAMES[$(state)]}"

HELPER_BEFORE=$(bal "$HELPER")
HEIR_BEFORE=$(bal "$HEIR")
log "before: helper=$HELPER_BEFORE heir=$HEIR_BEFORE"

log "waiting for Claimable (+240s)..."
while :; do
  NOW=$(cast block latest --rpc-url "$RPC" -f timestamp)
  if [ "$NOW" -ge $((T0 + 240)) ] && [ "$(state)" -ge 4 ]; then break; fi
  sleep 5
done
log "state=${NAMES[$(state)]}  activeTier=$(cast call "$DEMO" 'activeTier()(uint256)' --rpc-url "$RPC" | awk '{print $1}')"

log "HELPER (not a beneficiary) triggers the claim:"
send "assistedClaim" "$DEMO" "claim(uint256)" "$HELPER_KEY" 0

HELPER_AFTER=$(bal "$HELPER")
HEIR_AFTER=$(bal "$HEIR")
log "after : helper=$HELPER_AFTER heir=$HEIR_AFTER vault=$(assets) state=${NAMES[$(state)]}"
log "heir gained: $((HEIR_AFTER - HEIR_BEFORE)) (6dp)"
log "helper delta: $((HELPER_AFTER - HELPER_BEFORE)) (negative = paid gas, gained nothing)"
log "=== DONE ==="
