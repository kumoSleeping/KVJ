#!/bin/bash
# Create the local code-signing identity used by trim-macos.sh: a self-signed
# certificate and key as plain files (no keychain, no prompts) plus the compiled
# designated requirement for com.kumo.kvj. Run once per build machine; keep the
# directory, because a new identity makes macOS ask for privacy grants again.
#   make-signing-identity.sh [dir]     (default ~/kvj-toolchain/signing)
set -euo pipefail
DIR="${1:-$HOME/kvj-toolchain/signing}"
mkdir -p "$DIR" && chmod 700 "$DIR"
cd "$DIR"
if [ ! -f key.pem ]; then
    /usr/bin/openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
        -subj "/CN=KVJ Local Signing" -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" > /dev/null 2>&1
    chmod 600 key.pem
fi
LEAF=$(/usr/bin/openssl x509 -in cert.pem -outform der | shasum -a 1 | cut -d' ' -f1)
csreq -r "=identifier \"com.kumo.kvj\" and certificate leaf = H\"$LEAF\"" -b requirement.bin
echo "identity in $DIR (leaf $LEAF); install rcodesign with: cargo install apple-codesign"
