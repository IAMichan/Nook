#!/bin/sh
# Makes the stable self-signed signing identity for release builds, once, and prints what goes into the repository
# secrets MACOS_SIGNING_P12 and MACOS_SIGNING_P12_PASSWORD (Settings › Secrets and variables › Actions).
#
# Release builds signed with the same identity keep one signature across updates, so macOS asks for Keychain access
# (your password) and privacy permissions once instead of after every update. It does not take away Gatekeeper's
# warning on the first launch; only a Developer ID with notarization does (see .github/workflows/release.yml).
#
# Keep the files it writes (in ./nook-release-identity) somewhere safe: a new identity means asking for everything again.
set -eu
NAME="Nook Release Signing"
OUT="${1:-nook-release-identity}"
if [ -e "$OUT" ]; then echo "$OUT already exists; remove it or pass another folder." >&2; exit 1; fi
mkdir -p "$OUT"
cat > "$OUT/req.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
LEGACY=""
openssl version 2>/dev/null | grep -q '^OpenSSL 3' && LEGACY="-legacy"
PASS="$(openssl rand -hex 16)"
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$OUT/req.cnf" -extensions ext \
  -keyout "$OUT/key.pem" -out "$OUT/cert.pem" >/dev/null 2>&1
# shellcheck disable=SC2086 # LEGACY is empty or one flag
openssl pkcs12 -export $LEGACY -inkey "$OUT/key.pem" -in "$OUT/cert.pem" -name "$NAME" -out "$OUT/identity.p12" \
  -passout "pass:$PASS"
printf '%s' "$PASS" > "$OUT/password.txt"
base64 < "$OUT/identity.p12" | tr -d '\n' > "$OUT/identity.p12.base64"
rm "$OUT/req.cnf"
echo "Made \"$NAME\" in $OUT."
echo "MACOS_SIGNING_P12          = the contents of $OUT/identity.p12.base64"
echo "MACOS_SIGNING_P12_PASSWORD = the contents of $OUT/password.txt"
