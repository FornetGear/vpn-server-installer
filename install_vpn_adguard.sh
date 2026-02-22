#!/usr/bin/env bash
# Минимальный скрипт: 3X-UI + AdGuard Home + nginx (опционально для прокси)
# Сертификат — через встроенную функцию Cloudflare в 3X-UI
# Для чистой Ubuntu/Debian

apt update && apt upgrade -y

set -euo pipefail

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' NC='\033[0m'

log()  { echo -e "${GREEN}[+] $1${NC}"; }
err()  { echo -e "${RED}[-] $1${NC}" >&2; exit 1; }
warn() { echo -e "${YELLOW}[!] $1${NC}"; }

check_root() {
  [[ $EUID -eq 0 ]] || err "sudo / root required"
}

get_ip() {
  IP=$(curl -s -4 --connect-timeout 8 https://api.ipify.org || curl -s icanhazip.com || true)
  [[ -z "$IP" ]] && err "Не удалось определить публичный IP"
  echo "$IP"
}

ask_domain() {
  read -r -p "Домен (vpn.example.com) — уже добавлен в Cloudflare: " DOMAIN
  [[ -z "$DOMAIN" ]] && err "Домен обязателен (для подсказки в финале)"
}

install_minimal() {
  log "Установка минимальных пакетов"
  export DEBIAN_FRONTEND=noninteractive
  apt update -qq >/dev/null
  apt install -y -qq \
    curl wget tar unzip nginx \
    ca-certificates net-tools dnsutils socat >/dev/null || err "apt failed"
}

setup_ufw() {
  if command -v ufw >/dev/null; then
    log "Открываем 22,443 (80 не нужен для Cloudflare DNS-01)"
    ufw allow 22,443/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1 || true
  fi
}

install_adguard() {
  log "Установка AdGuard Home"
  curl -s -S -L https://raw.githubusercontent.com/AdguardTeam/AdGuardHome/master/scripts/install.sh \
    | sh -s -- -v || err "AdGuard install failed"

  systemctl stop AdGuardHome 2>/dev/null || true
  sed -i 's/bind_port: 3000/bind_port: 3001/' /opt/AdGuardHome/AdGuardHome.yaml || true
  systemctl enable --now AdGuardHome || warn "AdGuard не стартовал"
}

install_3xui() {
  log "Установка 3X-UI — следуй инструкциям в терминале!"
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
}

final_info() {
  echo -e "\n${GREEN}═══════════════════════════════════════════════${NC}"
  echo -e "             Готово!"
  echo ""
  echo -e " 3X-UI панель:     http://$SERVER_IP:порт_из_установки (пока без SSL)"
  echo -e " Получи SSL:       В панели → Settings → SSL Certificate Management"
  echo -e "                   Выбери Cloudflare SSL Certificate"
  echo -e "                   Введи: Email + Global API Key + Домен ($DOMAIN)"
  echo -e "                   → Получишь HTTPS за 1–2 минуты"
  echo ""
  echo -e " AdGuard Home:     http://$SERVER_IP:3001 → создай логин/пароль"
  echo ""
  echo -e " Nginx:            Уже стоит — используй для reverse-proxy позже"
  echo -e "                   (пример: проксировать панель на 443 через Cloudflare)"
  echo -e "${GREEN}═══════════════════════════════════════════════${NC}"
}

# Запуск
check_root
SERVER_IP=$(get_ip)
log "IP сервера: $SERVER_IP"

ask_domain

install_minimal
setup_ufw
install_adguard
install_3xui

final_info
