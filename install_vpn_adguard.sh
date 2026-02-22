#!/usr/bin/env bash
# Версия 2026-02 — максимально надёжная для Ubuntu/Debian
# Установка 3X-UI и AdGuard Home отдельно + диагностика

apt update && apt upgrade -y

set -euo pipefail

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

log()  { echo -e "${GREEN}[+] ${1}${NC}"; }
err()  { echo -e "${RED}[-] ERROR: ${1}${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!] ${1}${NC}"; }

# ────────────────────────────────────────────────

check_root() {
  [[ $EUID -eq 0 ]] || err "Запускайте от root или через sudo"
}

check_os() {
  if [[ ! -f /etc/os-release ]]; then err "/etc/os-release не найден"; fi
  . /etc/os-release
  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    err "Поддерживаются только Ubuntu и Debian"
  fi
}

get_ip() {
  IP=$(curl -s -4 --connect-timeout 7 https://api.ipify.org || curl -s icanhazip.com || echo "")
  [[ -z "$IP" ]] && err "Не удалось определить публичный IP"
  echo "$IP"
}

input_params() {
  echo ""
  read -r -p "Домен (например: vpn.mydomain.com): " DOMAIN
  [[ -z "$DOMAIN" ]] && err "Домен обязателен"
  read -r -p "Email для Let's Encrypt: " EMAIL
  [[ -z "$EMAIL" ]] && err "Email обязателен"
}

install_base() {
  log "Обновление системы + установка базовых пакетов"
  export DEBIAN_FRONTEND=noninteractive
  apt update -qq >/dev/null
  apt upgrade -y -qq >/dev/null
  apt install -y -qq \
    curl wget tar unzip nginx certbot python3-certbot-nginx \
    ca-certificates gnupg lsb-release net-tools dnsutils socat \
    sqlite3 >/dev/null || err "Не удалось установить пакеты"
}

stop_old_services() {
  log "Остановка конфликтующих веб-серверов"
  systemctl stop nginx apache2 httpd 2>/dev/null || true
  systemctl disable nginx apache2 httpd 2>/dev/null || true
}

wait_dns_propagation() {
  log "Проверка DNS (ждём до 120 сек пока $DOMAIN → $SERVER_IP)"
  for i in {1..24}; do
    resolved=$(dig +short "$DOMAIN" @1.1.1.1 2>/dev/null | head -n1 || true)
    if [[ "$resolved" == "$SERVER_IP" ]]; then
      log "DNS распространился ✓"
      return 0
    fi
    sleep 5
  done
  warn "DNS ещё не виден глобально → certbot может не сработать, но продолжаем"
}

open_firewall() {
  if command -v ufw >/dev/null; then
    log "Открываем порты в UFW (22,80,443,2087,3001)"
    ufw allow 22,80,443,2087,3001/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 || true
  else
    warn "ufw не найден — порты не открыты автоматически"
  fi
}

get_ssl() {
  log "Получаем сертификат Let's Encrypt"

  # Минимальный nginx для certbot
  mkdir -p /etc/nginx/sites-enabled
  cat > /etc/nginx/sites-enabled/default <<'EOF'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    location / { return 200 "certbot-verification-ok"; }
}
EOF

  nginx -t >/dev/null 2>&1 && systemctl restart nginx || err "nginx не стартует"

  certbot certonly --nginx --non-interactive --agree-tos --redirect \
    --email "$EMAIL" -d "$DOMAIN" || {
      err "certbot провалился. Проверьте:\n1. DNS A-запись домена\n2. Порты 80/443 открыты\n3. Нет другого веб-сервера"
    }

  log "Сертификат получен ✓"
}

install_adguard_home() {
  log "Установка AdGuard Home"

  curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
    | sh -s -- -v || err "Скачивание/установка AdGuard Home провалилась"

  systemctl stop AdGuardHome 2>/dev/null || true

  # Меняем порт на 3001, чтобы не конфликтовать
  if [[ -f /opt/AdGuardHome/AdGuardHome.yaml ]]; then
    sed -i 's/^bind_port: 3000/bind_port: 3001/' /opt/AdGuardHome/AdGuardHome.yaml || true
  fi

  systemctl daemon-reload
  systemctl enable --now AdGuardHome 2>/dev/null || {
    warn "AdGuard Home не запустился автоматически"
    journalctl -u AdGuardHome -n 30 --no-pager
  }

  if systemctl is-active --quiet AdGuardHome; then
    log "AdGuard Home работает на порту 3001"
  else
    warn "AdGuard Home НЕ запустился → зайдите вручную http://$SERVER_IP:3001"
  fi
}

install_3x_ui() {
  log "Установка 3X-UI (самая проблемная часть — делаем надёжно)"

  # Удаляем старые остатки, если были
  systemctl stop x-ui 3x-ui 2>/dev/null || true
  rm -rf /usr/local/x-ui /etc/systemd/system/x-ui.service /etc/systemd/system/3x-ui.service

  # Запускаем официальный скрипт — БЕЗ piped input, т.к. он не работает стабильно
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) || {
    err "Официальный install.sh 3X-UI завершился с ошибкой"
  }

  # Даём время на запуск и генерацию credentials
  sleep 8

  # Проверяем наличие команды и базы
  XUI_BIN=""
  if [[ -x /usr/local/x-ui/x-ui ]]; then
    XUI_BIN="/usr/local/x-ui/x-ui"
  elif [[ -x /usr/local/x-ui/bin/x-ui ]]; then
    XUI_BIN="/usr/local/x-ui/bin/x-ui"
  fi

  if [[ -z "$XUI_BIN" ]]; then
    err "Бинарник x-ui не найден после установки → 3X-UI не установился"
  fi

  # Пытаемся получить credentials
  CREDENTIALS=$($XUI_BIN setting -show 2>/dev/null | grep -iE 'username|password|port' || echo "")

  if [[ -z "$CREDENTIALS" ]] && [[ -f /usr/local/x-ui/bin/x-ui.db ]]; then
    CREDENTIALS=$(sqlite3 /usr/local/x-ui/bin/x-ui.db \
      "SELECT 'username: ' || username || ', password: ' || password || ', port: ??" FROM setting LIMIT 1;" 2>/dev/null || echo "")
  fi

  [[ -z "$CREDENTIALS" ]] && CREDENTIALS="не удалось извлечь автоматически — смотрите вывод установки выше или выполните '$XUI_BIN setting -show'"

  log "3X-UI установлен"
  echo -e "${YELLOW}Credentials:${NC}\n$CREDENTIALS"
}

show_summary() {
  echo -e "\n${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "          Установка завершена (насколько возможно) ✓"
  echo ""
  echo -e " 3X-UI панель →   https://$DOMAIN:порт_из_установки   (обычно 20000–60000)"
  echo -e "                  http://$SERVER_IP:порт_из_установки  (если SSL не настроен)"
  echo -e " Credentials →    $CREDENTIALS"
  echo -e "                  (если пусто — выполните: $XUI_BIN setting -show)"
  echo ""
  echo -e " AdGuard Home →   http://$SERVER_IP:3001"
  echo -e "                  → первый вход = создание логина/пароля"
  echo ""
  echo -e " IP сервера:      $SERVER_IP"
  echo -e " Домен:           $DOMAIN"
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
  echo ""
  echo "Если что-то не работает — покажите:"
  echo "  journalctl -u x-ui -n 40"
  echo "  journalctl -u AdGuardHome -n 40"
}

# ────────────────────────────────────────────────

check_root
check_os

SERVER_IP=$(get_ip)
log "Публичный IP сервера: $SERVER_IP"

input_params

install_base
stop_old_services
open_firewall
wait_dns_propagation
get_ssl
install_adguard_home
install_3x_ui

show_summary
