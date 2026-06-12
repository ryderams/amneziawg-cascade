#!/usr/bin/env bash
set -Eeuo pipefail

CONTAINER="amnezia-awg2"
SERVER_IF="awg0"
START_SCRIPT="/opt/amnezia/start.sh"
BACKUP_DIR="/root/awg-cascade-vps2-backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_FILE="/root/awg-cascade-vps2-rollback.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[-]${NC} $*"; }

valid_ipv4() {
  local ip="$1" octet
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

if [[ "${EUID}" -ne 0 ]]; then
  err "Запустите скрипт от root или через sudo."
  exit 1
fi

for command in docker awk grep sed mktemp mkdir cp chmod date; do
  if ! command -v "$command" >/dev/null 2>&1; then
    err "Не найдена команда: ${command}"
    exit 1
  fi
done

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  err "Контейнер ${CONTAINER} на VPS-2 не запущен."
  exit 1
fi

CASCADE_IP="${1:-}"
if [[ -z "$CASCADE_IP" ]]; then
  addresses=()
  while IFS= read -r address; do
    [[ -n "$address" ]] && addresses+=("${address%/32}")
  done < <(docker exec "$CONTAINER" awg show "$SERVER_IF" allowed-ips | \
    awk '$2 ~ /^([0-9]{1,3}\.){3}[0-9]{1,3}\/32$/ {print $2}')

  if ((${#addresses[@]} == 0)); then
    err "На VPS-2 не найдено ни одного клиентского IPv4-адреса /32."
    exit 1
  fi

  echo "Доступные клиентские адреса на VPS-2:"
  for index in "${!addresses[@]}"; do
    printf '  %d. %s/32\n' "$((index + 1))" "${addresses[index]}"
  done
  echo
  read -rp "Введите номер адреса служебного профиля VPS-1-cascade: " choice
  if [[ ! "$choice" =~ ^[0-9]+$ ]] || ((10#$choice < 1 || 10#$choice > ${#addresses[@]})); then
    err "Некорректный номер: ${choice}"
    exit 1
  fi
  selected_index=$((10#$choice - 1))
  CASCADE_IP="${addresses[selected_index]}"
fi
CASCADE_IP="${CASCADE_IP%/32}"

if ! valid_ipv4 "$CASCADE_IP"; then
  err "Некорректный IPv4-адрес: ${CASCADE_IP}"
  exit 1
fi

if ! docker exec "$CONTAINER" awg show "$SERVER_IF" allowed-ips | \
     awk -v ip="${CASCADE_IP}/32" '$2 == ip {found=1} END {exit !found}'; then
  err "Адрес ${CASCADE_IP}/32 не назначен ни одному peer на VPS-2."
  err "Создайте профиль VPS-1-cascade в AmneziaVPN и используйте Address из него."
  exit 1
fi

mkdir -p "$BACKUP_DIR"
docker cp "${CONTAINER}:${START_SCRIPT}" "$BACKUP_DIR/start.sh"

original="$(mktemp)"
patched="$(mktemp)"
docker cp "${CONTAINER}:${START_SCRIPT}" "$original"

awk -v ip="$CASCADE_IP" -v iface="$SERVER_IF" '
  BEGIN { managed = 0; inserted = 0 }
  /^# BEGIN awg-cascade-vps2$/ { managed = 1; next }
  /^# END awg-cascade-vps2$/ { managed = 0; next }
  managed { next }
  /^tail -f \/dev\/null$/ && !inserted {
    print "# BEGIN awg-cascade-vps2"
    print "ip route replace " ip "/32 dev " iface
    print "# END awg-cascade-vps2"
    inserted = 1
  }
  { print }
  END {
    if (!inserted) {
      print "# BEGIN awg-cascade-vps2"
      print "ip route replace " ip "/32 dev " iface
      print "# END awg-cascade-vps2"
    }
  }
' "$original" > "$patched"

docker cp "$patched" "${CONTAINER}:${START_SCRIPT}"
docker exec "$CONTAINER" chmod +x "$START_SCRIPT"
docker exec "$CONTAINER" ip route replace "${CASCADE_IP}/32" dev "$SERVER_IF"

cat > "$ROLLBACK_FILE" <<EOFROLL
#!/usr/bin/env bash
set -e
CONTAINER='${CONTAINER}'
START_SCRIPT='${START_SCRIPT}'
BACKUP_DIR='${BACKUP_DIR}'
CASCADE_IP='${CASCADE_IP}'
docker start "\$CONTAINER" >/dev/null 2>&1 || true
docker exec "\$CONTAINER" ip route del "\${CASCADE_IP}/32" dev ${SERVER_IF} 2>/dev/null || true
docker cp "\$BACKUP_DIR/start.sh" "\$CONTAINER:\$START_SCRIPT"
docker restart "\$CONTAINER" >/dev/null
echo "Настройка маршрута каскада на VPS-2 отменена."
EOFROLL
chmod +x "$ROLLBACK_FILE"

rm -f "$original" "$patched"

if docker exec "$CONTAINER" ip route get "$CASCADE_IP" | grep -q "dev ${SERVER_IF}"; then
  log "Маршрут ${CASCADE_IP}/32 через ${SERVER_IF} установлен на VPS-2."
  log "Он будет восстановлен после перезапуска контейнера."
  echo "Для отката выполните: bash ${ROLLBACK_FILE}"
else
  err "Не удалось проверить созданный маршрут."
  exit 1
fi
