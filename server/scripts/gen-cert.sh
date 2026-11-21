#!/bin/sh
# Self-signed ECDSA P-256 cert valid for 13 days: the shape Chrome accepts
# for WebTransport serverCertificateHashes (ECDSA, validity <= 14 days).
# usage: scripts/gen-cert.sh [outdir] [extra DNS name or IP ...]
set -eu
out=${1:-certs}; [ $# -gt 0 ] && shift
mkdir -p "$out"
san="DNS:localhost,IP:127.0.0.1,IP:::1"
for n in "$@"; do
  case "$n" in *[!0-9.:]*) san="$san,DNS:$n" ;; *) san="$san,IP:$n" ;; esac
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$out/key.pem" -out "$out/cert.pem" -days 13 -subj "/CN=s4-spike" \
  -addext "subjectAltName=$san" 2>/dev/null
printf 'cert: %s/cert.pem\nsha256 (base64): ' "$out"
openssl x509 -in "$out/cert.pem" -outform der | openssl dgst -sha256 -binary | base64
