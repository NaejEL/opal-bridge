#!/bin/sh
# Build opal-bridge_<version>_<arch>.ipk from files/ + ipk/.
# ipk format = tar.gz{debian-binary, control.tar.gz, data.tar.gz}.
# Output lands in build/ (gitignored). Run from the repo root (Git Bash ok).
set -e

VER=$(sed -n 's/^Version: //p' ipk/control)
ARCH=$(sed -n 's/^Architecture: //p' ipk/control)
OUT="build/opal-bridge_${VER}_${ARCH}.ipk"

rm -rf build/staging
mkdir -p build/staging/data build/staging/ctrl

cp -r files/. build/staging/data/
# every shipped file is a shell script; git-on-windows loses exec bits
find build/staging/data -type f -exec chmod 755 {} +

cp ipk/control ipk/postinst ipk/prerm ipk/postrm build/staging/ctrl/
chmod 755 build/staging/ctrl/postinst build/staging/ctrl/prerm build/staging/ctrl/postrm

echo 2.0 > build/staging/debian-binary
tar -C build/staging/data -czf build/staging/data.tar.gz --owner=0 --group=0 --numeric-owner .
tar -C build/staging/ctrl -czf build/staging/control.tar.gz --owner=0 --group=0 --numeric-owner .
tar -C build/staging -czf "$OUT" --owner=0 --group=0 --numeric-owner ./debian-binary ./control.tar.gz ./data.tar.gz

echo "built: $OUT"
tar -tzf "$OUT"
