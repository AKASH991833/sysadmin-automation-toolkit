# Enterprise learning path

This repository is one tool in the Linux operations portfolio. Native packages live in packaging/. The security crosswalk, fleet hardening role, read-only Prometheus/Grafana stack and incident reconstruction live in the companion [hardening repository](https://github.com/AKASH991833/linux-server-hardening-monitoring).

Study order: packaging/LEARN.md here, then compliance/LEARN.md, ansible/LEARN.md, monitoring/LEARN.md and incidents/LEARN.md there. Run all labs on disposable hosts first. User management, backups and web-stack deployment are operations, not automatically CIS controls. We do not invent CIS IDs for these commands.

Use the hardening exporter alongside this tool on the same lab host to monitor memory, filesystem and RAID health. The Grafana container demo itself only sees container state. A portfolio incident report is simulated evidence, not a claim that a production attack happened. The Ansible role applies selected hk hardening checks, not web-stack deployment or arbitrary user deletion.
