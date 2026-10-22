#!/usr/bin/env bash
# REAL storage drills on the kernel's own LVM and md-RAID, using loop devices (needs root).
#  - LVM: extend with online fs growth, copy-on-write snapshot that really fills up and is invalidated,
#         VG nearly full, snapshot-based consistent backup + restore after data loss, no leftovers
#  - RAID1: healthy -> member failed -> degraded alert -> remove -> spare added -> rebuild -> healthy, data intact
# Set STORAGE_NO_UDEV=1 in containers (no udevd there): LVM then creates device nodes itself.
set -uo pipefail
cd "$(dirname "$0")/.."
[[ $EUID -eq 0 ]] || { echo "needs root"; exit 77; }
export NO_COLOR=1
T=$(mktemp -d); export SYSOPS_STATE="$T/state"; SO="$PWD/sysops"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }
LOOPS=(); MNTS=()
cleanup() {
  set +e
  for m in "${MNTS[@]}"; do umount -l "$m" 2>/dev/null; done
  vgchange -an vgt >/dev/null 2>&1; vgremove -ff vgt >/dev/null 2>&1
  for md in /dev/md/sysops0 /dev/md_sysops0; do [[ -e $md ]] && mdadm --stop "$md" >/dev/null 2>&1; done
  for l in "${LOOPS[@]}"; do pvremove -ff -y "$l" >/dev/null 2>&1; losetup -d "$l" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT
mkloop() { local f="$T/$1.img"; truncate -s "$2" "$f"; local l; l=$(losetup -f --show "$f") || return 1; LOOPS+=("$l"); echo "$l"; }

if [[ -n ${STORAGE_NO_UDEV:-} ]]; then
  mkdir -p /etc/lvm/conf.d
  printf 'activation {\n udev_sync = 0\n udev_rules = 0\n verify_udev_operations = 0\n}\ndevices {\n use_devicesfile = 0\n}\n' > /etc/lvm/conf.d/sysops-ci.conf
  # older lvm2 without conf.d: append to lvm.conf
  grep -q 'conf.d' /etc/lvm/lvm.conf 2>/dev/null || printf 'activation {\n udev_sync = 0\n udev_rules = 0\n}\n' >> /etc/lvm/lvm.conf
fi
command -v lvcreate >/dev/null || { echo "lvm2 missing"; exit 1; }
echo "lvm: $(lvm version 2>&1 | head -1 | xargs)"; echo "kernel: $(uname -r)"; [[ -x $(command -v mdadm) ]] && mdadm --version 2>&1 | head -1
modprobe dm-snapshot 2>/dev/null; SNAPOK=0; dmsetup targets 2>/dev/null | grep -qw snapshot && SNAPOK=1; (( SNAPOK )) || echo "NOTE: kernel dm-snapshot target unavailable in this container - snapshot drills SKIPPED (they run on the Ubuntu runner job)"

echo "== LVM on loop devices"
L1=$(mkloop pv1 300M) && L2=$(mkloop pv2 300M) || { echo "cannot create loop devices here"; exit 77; }
assert "pvcreate/vgcreate/lvcreate"                   'pvcreate -y $L1 $L2 >/dev/null 2>&1 && vgcreate vgt $L1 $L2 >/dev/null 2>&1 && lvcreate -y -n data -L 120M vgt >/dev/null 2>&1 && ls /dev/vgt/data >/dev/null'
mkfs.ext4 -q /dev/vgt/data; mkdir -p "$T/mnt"; mount /dev/vgt/data "$T/mnt"; MNTS+=("$T/mnt")
for i in 1 2 3 4 5; do head -c 1M /dev/urandom > "$T/mnt/file$i.bin"; done; (cd "$T/mnt" && sha256sum file*.bin > "$T/sums.orig")
out=$($SO storage lvm status); rc=$?
assert "healthy VG/LV: exit 0"                        '(( rc == 0 )) && grep -q "VG vgt" <<<"$out"'
before=$(df -B1 --output=size "$T/mnt" | tail -1)
out=$($SO storage lvm extend vgt/data --by 100M); rc=$?
assert "extend dry-run changes nothing"               '(( rc == 0 )) && [[ $(df -B1 --output=size "$T/mnt" | tail -1) == "$before" ]] && grep -q dry-run <<<"$out"'
out=$($SO storage lvm extend vgt/data --by 100G 2>&1); rc=$?
assert "extend beyond VG free is refused"             '(( rc != 0 )) && grep -q "has only" <<<"$out"'
out=$($SO storage lvm extend vgt/data --by 80M --reserve 90 2>&1); rc=$?
assert "extend that eats the reserve is refused"      '(( rc != 0 )) && grep -q "reserve" <<<"$out"'
$SO storage lvm extend vgt/data --by 100M --apply >/dev/null 2>&1; rc=$?
after=$(df -B1 --output=size "$T/mnt" | tail -1)
assert "extend --apply grows LV AND mounted ext4"     '(( rc == 0 )) && (( after > before + 80*1024*1024 ))'
assert "data intact after online grow"                '(cd "$T/mnt" && sha256sum -c "$T/sums.orig" >/dev/null 2>&1)'

if (( SNAPOK )); then
echo "== LVM snapshot that really fills up"
snapout=$($SO storage lvm snapshot create vgt/data --size 32M --apply 2>&1); rc=$?; (( rc == 0 )) || echo "    snapshot create said: $snapout"
SNAP=$(lvs --noheadings -o lv_name vgt 2>/dev/null | tr -d ' ' | grep _sysops_snap_ | head -1)
assert "snapshot created"                             '(( rc == 0 )) && [[ -n $SNAP ]]'
echo "changed after snapshot" > "$T/mnt/file1.bin"
mkdir -p "$T/snapmnt"; mount -o ro "/dev/vgt/$SNAP" "$T/snapmnt" 2>/dev/null; MNTS+=("$T/snapmnt")
assert "snapshot still holds the OLD content"         '! grep -q "changed after" "$T/snapmnt/file1.bin"'
umount "$T/snapmnt"
out=$($SO storage lvm snapshot list)
assert "snapshot list shows it"                       'grep -q "$SNAP" <<<"$out"'
out=$($SO storage lvm status); rc=$?
assert "fresh snapshot is OK (exit 0)"                '(( rc == 0 ))'
dd if=/dev/urandom of="$T/mnt/churn.bin" bs=1M count=60 conv=fsync 2>/dev/null; sync
out=$($SO storage lvm status); rc=$?
assert "overflowing the COW area raises CRIT"         '(( rc == 2 )) && grep -qiE "snapshot .* (is|INVALID)" <<<"$out"'
$SO storage lvm snapshot remove "vgt/$SNAP" --apply >/dev/null 2>&1
assert "invalid snapshot can be removed"              '! lvs vgt/$SNAP >/dev/null 2>&1'
rm -f "$T/mnt/churn.bin"; echo "restored content" > "$T/mnt/file1.bin"; head -c 1M /dev/urandom > "$T/mnt/file1.bin"; (cd "$T/mnt" && sha256sum file*.bin > "$T/sums.orig")
out=$($SO storage lvm snapshot remove vgt/data --apply 2>&1); rc=$?
assert "refuses to remove a non-sysops LV"            '(( rc != 0 ))'
for i in 1 2 3 4; do $SO storage lvm snapshot create vgt/data --size 8M --apply >/dev/null 2>&1; sleep 1.1; done
$SO storage lvm snapshot prune vgt/data --keep 2 --apply >/dev/null 2>&1
assert "prune keeps the newest 2"                     '[[ $(lvs --noheadings -o lv_name vgt | grep -c _sysops_snap_) == 2 ]]'
for s in $(lvs --noheadings -o lv_name vgt | tr -d ' ' | grep _sysops_snap_); do lvremove -f vgt/$s >/dev/null 2>&1; done

echo "== LVM backup + restore after data loss"
bkout=$($SO storage lvm backup vgt/data --dest "$T/bk" --full --size 32M 2>&1); rc=$?; (( rc == 0 )) || echo "    backup said: $bkout"
assert "snapshot backup succeeds"                     '(( rc == 0 )) && ls "$T/bk"/lv-vgt-data-*-full.tar.gz >/dev/null && ls "$T/bk"/*.vg >/dev/null'
assert "no snapshot or mount left behind"             '[[ $(lvs --noheadings -o lv_name vgt | grep -c _sysops_snap_) == 0 ]] && ! mount | grep -q "_sysops_snap_"'
rm -rf "$T/mnt"/*; assert "data really gone"           '[[ -z $(ls "$T/mnt") ]]'
mkdir -p "$T/restored"; $SO backup restore --dest "$T/bk" --name lv-vgt-data --to "$T/restored" >/dev/null 2>&1
rdir=$(find "$T/restored" -name file1.bin -printf '%h\n' | head -1)
assert "restore brings every file back, checksums match" '[[ -n $rdir ]] && (cd "$rdir" && sha256sum -c "$T/sums.orig" >/dev/null 2>&1)'
out=$($SO storage lvm backup vgt/data --dest "$T/bk2" --size 900G 2>&1); rc=$?
assert "backup refuses when VG cannot hold the snapshot" '(( rc != 0 )) && grep -q "not enough free space" <<<"$out"'

else echo "  SKIP snapshot + snapshot-backup drills (no dm-snapshot)"; fi
echo "== LVM volume group nearly full"
lvcreate -y -n filler -l 98%FREE vgt >/dev/null 2>&1
out=$($SO storage lvm status); rc=$?
assert "VG with <5%% free raises CRIT"                 '(( rc == 2 )) && grep -q "unallocated" <<<"$out"'
lvremove -f vgt/filler >/dev/null 2>&1
out=$($SO storage lvm status); rc=$?
assert "back to OK after freeing space"               '(( rc == 0 ))'
umount "$T/mnt"; vgchange -an vgt >/dev/null 2>&1; vgremove -ff vgt >/dev/null 2>&1

echo "== software RAID1: fail, degrade, rebuild"
if ! command -v mdadm >/dev/null; then echo "  mdadm missing: RAID drills not run"; bad "mdadm is installed"; else
R1=$(mkloop r1 120M); R2=$(mkloop r2 120M); R3=$(mkloop r3 120M)
if mdadm --create /dev/md/sysops0 --level=1 --raid-devices=2 --metadata=1.2 --run --force "$R1" "$R2" >/dev/null 2>&1; then
  MD=$(readlink -f /dev/md/sysops0); MDN=$(basename "$MD")
  mdadm --wait "$MD" >/dev/null 2>&1; sleep 1
  mkfs.ext4 -q "$MD"; mkdir -p "$T/rmnt"; mount "$MD" "$T/rmnt"; MNTS+=("$T/rmnt")
  head -c 4M /dev/urandom > "$T/rmnt/precious.bin"; sum=$(sha256sum "$T/rmnt/precious.bin" | cut -d' ' -f1); sync
  out=$($SO storage raid status); rc=$?
  assert "healthy RAID1: exit 0, $MDN listed"          '(( rc == 0 )) && grep -q "$MDN" <<<"$out" && grep -q "all 2 devices active" <<<"$out"'
  mdadm "$MD" --fail "$R2" >/dev/null 2>&1; sleep 1
  out=$($SO storage raid status); rc=$?
  assert "member failed: CRIT exit 2, degraded + failed named" '(( rc == 2 )) && grep -q "DEGRADED 1/2" <<<"$out" && grep -q "FAILED" <<<"$out"'
  assert "webhook payload path does not crash"         'SYSOPS_WEBHOOK_URL=http://127.0.0.1:9/x $SO storage raid status --alert >/dev/null 2>&1; (( $? == 2 ))'
  assert "data still readable while degraded"          '[[ $(sha256sum "$T/rmnt/precious.bin" | cut -d" " -f1) == "$sum" ]]'
  mdadm "$MD" --remove "$R2" >/dev/null 2>&1
  out=$($SO storage raid status); rc=$?
  assert "after removal still degraded (exit 2)"       '(( rc == 2 ))'
  echo 15000 > /proc/sys/dev/raid/speed_limit_max 2>/dev/null || true   # slow the rebuild so we can observe it
  mdadm "$MD" --add "$R3" >/dev/null 2>&1; sleep 0.5
  out=$($SO storage raid status); rc=$?
  assert "rebuild running is reported as at least WARN/CRIT" '(( rc >= 1 ))'
  echo 200000 > /proc/sys/dev/raid/speed_limit_max 2>/dev/null || true
  mdadm --wait "$MD" >/dev/null 2>&1; sleep 1
  out=$($SO storage raid status); rc=$?
  assert "after rebuild: healthy again, exit 0"        '(( rc == 0 )) && grep -q "all 2 devices active" <<<"$out"'
  assert "data intact after the whole drill"           '[[ $(sha256sum "$T/rmnt/precious.bin" | cut -d" " -f1) == "$sum" ]]'
  out=$($SO storage health 2>&1); rc=$?
  assert "storage health combines raid+lvm+fstab"      'grep -q "RAID (md)" <<<"$out" && grep -q "LVM" <<<"$out" && grep -q fstab <<<"$out"'
  umount "$T/rmnt"; mdadm --stop "$MD" >/dev/null 2>&1
else
  echo "  could not create an md array in this environment"; bad "mdadm --create works"
fi; fi

echo; echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
