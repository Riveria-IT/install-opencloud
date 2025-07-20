#!/bin/bash
set -e

echo "✅ OpenCloud Installer"

# Alte Installation prüfen
echo "🔎 Überprüfe bestehende OpenCloud-Installation..."
if docker ps -a --format '{{.Names}}' | grep -q opencloud; then
  echo "⚠️  Es sieht so aus, als wäre OpenCloud bereits installiert!"
  read -rp "❓ Alte Installation jetzt vollständig entfernen? (j/n): " CONFIRM
  if [[ "$CONFIRM" =~ ^[Jj]$ ]]; then
    echo "🧹 Entferne alte Container, Volumes & Konfiguration..."

    docker compose -f /opt/opencloud/docker-compose.yml down --volumes || true
    sudo rm -rf /opt/opencloud || true

    docker compose -f ~/opencloud/deployments/examples/opencloud_full/docker-compose.yml down --volumes || true
    sudo rm -rf ~/opencloud || true

    sudo rm -f /etc/caddy/Caddyfile
    sudo systemctl restart caddy || true

    echo "✅ Alte Installation wurde entfernt."
  else
    echo "❌ Abgebrochen. Bitte Script beenden oder manuell bereinigen."
    exit 1
  fi
fi

# Auswahl
echo
echo "1) Minimal (Rolling, lokal über Caddy)"
echo "2) Voll (opencloud_full mit Domains und Traefik)"
read -rp "Wähle Version (1/2): " MODE

read -rp "📍 Server-IP oder Hostname (für Zertifikate/Domains): " HOST

# Pakete + Caddy-Repo
echo "📦 Installiere Abhängigkeiten..."

sudo apt update
sudo apt install -y curl git gnupg2 docker.io docker-compose debian-keyring debian-archive-keyring

if ! command -v caddy >/dev/null 2>&1; then
  echo "➕ Füge offizielles Caddy-Repository hinzu..."
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
    sed 's#^deb #deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] #' | \
    sudo tee /etc/apt/sources.list.d/caddy-stable.list > /dev/null
  sudo apt update
  sudo apt install -y caddy
fi

# MINIMAL
if [[ "$MODE" == "1" ]]; then
  echo "🎯 Starte Minimal-Setup..."

  sudo mkdir -p /opt/opencloud && cd /opt/opencloud

  cat <<EOF | sudo tee docker-compose.yml
version: '3.3'
services:
  opencloud-rolling:
    container_name: opencloud
    image: opencloudeu/opencloud-rolling
    volumes:
      - opencloud-data:/var/lib/opencloud
      - opencloud-config:/etc/opencloud
    ports:
      - 127.0.0.1:9200:9200
    entrypoint: [ "/bin/sh" ]
    command: ["-c", "opencloud init --insecure true || true; opencloud server"]
    environment:
      - IDM_CREATE_DEMO_USERS=false
      - OC_URL=https://$HOST
volumes:
  opencloud-data:
  opencloud-config:
EOF

  sudo docker compose up -d

  cat <<EOF | sudo tee /etc/caddy/Caddyfile
$HOST {
  tls internal
  encode gzip
  reverse_proxy https://127.0.0.1:9200 {
    transport http {
      tls_insecure_skip_verify
    }
  }
}
EOF

  sudo systemctl enable --now caddy
  sudo systemctl restart caddy
  echo "✅ Minimal-Setup abgeschlossen: https://$HOST"

# FULL
else
  echo "🎯 Starte Voll-Setup..."

  cd ~
  git clone https://github.com/opencloud-eu/opencloud.git || {
    echo "❌ Fehler beim Klonen des Repos"
    exit 1
  }

  cd opencloud/deployments/examples/opencloud_full
  cp .env.example .env

  sed -i "s/cloud.YOUR.DOMAIN/cloud.$HOST/g" .env
  sed -i "s/TRAEFIK_ACME_MAIL=.*/TRAEFIK_ACME_MAIL=admin@$HOST/" .env
  read -rp "🔐 Admin Passwort setzen (in .env): " ADM_PW
  sed -i "s/ADMIN_PASSWORD=.*/ADMIN_PASSWORD=$ADM_PW/" .env

  sed -i "s/COLLABORA_DOMAIN=.*/COLLABORA_DOMAIN=collabora.$HOST/" .env
  sed -i "s/WOPISERVER_DOMAIN=.*/WOPISERVER_DOMAIN=wopiserver.$HOST/" .env
  sed -i "s/TRAEFIK_DOMAIN=.*/TRAEFIK_DOMAIN=traefik.$HOST/" .env

  # Optionale Hosts-Datei
  sudo tee -a /etc/hosts <<EOF
127.0.0.1 cloud.$HOST
127.0.0.1 traefik.$HOST
127.0.0.1 collabora.$HOST
127.0.0.1 wopiserver.$HOST
EOF

  echo "🔍 .env ist konfiguriert – starte Deployment"
  sudo docker compose up -d
  echo "✅ Voll-Setup läuft unter: https://cloud.$HOST"
fi

echo
echo "ℹ️ Logs anzeigen: sudo docker logs -f opencloud"
