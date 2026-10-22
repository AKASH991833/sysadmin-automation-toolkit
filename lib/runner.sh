# shellcheck shell=bash
# Maintenance runner: runs a list of tasks with per-task timeout, overlap lock, summary table, exit code and optional webhook.
# tasks file:  name | timeout_seconds | command        (lines starting with # are ignored)

run_all() {
  local tasks=${1:-} lock="${SYSOPS_LOCK:-/tmp/sysops-run.lock}"; [[ -r $tasks ]] || die "usage: sysops run TASKS_FILE"
  exec 9>"$lock"
  flock -n 9 || { printf '%sanother run is still in progress (lock %s). Exiting.%s\n' "$YEL" "$lock" "$OFF" >&2; return 3; }
  local logdir="$STATE/runs/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$logdir"
  local name to cmd rc t0 dur status fails=0 rows=""
  printf '%sMAINTENANCE RUN%s %s\n' "$BLD" "$OFF" "$(date -u +%FT%TZ)"
  while IFS='|' read -r name to cmd; do
    name=$(echo "$name" | xargs); [[ -z $name || $name == \#* ]] && continue
    to=$(echo "$to" | xargs); cmd=$(echo "$cmd" | sed 's/^ *//')
    t0=$(date +%s.%N)
    timeout --kill-after=5 "$to" bash -c "$cmd" > "$logdir/$name.log" 2>&1; rc=$?
    dur=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')
    case $rc in 0) status="${GRN}OK     ${OFF}";; 124|137) status="${RED}TIMEOUT${OFF}"; fails=$((fails+1));; *) status="${RED}FAIL($rc)${OFF}"; fails=$((fails+1));; esac
    printf ' %-22s %s %6ss   log: %s\n' "$name" "$status" "$dur" "$logdir/$name.log"
    rows+="$name:$rc;"
  done < "$tasks"
  journal run_all "$tasks" "fails=$fails $rows"
  printf '\n%s task(s) failed. Logs: %s\n' "$fails" "$logdir"
  if (( fails )) && [[ -n ${SYSOPS_WEBHOOK_URL:-} ]]; then
    curl -fsS -m 10 -H 'Content-Type: application/json' -d "{\"text\":\"sysops: $fails task(s) failed on $(hostname): $(jesc "$rows")\"}" "$SYSOPS_WEBHOOK_URL" >/dev/null || warn "webhook failed"
  fi
  (( fails )) && return 1; return 0
}

cron_print() {
  local bin; bin=$(readlink -f "$0"); cat <<C
# /etc/cron.d/sysops   (install with: sysops cron | sudo tee /etc/cron.d/sysops)
15 1 * * *  root  $bin run /etc/sysops/tasks.conf >> /var/log/sysops-run.log 2>&1
C
}
