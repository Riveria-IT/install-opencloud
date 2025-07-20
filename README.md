# 🚀 OpenCloud Installer (Minimal & Full)

Dieses Bash-Script installiert **[OpenCloud](https://opencloud.eu)** auf einem Ubuntu- oder Debian-Server – interaktiv und vollständig automatisiert.

Du hast die Wahl zwischen zwei Varianten:

1. **Minimal-Installation** (Rolling-Version)  
   - Reverse-Proxy über **Caddy**
   - Kein Traefik, keine externen Domains nötig
   - Ideal für lokale/private Nutzung oder Tests

2. **Vollinstallation** (`opencloud_full`)  
   - Inklusive **Traefik**, **Collabora**, **WOPI** etc.  
   - Domains + Let's Encrypt werden automatisch eingerichtet  
   - Optimal für produktive Umgebungen

---

## ⚙️ Voraussetzungen

- Ubuntu 22.04+ oder Debian 12+
- Root-Zugang (sudo)
- Eine freie Domain oder interne IP für HTTPS-Zugriff

---

## 📥 Installation

```bash
wget https://raw.githubusercontent.com/Riveria-IT/install-opencloud/main/install_opencloud.sh
chmod +x install_opencloud.sh
./install_opencloud.sh
