# Native packages

A .deb is installed by apt/dpkg; a .rpm by dnf/rpm. The package puts sysops and its private files under /usr/lib/sysadmin-automation-toolkit and a command symlink in /usr/bin. It does not run hardening, start services or install a database at package installation.

Build: `packaging/build.sh deb` on Debian/Ubuntu or `packaging/build.sh rpm` where rpm-build is installed. Install with `sudo apt install ./dist/*.deb` or `sudo dnf install ./dist/*.rpm`. Remove with `sudo apt remove sysadmin-automation-toolkit` or `sudo dnf remove sysadmin-automation-toolkit`. State and administrator configuration are deliberately preserved.

Optional workload dependencies (nginx, MariaDB, LVM, mdadm, cron) still need explicit installation. Packages are architecture-independent Bash/Python. Package CI tests actual install, version and removal, not only archive creation.

A package repository is packages plus an index. APT InRelease and RPM repomd.xml signatures protect that index. The publication workflow builds, signs, tests APT and DNF installs, then deploys to GitHub Pages. It uses a new ephemeral signing key for each publication, expires it after 30 days, and discards the private key. This avoids a persistent secret but means keys rotate and users must re-bootstrap trust. It is a learning repository, not an unattended production update channel.

Download repository-key.asc and FINGERPRINT from the Pages root. Verify the fingerprint against an independently verified release, then dearmor the key into /usr/share/keyrings/portfolio.gpg. For APT add `deb [signed-by=/usr/share/keyrings/portfolio.gpg] BASE/apt ./` and run apt update/install. For DNF use BASE/rpm with repo_gpgcheck=1, gpgcheck=0 and gpgkey=BASE/repository-key.asc. RPM metadata is signed, but individual RPM headers are not signed; gpgcheck=0 is limited to this metadata-signed demo repo, never disable checks globally. Prefer release asset hashes/signatures for study. BASE is the verified Pages URL, not the GitHub code URL.

To verify detached release hashes: `gpg --import repository-key.asc`, compare the fingerprint, `gpg --verify SHA256SUMS.asc SHA256SUMS`, then `sha256sum -c SHA256SUMS` with the expected apt/ and rpm/ directory layout. A key downloaded from the same host is not independent proof of publisher identity. HTTPS and signatures do not make a package safe to run.
