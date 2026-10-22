#!/usr/bin/env bash
# Build a signed educational APT/RPM repository. Key is per-publication, short-lived.
set -euo pipefail
cd "$(dirname "$0")/.."
site=${1:-site}
mkdir -p "$site/apt" "$site/rpm"
cp dist/*.deb "$site/apt/"
cp dist/*.rpm "$site/rpm/"
g=$(mktemp -d); trap 'rm -rf "$g"' EXIT
export GNUPGHOME=$g
chmod 700 "$g"
gpg --batch --passphrase '' --quick-generate-key 'Linux Portfolio Packages (publication key)' rsa3072 sign 30d
key=$(gpg --batch --with-colons --list-keys | awk -F: '$1=="fpr"{print $10;exit}')
gpg --batch --armor --export "$key" > "$site/repository-key.asc"
printf '%s\n' "$key" > "$site/FINGERPRINT"
(cd "$site/apt"; dpkg-scanpackages . /dev/null > Packages; gzip -k -f Packages; apt-ftparchive release . > Release; gpg --batch --yes --local-user "$key" --clearsign -o InRelease Release; gpg --batch --yes --local-user "$key" --detach-sign -o Release.gpg Release)
createrepo_c "$site/rpm"
gpg --batch --yes --local-user "$key" --armor --detach-sign "$site/rpm/repodata/repomd.xml"
(cd "$site"; sha256sum apt/*.deb rpm/*.rpm > SHA256SUMS; gpg --batch --yes --local-user "$key" --armor --detach-sign SHA256SUMS)
cat > "$site/index.html" <<EOF
<!doctype html><html lang="en"><meta charset="utf-8"><title>Linux portfolio packages</title><h1>Linux portfolio packages</h1><p>Educational repository. Installation never runs hardening automatically.</p><ul><li><a href="apt/">APT packages</a></li><li><a href="rpm/repodata/repomd.xml">RPM metadata</a></li><li><a href="repository-key.asc">Publication public key</a></li><li><a href="FINGERPRINT">Key fingerprint</a></li><li><a href="SHA256SUMS">Package SHA256 hashes</a></li></ul><p>The signing key rotates each publication and expires in 30 days. Verify its fingerprint out-of-band before trusting a new key. This is not a stable production update channel.</p></html>
EOF
