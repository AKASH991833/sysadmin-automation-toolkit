# INTERVIEW.md - how to explain this project (sysops)

The 60-second pitch, the architecture, the design choices a hiring manager will ask about,
and 10 questions with strong answers. Everything here matches the code and the test suite.

## The 60-second pitch

"sysops turns the daily jobs of a Linux admin into one safe tool: users are managed
*declaratively* from a CSV - it diffs desired vs actual and shows a plan first, exactly like
Ansible's user module, in pure Bash - with idempotent apply, ownership tags so it never touches
accounts it didn't create, and one-command offboarding. Backups are GNU-tar incremental chains
that replay deletions correctly, with optional AES-256 encryption. Log cleanup skips files that
are still being written. A maintenance runner enforces per-task timeouts and an overlap lock.
Everything writes to an audit journal. The tests run real useradd on a fake root filesystem, and
CI runs real user management on both Ubuntu and Rocky Linux 9."

## Architecture

```
sysops (dispatch, usage, env: SYSOPS_ROOT / SYSOPS_STATE)
 |- lib/core.sh    colors, die/warn, JSON escaping, append-only audit journal (journal.jsonl)
 |- lib/users.sh   CSV -> plan (+ create / ~ modify / - lock / = ok) -> apply
 |                  ownership tag "[sysops]", prune, audit, offboard, delete
 |- lib/backup.sh  tar --listed-incremental chains, restore in order, AES-256, retention
 |- lib/logs.sh    age-based compress/delete, skips recent/open files, refuses system dirs
 |- lib/health.sh  text / md / html / json health, exit 0/1/2
 |- lib/runner.sh  tasks.conf runner: timeout per task, flock overlap guard, per-task logs
tests/             user namespaces + fake root: real useradd -R, no real root needed
examples/          users.csv and tasks.conf to copy
```

The one idea everything hangs on: **plan first, apply second.** Every mutating command defaults
to a dry-run that shows exactly the `useradd`/`usermod`/deletions it would do; `--apply` executes
and journals. You can review before anything changes.

## Design choices (and why)

1. **Declarative users from a CSV.** The CSV is the single source of truth. sync computes the
   diff (create/modify/lock/unchanged) and a second apply is a no-op - idempotent, reviewable in
   git, and the same file works on 1 server or 50.
2. **Ownership tags.** Managed accounts carry `[sysops]` in their GECOS. `--prune` locks only
   tagged accounts missing from the CSV; pre-existing accounts are never modified and `delete`
   refuses untagged users. The tool can never eat a legacy admin account.
3. **Offboard is not delete.** Offboard = lock + expire + kill sessions + remove SSH keys and
   sudo + archive the home with a SHA-256, keeping the account record for audit. Deleting is a
   separate, guarded step.
4. **Key-only accounts.** No passwords are ever set: accounts get `authorized_keys` with correct
   700/600 permissions. Password login is a hole you don't open in the first place.
5. **sudo vs wheel auto-detection.** `sudo: yes` maps to the `sudo` group on Debian/Ubuntu and
   `wheel` on RHEL-family; the Rocky CI job asserts a synced user actually lands in `wheel`.
6. **tar snapshot chains for incrementals.** `--listed-incremental` records what changed
   *including deletions*, so restore replays history: a file deleted on Tuesday stays deleted
   after restoring Wednesday's chain. The snapshot updates only after tar succeeds, so a failed
   run never corrupts the chain; retention removes whole chains, never half of one.
7. **Safe log cleanup.** Compress after N days, delete after M, but never a file modified in the
   last 10 minutes or held open by a process, and never inside system directories. Dry-run first.
8. **Runner with timeouts and a lock.** A hung backup must not stall the whole maintenance
   window (timeout per task), and a slow run must never overlap itself (`flock`, exit 3).

## 10 interview Q&A

**1. How is this different from just writing useradd in a loop?**
A loop is imperative and blind: run it twice and it fails or duplicates; remove a line and the
account stays forever. sync is declarative: it diffs desired (CSV) vs actual (/etc/passwd),
prints a plan, applies idempotently, and `--prune` locks accounts that left the CSV - but only
ones it created, thanks to the ownership tag.

**2. Prove the second run changes nothing.**
The test applies the same CSV twice and asserts the second plan reports
"0 create, 0 modify, 0 lock, 3 unchanged". Idempotency is a tested property, not a hope.

**3. How do you make sure the tool never touches accounts it didn't create?**
Every created account gets `[sysops]` in its GECOS. Prune and delete filter on that tag. The
fixture includes a `legacy` account and the tests assert it survives sync --prune and that
`user delete legacy` is refused.

**4. Walk me through offboarding a contractor.**
`sysops user offboard NAME` (plan) then `--apply`: the account is locked (`!` in shadow) and
expired, sessions killed, `~/.ssh/authorized_keys` removed, sudo/wheel membership stripped, the
home directory archived to `$STATE/archive/NAME-DATE.tar.gz` with a SHA-256 recorded, and the
journal gets an entry. The account record itself stays for audit; `user delete` is separate.

**5. How do your incremental backups handle deleted files?**
GNU tar's `--listed-incremental` snapshot remembers the tree. If a file disappears between runs,
the incremental records the deletion, and restoring the chain in order reproduces the latest
state - the deleted file does not come back. The test deletes a file mid-chain, restores, and
diffs the restored tree against the source.

**6. How is encryption handled?**
Each archive can be piped through AES-256-CBC (openssl, PBKDF2, salted) with a key file passed
via `--key`. The key never sits in the backup directory - the README tells you to keep it off
the backup disk. Restore decrypts in reverse chain order. Tampering is caught: the tests flip
bytes and expect failure.

**7. How do you test user management without root?**
Two ways. Normally: a user namespace (`unshare -Ur`) gives root powers *inside the namespace*,
and `useradd -R <fakeroot>` manages a fake `/etc/passwd` tree - real binaries, fake system.
In CI: the suite runs as real root, and separate live jobs run real useradd/offboard/delete on
Ubuntu and Rocky 9 VMs, asserting the wheel-group mapping on RHEL-family.

**8. What happens if a maintenance task hangs or a run overlaps?**
Each task in tasks.conf has a timeout - a hang is killed and reported as TIMEOUT while later
tasks continue. The runner holds an `flock`; a second invocation while one is active exits 3
immediately instead of doubling the load. The tests cover OK, FAIL, TIMEOUT and the lock.

**9. What are the honest limits?**
It's single-host (the CSV is the source of truth, not a directory service - that's what LDAP/
SSSD/FreeIPA solve). Password-based accounts are intentionally unsupported. Operations on the
real `/etc/passwd` are covered by CI VMs, not by the author's sandbox. No Windows, obviously.

**10. What would you build next?**
A `group sync` for declarative groups, SSH CA-signed certificates instead of per-user keys,
chrony/ntp and firewall task presets for the runner, a `--check` mode for Nagios-style drift
alarms on the CSV, and exporting journal.jsonl to syslog.

## Storage and cron (v1.3.0)
**Why a flock wrapper?** A cron job that takes longer than its interval starts twice and corrupts backups. `flock -n` skips the overlap and the kernel drops the lock if the process dies, so a crash never wedges the next run. A timeout stops a hung job from holding it forever.

**How do you extend an LV safely?** Plan first, refuse if the VG would drop below a reserve, then `lvextend` with filesystem resize so the mounted ext4/xfs grows online. Tested on a real loop-device VG with checksums before and after.

**Why do snapshot backups need care?** A snapshot has a fixed copy-on-write area. If writes exceed it, the snapshot is invalidated. The helper sizes it, mounts read-only, cleans up on every exit path (trap), and `lvm status` flags a snapshot nearing full. The drill really overflows one.

**How do you know a RAID is degraded?** `/proc/mdstat` shows `[2/1] [U_]`. The parser reads that, and the drill fails a real md RAID1 member, removes it, adds it back and watches the rebuild.

**What did you not test?** See the README table: the container distros share the runner kernel, so real LVM ran on Ubuntu and Debian 12 only; the other container distros skip LVM (device-mapper unusable there) and run RAID. UBI has no LVM/RAID tools.

## Honest test status
See the README "Honest test report" - it is kept in sync with CI and names exactly what ran where.


## Enterprise v2: questions you should be able to answer

- Why is a PASS not CIS certification? Mapping coverage is partial, and version, effective configuration, Match contexts and manual controls matter.
- What is idempotence? A second Ansible converge returns changed=0, verified by CI, not merely exit 0.
- Why sign package metadata? It protects the index and package hashes. Our learning key rotates, so trust must be re-bootstrapped; individual RPM headers remain unsigned.
- What does a Grafana panel prove? Only the samples from its data source. Missing host data and a container-visible filesystem are limits, not healthy verdicts.
- Is rollback the same as incident recovery? No. Our SUID demo proves rollback can restore the unsafe state. Eradication is a separate step.
- Did this run in a real company? No. Describe it honestly as a tested portfolio lab.
