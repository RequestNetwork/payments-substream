#!/usr/bin/env bash
# Stub-CLI tests for sinks/supervisor.sh: run `bash sinks/tests/run-tests.sh` (CI: image.yml).
# Each case gets its own STUB_DIR; the supervisor sees the fake `substreams` and `timeout` in
# sinks/tests/bin first on PATH, empty .spkg files and the real sinks/chains.env. Needs bash, perl,
# python3 and pgrep/pkill. Exit status = number of failed checks.
# shellcheck disable=SC2015  # `check && pass || fail` one-liners: pass only echoes, never fails
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
WT=$(cd "$ROOT/../.." && pwd)
CASES=$(mktemp -d "${TMPDIR:-/tmp}/supervisor-tests.XXXXXX")
trap 'pkill -f "$ROOT/bin/substreams" 2>/dev/null; rm -rf "$CASES"' EXIT
# make_app <dir>: an /app-shaped tree (the supervisor reads chains.env and the packages relative to
# its own path, never from the environment) holding a copy of the worktree's supervisor.
make_app() {
  rm -rf "$1"; mkdir -p "$1/sinks"
  cp "$WT/sinks/supervisor.sh" "$WT/sinks/chains.env" "$1/sinks/"
  : >"$1/tron.spkg"; : >"$1/evm.spkg"
}
make_app "$CASES/app"
SUP=$CASES/app/sinks/supervisor.sh
export PATH="$ROOT/bin:$PATH"
export SUBSTREAMS_API_TOKEN=stub-token
fails=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
expect() { # expect <-eq|-ge> <n> <grep-pattern> <file> <label>
  local n ok=false; n=$(grep -c -- "$3" "$4")
  case $1 in
    -eq) [ "$n" -eq "$2" ] && ok=true ;;
    -ge) [ "$n" -ge "$2" ] && ok=true ;;
  esac
  if [ "$ok" = true ]; then pass "$5 ($n)"; else fail "$5 (got $n, want $1 $2)"; echo "--- log:"; cat "$4"; echo "---"; fi
}
new_case() { export STUB_DIR=$CASES/$1; rm -rf "$STUB_DIR"; mkdir -p "$STUB_DIR"; LOG=$STUB_DIR/out.log; }
# run_sup <seconds> [env...]: start the supervisor with env, TERM it after N seconds, record exit code.
run_sup() {
  local secs=$1; shift
  env "$@" "$SUP" >"$LOG" 2>"$STUB_DIR/err.log" &
  SUP_PID=$!
  sleep "$secs"
  kill -TERM "$SUP_PID" 2>/dev/null
  wait "$SUP_PID"; SUP_EXIT=$?
}

echo "=== A. setup fails twice for base, tron runs meanwhile"
new_case A; echo 2 >"$STUB_DIR/setup_fail_base"
run_sup 18 CHAINS=tron,base SUBSTREAMS_SINK_DSN='postgres://u:p@h/db?sslmode=disable' SINK_PROGRESS_INTERVAL_SECONDS=1 SINK_STALL_SECONDS=600
expect -eq 2 '"event":"sink_setup_failed","chain":"base","code":3,"hint":"create the schema first (setup-payments-db.sql)","retry_in_seconds":' "$LOG" "two sink_setup_failed for base"
expect -eq 1 '"event":"sink_setup_failed".*"retry_in_seconds":5}' "$LOG" "first retry 5 s"
expect -eq 1 '"event":"sink_setup_failed".*"retry_in_seconds":10}' "$LOG" "second retry 10 s"
expect -eq 1 '"event":"sink_started","chain":"base".*"module_hash":"hash_base"' "$LOG" "base eventually started with module_hash"
expect -eq 1 '"event":"sink_started","chain":"tron".*"module_hash":"hash_tron"' "$LOG" "tron started once"
expect -ge 10 '"event":"sink_progress","chain":"tron"' "$LOG" "tron progress sampled while base retried"
expect -ge 10 '"event":"sink_progress","chain":"base"' "$LOG" "base progress sampled while retrying (null)"
[ "$SUP_EXIT" -eq 0 ] && pass "A exit 0 on TERM" || fail "A exit $SUP_EXIT"
head -3 "$LOG"; grep sink_setup_failed "$LOG"; grep sink_started "$LOG"

echo "=== B. finished replay: never stalled, supervisor_idle once, stays alive"
new_case B
run_sup 8 CHAINS=sepolia SINK_STOP_BLOCK_SEPOLIA=100 SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1 SINK_STALL_SECONDS=2
expect -eq 1 '"event":"sink_finished","chain":"sepolia"' "$LOG" "sink_finished"
expect -eq 0 'sink_stalled' "$LOG" "no sink_stalled"
expect -eq 0 'sink_exited' "$LOG" "no restart after finish"
expect -eq 1 '"event":"supervisor_idle","reason":"all_chains_finished"' "$LOG" "supervisor_idle once"
expect -ge 4 '"event":"sink_progress","chain":"sepolia".*"status":"finished"' "$LOG" "finished chain still reported"
[ "$SUP_EXIT" -eq 0 ] && pass "B stayed alive until TERM, exit 0" || fail "B exit $SUP_EXIT"
grep -c sink-run "$STUB_DIR/sink_runs.log" | grep -q '^1$' && pass "sink ran exactly once" || fail "sink run count: $(cat "$STUB_DIR/sink_runs.log")"
grep -E 'sink_finished|supervisor_idle|"status":"finished"' "$LOG" | head -4

echo "=== B2. healthcheck: healthy while a sink runs or once idle, unhealthy otherwise"
new_case B2
rm -f /tmp/payments-sink-idle
env CHAINS=sepolia SINK_STOP_BLOCK_SEPOLIA=100 SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1 "$SUP" >"$LOG" 2>/dev/null &
b2_pid=$!
sleep 6
[ -e /tmp/payments-sink-idle ] && pass "B2 idle marker written once every chain finished" || fail "B2 no idle marker"
"$WT/sinks/healthcheck.sh" && pass "B2 healthy while idle" || fail "B2 unhealthy while idle"
kill -TERM "$b2_pid" 2>/dev/null; wait "$b2_pid" 2>/dev/null
[ -e /tmp/payments-sink-idle ] && fail "B2 idle marker left after shutdown" || pass "B2 idle marker removed on shutdown"
pkill -f "$ROOT/bin/substreams" 2>/dev/null
"$WT/sinks/healthcheck.sh" && fail "B2 healthy with no sink and no marker" || pass "B2 unhealthy with no sink and no marker"
new_case B3
env CHAINS=base SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1 "$SUP" >"$LOG" 2>/dev/null &
b3_pid=$!
sleep 3
"$WT/sinks/healthcheck.sh" && pass "B3 healthy while a sink runs" || fail "B3 unhealthy while a sink runs"
kill -TERM "$b3_pid" 2>/dev/null; wait "$b3_pid" 2>/dev/null
new_case B4; echo 99 >"$STUB_DIR/setup_fail_base"
env CHAINS=base SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1 "$SUP" >"$LOG" 2>/dev/null &
b4_pid=$!
sleep 3
grep -q sink_setup_failed "$LOG" && pass "B4 setup keeps failing" || fail "B4 setup did not fail"
"$WT/sinks/healthcheck.sh" && fail "B4 healthy while only setup retries" || pass "B4 unhealthy while only setup retries"
kill -TERM "$b4_pid" 2>/dev/null; wait "$b4_pid" 2>/dev/null
pkill -f "$ROOT/bin/substreams" 2>/dev/null; true

echo "=== C. progress semantics: old-hash row -> current-hash row -> advance"
new_case C
printf 'Module oldhash000000: Block #500 (0xabc) [cursor-text]\n' >"$STUB_DIR/cursor_base"
( sleep 3.5; printf 'Module oldhash000000: Block #500 (0xabc) [c]\nModule hash_base: Block #600 (0xdef) [c2]\n' >"$STUB_DIR/cursor_base";
  sleep 2; printf 'Module oldhash000000: Block #500 (0xabc) [c]\nModule hash_base: Block #700 (0x123) [c3]\n' >"$STUB_DIR/cursor_base";
  sleep 2; printf 'Module oldhash000000: Block #500 (0xabc) [c]\nModule hash_base: Block #700 (0x123) [c3]\n' >"$STUB_DIR/cursor_base" ) &
run_sup 10 CHAINS=base SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1 SINK_STALL_SECONDS=600
expect -ge 2 '"event":"sink_progress","chain":"base","block_num":500,"cursor":"inherited"}' "$LOG" "inherited samples at 500"
expect -ge 1 '"event":"sink_progress","chain":"base","block_num":600,"cursor":"current"}' "$LOG" "current sample at 600"
expect -eq 0 '"event":"sink_progress_advanced".*"block_num":500' "$LOG" "inherited never an advance"
expect -eq 0 '"event":"sink_progress_advanced".*"block_num":600' "$LOG" "first current sample is not an advance"
expect -eq 1 '"event":"sink_progress_advanced","chain":"base","block_num":700,"previous_block_num":600}' "$LOG" "advanced 600->700 exactly once"
expect -eq 0 'sink_stalled' "$LOG" "no stall with large threshold"
grep -E 'sink_progress' "$LOG" | sort | uniq -c

echo "=== D. stalled uses the current-hash block; inherited-only still stalls with null"
new_case D
printf 'Module oldhash: Block #42 (x) [c]\n' >"$STUB_DIR/cursor_tron"
( sleep 4.5; printf 'Module oldhash: Block #42 (x) [c]\nModule hash_tron: Block #1000 (y) [c]\n' >"$STUB_DIR/cursor_tron" ) &
run_sup 9 CHAINS=tron SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1 SINK_STALL_SECONDS=3
expect -ge 1 '"event":"sink_stalled","chain":"tron","block_num":null,"stalled_seconds":' "$LOG" "stalled with null block while only inherited row exists"
expect -ge 2 '"event":"sink_stalled","chain":"tron","block_num":1000,"stalled_seconds":' "$LOG" "stalled with current-hash block 1000"
expect -eq 0 '"event":"sink_stalled","chain":"tron","block_num":42' "$LOG" "never stalled with the inherited block"
expect -eq 0 'sink_progress_advanced' "$LOG" "no advance (first current sample is a baseline)"
grep sink_stalled "$LOG" | head -3

echo "=== E. legacy DSN rules"
new_case E1
env CHAINS=tron,base DSN='postgres://u:p@h/db' "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "E1 legacy DSN + tron,base exit 1" || fail "E1 exit $code"
expect -eq 1 '"event":"sink_config_invalid","chain":null,"field":"CHAINS","reason":"legacy DSN supports tron only"}' "$LOG" "E1 reason"
new_case E2
run_sup 3 DSN='postgres://u:p@h/db?x=1' SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_started","chain":"tron".*"schema":"public"' "$LOG" "E2 legacy DSN alone runs tron in public"
grep -q 'sink-run public ' "$STUB_DIR/sink_runs.log" && pass "E2 sink got schemaName=public" || fail "E2 runs: $(cat "$STUB_DIR/sink_runs.log")"
grep -q 'schemaName=public' "$STUB_DIR/dsn_env.log" && pass "E2 dsn (env) carried &schemaName=public" || fail "E2 dsn env"
grep -q 'postgres://' "$STUB_DIR/calls.log" && fail "E2 DSN leaked into argv" || pass "E2 DSN never in argv"
[ "$SUP_EXIT" -eq 0 ] && pass "E2 exit 0" || fail "E2 exit $SUP_EXIT"
new_case E3
env CHAINS=base DSN='postgres://u:p@h/db' "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "E3 legacy DSN + base exit 1" || fail "E3 exit $code"

echo "=== F. duplicate chains"
new_case F
env CHAINS='tron, TRON' SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "F tron,TRON exit 1" || fail "F exit $code"
expect -eq 1 '"event":"sink_config_invalid","chain":"tron","field":"CHAINS","reason":"duplicate chain"}' "$LOG" "F reason"
grep -q sink_started "$LOG" && fail "F started a sink" || pass "F nothing started"
new_case F2
env CHAINS='tron,tron' SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "F2 tron,tron exit 1" || fail "F2 exit $code"

echo "=== G. config: empty CHAINS, bogus network, all-invalid, TERM leaves no orphans"
new_case G1
env CHAINS= SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "G1 empty CHAINS exit 1" || fail "G1 exit $code"
expect -eq 1 '"field":"CHAINS"' "$LOG" "G1 json error"
new_case G2
run_sup 3 CHAINS=tron,base SINK_NETWORK_BASE=bogus SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_config_invalid","chain":"base","field":"NETWORK"' "$LOG" "G2 bogus network skips base"
expect -eq 1 '"event":"sink_started","chain":"tron"' "$LOG" "G2 tron still runs"
[ "$SUP_EXIT" -eq 0 ] && pass "G2 exit 0" || fail "G2 exit $SUP_EXIT"
new_case G3
env CHAINS=base SINK_NETWORK_BASE=bogus SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "G3 no valid chain exit 1" || fail "G3 exit $code"
expect -eq 1 '"message":"no chain has a valid configuration"' "$LOG" "G3 message"
new_case G4; echo 99 >"$STUB_DIR/setup_fail_base"
run_sup 4 CHAINS=tron,base SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1
sleep 1
orphans=$(pgrep -f "$ROOT/bin/substreams" || true)
[ -z "$orphans" ] && pass "G4 no orphan stub processes after TERM (sink + setup-retry sleep)" || { fail "G4 orphans: $orphans"; pkill -f "$ROOT/bin/substreams"; }
[ "$SUP_EXIT" -eq 0 ] && pass "G4 exit 0" || fail "G4 exit $SUP_EXIT"
leftover=$(find /tmp "${TMPDIR:-/tmp}" -maxdepth 1 -name 'sink-supervisor.*' 2>/dev/null)
[ -z "$leftover" ] && pass "state dir cleaned" || fail "state dirs left behind: $leftover"
new_case G5; echo 7 >"$STUB_DIR/sink_exit_tron"
run_sup 4 CHAINS=tron SUBSTREAMS_SINK_DSN='postgres://u:p@h/db' SINK_PROGRESS_INTERVAL_SECONDS=1
expect -ge 1 '"event":"sink_exited","chain":"tron","exit_code":7,"restart_in_seconds":5}' "$LOG" "G5 crash restarts with backoff"
grep -q 'DSN\|u:p@h' "$LOG" && fail "DSN leaked to stdout" || pass "no DSN in stdout"

echo "=== H. audit guard rails (F2-F5)"
DSNV='postgres://u:p@h/db'
PROXY=TCUDPYnS9dH3WvFEaE7wN7vnDa51J4R4fd
# all_json <file> <label>: every stdout line parses as one JSON object.
all_json() {
  if python3 -c 'import json,sys
for l in open(sys.argv[1]):
    o=json.loads(l); assert isinstance(o,dict)' "$1" 2>/dev/null; then pass "$2 all lines valid JSON"; else fail "$2 invalid JSON line"; cat -v "$1"; fi
}
# reject <case> <field> <message-substring> [env...]: a lone invalid chain exits 1 with that field.
reject() {
  local c=$1 field=$2 msg=$3; shift 3
  new_case "$c"
  perl -e 'alarm 10; exec @ARGV' env "$@" "$SUP" >"$LOG" 2>/dev/null; code=$?
  pkill -f "$ROOT/bin/substreams" 2>/dev/null
  [ "$code" -eq 1 ] && pass "$c exit 1" || fail "$c exit $code"
  expect -eq 1 "\"event\":\"sink_config_invalid\",\"chain\":\"[a-z-]*\",\"field\":\"$field\".*$msg" "$LOG" "$c $field rejected"
  grep -q sink_started "$LOG" && fail "$c started a sink" || pass "$c nothing started"
  all_json "$LOG" "$c"
}
# Params come from the package manifest: every SINK_PARAMS_<CHAIN> override is rejected.
reject H1 PARAMS 'params come from the package manifest' CHAINS=tron SUBSTREAMS_SINK_DSN=$DSNV "SINK_PARAMS_TRON=mainnet_proxy_address=$PROXY"$'\n'"chain=tron"
reject H2 PARAMS 'params come from the package manifest' CHAINS=tron SUBSTREAMS_SINK_DSN=$DSNV "SINK_PARAMS_TRON=mainnet_proxy_address=TEvilEvilEvil"$'\n'"chain=tron"
reject H3 PARAMS 'params come from the package manifest' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_PARAMS_BASE=chain=base;addresses=0xabc'
new_case H9
run_sup 2 CHAINS=tron,base SUBSTREAMS_SINK_DSN=$DSNV SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_started","chain":"tron"' "$LOG" "H9 tron runs on its manifest params"
expect -eq 1 '"event":"sink_started","chain":"base"' "$LOG" "H9 base runs on its manifest params"
expect -eq 0 sink_config_invalid "$LOG" "H9 no config error"
grep -q -- '--params' "$STUB_DIR/calls.log" && fail "H9 a sink got --params" || pass "H9 no sink gets --params"
# F3 schema
reject H10 SCHEMA "does not match this chain's schema" CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_SCHEMA_BASE=mainnet
reject H11 SCHEMA "does not match this chain's schema" CHAINS=tron SUBSTREAMS_SINK_DSN=$DSNV SINK_SCHEMA_TRON=public
new_case H12
run_sup 2 CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_SCHEMA_BASE=base SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_started","chain":"base".*"schema":"base"' "$LOG" "H12 override equal to chains.env accepted"
new_case H13
make_app "$STUB_DIR/app"
sed 's/^BASE_SCHEMA=base$/BASE_SCHEMA=mainnet/' "$WT/sinks/chains.env" >"$STUB_DIR/app/sinks/chains.env"
env CHAINS=mainnet,base SUBSTREAMS_SINK_DSN=$DSNV "$STUB_DIR/app/sinks/supervisor.sh" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "H13 duplicate schema exit 1" || fail "H13 exit $code"
expect -eq 1 '"event":"sink_config_invalid","chain":null,"field":"SCHEMA","reason":"duplicate schema"}' "$LOG" "H13 reason"
[ -s "$STUB_DIR/sink_runs.log" ] || [ -s "$STUB_DIR/setup_ok.log" ] && fail "H13 started a sink" || pass "H13 neither chain started"
new_case H14
run_sup 2 DSN=$DSNV SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_started","chain":"tron".*"schema":"public"' "$LOG" "H14 legacy DSN still runs tron in public"
# F4 extra args
reject H15 EXTRA_ARGS 'flag not allowed: --dsn' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--dsn postgres://evil'
reject H16 EXTRA_ARGS 'flag not allowed: --plaintext' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--final-blocks-only --plaintext'
reject H17 EXTRA_ARGS 'flag not allowed: --api-token-envvar' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--api-token-envvar OTHER'
reject H18 EXTRA_ARGS 'flag not allowed: --params' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--params x=y'
reject H19 EXTRA_ARGS 'invalid value for --batch-block-flush-interval' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--batch-block-flush-interval abc'
reject H20 EXTRA_ARGS 'invalid value for --flush-retry-delay' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--flush-retry-delay 1x'
reject H21 EXTRA_ARGS 'invalid value for --flush-retry-count' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--flush-retry-count'
reject H22 EXTRA_ARGS 'flag not allowed: --insecure' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV "SINK_EXTRA_ARGS_BASE=--final-blocks-only"$'\n'"--insecure"
reject H23 EXTRA_ARGS 'flag not allowed: --batch-block-flush-interval=5' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--batch-block-flush-interval=5'
new_case H24
run_sup 2 CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_PROGRESS_INTERVAL_SECONDS=1 \
  "SINK_EXTRA_ARGS_BASE=--final-blocks-only  --batch-block-flush-interval 100"$'\n'"--batch-row-flush-interval 5 --live-block-flush-interval 1 --flush-retry-count 3 --flush-retry-delay 500ms"
expect -eq 1 '"event":"sink_started","chain":"base"' "$LOG" "H24 allow-listed extra args accepted"
grep -q -- '--prometheus-addr 127.0.0.1:9100 --final-blocks-only --batch-block-flush-interval 100 --batch-row-flush-interval 5 --live-block-flush-interval 1 --flush-retry-count 3 --flush-retry-delay 500ms$' "$STUB_DIR/calls.log" && pass "H24 extra args appended (newline-split too)" || { fail "H24 argv"; cat "$STUB_DIR/calls.log"; }
# F5 endpoint / network / json_str
reject H25 ENDPOINT 'streamingfast.io:443' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_ENDPOINT_BASE=evil.example:443 --plaintext'
reject H26 ENDPOINT 'streamingfast.io:443' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV "SINK_ENDPOINT_BASE=base.example:443"$'\n''{"severity":"WARNING","event":"sink_exited"}'
reject H27 ENDPOINT 'streamingfast.io:443' CHAINS=tron SUBSTREAMS_SINK_DSN=$DSNV 'SUBSTREAMS_ENDPOINTS_CONFIG_TRON=https://tron.example:443'
reject H28 NETWORK 'invalid network name' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_NETWORK_BASE=Base'
new_case H29
env CHAINS=$'ba\001se\033[31m' SUBSTREAMS_SINK_DSN=$DSNV "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "H29 control-char chain name exit 1" || fail "H29 exit $code"
all_json "$LOG" "H29"
LC_ALL=C grep -q $'[\001-\010\013-\037\177]' "$LOG" && fail "H29 raw control char in log" || pass "H29 no raw control char in log"
eval "$(sed -n '/^json_str() {/,/^}/p' "$SUP")"
got=$(json_str $'a"b\\c\nd\re\tf\001g\177h')
[ "$got" = '"a\"b\\c\nd\re\tfgh"' ] && pass "H30 json_str escapes \\n \\r \\t and drops other controls" || fail "H30 json_str got: $got"
python3 -c 'import json,sys; assert json.loads(sys.argv[1]) == "a\"b\\c\nd\re\tfgh"' "$got" && pass "H30 json_str output is a JSON string" || fail "H30 not JSON"
forged=$(json_str $'x"}\n{"severity":"WARNING","event":"sink_exited')
[ "$(printf '{"v":%s}\n' "$forged" | wc -l | tr -d ' ')" = 1 ] && pass "H31 newline cannot forge a second event line" || fail "H31 forged: $forged"

echo "=== I. audit guard rails, final round (token, endpoint host, evm params, paths, VM layout)"
reject I1 TOKEN_ENV 'SUBSTREAMS_API_TOKEN or SUBSTREAMS_API_TOKEN_ALT' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_TOKEN_ENV_BASE=SUBSTREAMS_SINK_DSN
reject I2 TOKEN_ENV 'SUBSTREAMS_API_TOKEN or SUBSTREAMS_API_TOKEN_ALT' CHAINS=tron DSN=$DSNV SINK_TOKEN_ENV_TRON=DSN
new_case I3
run_sup 2 CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SUBSTREAMS_API_TOKEN_ALT=stub-alt SINK_TOKEN_ENV_BASE=SUBSTREAMS_API_TOKEN_ALT SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_started","chain":"base"' "$LOG" "I3 alt token accepted"
grep -q -- '--api-token-envvar SUBSTREAMS_API_TOKEN_ALT' "$STUB_DIR/calls.log" && pass "I3 alt token var passed" || fail "I3 alt token var missing"
reject I4 ENDPOINT 'streamingfast.io:443' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_ENDPOINT_BASE=sink.attacker.example:443
reject I5 ENDPOINT 'streamingfast.io:443' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_ENDPOINT_BASE=base-mainnet.streamingfast.io.attacker.example:443
reject I6 ENDPOINT 'streamingfast.io:443' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_ENDPOINT_BASE=evilstreamingfast.io:443
reject I7 ENDPOINT 'streamingfast.io:443' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_ENDPOINT_BASE=base-mainnet.streamingfast.io:9000
new_case I8
run_sup 2 CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_ENDPOINT_BASE=base.substreams.pinax.network:443 SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_started","chain":"base"' "$LOG" "I8 pinax endpoint accepted"
reject I9 PARAMS 'params come from the package manifest' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_PARAMS_BASE=chain=base;addresses=0x00000000000000000000000000000000000000ee'
reject I10 SPKG 'package must be tron or evm' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_SPKG_BASE=../../tmp/evil'
new_case I11
printf 'touch %s/pwned\n' "$STUB_DIR" >"$STUB_DIR/evil.env"
mkdir -p "$STUB_DIR/evil-spkgs"
run_sup 2 CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV CHAINS_ENV_FILE="$STUB_DIR/evil.env" SPKG_DIR="$STUB_DIR/evil-spkgs" SINK_PROGRESS_INTERVAL_SECONDS=1
[ -e "$STUB_DIR/pwned" ] && fail "I11 CHAINS_ENV_FILE from env was sourced" || pass "I11 CHAINS_ENV_FILE from env ignored"
expect -eq 1 '"event":"sink_started","chain":"base"' "$LOG" "I11 SPKG_DIR from env ignored (built-in package used)"
new_case I12
# docker-compose.prod.yml (frozen VM): legacy DSN + token + the hardcoded TRON endpoint only.
run_sup 2 DSN=$DSNV SUBSTREAMS_ENDPOINTS_CONFIG_TRON=mainnet.tron.streamingfast.io:443 SINK_PROGRESS_INTERVAL_SECONDS=1
expect -eq 1 '"event":"sink_started","chain":"tron".*"schema":"public"' "$LOG" "I12 VM compose layout runs tron in public"
expect -eq 0 sink_config_invalid "$LOG" "I12 no config error"

echo "=== J. cursor reads are bounded (one stuck read never silences the other chains)"
new_case J1; : >"$STUB_DIR/cursor_hang_tron"; echo 'Module hash_base: Block #500 (abc) [x]' >"$STUB_DIR/cursor_base"
run_sup 6 CHAINS=tron,base SUBSTREAMS_SINK_DSN=$DSNV SINK_PROGRESS_INTERVAL_SECONDS=1 SINK_CURSOR_READ_TIMEOUT_SECONDS=1
expect -ge 2 '"event":"sink_progress","chain":"base","block_num":500,"cursor":"current"' "$LOG" "J1 base keeps reporting"
expect -ge 1 '"severity":"WARNING","event":"sink_progress","chain":"tron","block_num":null,"cursor":"unreadable","reason":"timeout","timeout_seconds":1' "$LOG" "J1 stuck tron read reported unreadable"
all_json "$LOG" "J1"
pkill -f "sleep 3017" 2>/dev/null; true
new_case J2
env CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_CURSOR_READ_TIMEOUT_SECONDS=0 "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "J2 zero cursor timeout exit 1" || fail "J2 exit $code"
expect -eq 1 '"event":"sink_config_invalid","chain":null,"field":"SINK_CURSOR_READ_TIMEOUT_SECONDS","message":"must be >= 1"}' "$LOG" "J2 reason"

new_case J3; : >"$STUB_DIR/cursor_ignore_term_tron"; echo 'Module hash_base: Block #500 (abc) [x]' >"$STUB_DIR/cursor_base"
run_sup 10 CHAINS=tron,base SUBSTREAMS_SINK_DSN=$DSNV SINK_PROGRESS_INTERVAL_SECONDS=1 SINK_CURSOR_READ_TIMEOUT_SECONDS=1
expect -ge 1 '"chain":"tron","block_num":null,"cursor":"unreadable"' "$LOG" "J3 a read that ignores TERM is killed and reported unreadable"
expect -ge 1 '"event":"sink_progress","chain":"base","block_num":500,"cursor":"current"' "$LOG" "J3 base still reported"
pkill -f "sleep 3018" 2>/dev/null; true
new_case J4; : >"$STUB_DIR/cursor_fail_tron"
run_sup 3 CHAINS=tron,base SUBSTREAMS_SINK_DSN=$DSNV SINK_PROGRESS_INTERVAL_SECONDS=1
expect -ge 1 '"severity":"WARNING","event":"sink_progress","chain":"tron","block_num":null,"cursor":"unreadable","reason":"error"' "$LOG" "J4 failed read reported unreadable, not none"
expect -eq 0 '"chain":"tron","block_num":null,"cursor":"none"' "$LOG" "J4 failed read never reported as none"
expect -ge 1 '"event":"sink_progress","chain":"base","block_num":null,"cursor":"none"' "$LOG" "J4 empty cursor table still reported as none"

echo "=== K. integers have no leading zeros (JSON numbers, never octal)"
reject K1 UNDO_BUFFER_SIZE 'not a non-negative integer' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_UNDO_BUFFER_SIZE_BASE=020
new_case K2
env CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV SINK_PROGRESS_INTERVAL_SECONDS=01 "$SUP" >"$LOG" 2>/dev/null; code=$?
[ "$code" -eq 1 ] && pass "K2 zero-padded global integer exit 1" || fail "K2 exit $code"
expect -eq 1 '"field":"SINK_PROGRESS_INTERVAL_SECONDS","message":"not an integer"' "$LOG" "K2 reason"
reject K3 EXTRA_ARGS 'invalid value for --flush-retry-count' CHAINS=base SUBSTREAMS_SINK_DSN=$DSNV 'SINK_EXTRA_ARGS_BASE=--flush-retry-count 03'
eval "$(sed -n '/^log() {/,/^}/p' "$SUP")"
eval "$(sed -n '/^json_str() {/,/^}/p' "$SUP")"
line=$(log INFO probe a 020 b 7 c -1 d 0)
python3 -c 'import json,sys; o=json.loads(sys.argv[1]); assert o["a"]=="020" and o["b"]==7 and o["c"]==-1 and o["d"]==0' "$line" && pass "K4 log emits zero-padded values as strings, integers as numbers" || fail "K4 log line: $line"

echo; echo "FAILURES: $fails"
exit "$fails"
