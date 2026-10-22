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

echo; echo "passed: $PASS   failed: $FAIL"
(( FAIL == 0 ))
