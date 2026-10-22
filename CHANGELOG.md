# Changelog

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
