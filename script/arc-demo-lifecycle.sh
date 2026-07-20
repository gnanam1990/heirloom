#!/usr/bin/env bash
# Heirloom - on-chain lifecycle proof against the seconds-scale DEMO vault.
#
# Walks the full ladder on Arc testnet in real time:
#   fund -> Active -> Nagging(60s) -> GuardianAlert(120s) -> CareMode(180s)
#   -> care spend -> Claimable(240s) -> claim -> Claimed
#
# UNAUDITED TESTNET CODE. The demo vault uses seconds-scale tier durations and
# is NOT a real safety net; it exists so the cascade can be shown on-chain
# without waiting 365 days.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

DEMO=0x12dbb68F3c68BD47BF9799db7112f03ac37f6042
USDC=0x3600000000000000000000000000000000000000
RPC="$ARC_TESTNET_RPC_URL"
LOG=/tmp/heirloom-lifecycle.log
: > "$LOG"

CG_KEY=$(cast wallet private-key --mnemonic "$DEMO_MNEMONIC" --mnemonic-index 3)
H0_KEY=$(cast wallet private-key --mnemonic "$DEMO_MNEMONIC" --mnemonic-index 4)
H0=$(cast wallet address --mnemonic "$DEMO_MNEMONIC" --mnemonic-index 4)
BILLS=$(cast keccak BILLS)

log(){ echo "$*" | tee -a "$LOG"; }

send(){ # send <label> <to> <sig> <key> [args...]
  local label="$1" to="$2" sig="$3" key="$4"; shift 4
  local out
  out=$(cast send "$to" "$sig" "$@" --private-key "$key" --rpc-url "$RPC" --json 2>/dev/null)
  local h b g
  h=$(echo "$out" | python3 -c "import sys,json;print(json.load(sys.stdin)['transactionHash'])")
  b=$(echo "$out" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['blockNumber'],16))")
  g=$(echo "$out" | python3 -c "import sys,json;print(int(json.load(sys.stdin)['gasUsed'],16))")
  log "TX|$label|$h|$b|$g"
}

state(){ cast call "$DEMO" 'state()(uint8)' --rpc-url "$RPC" | awk '{print $1}'; }
assets(){ cast call "$DEMO" 'totalAssets()(uint256)' --rpc-url "$RPC" | awk '{print $1}'; }
lastact(){ cast call "$DEMO" 'lastActivity()(uint64)' --rpc-url "$RPC" | awk '{print $1}'; }

NAMES=(Active Nagging GuardianAlert CareMode Claimable Claimed Recovered)

log "=== Heirloom demo-vault lifecycle proof ==="
log "vault $DEMO  chain 5042002"

# ---- fund -------------------------------------------------------------
send "approve"  "$USDC" "approve(address,uint256)" "$PRIVATE_KEY" "$DEMO" 3000000
send "deposit"  "$DEMO" "deposit(uint256)"         "$PRIVATE_KEY" 3000000
T0=$(lastact)
log "funded: $(assets) (6dp)  lastActivity=$T0  state=${NAMES[$(state)]}"

# ---- walk the ladder --------------------------------------------------
# Rungs are measured from lastActivity. No OWNER action may happen from here
# on, or the clock resets - that is invariant 1 doing its job.
watch_until(){ # watch_until <target_rung_seconds> <expected_state_idx>
  local target="$1" want="$2" now s
  while :; do
    now=$(cast block latest --rpc-url "$RPC" -f timestamp)
    s=$(state)
    if [ "$now" -ge $((T0 + target)) ] && [ "$s" -ge "$want" ]; then
      log "RUNG|+${target}s|${NAMES[$s]}|blockts=$now"
      return 0
    fi
    sleep 5
  done
}

watch_until 60  1
watch_until 120 2
watch_until 180 3

# ---- care mode: a capped payment to an APPROVED destination -----------
BILLS_PAYEE="$HEIRLOOM_CARE_BILLS_PAYEES"
log "care guardian paying approved BILLS payee $BILLS_PAYEE"
send "careSpend" "$DEMO" "careSpend(address,bytes32,uint256)" "$CG_KEY" "$BILLS_PAYEE" "$BILLS" 1000000
log "after careSpend: assets=$(assets)  state=${NAMES[$(state)]}  lastActivity=$(lastact) (unchanged => guardian spend does not reset the ladder)"

# ---- claimable: the cascade -------------------------------------------
watch_until 240 4
TIER=$(cast call "$DEMO" 'activeTier()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
log "activeTier=$TIER  registered payee=$H0"
send "claim" "$DEMO" "claim(uint256)" "$H0_KEY" "$TIER"
log "after claim: vault=$(assets)  heirBalance=$(cast call $USDC 'balanceOf(address)(uint256)' $H0 --rpc-url $RPC | awk '{print $1}')  state=${NAMES[$(state)]}"
log "=== DONE ==="
