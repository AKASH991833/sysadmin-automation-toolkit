# Changelog

## [1.3.0] - 2026-10-22
### Added
- `sysops cron add|list|remove|status|validate|wrap|audit`: managed `# BEGIN/END sysops:NAME` blocks, plan first and `--apply` to write, a crontab backup before every change, `%` escaped for you, schedule validation, an overlap-safe wrapper (flock, timeout, status file, webhook on failure) and an audit (writable scripts, `curl|sh`, root jobs run from /tmp, unescaped `%`, relative commands, every-minute jobs, cron.allow).
- `sysops storage health`, `raid status [--alert]`, `lvm status [--alert]`, `lvm extend VG/LV --by` (keeps a reserve, grows the filesystem), `lvm snapshot create|list|remove|prune`, `lvm backup VG/LV --dest` (snapshot, read-only mount, archive, cleanup on any exit, `vgcfgbackup`) and `fstab check|add`. Exit codes 0 ok / 1 warn / 2 crit.
- Real drills (`tests/storage-live.sh`): LVM and md RAID1 on loop devices, run in CI.
### Honest limits
- Real LVM and snapshot drills run on the Ubuntu runner and in the Debian 12 container. In the Debian 13, Rocky, Alma, CentOS Stream and Fedora containers device-mapper is not usable, so only the real RAID drill runs there (plus fixtures and real crontab tests). Not verified: real LVM on those distros.
- Red Hat UBI 9 has no mdadm/lvm2, so it only runs the fixture and crontab tests.

## [1.2.0] - 2026-10-22
### Added
- Debian CI matrices: the full test-suite on Debian 12 (bookworm) and Debian 13 (trixie),
  plus a live job running real useradd/offboard/delete with the Debian `sudo` sudo-group
  mapping asserted (the counterpart of the RHEL `wheel` assertion).

## [1.1.0] - 2026-10-22
### Added
- Rocky Linux 9 CI jobs: full test-suite on Rocky, plus a live job running real
  useradd/offboard/delete with the RHEL `wheel` sudo-group mapping asserted.
- INTERVIEW.md: 60-second pitch, architecture, design choices, 10 interview Q&A.
- Demo GIF in the README (rendered from real command output).
- Release badges, quick-start polish in the README.

## [1.0.0] - 2026-10-22
- Initial public release: declarative user sync from CSV (plan-first, idempotent, ownership
  tags, prune, audit), one-command offboarding with archived homes, tar incremental backup
  chains that replay deletions (AES-256 optional), safe log cleanup, maintenance runner with
  timeouts and overlap lock, health reports, audit journal.
  CI: ShellCheck, namespace/fake-root suite, real-useradd Ubuntu job.
