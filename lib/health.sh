# shellcheck shell=bash
# One-page system health report in text / markdown / html / json

_kv() { printf '%s\t%s\n' "$1" "$2"; }
health_collect() { # prints  section<TAB>key<TAB>value<TAB>state(ok|warn|crit|info)
  local cores load1 loadpct; cores=$(nproc); load1=$(cut -d' ' -f1 /proc/loadavg); loadpct=$(awk -v l="$load1" -v c="$cores" 'BEGIN{printf "%d", l*100/c}')
  local st=ok; (( loadpct >= 80 )) && st=warn; (( loadpct >= 150 )) && st=crit
  printf 'System\tHostname\t%s\tinfo\n' "${SYSOPS_HOSTNAME:-$(hostname)}"
  printf 'System\tOS\t%s\tinfo\n' "$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME")"
  printf 'System\tKernel\t%s\tinfo\n' "$(uname -r)"
  printf 'System\tUptime\t%s\tinfo\n' "$(uptime -p 2>/dev/null | sed 's/^up //')"
  printf 'CPU\tLoad average (1/5/15 min)\t%s (%s%% of %s cores)\t%s\n' "$(cut -d' ' -f1-3 /proc/loadavg)" "$loadpct" "$cores" "$st"
  local mt ma mp; mt=$(awk '/MemTotal/{print $2}' /proc/meminfo); ma=$(awk '/MemAvailable/{print $2}' /proc/meminfo); mp=$(( (mt-ma)*100/mt ))
  st=ok; (( mp >= 85 )) && st=warn; (( mp >= 95 )) && st=crit
  printf 'Memory\tRAM used\t%s%% (%s of %s)\t%s\n' "$mp" "$(human $(( (mt-ma)*1024 )))" "$(human $((mt*1024)))" "$st"
  local sp; sp=$(awk '/SwapTotal/{t=$2} /SwapFree/{f=$2} END{if(t>0) printf "%d",(t-f)*100/t; else print 0}' /proc/meminfo); st=ok; (( sp >= 50 )) && st=warn
  printf 'Memory\tSwap used\t%s%%\t%s\n' "$sp" "$st"
  local fs pct mnt
  while read -r fs pct mnt; do
    pct=${pct%\%}; st=ok; (( pct >= 80 )) && st=warn; (( pct >= 90 )) && st=crit
    printf 'Disk\t%s\t%s%% used (%s)\t%s\n' "$mnt" "$pct" "$fs" "$st"
  done < <(df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1{print $1, $5, $6}')
  local z; z=$(ps -eo stat= | grep -c '^Z' || true); st=ok; (( z > 0 )) && st=warn
  printf 'Processes\tZombie processes\t%s\t%s\n' "$z" "$st"
  ps -eo pcpu,pmem,comm --sort=-pcpu 2>/dev/null | awk 'NR>1 && NR<=4 {printf "Processes\tTop CPU #%d\t%s (%s%% cpu, %s%% mem)\tinfo\n", NR-1, $3, $1, $2}'
  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
    local f; f=$(systemctl list-units --state=failed --no-legend 2>/dev/null | grep -c . || true); st=ok; (( f > 0 )) && st=crit
    printf 'Services\tFailed systemd units\t%s\t%s\n' "$f" "$st"
  fi
  if command -v ss >/dev/null 2>&1; then printf 'Network\tListening TCP ports\t%s\tinfo\n' "$(ss -H -tln 2>/dev/null | awk '{n=split($4,a,":"); print a[n]}' | sort -nu | tr '\n' ' ')"; fi
  if [[ -r /var/lib/update-notifier/updates-available || -x /usr/lib/update-notifier/apt-check ]]; then :; fi
  if command -v apt-get >/dev/null 2>&1; then
    local up; up=$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true); st=ok; (( up > 0 )) && st=warn
    printf 'Updates\tPackages upgradable\t%s\t%s\n' "$up" "$st"
  fi
  [[ -f /var/run/reboot-required ]] && printf 'Updates\tReboot required\tyes\twarn\n'
  local lf; lf=$(last -n 3 -w 2>/dev/null | head -3 | awk '{print $1" from "$3}' | tr '\n' ';'); [[ -n $lf ]] && printf 'Security\tRecent logins\t%s\tinfo\n' "$lf"
}

health_report() {
  local fmt=${1:-text}; local data; data=$(health_collect)
  local worst=ok; grep -q $'\tcrit$' <<<"$data" && worst=crit || { grep -q $'\twarn$' <<<"$data" && worst=warn; }
  case $fmt in
    json)
      printf '{"generated":"%s","status":"%s","checks":[' "$(date -u +%FT%TZ)" "$worst"
      local first=1 s k v st; while IFS=$'\t' read -r s k v st; do (( first )) || printf ','; first=0; printf '{"section":"%s","name":"%s","value":"%s","state":"%s"}' "$s" "$(jesc "$k")" "$(jesc "$v")" "$st"; done <<<"$data"
      printf ']}\n' ;;
    md)
      printf '# Health report - %s\n\nGenerated %s - overall: **%s**\n\n| Section | Check | Value | State |\n|---|---|---|---|\n' "${SYSOPS_HOSTNAME:-$(hostname)}" "$(date -u +%FT%TZ)" "${worst^^}"
      local s k v st; while IFS=$'\t' read -r s k v st; do printf '| %s | %s | %s | %s |\n' "$s" "$k" "$v" "$st"; done <<<"$data" ;;
    html)
      local col=#22c55e; [[ $worst == warn ]] && col=#eab308; [[ $worst == crit ]] && col=#ef4444
      printf '<!doctype html><meta charset="utf-8"><title>Health report</title><style>body{font:15px system-ui;background:#0f172a;color:#e2e8f0;padding:28px}table{border-collapse:collapse;width:100%%;background:#1e293b;border-radius:12px;overflow:hidden}td,th{padding:9px 12px;text-align:left;border-bottom:1px solid #334155}th{color:#94a3b8;font-size:12px;text-transform:uppercase}.s{padding:2px 10px;border-radius:99px;font-weight:700;color:#0f172a}.ok{background:#22c55e}.warn{background:#eab308}.crit{background:#ef4444}.info{background:#64748b;color:#fff}h1 span{color:%s}</style>' "$col"
      printf '<h1>Health report <span>%s</span></h1><p>%s &middot; %s</p><table><tr><th>Section<th>Check<th>Value<th>State</tr>' "${worst^^}" "${SYSOPS_HOSTNAME:-$(hostname)}" "$(date -u +%FT%TZ)"
      local s k v st; while IFS=$'\t' read -r s k v st; do printf '<tr><td>%s<td>%s<td>%s<td><span class="s %s">%s</span></tr>' "$s" "$k" "$(printf '%s' "$v" | sed 's/&/\&amp;/g;s/</\&lt;/g')" "$st" "$st"; done <<<"$data"; printf '</table>\n' ;;
    *)
      printf '%sHealth report%s  %s   overall: %s\n' "$BLD" "$OFF" "${SYSOPS_HOSTNAME:-$(hostname)}" "$worst"
      local s k v st last="" c; while IFS=$'\t' read -r s k v st; do
        [[ $s != "$last" ]] && { printf '\n%s%s%s\n' "$BLD" "$s" "$OFF"; last=$s; }
        case $st in ok) c=$GRN;; warn) c=$YEL;; crit) c=$RED;; *) c=$DIM;; esac
        printf '  %-28s %s%s%s\n' "$k" "$c" "$v" "$OFF"
      done <<<"$data" ;;
  esac
  [[ $worst == crit ]] && return 2; [[ $worst == warn ]] && return 1; return 0
}

disk_hogs() {
  local path=${1:-/} top=${2:-10}
  printf '%sLargest directories under %s%s\n' "$BLD" "$path" "$OFF"
  du -xk --max-depth=2 "$path" 2>/dev/null | sort -rn | sed -n "2,$((top+1))p" | awk '{printf "  %10.1f MB  %s\n", $1/1024, $2}'
  printf '\n%sLargest files%s\n' "$BLD" "$OFF"
  find "$path" -xdev -type f -size +1M -printf '%s %p\n' 2>/dev/null | sort -rn | head -"$top" | awk '{printf "  %10.1f MB  %s\n", $1/1048576, $2}'
}
