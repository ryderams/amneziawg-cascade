#!/usr/bin/env bash
set -u

CONTAINER="amnezia-awg2"
SERVER_IF="awg0"
OUT_IF="awg-out"
TABLE_ID="200"

section() {
  printf '\n===== %s =====\n' "$1"
}

run() {
  printf '\n$ %s\n' "$*"
  "$@" 2>&1 || true
}

container_run() {
  printf '\n$ docker exec %s %s\n' "$CONTAINER" "$*"
  docker exec "$CONTAINER" "$@" 2>&1 || true
}

if [[ "${EUID}" -ne 0 ]]; then
  echo "Запустите от root: sudo bash $0"
  exit 1
fi

section "Контейнер"
run docker ps -a --filter "name=^/${CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Контейнер ${CONTAINER} не запущен."
  exit 1
fi

section "AWG без приватных ключей"
container_run awg show interfaces
container_run awg show "$SERVER_IF" listen-port
container_run awg show "$SERVER_IF" peers
container_run awg show "$OUT_IF" endpoints
container_run awg show "$OUT_IF" allowed-ips
container_run awg show "$OUT_IF" latest-handshakes
container_run awg show "$OUT_IF" transfer

section "Интерфейсы и MTU"
container_run ip -br -4 addr
container_run ip -br link show "$SERVER_IF"
container_run ip -br link show "$OUT_IF"

section "Маршрутизация"
container_run ip rule show
container_run ip route show table main
container_run ip route show table "$TABLE_ID"

CLIENT_IP="$(docker exec "$CONTAINER" ip -o -4 addr show dev "$SERVER_IF" 2>/dev/null | awk 'NR==1 {split($4, a, "/"); print a[1]}')"
if [[ -n "$CLIENT_IP" ]]; then
  container_run ip route get 1.1.1.1 from "$CLIENT_IP"
fi

section "Forwarding и фильтрация"
container_run sysctl net.ipv4.ip_forward
container_run sysctl net.ipv4.conf.all.rp_filter
container_run sysctl net.ipv4.conf.default.rp_filter
container_run iptables -nvL FORWARD --line-numbers
container_run iptables -t nat -nvL POSTROUTING --line-numbers
container_run iptables -t mangle -nvL FORWARD --line-numbers

section "Проверка из контейнера"
container_run ping -c 2 -W 3 1.1.1.1
if [[ -n "$CLIENT_IP" ]]; then
  container_run ping -I "$CLIENT_IP" -c 2 -W 3 1.1.1.1
  container_run curl --interface "$CLIENT_IP" -4 -v --max-time 15 https://ifconfig.me
fi

section "Логи контейнера"
run docker logs --tail 80 "$CONTAINER"

cat <<'EOF'

===== Проверка с подключённого устройства =====
Не отключая каскад, откройте на устройстве любой сайт несколько раз, затем снова
запустите этот диагностический скрипт. У правил awg0 -> awg-out должны увеличиться
счётчики pkts/bytes, а команда transfer должна показать принятые и отправленные байты.
EOF
