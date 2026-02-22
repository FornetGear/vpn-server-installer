#!/usr/bin/env bash
# Исправленная версия — февраль 2026
# Учитывает авто-генерацию 3X-UI и wizard AdGuard Home

set -euo pipefail

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

log()  { echo -e "${GREEN}[+] $1${NC}"; }
err()  { echo -e "${RED}[-] $1${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }

check_root() {
  [[ $EUID -eq 0 ]] || err "Запускайте от root / через sudo"
}

detect_os() {
  source /etc/os-release 2>/dev/null || err "Нет /etc/os-release"
  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    err "Только Ubuntu / Debian"
  fi
}

get_public_ip() {
  local ip
  ip=$(curl -s -4 --connect-timeout 8 https://api.ipify.org || curl -s icanhazip.com || curl -s ifconfig.me)
  [[ -z "$ip" ]] && err "Не удалось определить публичный IP"
  echo "$ip"
}

ask_params() {
  read -rp "Домен (vpn.example.com): " DOMAIN
  [[ -z "$DOMAIN" ]] && err "Домен обязателен"
  read -rp "Email для Let's Encrypt: " EMAIL
  [[ -z "$EMAIL" ]] && err "Email обязателен"
}

install_packages() {
  log "Установка необходимых пакетов..."
  export DEBIAN_FRONTEND=noninteractive
  apt update -qq && apt install -y -qq \
    curl wget unzip tar nginx certbot python3-certbot-nginx \
    net-tools dnsutils socat >/dev/null
}

stop_conflicts() {
  systemctl stop nginx apache2 2>/dev/null || true
}

wait_for_dns() {
  local domain_ip
  log "Ожидание распространения DNS (до 2 минут)..."
  for i in {1..24}; do
    domain_ip=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | head -n1 || true)
    [[ "$domain_ip" == "$SERVER_IP" ]] && { log "DNS OK"; return 0; }
    sleep 5
  done
  warn "DNS ещё не обновился → certbot может не сработать"
}

setup_ufw() {
  if command -v ufw &>/dev/null; then
    ufw allow 22 80 443 2087 3001 >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 || true
  fi
}

install_and_get_ssl() {
  systemctl start nginx || err "nginx не запускается"

  # Временный конфиг для certbot
  cat >/etc/nginx/sites-enabled/default <<EOF
server {
    listen 80 default_server;
    server_name _;
    location / { return 200 "certbot placeholder"; }
}
EOF
  nginx -t && systemctl reload nginx || err "Плохой nginx config"

  certbot certonly --nginx --non-interactive --agree-tos \
    --email "$EMAIL" -d "$DOMAIN" --redirect || \
    err "certbot failed → проверьте DNS + открытые 80/443"

  log "SSL получен"
}

install_adguard() {
  log "Установка AdGuard Home..."
  curl -sSL https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh | sh -s -- -v

  systemctl stop AdGuardHome 2>/dev/null || true
  sed -i 's/bind_port: 3000/bind_port: 3001/' /opt/AdGuardHome/AdGuardHome.yaml 2>/dev/null || true
  systemctl start AdGuardHome || warn "AdGuard не стартовал"

  log "AdGuard → после установки зайдите http://$SERVER_IP:3001 и создайте логин/пароль"
}

install_3xui() {
  log "Установка 3X-UI..."

  # Запускаем установку без ввода (он сам сгенерит credentials)
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) <<EOF
n
EOF

  sleep 6

  # Пытаемся вытащить сгенерированные логин/пароль
  if command -v x-ui &>/dev/null; then
    CREDENTIALS=$(x-ui setting -show 2>/dev/null | grep -E 'username|password' || true)
  fi

  if [[ -z "$CREDENTIALS" ]]; then
    # Альтернатива — смотрим в базу (если sqlite3 есть)
    if command -v sqlite3 &>/dev/null && [[ -f /usr/local/x-ui/bin/x-ui.db ]]; then
      CREDENTIALS=$(sqlite3 /usr/local/x-ui/bin/x-ui.db "SELECT username, password FROM setting LIMIT 1;" || true)
    fi
  fi

  # Если ничего не нашли — скажем пользователю зайти и посмотреть
  if [[ -z "$CREDENTIALS" ]]; then
    CREDENTIALS="не удалось автоматически извлечь → зайдите в панель и посмотрите/смените в настройках"
  fi
}

final_message() {
  echo -e "\n${GREEN}════════════════════════════════════════════════════${NC}"
  echo -e " Установка завершена ${GREEN}✓${NC}\n"

  echo -e " → 3X-UI панель:"
  echo -e "    https://$DOMAIN:54321  (или другой порт, который выбрали)"
  echo -e "    Логин / пароль:  $CREDENTIALS"
  echo -e "    (если не отобразилось выше — смотрите вывод установки 3X-UI или выполните 'x-ui setting -show')\n"

  echo -e " → AdGuard Home:"
  echo -e "    http://$SERVER_IP:3001  (или https://$DOMAIN/adguard — если настроите reverse-proxy позже)"
  echo -e "    → первый вход → создайте свой логин и пароль в мастере\n"

  echo -e " IP сервера:       $SERVER_IP"
  echo -e "${GREEN}════════════════════════════════════════════════════${NC}"
}

# ────────────────────────────────────────

check_root
detect_os

SERVER_IP=$(get_public_ip)
log "Ваш IP: $SERVER_IP"

ask_params

install_packages
stop_conflicts
setup_ufw
wait_for_dns
install_and_get_ssl
install_adguard
install_3xui

final_message
