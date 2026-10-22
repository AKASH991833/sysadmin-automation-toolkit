# shellcheck shell=bash
# Storage: LVM health + safe extend / snapshot / snapshot-backup, software RAID (md) status, fstab validation.
# Read-only commands exit 0 ok / 1 warning / 2 critical so cron and monitoring can alert on them.
# Test hooks: SYSOPS_MDSTAT (alternate /proc/mdstat), SYSOPS_LVM_FIXTURE (dir with vgs.txt lvs.txt pvs.txt in the same column format).

ST_WARN_VG_FREE=${SYSOPS_VG_FREE_WARN:-10}; ST_CRIT_VG_FREE=${SYSOPS_VG_FREE_CRIT:-5}   # % of the VG still unallocated
ST_WARN_USED=${SYSOPS_LV_USED_WARN:-80};   ST_CRIT_USED=${SYSOPS_LV_USED_CRIT:-95}      # % used: snapshots and thin pools

_st_sev=0
_st_ok()   { printf ' %s[ OK ]%s %s\n' "$GRN" "$OFF" "$*"; }
_st_warn() { printf ' %s[WARN]%s %s\n' "$YEL" "$OFF" "$*"; (( _st_sev < 1 )) && _st_sev=1; }
_st_crit() { printf ' %s[CRIT]%s %s\n' "$RED" "$OFF" "$*"; _st_sev=2; }
_st_alert() { # message  - webhook on warn/crit when SYSOPS_WEBHOOK_URL is set
  [[ -n ${SYSOPS_WEBHOOK_URL:-} ]] && curl -fsS -m 10 -H 'Content-Type: application/json' -d "{\"text\":\"sysops storage on $(hostname): $(jesc "$1")\"}" "$SYSOPS_WEBHOOK_URL" >/dev/null 2>&1 || true
}
_st_lvm() { # tool args... -> machine-readable rows (fixture aware)
  local tool=$1; shift
  if [[ -n ${SYSOPS_LVM_FIXTURE:-} ]]; then cat "$SYSOPS_LVM_FIXTURE/$tool.txt" 2>/dev/null; return 0; fi
  command -v "$tool" >/dev/null 2>&1 || return 127
  "$tool" --noheadings --separator '|' --units b --nosuffix "$@" 2>/dev/null
}
_trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; printf '%s' "${s%"${s##*[![:space:]]}"}"; }
_pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print 0; else printf "%d", (a*100)/b }'; }

# ---------------------------------------------------------------- RAID (md)
raid_status() {
  local quiet=0 alert=0; while (( $# )); do case $1 in --alert) alert=1; shift;; --quiet) quiet=1; shift;; *) die "usage: sysops storage raid status [--alert]";; esac; done
  local md=${SYSOPS_MDSTAT:-/proc/mdstat}; _st_sev=0
  echo "${BLD}RAID (md)${OFF}"
  if [[ ! -r $md ]]; then echo "  no software RAID (no $md)"; return 0; fi
  if ! grep -q '^md' "$md"; then echo "  no md arrays configured"; return 0; fi
  local line name="" state="" level="" members="" detail="" msgs=""
  local -A seen
  while IFS= read -r line; do
    if [[ $line =~ ^(md[0-9a-zA-Z_]+)[[:space:]]*:[[:space:]]*([a-z-]+)[[:space:]]+(\(auto-read-only\)[[:space:]]+)?([a-z0-9]+)?[[:space:]]*(.*)$ ]]; then
      name=${BASH_REMATCH[1]}; state=${BASH_REMATCH[2]}; level=${BASH_REMATCH[4]}; members=${BASH_REMATCH[5]}; seen[$name]=1
      if [[ $state == inactive ]]; then _st_crit "$name is INACTIVE (members: $members)"; name=""; continue; fi
      if [[ $state == *auto-read-only* || ${BASH_REMATCH[3]} == *auto-read-only* ]]; then _st_warn "$name is auto-read-only (not yet written to since assembly)"; fi
      local f; f=$(grep -oE '[a-z0-9]+\[[0-9]+\]\(F\)' <<<"$members" | tr '\n' ' ')
      [[ -n $f ]] && _st_crit "$name ($level): FAILED member(s): $f"
      continue
    fi
    # status line:  1046528 blocks super 1.2 [2/2] [UU]
    if [[ -n $name && $line =~ \[([0-9]+)/([0-9]+)\][[:space:]]*\[([U_]+)\] ]]; then
      local want=${BASH_REMATCH[1]} have=${BASH_REMATCH[2]} map=${BASH_REMATCH[3]}
      if (( have < want )); then _st_crit "$name ($level): DEGRADED $have/$want devices active [$map]"
      else _st_ok "$name ($level): all $want devices active [$map]"; fi
      continue
    fi
    if [[ -n $name && $line =~ (resync|recovery|reshape|check)[[:space:]]*=[[:space:]]*([0-9.]+)%.*finish=([0-9.]+min) ]]; then
      _st_warn "$name: ${BASH_REMATCH[1]} in progress ${BASH_REMATCH[2]}% (eta ${BASH_REMATCH[3]})"
    elif [[ -n $name && $line =~ (resync|recovery)[[:space:]]*=[[:space:]]*([A-Za-z]+) ]]; then
      _st_warn "$name: ${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    fi
  done < "$md"
  if command -v mdadm >/dev/null 2>&1 && [[ -z ${SYSOPS_MDSTAT:-} ]]; then
    local n; for n in "${!seen[@]}"; do
      local d; d=$(mdadm --detail "/dev/$n" 2>/dev/null | sed -n 's/^ *State : //p' | head -1)
      [[ -n $d ]] && printf '       %s mdadm state: %s\n' "$n" "$d"
    done
  fi
  (( _st_sev == 0 )) && echo "  all arrays healthy"
  journal raid_status "$md" "severity=$_st_sev"
  (( alert && _st_sev >= 1 )) && _st_alert "RAID severity $_st_sev (see 'sysops storage raid status')"
  return "$_st_sev"
}

# ---------------------------------------------------------------- LVM health
lvm_status() {
  local alert=0; [[ ${1:-} == --alert ]] && alert=1; _st_sev=0
  echo "${BLD}LVM${OFF}"
  local vgs lvs pvs; vgs=$(_st_lvm vgs -o vg_name,vg_size,vg_free,pv_count,vg_attr); local rc=$?
  if (( rc == 127 )); then echo "  lvm2 tools not installed - nothing to check"; return 0; fi
  if [[ -z $vgs ]]; then echo "  no volume groups"; return 0; fi
  local vg size free npv attr
  while IFS='|' read -r vg size free npv attr; do
    vg=$(_trim "$vg"); [[ -z $vg ]] && continue; size=$(_trim "$size"); free=$(_trim "$free"); attr=$(_trim "$attr")
    local fp; fp=$(_pct "$free" "$size")
    if (( fp < ST_CRIT_VG_FREE )); then _st_crit "VG $vg: only ${fp}% unallocated ($(human "$free") of $(human "$size")) - cannot extend or snapshot"
    elif (( fp < ST_WARN_VG_FREE )); then _st_warn "VG $vg: ${fp}% unallocated ($(human "$free") of $(human "$size"))"
    else _st_ok "VG $vg: ${fp}% unallocated ($(human "$free") free of $(human "$size"), $(_trim "$npv") PV)"; fi
    [[ ${attr:3:1} == p ]] && _st_crit "VG $vg is PARTIAL: a physical volume is missing"
    [[ ${attr:0:1} == r ]] || true
  done <<<"$vgs"
  pvs=$(_st_lvm pvs -o pv_name,vg_name,pv_attr,pv_missing 2>/dev/null || true)
  local pv pvg pattr pmiss
  while IFS='|' read -r pv pvg pattr pmiss; do
    pv=$(_trim "$pv"); [[ -z $pv ]] && continue
    [[ $pv == *unknown* || $(_trim "${pmiss:-}") == missing ]] && _st_crit "PV $pv of VG $(_trim "$pvg") is MISSING"
  done <<<"$pvs"
  lvs=$(_st_lvm lvs -o vg_name,lv_name,lv_attr,lv_size,data_percent,metadata_percent,origin,pool_lv)
  local lv lattr lsize dp mp origin pool
  while IFS='|' read -r vg lv lattr lsize dp mp origin pool; do
    vg=$(_trim "$vg"); [[ -z $vg ]] && continue; lv=$(_trim "$lv"); lattr=$(_trim "$lattr"); dp=$(_trim "${dp:-}"); mp=$(_trim "${mp:-}"); origin=$(_trim "${origin:-}")
    local dpi=${dp%%.*}; local mpi=${mp%%.*}; [[ $dpi =~ ^[0-9]+$ ]] || dpi=""; [[ $mpi =~ ^[0-9]+$ ]] || mpi=""
    local t=${lattr:0:1} h=${lattr:8:1} s=${lattr:4:1}
    [[ ${lattr:8:1} == p ]] && _st_crit "LV $vg/$lv is PARTIAL (a PV it needs is missing)"
    [[ $t == m || $t == M ]] && true
    [[ $s == I || $s == S ]] && { _st_crit "snapshot $vg/$lv is INVALID/dropped (it filled up) - its backup is useless"; continue; }
    if [[ -n $origin && -n $dpi ]]; then   # classic snapshot: data_percent = how full the COW area is
      if (( dpi >= ST_CRIT_USED )); then _st_crit "snapshot $vg/$lv of $origin is ${dpi}% full - it will be invalidated soon"
      elif (( dpi >= ST_WARN_USED )); then _st_warn "snapshot $vg/$lv of $origin is ${dpi}% full"; else _st_ok "snapshot $vg/$lv of $origin: ${dpi}% used"; fi
    elif [[ $t == t && -n $dpi ]]; then    # thin pool
      if (( dpi >= ST_CRIT_USED )); then _st_crit "thin pool $vg/$lv data ${dpi}% full - writes will start failing"
      elif (( dpi >= ST_WARN_USED )); then _st_warn "thin pool $vg/$lv data ${dpi}% full"; else _st_ok "thin pool $vg/$lv data ${dpi}% used"; fi
      if [[ -n $mpi ]]; then (( mpi >= ST_CRIT_USED )) && _st_crit "thin pool $vg/$lv METADATA ${mpi}% full" || { (( mpi >= ST_WARN_USED )) && _st_warn "thin pool $vg/$lv metadata ${mpi}% full"; }; fi
    elif [[ $t == r || $t == m ]]; then
      [[ ${lattr:8:1} == r ]] && _st_warn "LV $vg/$lv: RAID LV needs refresh/replace"
    fi
  done <<<"$lvs"
  (( _st_sev == 0 )) && echo "  LVM healthy"
  journal lvm_status "lvm" "severity=$_st_sev"
  (( alert && _st_sev >= 1 )) && _st_alert "LVM severity $_st_sev (see 'sysops storage lvm status')"
  return "$_st_sev"
}

_lv_info() { # VG/LV -> sets LV_VG LV_NAME LV_PATH LV_FS LV_MNT
  [[ $1 =~ ^([A-Za-z0-9_.+-]+)/([A-Za-z0-9_.+-]+)$ ]] || die "logical volume must be given as VG/LV"
  LV_VG=${BASH_REMATCH[1]}; LV_NAME=${BASH_REMATCH[2]}; LV_PATH=/dev/$LV_VG/$LV_NAME
  command -v lvs >/dev/null || die "lvm2 is not installed"
  lvs "$LV_VG/$LV_NAME" >/dev/null 2>&1 || die "no such logical volume: $LV_VG/$LV_NAME"
  LV_FS=$(blkid -o value -s TYPE "$LV_PATH" 2>/dev/null || true); LV_MNT=$(findmnt -n -o TARGET "$LV_PATH" 2>/dev/null | head -1 || true)
}
_vg_free() { vgs --noheadings --units b --nosuffix -o vg_free "$1" 2>/dev/null | tr -d ' '; }
_vg_size() { vgs --noheadings --units b --nosuffix -o vg_size "$1" 2>/dev/null | tr -d ' '; }
_to_bytes() { # 5G 500M 1T 100% -> bytes (no %)
  local v=$1 n u; [[ $v =~ ^([0-9]+)([KkMmGgTt]?)$ ]] || die "bad size '$v' (examples: 500M, 5G, 1T)"
  n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]^^}
  case $u in K) echo $((n*1024));; M|"") echo $((n*1024*1024));; G) echo $((n*1024*1024*1024));; T) echo $((n*1024*1024*1024*1024));; esac
}

lvm_extend() {
  local target=${1:-}; shift || true; local by="" apply=0 reserve=$ST_WARN_VG_FREE force=0
  while (( $# )); do case $1 in --by) by=$2; shift 2;; --apply) apply=1; shift;; --reserve) reserve=$2; shift 2;; --force) force=1; shift;; *) die "unknown option $1";; esac; done
  [[ -n $target && -n $by ]] || die "usage: sysops storage lvm extend VG/LV --by 5G [--reserve PCT] [--force] [--apply]"
  _lv_info "$target"
  local want free size after; want=$(_to_bytes "$by"); free=$(_vg_free "$LV_VG"); size=$(_vg_size "$LV_VG")
  echo "plan: extend $LV_VG/$LV_NAME by $(human "$want")  (fs: ${LV_FS:-none}, mounted at: ${LV_MNT:-not mounted}, VG free: $(human "$free"))"
  (( want <= free )) || die "VG $LV_VG has only $(human "$free") free, need $(human "$want"). Add a disk (pvcreate + vgextend) first."
  after=$(( free - want )); local ap; ap=$(_pct "$after" "$size")
  if (( ap < reserve )) && (( ! force )); then die "that would leave only ${ap}% of the VG free (< ${reserve}% reserve for snapshots). Use --force to override."; fi
  case ${LV_FS:-} in ext2|ext3|ext4|xfs|btrfs) ;; "") warn "no filesystem detected - only the LV will grow";; *) die "online resize of '$LV_FS' is not supported by this helper";; esac
  (( apply )) || { echo "(dry-run: add --apply)"; return 0; }
  local before; before=$(blockdev --getsize64 "$LV_PATH")
  if [[ -n $LV_FS ]]; then lvextend -r -L "+${want}b" "$LV_VG/$LV_NAME" >/dev/null || die "lvextend failed - nothing else was changed"
  else lvextend -L "+${want}b" "$LV_VG/$LV_NAME" >/dev/null || die "lvextend failed"; fi
  local now; now=$(blockdev --getsize64 "$LV_PATH")
  (( now > before )) || die "LV did not grow"
  if [[ -n $LV_FS && -n $LV_MNT ]]; then
    local fsz; fsz=$(df -B1 --output=size "$LV_MNT" | tail -1 | tr -d ' ')
    (( fsz > before * 90 / 100 )) || die "filesystem did not grow to match the LV"
    echo "  filesystem on $LV_MNT now $(human "$fsz")"
  fi
  journal lvm_extend "$LV_VG/$LV_NAME" "+$(human "$want") -> $(human "$now")"
  printf '%s[ OK ]%s %s/%s: %s -> %s\n' "$GRN" "$OFF" "$LV_VG" "$LV_NAME" "$(human "$before")" "$(human "$now")"
}

lvm_snapshot() {
  local sub=${1:-}; shift || true
  case $sub in
    create)
      local target=${1:-}; shift || true; local size="" apply=0
      while (( $# )); do case $1 in --size) size=$2; shift 2;; --apply) apply=1; shift;; *) die "unknown option $1";; esac; done
      [[ -n $target ]] || die "usage: sysops storage lvm snapshot create VG/LV [--size 1G] [--apply]"
      _lv_info "$target"; local sname="${LV_NAME}_sysops_snap_$(date +%Y%m%d_%H%M%S)"
      local free; free=$(_vg_free "$LV_VG")
      [[ -n $size ]] || { size=$(( free / 4 )); size="${size}b"; }
      local sb; if [[ $size == *b ]]; then sb=${size%b}; else sb=$(_to_bytes "$size"); fi
      echo "plan: snapshot $LV_VG/$LV_NAME -> $sname with $(human "$sb") copy-on-write space (VG free: $(human "$free"))"
      (( sb <= free )) || die "not enough free space in $LV_VG for a $(human "$sb") snapshot"
      (( sb >= 8388608 )) || die "snapshot size too small (< 8M)"
      (( apply )) || { echo "(dry-run: add --apply)"; return 0; }
      local err; err=$(lvcreate -s -n "$sname" -L "${sb}b" "$LV_VG/$LV_NAME" 2>&1) || die "lvcreate failed: $(tr '\n' ' ' <<<"$err")"
      journal lvm_snapshot_create "$LV_VG/$sname" "$(human "$sb")"
      printf '%s[ OK ]%s created %s/%s\n' "$GRN" "$OFF" "$LV_VG" "$sname" ;;
    list)
      command -v lvs >/dev/null || die "lvm2 is not installed"
      printf '%-44s %-14s %8s\n' SNAPSHOT ORIGIN USED%
      lvs --noheadings --separator '|' -o vg_name,lv_name,origin,data_percent,lv_attr 2>/dev/null | while IFS='|' read -r v l o d a; do
        [[ -n $(_trim "$o") ]] && printf '%-44s %-14s %8s\n' "$(_trim "$v")/$(_trim "$l")" "$(_trim "$o")" "$(_trim "$d")"; done; true ;;
    remove)
      local target=${1:-}; shift || true; local apply=0; [[ ${1:-} == --apply ]] && apply=1
      [[ $target =~ _sysops_snap_ ]] || die "refusing: only snapshots created by sysops (…_sysops_snap_…) can be removed with this command"
      _lv_info "$target"
      local org; org=$(lvs --noheadings -o origin "$LV_VG/$LV_NAME" | tr -d ' '); [[ -n $org ]] || die "$target is not a snapshot"
      echo "plan: remove snapshot $target (origin $org)"; (( apply )) || { echo "(dry-run: add --apply)"; return 0; }
      [[ -z $LV_MNT ]] || die "snapshot is mounted at $LV_MNT"
      lvremove -f "$LV_VG/$LV_NAME" >/dev/null || die "lvremove failed"; journal lvm_snapshot_remove "$target" ""; printf '%s[ OK ]%s removed %s\n' "$GRN" "$OFF" "$target" ;;
    prune)
      local target=${1:-}; shift || true; local keep=3 apply=0
      while (( $# )); do case $1 in --keep) keep=$2; shift 2;; --apply) apply=1; shift;; *) die "unknown option $1";; esac; done
      [[ -n $target ]] || die "usage: sysops storage lvm snapshot prune VG/LV [--keep 3] [--apply]"
      _lv_info "$target"
      local all; all=$(lvs --noheadings -o lv_name --select "origin=$LV_NAME && lv_name=~_sysops_snap_" "$LV_VG" 2>/dev/null | tr -d ' ' | sort)
      local n; n=$(grep -c . <<<"$all" || true); echo "$n sysops snapshot(s) of $target, keeping newest $keep"
      (( n > keep )) || { echo "nothing to prune"; return 0; }
      local s; for s in $(head -n $((n-keep)) <<<"$all"); do
        if (( apply )); then lvremove -f "$LV_VG/$s" >/dev/null && { echo "  removed $s"; journal lvm_snapshot_remove "$LV_VG/$s" prune; }; else echo "  would remove $s"; fi; done ;;
    *) die "snapshot: create | list | remove | prune" ;;
  esac
}

# consistent backup: snapshot -> read-only mount -> sysops incremental backup -> always clean up
lvm_backup() {
  local target=${1:-}; shift || true; local dest="" key="" name="" size="" full=0
  while (( $# )); do case $1 in --dest) dest=$2; shift 2;; --key) key=$2; shift 2;; --name) name=$2; shift 2;; --size) size=$2; shift 2;; --full) full=1; shift;; *) die "unknown option $1";; esac; done
  [[ -n $target && -n $dest ]] || die "usage: sysops storage lvm backup VG/LV --dest DIR [--name N] [--size 1G] [--key FILE] [--full]"
  _lv_info "$target"; [[ -n $name ]] || name="lv-${LV_VG}-${LV_NAME}"
  local sname="${LV_NAME}_sysops_snap_bk$$" free; free=$(_vg_free "$LV_VG")
  local sb; if [[ -n $size ]]; then sb=$(_to_bytes "$size"); else sb=$(( free / 4 )); fi
  (( sb <= free && sb >= 8388608 )) || die "not enough free space in $LV_VG for a snapshot ($(human "$free") free)"
  mkdir -p "$dest"; chmod 700 "$dest"
  # LVM metadata backup alongside the data: lets you rebuild the VG layout after a disk loss
  command -v vgcfgbackup >/dev/null && vgcfgbackup -f "$dest/$name-vgcfg-$(date +%Y%m%d-%H%M%S).vg" "$LV_VG" >/dev/null 2>&1 && echo "  saved LVM metadata for $LV_VG"
  _BK_MNT=$(mktemp -d); _BK_MOUNTED=0; _BK_MADE=0; _BK_VG=$LV_VG; _BK_SNAP=$sname
  _bk_cleanup() { (( _BK_MOUNTED )) && umount "$_BK_MNT" 2>/dev/null; (( _BK_MADE )) && lvremove -f "$_BK_VG/$_BK_SNAP" >/dev/null 2>&1; rmdir "$_BK_MNT" 2>/dev/null; _BK_MOUNTED=0; _BK_MADE=0; }
  trap _bk_cleanup EXIT     # also runs when die() aborts half way: never leave a snapshot or mount behind
  local err; err=$(lvcreate -s -n "$sname" -L "${sb}b" "$LV_VG/$LV_NAME" 2>&1) || die "snapshot creation failed: $(tr '\n' ' ' <<<"$err")"; _BK_MADE=1
  local opts=ro; [[ $LV_FS == xfs ]] && opts=ro,nouuid
  mount -o "$opts" "/dev/$LV_VG/$sname" "$_BK_MNT" || die "could not mount the snapshot read-only"; _BK_MOUNTED=1
  echo "  snapshot $sname mounted read-only, backing up"
  local bargs=(--name "$name" --src "$_BK_MNT" --dest "$dest"); [[ -n $key ]] && bargs+=(--key "$key"); (( full )) && bargs+=(--full)
  backup_run "${bargs[@]}"; local rc=$?
  local used; used=$(lvs --noheadings -o data_percent "$LV_VG/$sname" 2>/dev/null | tr -d ' ')
  echo "  snapshot copy-on-write used: ${used:-?}%  (removed after the backup)"
  _bk_cleanup; trap - EXIT
  journal lvm_backup "$LV_VG/$LV_NAME" "dest=$dest rc=$rc"
  return "$rc"
}

# ---------------------------------------------------------------- fstab validation
# One bad fstab line can stop a server from booting (systemd drops to emergency mode). Validate BEFORE rebooting.
_fstab_resolve() { # spec -> 0 if exists
  case $1 in
    UUID=*)     [[ -e /dev/disk/by-uuid/${1#UUID=} ]] || { command -v blkid >/dev/null && blkid -U "${1#UUID=}" >/dev/null 2>&1; };;
    LABEL=*)    [[ -e /dev/disk/by-label/${1#LABEL=} ]] || { command -v blkid >/dev/null && blkid -L "${1#LABEL=}" >/dev/null 2>&1; };;
    PARTUUID=*) [[ -e /dev/disk/by-partuuid/${1#PARTUUID=} ]];;
    /dev/*)     [[ -e $1 ]];;
    *) return 0;;
  esac
}
fstab_check() {
  local file=/etc/fstab resolve=1 quiet=0
  while (( $# )); do case $1 in --no-resolve) resolve=0; shift;; --quiet) quiet=1; shift;; *) file=$1; shift;; esac; done
  [[ -r $file ]] || die "cannot read $file"
  local errs=0 warns=0 n=0 line; local -A mnts
  _fe() { printf ' %s[FAIL]%s line %d: %s\n' "$RED" "$OFF" "$n" "$*"; errs=$((errs+1)); }
  _fw() { printf ' %s[WARN]%s line %d: %s\n' "$YEL" "$OFF" "$n" "$*"; warns=$((warns+1)); }
  while IFS= read -r line; do
    n=$((n+1)); [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    local -a f; read -ra f <<<"$line"
    if (( ${#f[@]} < 4 )); then _fe "needs at least 4 fields (device mountpoint fstype options), got ${#f[@]}: $line"; continue; fi
    if (( ${#f[@]} > 6 )); then _fe "too many fields (${#f[@]}); spaces in a path must be written as \\040"; continue; fi
    local dev=${f[0]} mp=${f[1]} fs=${f[2]} opt=${f[3]} dump=${f[4]:-0} pass=${f[5]:-0}
    [[ $dump =~ ^[01]$ ]] || _fe "dump field must be 0 or 1, got '$dump'"
    [[ $pass =~ ^[012]$ ]] || _fe "pass (fsck order) must be 0, 1 or 2, got '$pass'"
    [[ $opt == *default,* || $opt == *,default || $opt == default ]] && _fe "option 'default' is a typo - it must be 'defaults'"
    [[ $opt == *" "* ]] && _fe "options must not contain spaces"
    [[ $fs == swap ]] && { [[ $mp == none || $mp == swap ]] || _fw "swap entry should use 'none' as mountpoint"; }
    if [[ $fs != swap && $mp != none ]]; then
      [[ $mp == /* ]] || _fe "mountpoint '$mp' must be an absolute path"
      if [[ -n ${mnts[$mp]:-} ]]; then _fe "mountpoint $mp is already used on line ${mnts[$mp]}"; fi; mnts[$mp]=$n
      (( resolve )) && [[ $mp == /* && ! -d $mp ]] && _fe "mountpoint directory $mp does not exist (the mount fails at boot)"
    fi
    [[ $mp == / && $pass != 1 && $fs != btrfs && $fs != xfs ]] && _fw "root filesystem should have pass=1"
    [[ $mp != / && $pass == 1 ]] && _fw "pass=1 is meant for / only; use 2"
    case $fs in nfs|nfs4|cifs|smb3|glusterfs|ceph|fuse.sshfs)
      [[ ,$opt, == *,_netdev,* || ,$opt, == *,nofail,* ]] || _fw "network filesystem without _netdev/nofail: an unreachable server can hang or break boot";; esac
    if [[ $mp != / && $mp != /boot* && $fs != swap && $fs != tmpfs && $fs != nfs* && $fs != cifs && $fs != proc && $fs != sysfs && $fs != devpts && $fs != none && $fs != bind ]]; then
      [[ ,$opt, == *,nofail,* || ,$opt, == *,noauto,* ]] || _fw "no 'nofail' on $mp: if this disk is missing the server drops into emergency mode at boot"; fi
    if (( resolve )); then _fstab_resolve "$dev" || _fe "device $dev does not exist (UUID/label typo or disk missing)"; fi
  done < "$file"
  # the util-linux verifier is a second opinion when present (no output parsing: its verdict is its exit code)
  if (( resolve )) && command -v findmnt >/dev/null 2>&1 && findmnt --help 2>&1 | grep -q -- --verify; then
    if ! findmnt --verify --tab-file "$file" >/dev/null 2>&1; then
      local fe; fe=$(findmnt --verify --tab-file "$file" 2>&1 | grep -E 'error|\[E\]' | head -3)
      [[ -n $fe ]] && { printf ' %s[FAIL]%s findmnt --verify: %s\n' "$RED" "$OFF" "$(tr '\n' ' ' <<<"$fe")"; errs=$((errs+1)); }
    fi
  fi
  if (( errs )); then printf '%d error(s), %d warning(s) in %s - DO NOT REBOOT with this file\n' "$errs" "$warns" "$file"; return 2; fi
  (( warns )) && { printf '%s valid with %d warning(s)\n' "$file" "$warns"; return 1; }
  printf '%s[ OK ]%s %s is valid\n' "$GRN" "$OFF" "$file"
}
# add a line safely: build the new file aside, validate it, keep a backup, then replace atomically
fstab_add() {
  local dev="" mp="" fs="" opts="defaults,nofail" pass=2 apply=0 file=/etc/fstab
  while (( $# )); do case $1 in --device) dev=$2; shift 2;; --mount) mp=$2; shift 2;; --fs) fs=$2; shift 2;; --opts) opts=$2; shift 2;;
    --pass) pass=$2; shift 2;; --file) file=$2; shift 2;; --apply) apply=1; shift;; *) die "unknown option $1";; esac; done
  [[ -n $dev && -n $mp && -n $fs ]] || die "usage: sysops storage fstab add --device UUID=... --mount /data --fs ext4 [--opts defaults,nofail] [--pass 2] [--apply]"
  local tmp; tmp=$(mktemp); cp "$file" "$tmp"; printf '%s\t%s\t%s\t%s\t0\t%s\n' "$dev" "$mp" "$fs" "$opts" "$pass" >> "$tmp"
  echo "plan: append  $dev  $mp  $fs  $opts  0  $pass"
  fstab_check "$tmp" ${SYSOPS_FSTAB_NORESOLVE:+--no-resolve}; local rc=$?
  (( rc == 2 )) && { rm -f "$tmp"; die "validation failed - $file NOT modified"; }
  (( apply )) || { rm -f "$tmp"; echo "(dry-run: add --apply)"; return 0; }
  mkdir -p "$STATE/fstab-backups"; local bk="$STATE/fstab-backups/fstab-$(date +%Y%m%d-%H%M%S-%N)"; cp -p "$file" "$bk"
  cat "$tmp" > "$file"; rm -f "$tmp"
  journal fstab_add "$mp" "$dev $fs backup=$bk"; printf '%s[ OK ]%s fstab updated (backup %s)\n' "$GRN" "$OFF" "$bk"
}

storage_health() { # raid + lvm + fstab, worst exit code
  local worst=0 rc
  raid_status "$@"; rc=$?; (( rc > worst )) && worst=$rc
  lvm_status "$@";  rc=$?; (( rc > worst )) && worst=$rc
  echo "${BLD}fstab${OFF}"
  if [[ -n $UROOT ]]; then fstab_check "$UROOT/etc/fstab" --no-resolve; else fstab_check /etc/fstab; fi; rc=$?; (( rc > worst )) && worst=$rc
  return "$worst"
}

storage_cmd() {
  case ${1:-} in
    health) shift; storage_health "$@";;
    raid)   shift; [[ ${1:-} == status ]] || die "raid: status"; shift; raid_status "$@";;
    lvm)    shift; case ${1:-} in status) shift; lvm_status "$@";; extend) shift; lvm_extend "$@";; snapshot) shift; lvm_snapshot "$@";; backup) shift; lvm_backup "$@";; *) die "lvm: status | extend | snapshot | backup";; esac;;
    fstab)  shift; case ${1:-} in check) shift; fstab_check "$@";; add) shift; fstab_add "$@";; *) die "fstab: check | add";; esac;;
    *) die "storage: health | lvm | raid | fstab";;
  esac
}
