#!/bin/bash
set -e

echo "✅ OpenCloud Installer"

# Auswahlmenü
echo "1) Minimal (Rolling, lokal über Caddy)"
echo "2) Voll (opencloud_full mit Domains und Traefik)"
read -rp "Wähle Version (1/2): " MODE

read -rp "📍 Server-IP oder Hostname (für Zertifikate/Domains): " HOST

# Pakete installieren
sudo apt update
sudo apt install -y docker.io docker-compose caddy git curl

if [[ "$MODE" == "1" ]]; then
  echo "🎯 Minimal-Setup..."

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

  sudo systemctl restart caddy
  echo "✅ Minimal-Setup abgeschlossen: https://$HOST"

else
  echo "🎯 Voll-Setup (Full Beispiel von OpenCloud Compose)..."

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

  # Optional: lokale Namensauflösung
  sudo tee -a /etc/hosts <<EOF
127.0.0.1 cloud.$HOST
127.0.0.1 traefik.$HOST
127.0.0.1 collabora.$HOST
127.0.0.1 wopiserver.$HOST
EOF

  echo "🔍 .env ist konfiguriert, starte Deployment"
  sudo docker compose up -d
  echo "✅ Voll-Setup läuft unter: https://cloud.$HOST"
fi

echo "ℹ️ Logs anzeigen: sudo docker logs -f opencloud"
