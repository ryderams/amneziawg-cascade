#!/usr/bin/env bash
set -u

CONTAINER="amnezia-awg2"
SERVER_IF="awg0"

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

section "Контейнер VPS-2"
run docker ps -a --filter "name=^/${CONTAINER}$" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  echo "Контейнер ${CONTAINER} не запущен."
  exit 1
fi

section "Peer VPS-1 без приватных ключей"
container_run awg show "$SERVER_IF" listen-port
container_run awg show "$SERVER_IF" peers
container_run awg show "$SERVER_IF" allowed-ips
container_run awg show "$SERVER_IF" latest-handshakes
container_run awg show "$SERVER_IF" transfer
container_run awg show "$SERVER_IF" endpoints

CASCADE_IP="${1:-}"
if [[ -n "$CASCADE_IP" ]]; then
  section "Проверка адреса каскада ${CASCADE_IP}"
  container_run ip route get "$CASCADE_IP"
  printf '\nPeer, которому назначен адрес %s:\n' "$CASCADE_IP"
  docker exec "$CONTAINER" awg show "$SERVER_IF" allowed-ips 2>&1 | grep -F "$CASCADE_IP" || \
    echo "Адрес ${CASCADE_IP} не найден среди AllowedIPs peer на VPS-2."
fi

section "Интерфейсы и маршруты"
container_run ip -br -4 addr
container_run ip route show table main
container_run ip rule show

section "Forwarding, NAT и firewall"
container_run sysctl net.ipv4.ip_forward
container_run sysctl net.ipv4.conf.all.rp_filter
container_run iptables -nvL FORWARD --line-numbers
container_run iptables -t nat -nvL POSTROUTING --line-numbers

section "Доступ VPS-2 в Интернет"
container_run ping -c 2 -W 3 1.1.1.1
container_run curl -4 -v --max-time 15 https://ifconfig.me

cat <<'EOF'

===== Как проводить тест =====
1. Оставьте устройство подключённым к каскаду через VPS-1.
2. Несколько раз попробуйте открыть 2ip.ru.
3. Сразу после этого запустите диагностику VPS-2 ещё раз.

У peer VPS-1 должны увеличиваться и received, и sent в разделе transfer.
В POSTROUTING должен расти счётчик MASQUERADE для внутренней сети AWG VPS-2.
EOF
