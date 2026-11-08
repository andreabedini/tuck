#!/usr/bin/env bash
# Build and install Tcl 9 from source into /usr/local (Ubuntu 24.04 ships only 8.6).
# Idempotent: does nothing if `tclsh` already reports the wanted version.
# Needs gcc and make; run as root (or with write access to /usr/local).
set -euo pipefail

VERSION=9.0.3
SHA256=2537ba0c86112c8c953f7c09d33f134dd45c0fb3a71f2d7f7691fd301d2c33a6
URL="https://prdownloads.sourceforge.net/tcl/tcl${VERSION}-src.tar.gz"
PREFIX=${PREFIX:-/usr/local}

if [ -x "$PREFIX/bin/tclsh" ] &&
   [ "$(echo 'puts [info patchlevel]' | "$PREFIX/bin/tclsh")" = "$VERSION" ]; then
    echo "Tcl $VERSION already installed"
    exit 0
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"

curl -fsSL -o tcl.tar.gz "$URL"
echo "$SHA256  tcl.tar.gz" | sha256sum -c -
tar xzf tcl.tar.gz
cd "tcl${VERSION}/unix"
./configure --prefix="$PREFIX" >/dev/null
# Only the interpreter and its script library (which includes tcltest); skip the
# bundled extensions (sqlite, tdbc, itcl, thread), which Tuck does not use.
make -j"$(nproc)" binaries libraries >/dev/null
make install-binaries install-libraries install-tzdata install-msgs >/dev/null

# Tcl installs the shell as tclsh9.0; the repo's docs and tests call `tclsh`.
ln -sf "$PREFIX/bin/tclsh${VERSION%.*}" "$PREFIX/bin/tclsh"
echo "Installed Tcl $(echo 'puts [info patchlevel]' | "$PREFIX/bin/tclsh")"
