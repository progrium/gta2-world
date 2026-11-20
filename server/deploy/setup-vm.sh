#!/bin/sh
# One-time setup of a fresh Ubuntu 24.04 (or Debian 12) VM as a game server.
#
#   sudo sh deploy/setup-vm.sh game.example.com you@example.com
#
# Before running: point the domain's A (and AAAA) record at this VM, and
# open TCP 80, TCP 443 and UDP 443 in the provider's firewall. After it
# finishes, copy your own GTA2 .gmp files into /var/lib/gta2/data (never
# commit or publish them) and run `systemctl restart gta2-server`.
#
# Re-running is safe: it rebuilds and reinstalls the binary from this
# checkout and leaves certificates and data alone.
set -eu
domain=${1:?usage: setup-vm.sh DOMAIN EMAIL}
email=${2:?usage: setup-vm.sh DOMAIN EMAIL}
here=$(cd "$(dirname "$0")/.." && pwd)
ZIG_VERSION=0.17.0

[ "$(id -u)" = 0 ] || { echo "run as root (sudo)"; exit 1; }

echo "== packages"
apt-get update -q
apt-get install -y -q git cmake build-essential pkg-config libgnutls28-dev certbot curl ufw

echo "== zig $ZIG_VERSION"
arch=$(uname -m)
case "$arch" in
  x86_64) zsha=1cbe9df9f27e6b78d14ccbca43b6703a404ef79ef1c463de901d7f088d4e2026 ;;
  aarch64) zsha=${ZIG_SHA256:?set ZIG_SHA256 to the published sha256 of zig-aarch64-linux-$ZIG_VERSION.tar.xz} ;;
  *) echo "unsupported arch $arch"; exit 1 ;;
esac
if ! zig version 2>/dev/null | grep -qx "$ZIG_VERSION"; then
  tmp=$(mktemp -d)
  curl -sSfL -o "$tmp/zig.tar.xz" "https://ziglang.org/download/$ZIG_VERSION/zig-$arch-linux-$ZIG_VERSION.tar.xz"
  echo "$zsha  $tmp/zig.tar.xz" | sha256sum -c -
  tar xf "$tmp/zig.tar.xz" -C /opt
  ln -sf "/opt/zig-$arch-linux-$ZIG_VERSION/zig" /usr/local/bin/zig
  rm -rf "$tmp"
fi

echo "== build"
cd "$here"
[ -f deps/out/lib/libngtcp2.a ] || sh scripts/build-deps.sh
zig build -Doptimize=ReleaseSafe
install -m 0755 zig-out/bin/gta2-server /usr/local/bin/gta2-server

echo "== user and directories"
id gta2 >/dev/null 2>&1 || useradd --system --home /var/lib/gta2 --shell /usr/sbin/nologin gta2
install -d -o gta2 -g gta2 -m 0750 /var/lib/gta2 /var/lib/gta2/data /var/lib/gta2/replays
install -d -o root -g gta2 -m 0750 /var/lib/gta2/certs
install -d -o root -g root -m 0755 /var/lib/gta2/acme
# Keep two weeks of replays.
echo "d /var/lib/gta2/replays 0750 gta2 gta2 14d" > /etc/tmpfiles.d/gta2-server.conf

echo "== kernel UDP buffers (the server asks for 4 MiB)"
cat > /etc/sysctl.d/60-gta2-server.conf <<SYSCTL
net.core.rmem_max = 4194304
net.core.wmem_max = 4194304
SYSCTL
sysctl -q --system

echo "== firewall"
ufw allow OpenSSH >/dev/null
ufw allow 80/tcp >/dev/null
ufw allow 443/tcp >/dev/null
ufw allow 443/udp >/dev/null
ufw --force enable >/dev/null

echo "== certificate"
install -m 0755 deploy/certbot-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/gta2-server.sh 2>/dev/null || {
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  install -m 0755 deploy/certbot-deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/gta2-server.sh
}
install -m 0644 deploy/gta2-server.service /etc/systemd/system/gta2-server.service
systemctl daemon-reload
if [ ! -d "/etc/letsencrypt/live/$domain" ]; then
  # First issue: nothing listens on :80 yet, so certbot can answer itself.
  systemctl stop gta2-server 2>/dev/null || true
  certbot certonly --standalone --non-interactive --agree-tos -m "$email" -d "$domain"
  RENEWED_LINEAGE="/etc/letsencrypt/live/$domain" sh deploy/certbot-deploy-hook.sh
  systemctl enable --now gta2-server
  # Renewals go through the running server's /.well-known/acme-challenge/
  # (served from /var/lib/gta2/acme), so games are never interrupted.
  certbot reconfigure --cert-name "$domain" --webroot -w /var/lib/gta2/acme --non-interactive || \
    echo "warning: switch renewals to --webroot -w /var/lib/gta2/acme by hand (certbot < 2.3)"
else
  RENEWED_LINEAGE="/etc/letsencrypt/live/$domain" sh deploy/certbot-deploy-hook.sh
  systemctl enable gta2-server
  systemctl restart gta2-server
fi

echo "== done"
ls /var/lib/gta2/data/*.gmp >/dev/null 2>&1 || echo "Now copy your own .gmp files into /var/lib/gta2/data and run: systemctl restart gta2-server"
echo "Health:  curl https://$domain/healthz"
echo "Metrics: curl https://$domain/metrics"
echo "Logs:    journalctl -u gta2-server -f"
