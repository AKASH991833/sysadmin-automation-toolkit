# shellcheck shell=bash
# Incremental backups with GNU tar (--listed-incremental), checksums, optional AES-256 encryption, chain-aware retention.
# Files:  NAME-YYYYmmdd-HHMMSS-full.tar.gz[.enc]  and  NAME-...-incN.tar.gz[.enc]   + NAME.snar (tar snapshot state)

_enc() { local key=$1; openssl enc -aes-256-cbc -pbkdf2 -salt -pass "file:$key"; }
_dec() { local key=$1; openssl enc -d -aes-256-cbc -pbkdf2 -pass "file:$key"; }

backup_run() {
  local name="" dest="" src="" key="" full=0 keep=3 excl=()
  while (( $# )); do case $1 in
    --name) name=$2; shift 2;; --dest) dest=$2; shift 2;; --src) src=$2; shift 2;; --key) key=$2; shift 2;;
    --full) full=1; shift;; --keep-chains) keep=$2; shift 2;; --exclude) excl+=(--exclude "$2"); shift 2;; *) die "unknown option $1";; esac; done
  [[ -n $name && -n $dest && -n $src ]] || die "usage: sysops backup run --name N --src \"/etc /home\" --dest DIR [--full] [--key FILE] [--keep-chains 3] [--exclude PATTERN]"
  [[ -z $key || -r $key ]] || die "key file not readable: $key"
  mkdir -p "$dest"; chmod 700 "$dest"
  local snar="$dest/$name.snar" stamp kind; stamp=$(date +%Y%m%d-%H%M%S)
  if (( full )) || [[ ! -f $snar ]] || [[ $(date +%u) == 7 && -z $(ls "$dest"/"$name"-"$(date +%Y%m%d)"*-full.* 2>/dev/null) ]]; then
    rm -f "$snar"; kind=full
  else
    local n; n=$(ls "$dest/$name"-*-inc*.tar.gz* 2>/dev/null | wc -l); kind="inc$((n+1))"
  fi
  # incremental level uses a COPY of the snapshot so a failed run never corrupts the chain
  local work; work=$(mktemp); [[ -f $snar ]] && cp "$snar" "$work"
  local out="$dest/$name-$stamp-$kind.tar.gz"; [[ -n $key ]] && out+=".enc"
  # shellcheck disable=SC2086
  if [[ -n $key ]]; then tar --listed-incremental="$work" "${excl[@]}" -czf - $src 2>/dev/null | _enc "$key" > "$out"
  else tar --listed-incremental="$work" "${excl[@]}" -czf "$out" $src 2>/dev/null; fi
  local rc=$?; (( rc > 1 )) && { rm -f "$work" "$out"; die "tar failed (rc=$rc)"; }   # rc 1 = "file changed as we read it": acceptable
  mv "$work" "$snar"
  ( cd "$dest" && sha256sum "$(basename "$out")" >> "$name.sha256" )
  printf '%s %s backup -> %s (%s)\n' "${GRN}[ OK ]${OFF}" "$kind" "$out" "$(human "$(stat -c %s "$out")")"
  journal backup "$name" "$kind $out"
  # retention: keep the newest N full chains (a full + its incrementals are deleted together)
  local fulls; fulls=$(ls "$dest/$name"-*-full.tar.gz* 2>/dev/null | sort)
  local count; count=$(echo "$fulls" | grep -c . || true)
  if (( count > keep )); then
    local cutoff; cutoff=$(echo "$fulls" | sed -n "$((count-keep+1))p" | sed -E "s/.*$name-([0-9]{8}-[0-9]{6})-full.*/\1/")
    local f ts
    for f in "$dest/$name"-*.tar.gz*; do ts=$(basename "$f" | sed -E "s/^$name-([0-9]{8}-[0-9]{6})-.*/\1/"); [[ $ts < $cutoff ]] && { rm -f "$f"; echo "  pruned $(basename "$f")"; }; done
  fi
  return 0
}

backup_list() {
  local dest=${1:-} name=${2:-}; [[ -d $dest ]] || die "usage: sysops backup list DIR [NAME]"
  printf '%-52s %10s  %s\n' FILE SIZE TYPE
  local f; for f in $(ls "$dest"/${name:+$name-}*.tar.gz* 2>/dev/null | sort); do
    printf '%-52s %10s  %s\n' "$(basename "$f")" "$(human "$(stat -c %s "$f")")" "$(basename "$f" | grep -oE '(full|inc[0-9]+)')"
  done
}

backup_restore() { # restores the newest chain (full + all incrementals, in order) into TARGET; deletions are replayed
  local dest="" name="" to="" key=""
  while (( $# )); do case $1 in --dest) dest=$2; shift 2;; --name) name=$2; shift 2;; --to) to=$2; shift 2;; --key) key=$2; shift 2;; *) die "unknown option $1";; esac; done
  [[ -d $dest && -n $name && -n $to ]] || die "usage: sysops backup restore --dest DIR --name N --to TARGET [--key FILE]"
  mkdir -p "$to"
  local lastfull; lastfull=$(ls "$dest/$name"-*-full.tar.gz* 2>/dev/null | sort | tail -1); [[ -n $lastfull ]] || die "no full backup for $name"
  local fts; fts=$(basename "$lastfull" | sed -E "s/^$name-([0-9]{8}-[0-9]{6})-.*/\1/")
  # verify checksums first
  ( cd "$dest" && grep -F "$(basename "$lastfull")" "$name.sha256" | sha256sum -c --quiet ) || die "checksum failed for $lastfull"
  local f ts n=0
  for f in "$lastfull" $(ls "$dest/$name"-*-inc*.tar.gz* 2>/dev/null | sort -t- -k2,3); do
    ts=$(basename "$f" | sed -E "s/^$name-([0-9]{8}-[0-9]{6})-.*/\1/"); [[ $ts < $fts ]] && continue
    ( cd "$dest" && grep -F "$(basename "$f")" "$name.sha256" | sha256sum -c --quiet ) || die "checksum failed for $f"
    if [[ $f == *.enc ]]; then [[ -r $key ]] || die "encrypted backup: pass --key FILE"; _dec "$key" < "$f" | tar --listed-incremental=/dev/null -xzf - -C "$to"
    else tar --listed-incremental=/dev/null -xzf "$f" -C "$to"; fi
    n=$((n+1)); printf '  applied %s\n' "$(basename "$f")"
  done
  printf '%s[ OK ]%s restored %s archive(s) into %s\n' "$GRN" "$OFF" "$n" "$to"
}
