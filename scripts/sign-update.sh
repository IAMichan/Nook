#!/bin/bash
# Signs a Windows or Linux release file (Nook-<version>-Windows-setup.exe, Nook-<version>-Linux.AppImage) with the same
# Ed25519 key as the macOS .zip, so the Tauri app can check an update before it runs it (core/src/updates). The
# counterpart of scripts/sign-update.swift for the Linux runner that attaches the Windows and Linux files: OpenSSL 3
# instead of CryptoKit, the same formats (keys are base64 of their 32 raw bytes, the signature base64 of its 64 bytes).
#
#   NOOK_UPDATE_SIGNING_KEY=… NOOK_UPDATE_PUBLIC_KEY=… scripts/sign-update.sh <file>
#       writes <file>.sig. It refuses a private key that does not belong to NOOK_UPDATE_PUBLIC_KEY, and checks the
#       signature it made, so a release never carries a signature its own builds reject.
set -euo pipefail

[ $# -eq 1 ] || { echo "usage: $0 <file>" >&2; exit 2; }
FILE="$1"
[ -f "$FILE" ] || { echo "Cannot read $FILE." >&2; exit 1; }
: "${NOOK_UPDATE_SIGNING_KEY:?NOOK_UPDATE_SIGNING_KEY is not set}"
: "${NOOK_UPDATE_PUBLIC_KEY:?NOOK_UPDATE_PUBLIC_KEY is not set}"
OPENSSL="${OPENSSL:-openssl}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The raw 32-byte seed as PKCS#8 DER, and the raw public key as SubjectPublicKeyInfo DER (RFC 8410).
seed_hex="$(printf '%s' "$NOOK_UPDATE_SIGNING_KEY" | tr -d '[:space:]' | base64 -d | od -An -tx1 -v | tr -d ' \n')"
[ "${#seed_hex}" -eq 64 ] || { echo "NOOK_UPDATE_SIGNING_KEY is not a base64 Ed25519 private key (32 bytes)." >&2; exit 1; }
public_hex="$(printf '%s' "$NOOK_UPDATE_PUBLIC_KEY" | tr -d '[:space:]' | base64 -d | od -An -tx1 -v | tr -d ' \n')"
[ "${#public_hex}" -eq 64 ] || { echo "NOOK_UPDATE_PUBLIC_KEY is not a base64 Ed25519 public key (32 bytes)." >&2; exit 1; }
printf '302e020100300506032b657004220420%s' "$seed_hex" | xxd -r -p > "$WORK/key.der"
printf '302a300506032b6570032100%s' "$public_hex" | xxd -r -p > "$WORK/public.der"

derived="$("$OPENSSL" pkey -inform DER -in "$WORK/key.der" -pubout -outform DER | od -An -tx1 -v | tr -d ' \n')"
[ "$derived" = "302a300506032b6570032100$public_hex" ] || {
    echo "NOOK_UPDATE_SIGNING_KEY does not belong to NOOK_UPDATE_PUBLIC_KEY." >&2
    exit 1
}

"$OPENSSL" pkeyutl -sign -rawin -inkey "$WORK/key.der" -keyform DER -in "$FILE" -out "$WORK/signature"
"$OPENSSL" pkeyutl -verify -rawin -pubin -inkey "$WORK/public.der" -keyform DER -in "$FILE" -sigfile "$WORK/signature" >/dev/null || {
    echo "Signing failed." >&2
    exit 1
}
base64 < "$WORK/signature" | tr -d '\n' > "$FILE.sig"
echo >> "$FILE.sig"
echo "Signed $(basename "$FILE") → $(basename "$FILE").sig"
