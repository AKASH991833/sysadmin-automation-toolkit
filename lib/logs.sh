# shellcheck shell=bash
# Safe log cleanup: compress old logs, delete very old ones, never touch files that are still being written.

logs_clean() {
  local dir="" compress=7 delete=30 apply=0 pattern='*.log*' max=""
  while (( $# )); do case $1 in
    --dir) dir=$2; shift 2;; --compress-after) compress=$2; shift 2;; --delete-after) delete=$2; shift 2;;
    --pattern) pattern=$2; shift 2;; --apply) apply=1; shift;; *) die "unknown option $1";; esac; done
  [[ -d $dir ]] || die "usage: sysops logs clean --dir DIR [--compress-after 7] [--delete-after 30] [--pattern '*.log*'] [--apply]"
  case $dir in /|/bin|/usr|/etc|/boot|/lib|/sbin|/proc|/sys|/dev) die "refusing to clean system directory $dir";; esac
  printf '%sLOG CLEANUP%s %s %s\n' "$BLD" "$OFF" "$dir" "$( ((apply)) || echo '(dry-run, add --apply)')"
  local f freed=0 n_c=0 n_d=0 busy=0 age
  while IFS= read -r -d '' f; do
    age=$(( ( $(date +%s) - $(stat -c %Y "$f") ) / 86400 ))
    # skip anything modified in the last 10 minutes or open by a process (still being written)
    if [[ -n $(find "$f" -mmin -10 2>/dev/null) ]] || { command -v fuser >/dev/null && fuser -s "$f" 2>/dev/null; }; then busy=$((busy+1)); continue; fi
    local sz; sz=$(stat -c %s "$f")
    if (( age >= delete )); then
      printf ' %s-%s delete   %-40s %6s days  %s\n' "$RED" "$OFF" "$(basename "$f")" "$age" "$(human "$sz")"
      n_d=$((n_d+1)); freed=$((freed+sz)); (( apply )) && rm -f -- "$f"
    elif (( age >= compress )) && [[ $f != *.gz && $f != *.xz && $f != *.zst ]]; then
      printf ' %s~%s compress %-40s %6s days  %s\n' "$YEL" "$OFF" "$(basename "$f")" "$age" "$(human "$sz")"
      n_c=$((n_c+1))
      if (( apply )); then gzip -9 -- "$f" && { local nsz; nsz=$(stat -c %s "$f.gz"); freed=$((freed+sz-nsz)); }
      else freed=$((freed+sz*7/10)); fi          # dry-run estimate: typical text logs shrink ~70-90%
    fi
  done < <(find "$dir" -maxdepth 3 -type f -name "$pattern" -print0)
  printf '\n%s deleted, %s compressed, %s skipped (in use / modified in last 10 min) -> %s %s\n' "$n_d" "$n_c" "$busy" "$( ((apply)) && echo freed || echo 'would free about')" "$(human "$freed")"
  (( apply )) && journal logs_clean "$dir" "deleted=$n_d compressed=$n_c freed=$freed"
  return 0
}
