# shellcheck shell=bash
# Crontab management: managed entries (add/list/remove), validation, overlap-safe wrapper, status, audit.
# Everything that changes a crontab is plan-first (add --apply), keeps a backup, and never touches lines it does not own.

CRON_STATE="$STATE/cron"
CRONTAB_BIN=${SYSOPS_CRONTAB:-crontab}

_cron_need() { command -v "$CRONTAB_BIN" >/dev/null 2>&1 || die "no 'crontab' command found (install cron / cronie)"; }
_cron_read()  { # [user] -> current crontab on stdout (empty if none)
  if [[ -n ${1:-} ]]; then "$CRONTAB_BIN" -u "$1" -l 2>/dev/null || true; else "$CRONTAB_BIN" -l 2>/dev/null || true; fi
}
_cron_write() { # user ; stdin = new crontab
  if [[ -n ${1:-} ]]; then "$CRONTAB_BIN" -u "$1" -; else "$CRONTAB_BIN" -; fi
}

# ---- schedule validation ------------------------------------------------------------------
# one field: list of  (*|N|N-M)(/step)?  with names allowed for month (jan-dec) and dow (sun-sat)
_cron_field_ok() { # field min max kind
  local f=${1,,} min=$2 max=$3 kind=$4 part base step lo hi
  [[ -n $f ]] || return 1
  if [[ $kind == mon ]]; then f=${f//jan/1}; f=${f//feb/2}; f=${f//mar/3}; f=${f//apr/4}; f=${f//may/5}; f=${f//jun/6}
    f=${f//jul/7}; f=${f//aug/8}; f=${f//sep/9}; f=${f//oct/10}; f=${f//nov/11}; f=${f//dec/12}; fi
  if [[ $kind == dow ]]; then f=${f//sun/0}; f=${f//mon/1}; f=${f//tue/2}; f=${f//wed/3}; f=${f//thu/4}; f=${f//fri/5}; f=${f//sat/6}; fi
  local -a parts; IFS=, read -ra parts <<<"$f"
  for part in "${parts[@]}"; do
    base=${part%%/*}; step=""; [[ $part == */* ]] && step=${part#*/}
    if [[ -n $step ]]; then [[ $step =~ ^[0-9]+$ ]] && (( step >= 1 )) || return 1; fi
    if [[ $base == '*' ]]; then continue
    elif [[ $base =~ ^[0-9]+$ ]]; then (( base >= min && base <= max )) || return 1
    elif [[ $base =~ ^([0-9]+)-([0-9]+)$ ]]; then lo=${BASH_REMATCH[1]}; hi=${BASH_REMATCH[2]}
      (( lo >= min && hi <= max && lo <= hi )) || return 1
    else return 1; fi
  done
  return 0
}
cron_schedule_check() { # "m h dom mon dow" or @alias ; prints reason on failure
  local s=$1
  case ${s,,} in @reboot|@yearly|@annually|@monthly|@weekly|@daily|@midnight|@hourly) return 0;; esac
  local -a f; read -ra f <<<"$s"
  (( ${#f[@]} == 5 )) || { echo "schedule needs 5 fields (min hour day month weekday) or an @alias, got ${#f[@]}"; return 1; }
  _cron_field_ok "${f[0]}" 0 59 min || { echo "bad minute field '${f[0]}' (0-59)"; return 1; }
  _cron_field_ok "${f[1]}" 0 23 hr  || { echo "bad hour field '${f[1]}' (0-23)"; return 1; }
  _cron_field_ok "${f[2]}" 1 31 dom || { echo "bad day-of-month field '${f[2]}' (1-31)"; return 1; }
  _cron_field_ok "${f[3]}" 1 12 mon || { echo "bad month field '${f[3]}' (1-12 or jan-dec)"; return 1; }
  _cron_field_ok "${f[4]}" 0 7  dow || { echo "bad weekday field '${f[4]}' (0-7 or sun-sat)"; return 1; }
  return 0
}

# cron treats an unescaped % in the command as a newline - the classic "date +%F" bug
_cron_escape_pct() { local c=$1; c=${c//\\%/%}; printf '%s' "${c//%/\\%}"; }

# ---- managed entries ----------------------------------------------------------------------
_cron_strip() { # name ; stdin crontab -> crontab without that managed block
  awk -v n="sysops:$1" '$0=="# BEGIN "n{skip=1;next} $0=="# END "n{skip=0;next} !skip' 
}
_cron_block() { # name schedule command timeout
  local bin; bin=$(readlink -f "${BASH_SOURCE[0]%/lib/cron.sh}/sysops")
  printf '# BEGIN sysops:%s\n# managed by sysops - edit with: sysops cron add %s ...\n%s %s cron wrap --name %s --timeout %s -- %s\n# END sysops:%s\n' \
    "$1" "$1" "$2" "$bin" "$1" "$4" "$(_cron_escape_pct "$3")" "$1"
}
cron_add() {
  local name="" sched="" cmd="" to=3600 user="" apply=0
  name=${1:-}; shift || true
  while (( $# )); do case $1 in
    --schedule) sched=$2; shift 2;; --cmd) cmd=$2; shift 2;; --timeout) to=$2; shift 2;;
    --user) user=$2; shift 2;; --apply) apply=1; shift;; *) die "unknown option $1";; esac; done
  [[ $name =~ ^[a-z0-9][a-z0-9_-]{0,40}$ ]] || die "usage: sysops cron add NAME --schedule '*/5 * * * *' --cmd 'command' [--timeout 3600] [--user U] [--apply]   (NAME: a-z 0-9 _ -)"
  [[ -n $sched && -n $cmd ]] || die "cron add needs --schedule and --cmd"
  [[ $to =~ ^[0-9]+$ ]] || die "--timeout must be seconds"
  [[ $sched != @reboot ]] || die "@reboot jobs are not supported by the overlap-safe wrapper; use a systemd unit"
  local why; why=$(cron_schedule_check "$sched") || die "invalid schedule: $why"
  _cron_need
  local cur new blk; cur=$(_cron_read "$user"); blk=$(_cron_block "$name" "$sched" "$cmd" "$to")
  new=$(printf '%s\n' "$cur" | _cron_strip "$name"); new=$(printf '%s\n%s\n' "${new%$'\n'}" "$blk" | sed '/./,$!d')
  if [[ "$cur" == "$new" ]]; then printf '%s[ OK ]%s cron job %s already up to date\n' "$GRN" "$OFF" "$name"; return 0; fi
  if grep -q "^# BEGIN sysops:$name\$" <<<"$cur"; then printf 'plan: UPDATE managed job %s\n' "$name"; else printf 'plan: ADD managed job %s\n' "$name"; fi
  printf '%s\n' "$blk" | sed 's/^/  + /'
  [[ $sched == '* * * * *' ]] && printf '  note: runs every minute - the wrapper skips a run while the previous one is still active\n'
  (( apply )) || { printf '(dry-run: add --apply to install)\n'; return 0; }
  mkdir -p "$STATE/cron-backups"; local bk; bk="$STATE/cron-backups/${user:-$(id -un)}-$(date +%Y%m%d-%H%M%S-%N).crontab"
  printf '%s\n' "$cur" > "$bk"
  printf '%s\n' "$new" | _cron_write "$user" || die "crontab refused the new table (backup: $bk)"
  # verify what the system actually stored
  if ! _cron_read "$user" | grep -q "^# BEGIN sysops:$name\$"; then die "install verification failed (backup: $bk)"; fi
  journal cron_add "$name" "$sched | $cmd"
  printf '%s[ OK ]%s installed %s (previous crontab saved: %s)\n' "$GRN" "$OFF" "$name" "$bk"
}
cron_remove() {
  local name=${1:-} user="" apply=0; shift || true
  while (( $# )); do case $1 in --user) user=$2; shift 2;; --apply) apply=1; shift;; *) die "unknown option $1";; esac; done
  [[ -n $name ]] || die "usage: sysops cron remove NAME [--user U] [--apply]"
  _cron_need
  local cur; cur=$(_cron_read "$user")
  grep -q "^# BEGIN sysops:$name\$" <<<"$cur" || { printf '%s no managed job named %s (unmanaged lines are never touched)\n' "${YEL}[WARN]${OFF}" "$name"; return 1; }
  printf 'plan: REMOVE managed job %s (all other lines stay untouched)\n' "$name"
  (( apply )) || { printf '(dry-run: add --apply)\n'; return 0; }
  mkdir -p "$STATE/cron-backups"; printf '%s\n' "$cur" > "$STATE/cron-backups/${user:-$(id -un)}-$(date +%Y%m%d-%H%M%S-%N).crontab"
  printf '%s\n' "$cur" | _cron_strip "$name" | _cron_write "$user" || die "crontab refused the new table"
  journal cron_remove "$name" ""; printf '%s[ OK ]%s removed %s\n' "$GRN" "$OFF" "$name"
}
cron_list() {
  local user=""; [[ ${1:-} == --user ]] && user=$2
  _cron_need
  local cur; cur=$(_cron_read "$user")
  [[ -n $cur ]] || { echo "no crontab for ${user:-$(id -un)}"; return 0; }
  local line name inblk=""
  printf '%-20s %-22s %s\n' NAME SCHEDULE COMMAND
  while IFS= read -r line; do
    if [[ $line =~ ^"# BEGIN sysops:"(.*)$ ]]; then inblk=${BASH_REMATCH[1]}; continue; fi
    [[ $line == "# END sysops:"* ]] && { inblk=""; continue; }
    [[ -z $line || $line == \#* ]] && continue
    if [[ -n $inblk ]]; then
      local sch cmd; sch=$(awk '{print $1,$2,$3,$4,$5}' <<<"$line"); cmd=${line#*" -- "}
      printf '%-20s %-22s %s\n' "$inblk" "$sch" "$cmd"
    else printf '%-20s %s\n' "(unmanaged)" "$line"; fi
  done <<<"$cur"
}

# ---- lint any crontab text ----------------------------------------------------------------
cron_validate() { # [file] [--system]   (--system = /etc/crontab or cron.d format with a user column)
  local file="" sys=0 user=""
  while (( $# )); do case $1 in --system) sys=1; shift;; --user) user=$2; shift 2;; *) file=$1; shift;; esac; done
  local txt n=0 errs=0 warns=0 line
  if [[ -n $file ]]; then [[ -r $file ]] || die "cannot read $file"; txt=$(cat "$file"); else _cron_need; txt=$(_cron_read "$user"); fi
  while IFS= read -r line; do
    n=$((n+1)); line=${line#"${line%%[![:space:]]*}"}
    [[ -z $line || $line == \#* ]] && continue
    if [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]]; then continue; fi   # VAR=value
    local -a f; read -ra f <<<"$line"
    local nsched=5 ucol=0; [[ ${f[0]} == @* ]] && nsched=1; (( sys )) && ucol=1
    local sch="${f[*]:0:$nsched}" why
    if ! why=$(cron_schedule_check "$sch"); then printf '%s[FAIL]%s line %d: %s\n' "$RED" "$OFF" "$n" "$why"; errs=$((errs+1)); continue; fi
    if (( ${#f[@]} < nsched + ucol + 1 )); then printf '%s[FAIL]%s line %d: no command after the schedule%s\n' "$RED" "$OFF" "$n" "$( ((sys)) && echo ' / user column')"; errs=$((errs+1)); continue; fi
    if (( sys )) && ! id "${f[nsched]}" >/dev/null 2>&1; then printf '%s[WARN]%s line %d: user %s does not exist on this system\n' "$YEL" "$OFF" "$n" "${f[nsched]}"; warns=$((warns+1)); fi
    local cmd="${f[*]:$((nsched+ucol))}"
    if [[ $cmd =~ (^|[^\\])% ]]; then printf '%s[FAIL]%s line %d: unescaped %% in the command - cron turns it into a newline (use \\%%)\n' "$RED" "$OFF" "$n"; errs=$((errs+1)); fi
  done <<<"$txt"
  if (( errs )); then printf '%d error(s), %d warning(s)\n' "$errs" "$warns"; return 1; fi
  printf '%s[ OK ]%s crontab syntax valid (%d warning(s))\n' "$GRN" "$OFF" "$warns"
}

# ---- overlap-safe wrapper -----------------------------------------------------------------
cron_wrap() {
  local name="" to=3600; while (( $# )); do case $1 in --name) name=$2; shift 2;; --timeout) to=$2; shift 2;; --) shift; break;; *) die "usage: sysops cron wrap --name N [--timeout S] -- command...";; esac; done
  [[ $name =~ ^[a-z0-9][a-z0-9_-]*$ && $# -gt 0 ]] || die "usage: sysops cron wrap --name N [--timeout S] -- command..."
  mkdir -p "$CRON_STATE"; chmod 700 "$CRON_STATE" 2>/dev/null || true
  local log="$CRON_STATE/$name.log" st="$CRON_STATE/$name.status" lock="$CRON_STATE/$name.lock"
  # flock is released by the kernel when the holder dies, so a crashed run can never wedge the job (unlike pid files)
  exec 8>"$lock"
  if ! flock -n 8; then
    printf '%s skipped: previous run still active\n' "$(date -u +%FT%TZ)" >> "$log"
    printf 'last_skip=%s\n' "$(date +%s)" >> "$st.skips"; journal cron_skip "$name" "previous run still active"; return 0
  fi
  if [[ -f $log ]] && (( $(stat -c %s "$log") > 1048576 )); then mv -f "$log" "$log.1"; fi   # simple size rotation
  local t0 rc; t0=$(date +%s)
  printf '%s start: %s\n' "$(date -u +%FT%TZ)" "$*" >> "$log"
  timeout --kill-after=10 "$to" bash -c "$*" >> "$log" 2>&1 8>&-; rc=$?
  local dur=$(( $(date +%s) - t0 ))
  printf '%s end: rc=%s duration=%ss\n' "$(date -u +%FT%TZ)" "$rc" "$dur" >> "$log"
  printf 'rc=%s\nstart=%s\nduration=%s\n' "$rc" "$t0" "$dur" > "$st"
  if (( rc != 0 )); then
    journal cron_fail "$name" "rc=$rc"
    if [[ -n ${SYSOPS_WEBHOOK_URL:-} ]]; then
      curl -fsS -m 10 -H 'Content-Type: application/json' -d "{\"text\":\"sysops cron: job $name failed (rc=$rc) on $(hostname)\"}" "$SYSOPS_WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
  fi
  return "$rc"
}
cron_status() {
  local user="" ; [[ ${1:-} == --user ]] && user=$2
  _cron_need
  local names; names=$(_cron_read "$user" | sed -n 's/^# BEGIN sysops://p'); local bad=0 n
  [[ -n $names ]] || { echo "no sysops-managed cron jobs"; return 0; }
  printf '%-20s %-9s %-10s %s\n' JOB LAST-RC DURATION LAST-RUN
  for n in $names; do
    local st="$CRON_STATE/$n.status"
    if [[ ! -f $st ]]; then printf '%-20s %-9s\n' "$n" "never-run"; continue; fi
    local rc dur start; rc=$(sed -n 's/^rc=//p' "$st"); dur=$(sed -n 's/^duration=//p' "$st"); start=$(sed -n 's/^start=//p' "$st")
    local mark="$GRN"; [[ $rc != 0 ]] && { mark="$RED"; bad=1; }
    printf '%-20s %s%-9s%s %-10s %s\n' "$n" "$mark" "$rc" "$OFF" "${dur}s" "$(date -d "@$start" '+%F %T' 2>/dev/null)"
  done
  return "$bad"
}

# ---- audit --------------------------------------------------------------------------------
cron_audit() {
  local crit=0 warn=0 files=() f
  local etc="$UROOT/etc" spool
  [[ -f $etc/crontab ]] && files+=("$etc/crontab")
  for f in "$etc"/cron.d/*; do [[ -f $f ]] && files+=("$f"); done
  for spool in "$UROOT"/var/spool/cron/crontabs "$UROOT"/var/spool/cron; do
    for f in "$spool"/*; do [[ -f $f ]] && files+=("$f"); done
  done
  local cf; echo "${BLD}CRON AUDIT${OFF}  (${#files[@]} crontab file(s) under ${UROOT:-/})"
  fnd() { local sev=$1; shift; if [[ $sev == CRIT ]]; then printf ' %s[CRIT]%s %s\n' "$RED" "$OFF" "$*"; crit=$((crit+1)); else printf ' %s[WARN]%s %s\n' "$YEL" "$OFF" "$*"; warn=$((warn+1)); fi; }
  for cf in "${files[@]}"; do
    local mode own; mode=$(stat -c %a "$cf"); own=$(stat -c %U "$cf")
    local isdir=0; [[ $cf == */cron.d/* || $cf == */etc/crontab ]] && isdir=1
    (( isdir )) && [[ $own != root && -z $UROOT ]] && fnd CRIT "$cf is owned by $own, system cron files must be owned by root"
    (( (8#$mode & 8#022) != 0 )) && fnd CRIT "$cf is group/world-writable (mode $mode): anyone with write access runs commands as the job's user"
    local line n=0
    while IFS= read -r line; do
      n=$((n+1)); line=${line#"${line%%[![:space:]]*}"}
      [[ -z $line || $line == \#* || $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] && continue
      local -a w; read -ra w <<<"$line"; local nsched=5 ucol=0 runas
      [[ ${w[0]} == @* ]] && nsched=1; (( isdir )) && ucol=1
      runas=root; (( ucol )) && runas=${w[nsched]}; (( ! ucol )) && [[ $cf == */crontabs/* || $cf == */spool/cron/* ]] && runas=$(basename "$cf")
      local cmd="${w[*]:$((nsched+ucol))}" prog=${w[$((nsched+ucol))]:-}
      [[ $runas == root ]] && [[ $cmd == */tmp/* || $cmd == */dev/shm/* ]] && fnd CRIT "$cf:$n root job runs something from a world-writable temp dir: $cmd"
      [[ $cmd =~ (curl|wget)[^|]*\|[[:space:]]*(ba)?sh ]] && fnd CRIT "$cf:$n pipes a download into a shell: $cmd"
      if [[ $prog == /* ]]; then
        local p="$UROOT$prog"
        if [[ ! -e $p ]]; then
          [[ -z $UROOT ]] && fnd WARN "$cf:$n command not found: $prog (job fails silently every run)"
        else
          local m; m=$(stat -c %a "$p"); (( (8#$m & 8#002) != 0 )) && fnd CRIT "$cf:$n script $prog is world-writable (mode $m) and runs as $runas: privilege escalation path"
          local dm; dm=$(stat -c %a "$(dirname "$p")"); [[ $runas == root ]] && (( (8#$dm & 8#002) != 0 )) && [[ ! -k $(dirname "$p") ]] && fnd WARN "$cf:$n directory of $prog is world-writable without sticky bit"
          [[ $runas == root && $(stat -c %U "$p") != root && -z $UROOT ]] && fnd WARN "$cf:$n script $prog runs as root but is owned by $(stat -c %U "$p")"
        fi
      elif [[ -n $prog && $prog != *=* && $prog != cd && $prog != [* && ! $prog =~ ^(if|for|test|\() ]]; then
        [[ $cmd != *PATH=* ]] && fnd WARN "$cf:$n relative command '$prog' relies on cron's minimal PATH - use an absolute path"
      fi
      [[ $cmd =~ (^|[^\\])% ]] && fnd CRIT "$cf:$n unescaped % in the command (cron turns it into a newline): $cmd"
      [[ $cmd != *">"* && $cmd != *"cron wrap"* && $cmd != *logger* && $cmd != *"|"* && $cmd != *" > "* ]] && [[ $nsched == 5 && ${w[0]} == '*' && ${w[1]} == '*' ]] && \
        fnd WARN "$cf:$n runs every minute without output handling or overlap protection: wrap it (sysops cron add) - $cmd"
    done < "$cf"
  done
  # access control files
  if [[ ! -e $etc/cron.allow && ! -e $etc/cron.deny ]]; then fnd WARN "neither cron.allow nor cron.deny exists: every user may create cron jobs"; fi
  [[ -e $etc/cron.allow ]] && (( (8#$(stat -c %a "$etc/cron.allow") & 8#022) != 0 )) && fnd CRIT "$etc/cron.allow is group/world-writable"
  for f in "$etc"/cron.{hourly,daily,weekly,monthly}/*; do
    [[ -f $f ]] || continue; (( (8#$(stat -c %a "$f") & 8#002) != 0 )) && fnd CRIT "$f is world-writable and executed by run-parts as root"
  done
  printf '%d critical, %d warning(s)\n' "$crit" "$warn"
  journal cron_audit "${UROOT:-/}" "crit=$crit warn=$warn"
  (( crit )) && return 2; (( warn )) && return 1; return 0
}

cron_cmd() {
  case ${1:-} in
    ""|print) cron_print;;
    add) shift; cron_add "$@";; remove|rm) shift; cron_remove "$@";; list|ls) shift; cron_list "$@";;
    validate|lint) shift; cron_validate "$@";; wrap) shift; cron_wrap "$@";; status) shift; cron_status "$@";; audit) shift; cron_audit "$@";;
    *) die "cron: add | remove | list | status | validate | wrap | audit | print";;
  esac
}
