#!/usr/bin/env bash
# Development update PKI for RAUC bundle signing.
#   keys/ca.cert.pem       trust anchor baked into the image (/etc/rauc/ca.cert.pem)
#   keys/dev.{key,cert}.pem   signing key for official bundles (CA-issued, codeSigning EKU)
#   keys/attacker.{key,cert}.pem  self-signed key used by the "rogue update" test
# Private keys are git-ignored. A production fleet keeps the CA offline / in an HSM.
set -euo pipefail
K="$(cd "$(dirname "$0")/.." && pwd)/keys"
mkdir -p "$K"
cd "$K"
[ -f dev.key.pem ] && { echo "keys already exist in $K"; exit 0; }

EXT=$(mktemp)
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid\n' > "$EXT"

openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout ca.key.pem -out ca.cert.pem -days 3650 \
    -subj "/O=EdgeSight/OU=Release Engineering/CN=EdgeSight Development Update CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null

openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout dev.key.pem -out dev.csr.pem \
    -subj "/O=EdgeSight/OU=Release Engineering/CN=EdgeSight Bundle Signing 2026" 2>/dev/null
openssl x509 -req -in dev.csr.pem -CA ca.cert.pem -CAkey ca.key.pem -CAcreateserial \
    -out dev.cert.pem -days 1825 -extfile "$EXT" 2>/dev/null
rm -f dev.csr.pem

# A key that is NOT chained to the CA: bundles signed with it must be refused
openssl req -x509 -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
    -keyout attacker.key.pem -out attacker.cert.pem -days 365 \
    -subj "/O=Evil Corp/CN=Totally Legit Update" \
    -addext "extendedKeyUsage=codeSigning" 2>/dev/null
rm -f "$EXT"
chmod 0600 ./*.key.pem
echo "generated update PKI in $K"
openssl x509 -in dev.cert.pem -noout -subject -issuer
