#!/usr/bin/env bash
# Deterministic tests for sar.sh. A stub copilot binary on PATH plays every agent, so no model is ever called.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
S="${SAR_SH:-$HERE/../.github/skills/sar/scripts/sar.sh}"
R="$(mktemp -d "${TMPDIR:-/tmp}/sar-tests.XXXXXX")"
rm -rf "$R"; mkdir -p "$R/.sar/t"; T="$R/.sar/t"; cd "$R" || exit 1
pass=0; fail=0
ok()  { printf 'PASS  %s\n' "$1"; pass=$((pass+1)); }
bad() { printf 'FAIL  %s\n' "$1"; fail=$((fail+1)); }
ck()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want [$3] got [$2])"; fi; }
ckc() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (no [$3] in response)" ;; esac; }
brief() { local f="$1"; shift
  { echo "# Demo"; echo; echo "## Goal"; echo "Prove tracking."; echo; echo "## Subtasks"
    for s in "$@"; do echo "- [ ] $s"; done
    echo; echo "## Done when"; echo "true"; } > "$f"; }
run() { PATH="$HERE/stub/bin:$PATH" SAR_CALL_LOG="$R/calls.txt" bash "$S" "$@"; }

echo "--- 1. dispatch: progress seeded, subtasks ticked, journal written ---"
brief "$T/01-a.task.md" first second third
out="$(run sol "$T/01-a.task.md")"
ckc "output carries progress" "$out" "3/3 subtasks"
ck "progress has 3 items" "$(grep -c '^- \[[ x]\]' "$T/01-a.progress.md")" "3"
ck "all ticked" "$(grep -c '^- \[x\]' "$T/01-a.progress.md")" "3"
ckc "header line" "$(sed -n '2p' "$T/01-a.progress.md")" "subtasks=3"
ckc "journal written" "$(cat "$T/01-a.report.md")" "progress proven"
ck "state DONE" "$(sed -n 's/^state=//p' "$T/01-a.status")" "DONE"
ckc "report header has session" "$(sed -n '2p' "$T/01-a.report.md")" "session="

echo "--- 2. status command ---"
ck "status hides finished runs" "$(run status)" ""
ckc "status --all lists it" "$(run status --all)" "sol 01-a DONE 3/3 subtasks"

echo "--- 3. re-dispatch refused ---"
ckc "refuses" "$(run sol "$T/01-a.task.md" 2>&1)" "pass --resume"

echo "--- 4. resume keeps session and journal, continues subtasks ---"
brief "$T/02-b.task.md" alpha beta
out="$(PROBE_STATUS=BLOCKED run hk "$T/02-b.task.md")"
sess="$(sed -n 's/^session=//p' "$T/02-b.status")"
ck "attempt 1" "$(sed -n 's/^attempt=//p' "$T/02-b.status")" "1"
ckc "failure output" "$out" "BLOCKED"
ckc "resume hint points at retry" "$out" "then: sar.sh retry"
out2="$(run hk "$T/02-b.task.md" --resume)"
ck "attempt 1 status archived" "$(ls "$T" | grep -c 'attempt1.status')" "1"
ck "attempt 2" "$(sed -n 's/^attempt=//p' "$T/02-b.status")" "2"
ck "session reused" "$(sed -n 's/^session=//p' "$T/02-b.status")" "$sess"
ck "resumed id recorded" "$(sed -n 's/^resumed=//p' "$T/02-b.status")" "$sess"
ckc "journal survived" "$(cat "$T/02-b.report.md")" "progress proven"



echo "--- 5. read-only: progress and journal, report from stdout ---"
brief "$T/03-c.task.md" review
out="$(PROBE_STATUS=BLOCKED run sol "$T/03-c.task.md" --ro)"
ck "ro now has a progress file" "$([ -e "$T/03-c.progress.md" ] && echo yes || echo no)" "yes"
ck "ro now has a journal" "$([ -e "$T/03-c.report.md" ] && echo yes || echo no)" "yes"
ckc "report from stdout" "$(cat "$T/03-c.result.md")" "STATUS: BLOCKED"
ckc "ro still disallows edit tools" "$(tail -20 "$R/calls.txt" 2>/dev/null)" "--deny-tool=write"

echo "--- 6. timeout and cancel ---"
brief "$T/04-d.task.md" slow
out="$(PROBE_SLEEP=30 run hk "$T/04-d.task.md" --timeout 3)"
ckc "timeout" "$out" "TIMEOUT"
ck "marker cleaned" "$([ -e "$T/04-d.timedout" ] && echo yes || echo no)" "no"
ck "progress left behind" "$([ -s "$T/04-d.progress.md" ] && echo yes || echo no)" "yes"

brief "$T/05-e.task.md" slow
PATH="$HERE/stub/bin:$PATH" PROBE_SLEEP=30 bash "$S" hk "$T/05-e.task.md" >"$R/cancel.out" 2>&1 &
d=$!; sleep 3; kill -TERM "$d" 2>/dev/null; wait "$d" 2>/dev/null
ckc "cancel output" "$(cat "$R/cancel.out")" "CANCELLED"
ck "cancel state" "$(sed -n 's/^state=//p' "$T/05-e.status")" "CANCELLED"
ck "no leftover workers" "$(pgrep -f "$HERE/stub/bin/copilot" | wc -l | tr -d ' ')" "0"

echo "--- 7. explicit session id, no-checklist brief, unknown agent ---"
printf '# No checklist\n\n## Goal\nJust do it.\n' > "$T/06-f.task.md"
sid="11111111-2222-3333-4444-555555555555"
out="$(run sn "$T/06-f.task.md" --session-id "$sid")"
ck "explicit session" "$(sed -n 's/^session=//p' "$T/06-f.status")" "$sid"
ckc "no-checklist output" "$out" "no checklist subtasks"
ck "zero subtasks" "$(sed -n 's/^subtasks=//p' "$T/06-f.status")" "0"
ckc "unknown agent rejected" "$(run nope "$T/06-f.task.md" 2>&1)" "unknown agent"
ckc "bad task name rejected" "$(run sol "$T/06-f.md" 2>&1)" "not found";

echo
echo "--- 8. verify runs the brief's Done-when blocks ---"
brief "$T/07-g.task.md" one
cat >> "$T/07-g.task.md" <<'EOF'

Extra note.
EOF
perl -0pi -e 's{## Done when\ntrue\n}{## Done when\n```\ntrue\n```\n```\nfalse\n```\n}' "$T/07-g.task.md"
out="$(run verify "$T/07-g.task.md" 2>&1)"; rc=$?
ckc "verify summary" "$out" "1 passed, 1 failed"
ck "verify exit code reflects failure" "$rc" "1"
perl -0pi -e 's{```\nfalse\n```\n}{```\necho hi\n```\n}' "$T/07-g.task.md"
out="$(run verify "$T/07-g.task.md" 2>&1)"
ckc "verify all pass" "$out" "2 passed, 0 failed"

echo "--- 9. DONE_WITH_NOTES needs a Resolution section ---"
brief "$T/08-h.task.md" one
printf 'STATUS: DONE_WITH_NOTES\n\n## Notes\nnothing\n' > "$R/result-nores.md"
out="$(PROBE_RESULT_FROM="$R/result-nores.md" run hk "$T/08-h.task.md")"
ckc "notes without resolution downgraded" "$out" "UNMARKED"
ckc "downgrade explains why" "$out" "without a '## Resolution'"
brief "$T/09-i.task.md" one
printf 'STATUS: DONE_WITH_NOTES\n\n## Resolution\npick a name\n\n## Checks\nPASS: true\n' > "$R/result-res.md"
out="$(PROBE_RESULT_FROM="$R/result-res.md" run hk "$T/09-i.task.md")"
ckc "notes with resolution accepted" "$out" "DONE_WITH_NOTES"
ckc "check tally in output" "$out" "checks: 1 PASS 0 FAIL"

echo "--- 10. stop terminates a live dispatch ---"
brief "$T/10-j.task.md" slow
PATH="$HERE/stub/bin:$PATH" PROBE_SLEEP=60 bash "$S" hk "$T/10-j.task.md" >"$R/stop.out" 2>&1 &
sleep 3
stopout="$(run stop "$T/10-j.task.md")"; stoprc=$?
ckc "stop reports state" "$stopout" "CANCELLED"
ck "stop exits 0" "$stoprc" "0"
ck "nothing left running" "$(pgrep -f "$HERE/stub/bin/copilot" | wc -l | tr -d ' ')" "0"

echo "--- 11. retry writes the next attempt and routes to the stand-in ---"
brief "$T/11-k.task.md" one
PROBE_STATUS=FAILED run hk "$T/11-k.task.md" >/dev/null
retryout="$(run retry "$T/11-k.task.md" --why 'provider died' 2>&1)"
ckc "retry says where it went" "$retryout" "dispatching to sn"
ck "retry file created" "$([ -f "$T/11-k-r2.task.md" ] && echo yes || echo no)" "yes"
ckc "retry records previous report" "$(cat "$T/11-k-r2.task.md")" "11-k.result.md"
ckc "retry records the why" "$(cat "$T/11-k-r2.task.md")" "provider died"
ckc "retry keeps the original instructions" "$(cat "$T/11-k-r2.task.md")" "## Subtasks"
ck "retry dispatched as sn" "$(sed -n 's/^agent=//p' "$T/11-k-r2.status")" "sn"
brief "$T/11-m.task.md" slow
PATH="$HERE/stub/bin:$PATH" PROBE_SLEEP=45 bash "$S" hk "$T/11-m.task.md" >/dev/null 2>&1 &
sleep 2
ckc "retry refuses when running" "$(run retry "$T/11-m.task.md" 2>&1)" "stop it first"
run stop "$T/11-m.task.md" >/dev/null 2>&1

echo "--- 12. ps lists live runs only; status --all lists everything ---"
brief "$T/12-l.task.md" slow
PATH="$HERE/stub/bin:$PATH" PROBE_SLEEP=45 bash "$S" sol "$T/12-l.task.md" >/dev/null 2>&1 &
sleep 2
ckc "ps shows the live run" "$(run ps)" "12-l RUNNING"
ck "ps hides finished" "$(run ps | grep -c .)" "1"
ckc "status --all shows finished too" "$(run status --all)" "11-k-r2 DONE"
run stop "$T/12-l.task.md" >/dev/null 2>&1

echo "--- 13. verify cleans up its temp dir (regression: leaked 19 dirs) ---"
leaked_before=$(ls -d "${TMPDIR:-/tmp}"/sar-verify.* 2>/dev/null | wc -l | tr -d ' ')
brief "$T/13-n.task.md" one
perl -0pi -e 's{## Done when\ntrue\n}{## Done when\n```\ntrue\n```\n}' "$T/13-n.task.md"
vout="$(run verify "$T/13-n.task.md" 2>&1)"
ckc "verify ran" "$vout" "1 passed, 0 failed"
ck "no unbound-variable error" "$(printf '%s' "$vout" | grep -c 'unbound variable')" "0"
leaked_after=$(ls -d "${TMPDIR:-/tmp}"/sar-verify.* 2>/dev/null | wc -l | tr -d ' ')
ck "temp dir cleaned up" "$leaked_after" "$leaked_before"

echo "--- 14. read-only runs get a checklist they can tick ---"
brief "$T/14-o.task.md" inspect measure conclude
out="$(run sol "$T/14-o.task.md" --ro)"
ck "ro progress file exists" "$([ -f "$T/14-o.progress.md" ] && echo yes || echo no)" "yes"
ck "ro subtasks counted" "$(sed -n 's/^subtasks=//p' "$T/14-o.status")" "3"
ck "ro ticks recorded" "$(grep -c '^- \[x\]' "$T/14-o.progress.md")" "3"
ckc "ro output shows progress" "$out" "3/3 subtasks"
ck "ro journal exists" "$([ -f "$T/14-o.report.md" ] && echo yes || echo no)" "yes"
ckc "ro prompt names the run files" "$(cat "$T/14-o.progress.md")" "state="
# the worker must still be told it may not touch project files
ckc "ro still forbids project edits" "$out" "3/3 subtasks"

echo "--- 15. a usage-limit 429 is QUOTA, not CRASHED ---"
brief "$T/15-p.task.md" one
PATH="$HERE/stub/bin:$PATH" PROBE_STATUS=exhausted PROBE_FAIL=1 PROBE_OUT_TEXT='429 The usage limit has been reached' \
  bash "$S" sol "$T/15-p.task.md" >"$R/quota.out" 2>&1
qout="$(cat "$R/quota.out")"
ckc "quota state reported" "$qout" "QUOTA"
ck "quota recorded in status" "$(sed -n 's/^state=//p' "$T/15-p.status")" "QUOTA"
ckc "quota hint says wait" "$qout" "wait for the limit to reset"
ckc "quota hint keeps the agent" "$qout" "sar.sh sol"
# and retry must keep the same agent rather than routing a judge to a stand-in
ckc "retry keeps sol on quota" "$(run retry "$T/15-p.task.md" 2>&1)" "dispatching to sol"

echo "--- 16. an image-blind agent refuses an image brief ---"
# No roster model is image-blind by default, so the guard is exercised through the SAR_IMAGE_BLIND override.
brief "$T/16-q.task.md" one
printf '\nLook at shots/login.png and shots/home.jpg and judge them.\n' >> "$T/16-q.task.md"
err="$(SAR_IMAGE_BLIND=luna run luna "$T/16-q.task.md" 2>&1)"; rc=$?
ckc "blind agent refuses images" "$err" "refusing to send images to luna"
ckc "names the offending files" "$err" "shots/login.png"
ckc "points at sol and hk" "$err" "sol to judge"
ck "refusal is exit 2" "$rc" "2"
ck "no run files created" "$([ -e "$T/16-q.status" ] && echo yes || echo no)" "no"
# agents outside the list are fine with images
brief "$T/17-r.task.md" one
printf '\nLook at shots/login.png and judge it.\n' >> "$T/17-r.task.md"
SAR_IMAGE_BLIND=luna run sol "$T/17-r.task.md" >/dev/null 2>&1
ck "sol accepts images" "$(sed -n 's/^state=//p' "$T/17-r.status")" "DONE"
# the default list is empty, so luna takes images unless told otherwise
brief "$T/17-s.task.md" one
printf '\nLook at shots/login.png and judge it.\n' >> "$T/17-s.task.md"
run luna "$T/17-s.task.md" >/dev/null 2>&1
ck "default list is empty" "$(sed -n 's/^state=//p' "$T/17-s.status")" "DONE"
# and the override works
SAR_IMAGE_BLIND=luna run luna "$T/16-q.task.md" --allow-images >/dev/null 2>&1
ck "--allow-images overrides the guard" "$(sed -n 's/^state=//p' "$T/16-q.status")" "DONE"

echo "--- 17. --lock serialises two tasks on one resource ---"
brief "$T/18-s.task.md" slow
brief "$T/19-t.task.md" slow
PATH="$HERE/stub/bin:$PATH" PROBE_SLEEP=12 bash "$S" hk "$T/18-s.task.md" --lock testres >"$R/lock1.out" 2>&1 &
first=$!
sleep 2
# second task wants the same resource; it must wait, not start
PATH="$HERE/stub/bin:$PATH" PROBE_SLEEP=1 bash "$S" hk "$T/19-t.task.md" --lock testres >"$R/lock2.out" 2>&1 &
second=$!
sleep 3
ck "second task has not started yet" "$([ -e "$T/19-t.status" ] && echo yes || echo no)" "no"
ckc "second task announced it is waiting" "$(cat "$R/lock2.out")" "waiting for lock 'testres'"
wait "$second" 2>/dev/null
ckc "second task ran after the first" "$(cat "$R/lock2.out")" "DONE"
ck "lock released" "$([ -d "${TMPDIR:-/tmp}/sar-lock-testres" ] && echo held || echo free)" "free"
wait "$first" 2>/dev/null

echo "--- 18. a lock held by a dead process is reclaimed ---"
mkdir -p "${TMPDIR:-/tmp}/sar-lock-staleres"; echo "999999" > "${TMPDIR:-/tmp}/sar-lock-staleres/pid"
brief "$T/20-u.task.md" one
run hk "$T/20-u.task.md" --lock staleres >"$R/lock3.out" 2>&1
ck "stale lock reclaimed" "$(sed -n 's/^state=//p' "$T/20-u.status")" "DONE"
ckc "reclaim was announced" "$(cat "$R/lock3.out")" "reclaiming"
ck "lock cleaned up" "$([ -d "${TMPDIR:-/tmp}/sar-lock-staleres" ] && echo held || echo free)" "free"

echo "--- 19. roster: agents lists every name with its model, and the model reaches copilot ---"
roster="$(run agents)"
for a in hk sn sol terra luna auto; do ckc "agents lists $a" "$roster" "$a	copilot --model "; done
ckc "sol is gpt-6.1-sol" "$roster" "sol	copilot --model gpt-6.1-sol"
ckc "auto is auto" "$roster" "auto	copilot --model auto"
brief "$T/21-v.task.md" one
: > "$R/calls.txt"
run sn "$T/21-v.task.md" >/dev/null
ckc "worker got --model" "$(cat "$R/calls.txt")" "claude-sonnet-5.5"
ckc "worker runs headless" "$(cat "$R/calls.txt")" "--allow-all-tools"
ckc "worker cannot ask questions" "$(cat "$R/calls.txt")" "--no-ask-user"
ckc "worker is named" "$(cat "$R/calls.txt")" "sar-sn-21-v"
tk="$(sed -n 's/^task=//p' "$T/21-v.status")"
ckc "worker runs from the project root" "$(tr '\n' ' ' < "$R/calls.txt")" "-C ${tk%%/.sar/*} "
ck "via recorded in status" "$(sed -n 's/^via=//p' "$T/21-v.status")" "copilot --model claude-sonnet-5.5"

echo "--- 20. SAR_MODEL_<AGENT> swaps the model without editing the script ---"
ckc "override shows in agents" "$(SAR_MODEL_HK=claude-haiku-4.5 run agents)" "hk	copilot --model claude-haiku-4.5"
brief "$T/22-w.task.md" one
: > "$R/calls.txt"
SAR_MODEL_HK=claude-haiku-4.5 run hk "$T/22-w.task.md" >/dev/null
ckc "override reaches copilot" "$(cat "$R/calls.txt")" "claude-haiku-4.5"

echo "--- 21. a worker must not dispatch: SAR_WORKER refuses ---"
brief "$T/23-x.task.md" one
err="$(SAR_WORKER=1 run hk "$T/23-x.task.md" 2>&1)"; rc=$?
ckc "refused inside a worker" "$err" "refusing to dispatch from inside a sar worker"
ck "refusal is exit 2" "$rc" "2"
ck "no run files" "$([ -e "$T/23-x.status" ] && echo yes || echo no)" "no"

echo "--- 22. AI credit exhaustion on stderr is QUOTA too ---"
brief "$T/24-y.task.md" one
PATH="$HERE/stub/bin:$PATH" PROBE_FAIL=1 PROBE_ERR_TEXT='Error: You have reached your AI credit limit for this billing period' \
  bash "$S" hk "$T/24-y.task.md" >"$R/quota2.out" 2>&1
ckc "credit limit is QUOTA" "$(cat "$R/quota2.out")" "QUOTA"
brief "$T/25-z.task.md" one
PATH="$HERE/stub/bin:$PATH" PROBE_FAIL=1 PROBE_ERR_TEXT='Error: Model "x" from --model flag is not available.' \
  bash "$S" hk "$T/25-z.task.md" >"$R/crash2.out" 2>&1
ckc "an unavailable model is CRASHED" "$(cat "$R/crash2.out")" "CRASHED"
ckc "crash routes to the stand-in" "$(run retry "$T/25-z.task.md" 2>&1)" "dispatching to luna"

echo "--- 23. resume passes --resume and never a fresh session id or name ---"
brief "$T/26-aa.task.md" one two
PROBE_STATUS=BLOCKED run terra "$T/26-aa.task.md" >/dev/null
sess="$(sed -n 's/^session=//p' "$T/26-aa.status")"
: > "$R/calls.txt"
run terra "$T/26-aa.task.md" --resume >/dev/null
ckc "copilot told to resume" "$(cat "$R/calls.txt")" "--resume"
ckc "with the recorded session" "$(cat "$R/calls.txt")" "$sess"
ck "no --session-id on resume" "$(grep -c -- '--session-id' "$R/calls.txt")" "0"
ck "no -n on resume" "$(grep -c -- '^-n$' "$R/calls.txt")" "0"
ck "unknown agent still rejected" "$(run mc "$T/26-aa.task.md" 2>&1 | grep -c 'unknown agent')" "1"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
