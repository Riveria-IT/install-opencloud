#!/usr/bin/env bash
set -euo pipefail

echo "✅ OpenCloud Installer (Minimal via Caddy ODER Full via Traefik/Compose)"
echo "   Getestet auf Debian/Ubuntu (root/sudo benötigt)"

# ---------- helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1 || return 1; }
confirm() { read -rp "$1 (j/N): " _a; [[ "${_a:-N}" =~ ^[JjYy]$ ]]; }

# ---------- preflight ----------
if ! need_cmd sudo; then
  echo "❌ sudo fehlt. Bitte sudo installieren/konfigurieren."
  exit 1
fi

echo "🔎 Prüfe bestehende OpenCloud-Container/Stacks ..."
if docker ps -a --format '{{.Names}}' | grep -Eq '^opencloud$'; then
  echo "⚠️  Es existiert ein Container namens 'opencloud'."
  if confirm "❓ Alte Minimal-Installation jetzt entfernen?"; then
    sudo docker rm -f opencloud || true
    sudo rm -rf /opt/opencloud || true
  fi
fi
if [ -d /opt/opencloud-compose ]; then
  echo "⚠️  Es gibt ein Verzeichnis /opt/opencloud-compose (Full-Setup)."
  if confirm "❓ Full-Setup stoppen & entfernen (docker compose down)?"; then
    (cd /opt/opencloud-compose && sudo docker compose down --remove-orphans || true)
    sudo rm -rf /opt/opencloud-compose || true
  fi
fi

# ---------- packages ----------
echo "📦 Installiere Abhängigkeiten (Docker, Compose v2, Caddy, Git, curl, gpg, ca-certificates) ..."
sudo apt-get update -y
sudo apt-get install -y curl git gnupg2 ca-certificates docker.io docker-compose-plugin

# Docker-Dienst sicher starten
sudo systemctl enable --now docker

# Compose v2 Check (wichtig!)
if ! docker compose version >/dev/null 2>&1; then
  echo "❌ 'docker compose' (v2) nicht gefunden. Bitte Docker laut offizieller Anleitung installieren."
  exit 1
fi

echo
echo "🔧 Modus wählen:"
echo "  1) Minimal (ein Host/FQDN, Caddy als Reverse-Proxy, interner 9200)"
echo "  2) Full (Traefik + Collabora via opencloud-compose, produktionsfähig)"
read -rp "Auswahl (1/2): " MODE

if [[ "${MODE:-}" != "1" && "${MODE:-}" != "2" ]]; then
  echo "❌ Ungültige Auswahl."
  exit 1
fi

if [[ "$MODE" == "1" ]]; then
  # ---------- Minimal mit Caddy ----------
  read -rp "🌐 FQDN (z. B. cloud.example.com): " FQDN
  read -rsp "🔐 Admin-Passwort (für OpenCloud 'admin'): " ADM_PW; echo
  echo
  echo "🛡️  TLS-Variante wählen:"
  echo "  - Öffentlich (Let's Encrypt automatisch, empfohlen)"
  echo "  - Intern (Caddys 'tls internal' – nur Lab/ohne echte Domain)"
  confirm "👉 Internes TLS verwenden?" && TLS_INTERNAL=true || TLS_INTERNAL=false

  # Caddy installieren (falls fehlt)
  if ! need_cmd caddy; then
    echo "➕ Installiere Caddy Repo & Paket ..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | \
      sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | \
      sed 's#^deb #deb [signed-by=/usr/share/keyrings/caddy-stable-archive-keyring.gpg] #' | \
      sudo tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
    sudo apt-get update -y
    sudo apt-get install -y caddy
  fi

  echo "📁 Erzeuge Compose-Stack unter /opt/opencloud ..."
  sudo mkdir -p /opt/opencloud
  cd /opt/opencloud

  cat <<EOF | sudo tee docker-compose.yml >/dev/null
version: "3.9"
services:
  opencloud:
    image: opencloudeu/opencloud-rolling:latest
    container_name: opencloud
    restart: unless-stopped
    ports:
      - "127.0.0.1:9200:9200"
    volumes:
      - opencloud-config:/etc/opencloud
      - opencloud-data:/var/lib/opencloud
    environment:
      - OC_INSECURE=true
      - PROXY_HTTP_ADDR=0.0.0.0:9200
      - OC_URL=https://${FQDN}
    entrypoint: ["/bin/sh","-c"]
    command:
      - |
        opencloud init --insecure true --admin-password '${ADM_PW}' || true
        exec opencloud server
volumes:
  opencloud-config:
  opencloud-data:
EOF

  echo "🚀 Starte OpenCloud (Minimal) ..."
  sudo docker compose up -d

  echo "📝 Schreibe Caddyfile ..."
  if $TLS_INTERNAL; then
    cat <<EOF | sudo tee /etc/caddy/Caddyfile >/dev/null
${FQDN} {
  tls internal
  encode gzip
  reverse_proxy https://127.0.0.1:9200 {
    transport http {
      tls_insecure_skip_verify
    }
  }
}
EOF
  else
    # Öffentliches TLS: Caddy holt automatisch Let's Encrypt
    cat <<EOF | sudo tee /etc/caddy/Caddyfile >/dev/null
${FQDN} {
  encode gzip
  reverse_proxy https://127.0.0.1:9200 {
    transport http {
      tls_insecure_skip_verify
    }
  }
}
EOF
  fi

  sudo systemctl enable --now caddy
  sudo systemctl reload caddy || sudo systemctl restart caddy

  echo
  echo "✅ Fertig! Öffne: https://${FQDN}"
  echo "   Login: admin / (dein Passwort)"
  echo "   Logs:  sudo docker logs -f opencloud"

else
  # ---------- Full mit Traefik & Collabora ----------
  read -rp "🌐 Basis-Domain (z. B. example.com): " BASE_DOMAIN
  read -rsp "🔐 INITIAL_ADMIN_PASSWORD (OpenCloud 'admin'): " INITIAL_ADMIN_PASSWORD; echo
  read -rp "📧 E-Mail für Let's Encrypt (Traefik): " LE_MAIL

  export OC_DOMAIN="cloud.${BASE_DOMAIN}"
  export COLLABORA_DOMAIN="collabora.${BASE_DOMAIN}"
  export WOPISERVER_DOMAIN="wopiserver.${BASE_DOMAIN}"
  export KEYCLOAK_DOMAIN="keycloak.${BASE_DOMAIN}"

  echo "📁 Klone opencloud-compose nach /opt/opencloud-compose ..."
  sudo rm -rf /opt/opencloud-compose || true
  sudo git clone https://github.com/opencloud-eu/opencloud-compose.git /opt/opencloud-compose
  cd /opt/opencloud-compose
  sudo cp .env.example .env

  echo "✍️  Setze .env Variablen ..."
  sudo sed -i -E "s|^OC_DOMAIN=.*|OC_DOMAIN=${OC_DOMAIN}|g" .env
  sudo sed -i -E "s|^COLLABORA_DOMAIN=.*|COLLABORA_DOMAIN=${COLLABORA_DOMAIN}|g" .env
  sudo sed -i -E "s|^WOPISERVER_DOMAIN=.*|WOPISERVER_DOMAIN=${WOPISERVER_DOMAIN}|g" .env
  sudo sed -i -E "s|^KEYCLOAK_DOMAIN=.*|KEYCLOAK_DOMAIN=${KEYCLOAK_DOMAIN}|g" .env
  sudo sed -i -E "s|^INITIAL_ADMIN_PASSWORD=.*|INITIAL_ADMIN_PASSWORD=${INITIAL_ADMIN_PASSWORD}|g" .env
  sudo sed -i -E "s|^TRAEFIK_LETSENCRYPT_EMAIL=.*|TRAEFIK_LETSENCRYPT_EMAIL=${LE_MAIL}|g" .env

  # Volle Auswahl: Core + Collabora + Traefik (OpenCloud & Collabora)
  if grep -q '^#\?COMPOSE_FILE=' .env; then
    sudo sed -i -E \
      "s|^#?COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:weboffice/collabora.yml:traefik/opencloud.yml:traefik/collabora.yml|g" .env
  else
    echo "COMPOSE_FILE=docker-compose.yml:weboffice/collabora.yml:traefik/opencloud.yml:traefik/collabora.yml" | sudo tee -a .env >/dev/null
  fi

  echo "🚀 Starte OpenCloud (Full) ..."
  sudo docker compose up -d

  echo
  echo "✅ Fertig! Haupt-URL: https://${OC_DOMAIN}"
  echo "   Collabora:         https://${COLLABORA_DOMAIN}"
  echo "   WOPI Server:       https://${WOPISERVER_DOMAIN}"
  echo "   Keycloak:          https://${KEYCLOAK_DOMAIN}"
  echo "   Login: admin / (dein INITIAL_ADMIN_PASSWORD)"
  echo "   Logs:  sudo docker compose logs -f"
fi
