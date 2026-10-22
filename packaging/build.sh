#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
format=${1:?usage: packaging/build.sh deb|rpm}
name=sysadmin-automation-toolkit
cmd=sysops
version=2.0.0
out=$PWD/dist
mkdir -p "$out"
t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
stage=$t/stage
mkdir -p "$stage/usr/lib/$name" "$stage/usr/bin"
cp "$cmd" LICENSE "$stage/usr/lib/$name/"
for d in lib checks config compliance; do [[ ! -d $d ]] || cp -r "$d" "$stage/usr/lib/$name/"; done
ln -s "../lib/$name/$cmd" "$stage/usr/bin/$cmd"
if [[ $format == deb ]]; then
 mkdir -p "$stage/DEBIAN"
 cat > "$stage/DEBIAN/control" <<EOF
Package: $name
Version: $version
Architecture: all
Maintainer: Akash Vishwakarma
Depends: bash, coreutils, findutils, grep, sed, gawk, util-linux, python3
Description: Linux administration toolkit, plan first and apply explicitly
EOF
 dpkg-deb --root-owner-group --build "$stage" "$out/${name}_${version}_all.deb"
elif [[ $format == rpm ]]; then
 mkdir -p "$t/rpm"/{BUILD,RPMS,SOURCES,SPECS,SRPMS,BUILDROOT}
 tar -C "$stage" -czf "$t/rpm/SOURCES/payload.tar.gz" .
 cat > "$t/rpm/SPECS/tool.spec" <<EOF
Name: $name
Version: $version
Release: 1
Summary: Linux administration toolkit
License: MIT
BuildArch: noarch
Source0: payload.tar.gz
Requires: bash, coreutils, findutils, grep, sed, gawk, util-linux, python3
%description
Plan-first Linux administration toolkit. No services or fixes are enabled at install.
%prep
%build
%install
mkdir -p %{buildroot}
tar -xzf %{SOURCE0} -C %{buildroot}
%files
/usr/lib/$name
/usr/bin/$cmd
EOF
 rpmbuild --define "_topdir $t/rpm" -bb "$t/rpm/SPECS/tool.spec"
 cp "$t/rpm/RPMS/noarch/"*.rpm "$out/"
else echo 'expected deb or rpm' >&2; exit 2; fi
