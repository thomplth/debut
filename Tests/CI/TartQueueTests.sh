#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/../.."

failures=0
fail() {
    echo "FAIL: $1" >&2
    failures=$((failures + 1))
}

queue_lib="scripts/tart-queue.sh"
[[ -f "$queue_lib" ]] || { echo "FAIL: missing $queue_lib" >&2; exit 1; }

work="$(mktemp -d)"
trap 'kill $(jobs -p) 2>/dev/null || true; rm -rf "$work"' EXIT
export DEBUT_TART_QUEUE_DIR="$work/queue"
export DEBUT_TART_QUEUE_POLL=0.1

# A job holds the queue for $2 seconds and logs its start and end. Always run it with `&`, so
# the job itself is the process that owns the ticket and `$!` names it.
queue_job() {
    # shellcheck source=/dev/null
    source "$queue_lib"
    trap tart_queue_leave EXIT
    tart_queue_enter "job $1" >/dev/null
    echo "start $1" >> "$work/log"
    sleep "$2"
    echo "end $1" >> "$work/log"
    # bash 3.2 skips an EXIT trap when a backgrounded function returns normally.
    tart_queue_leave
}

# Arrival order is service order, and no two jobs overlap.
: > "$work/log"
queue_job 1 0.8 & sleep 0.2
queue_job 2 0.3 & sleep 0.2
queue_job 3 0.3 &
wait
expected=$'start 1\nend 1\nstart 2\nend 2\nstart 3\nend 3'
[[ "$(<"$work/log")" == "$expected" ]] \
    || fail "queued jobs overlapped or ran out of order: $(tr '\n' ',' < "$work/log")"
[[ -z "$(ls "$DEBUT_TART_QUEUE_DIR"/*.ticket 2>/dev/null)" ]] \
    || fail "finished jobs left tickets behind"

# A ticket whose owner has exited does not block the line.
/usr/bin/true & dead_pid=$!
wait "$dead_pid"
mkdir -p "$DEBUT_TART_QUEUE_DIR"
printf 'pid=%s\nstart=Thu Jan  1 00:00:00 1970\ncreated=0\nowner=dead\n' "$dead_pid" \
    > "$DEBUT_TART_QUEUE_DIR/00000000000000001-0000001.ticket"
# A live PID with another process's start time is a recycled PID, not the owner.
printf 'pid=%s\nstart=Thu Jan  1 00:00:00 1970\ncreated=0\nowner=recycled\n' "$$" \
    > "$DEBUT_TART_QUEUE_DIR/00000000000000002-0000002.ticket"
: > "$work/log"
queue_job 4 0 &
job_pid=$!
for _ in {1..30}; do [[ -s "$work/log" ]] && break; sleep 0.1; done
[[ -s "$work/log" ]] || fail "a dead or recycled owner's ticket blocked the queue"
wait "$job_pid" 2>/dev/null || true
[[ ! -e "$DEBUT_TART_QUEUE_DIR/00000000000000001-0000001.ticket" ]] || fail "a dead owner's ticket was not pruned"
[[ ! -e "$DEBUT_TART_QUEUE_DIR/00000000000000002-0000002.ticket" ]] || fail "a recycled PID kept a dead run's place"

# A killed waiter cannot strand the jobs behind it, and a waiter never displaces the head.
: > "$work/log"
queue_job holder 1.2 & sleep 0.2
queue_job victim 0.1 & victim=$!
sleep 0.2
queue_job after 0.1 & sleep 0.2
kill -9 "$victim" 2>/dev/null || true
wait 2>/dev/null || true
grep -q 'start victim' "$work/log" && fail "a killed waiter still ran"
[[ "$(head -1 "$work/log")" == "start holder" ]] || fail "the head lost its turn to a waiter"
grep -q 'start after' "$work/log" || fail "a killed waiter stranded the job behind it"

# Leaving removes only the caller's own ticket.
(
    source "$queue_lib"
    tart_queue_enter "mine" >/dev/null
    printf 'pid=%s\nstart=%s\ncreated=0\nowner=other\n' "$$" "$(tart_queue_start_time "$$")" \
        > "$DEBUT_TART_QUEUE_DIR/99999999999999999-9999999.ticket"
    tart_queue_leave
)
[[ -e "$DEBUT_TART_QUEUE_DIR/99999999999999999-9999999.ticket" ]] || fail "leaving removed another owner's ticket"
rm -f "$DEBUT_TART_QUEUE_DIR"/*.ticket

# Waiting is reported with position and the running owner, separately from execution.
(
    source "$queue_lib"
    trap tart_queue_leave EXIT
    tart_queue_enter "long run" >/dev/null
    sleep 1
) & sleep 0.3
wait_output="$(source "$queue_lib"; trap tart_queue_leave EXIT; tart_queue_enter "short run")"
wait
grep -q 'position 2 of 2; running: long run' <<< "$wait_output" \
    || fail "a waiter did not report its position and the running owner: $wait_output"
grep -q 'acquired after' <<< "$wait_output" || fail "a waiter did not report how long it waited"

# Every script that boots the shared Debut VM joins the queue before touching the guest.
for script in scripts/tart-e2e.sh scripts/tart-performance.sh scripts/demo-capture.sh scripts/tart-update-e2e.sh; do
    grep -q 'source .*tart-queue\.sh' "$script" || { fail "$script does not use the Tart queue"; continue; }
    enter_line="$(grep -n 'tart_queue_enter' "$script" | head -1 | cut -d: -f1)"
    # tart-e2e.sh defines its boot helper above the entry point; what matters is the call.
    if [[ "$script" == scripts/tart-e2e.sh ]]; then
        boot_line="$(grep -n '^    start_vm$' "$script" | head -1 | cut -d: -f1)"
    else
        boot_line="$(grep -n 'tart run ' "$script" | head -1 | cut -d: -f1)"
    fi
    stop_line="$(grep -n 'tart stop' "$script" | head -1 | cut -d: -f1 || true)"
    [[ -n "$enter_line" && -n "$boot_line" ]] && (( enter_line < boot_line )) \
        || fail "$script boots the guest before it holds the queue"
    if [[ -n "$stop_line" && "$script" != scripts/tart-e2e.sh ]] && (( stop_line < enter_line )); then
        fail "$script stops a guest before it holds the queue"
    fi
done

# `stop` would kill another task's guest mid-run, so it refuses while someone else holds the queue.
stub="$work/bin"
mkdir -p "$stub"
printf '#!/bin/bash\necho "$*" >> "%s/tart-calls"\nexit 0\n' "$work" > "$stub/tart"
chmod +x "$stub/tart"
(
    source "$queue_lib"
    trap tart_queue_leave EXIT
    tart_queue_enter "busy run" >/dev/null
    sleep 2
) & sleep 0.3
set +e
stop_output="$(PATH="$stub:$PATH" scripts/tart-e2e.sh stop 2>&1)"
stop_status=$?
set -e
wait
(( stop_status != 0 )) || fail "stop succeeded while another run held the queue"
grep -q 'busy run' <<< "$stop_output" || fail "stop did not name the run it protected: $stop_output"
grep -q '^stop' "$work/tart-calls" 2>/dev/null && fail "stop reached tart while another run held the queue"

if (( failures > 0 )); then
    exit 1
fi
echo "PASS: Tart queue contract"
