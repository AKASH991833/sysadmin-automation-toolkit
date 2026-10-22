# Linux operations: study from zero

Start in a disposable VM, not a work server. A command can pass a test and still be inappropriate for your system.

## Before you begin
Learn paths (`pwd`, `ls`, `cd`), permissions (`ls -l`, `chmod`), users (`id`), processes (`ps`) and service logs (`journalctl`). Read `--help` before using --apply. Dry-run prints a plan; --apply changes files. Backup and console access matter more than a green badge.

## Five enterprise lessons
1. CIS: a benchmark defines expected configuration. The shared hardening repository's compliance/LEARN.md explains versioned control references, partial checks and unmapped checks. It is not a compliance certificate.
2. Ansible: ansible/LEARN.md in the shared repository explains inventories, selected hardening, serial batches, repeat runs and rollback. Install-only preview is the default.
3. Packages: packaging/LEARN.md here explains how a tool becomes a .deb/.rpm, how an index works, and how signing/trust bootstrap differs from HTTPS.
4. Metrics: monitoring/LEARN.md in the shared repository explains an exporter, Prometheus, Grafana, alert rules and missing data. A container demo is not full host monitoring.
5. Incidents: incidents/LEARN.md in the shared repository explains evidence, detection, containment, rollback and eradication. Rollback can reintroduce a security problem.

Shared repository: https://github.com/AKASH991833/linux-server-hardening-monitoring

## Practice, then explain
Run one lab, save its output, change one thing and rerun. Explain what changed, how it was detected, how to undo it and what the test did not prove. In an interview call this a hands-on lab, not employment or production incident experience.
