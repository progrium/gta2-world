#!/bin/sh
# certbot deploy hook: copy the renewed certificate where the server (user
# gta2) can read it, then tell the server to reload it. Live games keep
# running; new connections get the new certificate.
# Installed to /etc/letsencrypt/renewal-hooks/deploy/ by setup-vm.sh.
set -eu
dst=/var/lib/gta2/certs
install -d -o root -g gta2 -m 0750 "$dst"
for f in fullchain.pem privkey.pem; do
  install -o root -g gta2 -m 0640 "$RENEWED_LINEAGE/$f" "$dst/$f"
done
systemctl reload gta2-server 2>/dev/null || true
