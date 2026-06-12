#!/usr/bin/env bash
set -Eeuo pipefail

# Каскад для стандартной контейнерной установки AmneziaWG 2.0:
# клиент -> awg0 на VPS-1 -> awg-out -> VPS-2 -> Интернет

CONTAINER="amnezia-awg2"
SERVER_IF="awg0"
OUT_IF="awg-out"
TABLE_ID="200"
CONTAINER_DIR="/opt/amnezia/awg"
OUT_CONF="${CONTAINER_DIR}/${OUT_IF}.conf"
START_SCRIPT="/opt/amnezia/start.sh"
BACKUP_DIR="/root/awg-cascade-backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_FILE="/root/awg-cascade-rollback.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[-]${NC} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запустите скрипт от root или через sudo."
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_host_cmds() {
  local missing=() command
  for command in docker awk sed grep tr head install mktemp cp chmod mkdir touch rm date; do
    cmd_exists "$command" || missing+=("$command")
  done
  if ((${#missing[@]})); then
    err "На VPS-1 не найдены необходимые команды: ${missing[*]}"
    exit 1
  fi
}

container_exec() {
  docker exec "$CONTAINER" "$@"
}

check_awg_container() {
  local command

  if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER"; then
      err "Контейнер ${CONTAINER} найден, но не запущен."
    else
      err "Контейнер ${CONTAINER} не найден на VPS-1."
    fi
    err "Установите и запустите AmneziaWG 2.0 через приложение AmneziaVPN."
    exit 1
  fi

  for command in awg awg-quick ip iptables awk sed grep curl; do
    if ! container_exec sh -c "command -v ${command} >/dev/null 2>&1"; then
      if [[ "$command" == "curl" ]]; then
        warn "В контейнере нет curl: проверка внешнего IP будет пропущена."
      else
        err "В контейнере ${CONTAINER} не найдена команда ${command}."
        exit 1
      fi
    fi
  done

  if ! container_exec test -f "${CONTAINER_DIR}/${SERVER_IF}.conf"; then
    err "В контейнере не найден серверный конфиг ${CONTAINER_DIR}/${SERVER_IF}.conf."
    exit 1
  fi

  if ! container_exec awg show interfaces | tr ' ' '\n' | grep -qx "$SERVER_IF"; then
    err "Серверный интерфейс ${SERVER_IF} в контейнере ${CONTAINER} не запущен."
    exit 1
  fi

  log "Контейнер AmneziaWG 2.0 найден, интерфейс ${SERVER_IF} запущен."
}

detect_client_subnet() {
  container_exec ip -o -4 route show dev "$SERVER_IF" scope link 2>/dev/null | \
    awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print $1; exit}'
}

choose_client_subnet() {
  CLIENT_SUBNET="$(detect_client_subnet)"
  if [[ -n "$CLIENT_SUBNET" ]]; then
    log "Клиентская подсеть определена автоматически: ${CLIENT_SUBNET} (${SERVER_IF})"
    return
  fi

  warn "Не удалось автоматически определить клиентскую подсеть ${SERVER_IF}."
  read -rp "Введите клиентскую подсеть VPS-1 [пример: 10.8.1.0/24]: " CLIENT_SUBNET
}

valid_ipv4_subnet() {
  local subnet="$1" ip prefix octet
  [[ "$subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]] || return 1
  ip="${subnet%/*}"
  prefix="${subnet#*/}"
  ((10#$prefix <= 32)) || return 1
  IFS=. read -r -a octets <<< "$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

ipv4_to_int() {
  local ip="$1" a b c d
  IFS=. read -r a b c d <<< "$ip"
  printf '%u\n' "$(( (10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d ))"
}

ip_belongs_to_subnet() {
  local ip="$1" subnet="$2" prefix network_ip ip_num network_num mask
  prefix="${subnet#*/}"
  network_ip="${subnet%/*}"
  ip_num="$(ipv4_to_int "$ip")"
  network_num="$(ipv4_to_int "$network_ip")"
  if ((10#$prefix == 0)); then
    mask=0
  else
    mask=$(( (0xFFFFFFFF << (32 - 10#$prefix)) & 0xFFFFFFFF ))
  fi
  (( (ip_num & mask) == (network_num & mask) ))
}

check_subnet_conflict() {
  local config="$1" out_address out_ip
  out_address="$(sed -n -E 's/^Address[[:space:]]*=[[:space:]]*([^,[:space:]]+).*/\1/p' "$config" | head -n 1)"
  out_ip="${out_address%/*}"

  if [[ ! "$out_address" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    err "Не удалось прочитать IPv4-адрес из параметра Address: ${out_address:-пусто}"
    exit 1
  fi

  if ip_belongs_to_subnet "$out_ip" "$CLIENT_SUBNET"; then
    err "Адрес туннеля VPS-2 (${out_address}) пересекается с подсетью клиентов VPS-1 (${CLIENT_SUBNET})."
    err "Задайте на VPS-2 другую внутреннюю подсеть AWG, создайте новый профиль и повторите запуск."
    exit 1
  fi
}

read_client_config() {
  local tmp="$1" line input_finished=0

  echo
  echo "Вставьте полный клиентский конфиг AWG, созданный на VPS-2 для VPS-1."
  echo "После последней строки конфига введите отдельной строкой: END"
  echo

  while IFS= read -r line; do
    if [[ "$line" == "END" ]]; then
      input_finished=1
      break
    fi
    printf '%s\n' "$line" >> "$tmp"
  done

  if ((input_finished == 0)); then
    err "Ввод конфига не завершён строкой END."
    exit 1
  fi

  sed -i 's/\r$//' "$tmp"
  sed -i -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$tmp"
  sed -i -E '/^I[1-5][[:space:]]*=[[:space:]]*$/d' "$tmp"
  sed -i -E '/^DNS[[:space:]]*=/d' "$tmp"

  if [[ "$(grep -c '^\[Interface\]' "$tmp")" -ne 1 ]] || \
     [[ "$(grep -c '^\[Peer\]' "$tmp")" -ne 1 ]]; then
    err "Конфиг должен содержать ровно по одной секции [Interface] и [Peer]."
    exit 1
  fi

  if ! grep -q '^PrivateKey[[:space:]]*=[[:space:]]*[^[:space:]]' "$tmp" || \
     ! grep -q '^Address[[:space:]]*=[[:space:]]*[^[:space:]]' "$tmp" || \
     ! grep -q '^PublicKey[[:space:]]*=[[:space:]]*[^[:space:]]' "$tmp" || \
     ! grep -q '^Endpoint[[:space:]]*=[[:space:]]*[^[:space:]]' "$tmp"; then
    err "Конфиг должен содержать непустые Address, PrivateKey, PublicKey и Endpoint."
    exit 1
  fi

  if ! grep -q '^S3[[:space:]]*=[[:space:]]*[^[:space:]]' "$tmp" || \
     ! grep -q '^S4[[:space:]]*=[[:space:]]*[^[:space:]]' "$tmp"; then
    err "В конфиге нет параметров S3 и S4, характерных для AmneziaWG 2.0."
    err "Создайте на VPS-2 новый профиль AmneziaWG 2.0, а не AmneziaWG Legacy."
    exit 1
  fi
}

prepare_out_config() {
  local source="$1" result="$2"

  awk -v table_id="$TABLE_ID" -v out_if="$OUT_IF" -v client_subnet="$CLIENT_SUBNET" '
    BEGIN { in_interface = 0; hooks_added = 0 }

    /^\[Interface\]$/ { in_interface = 1; print; next }

    /^\[Peer\]$/ {
      if (in_interface && !hooks_added) {
        print "MTU = 1280"
        print "Table = off"
        print "PostUp = ip route replace default dev " out_if " table " table_id "; while ip rule del from " client_subnet " table " table_id " 2>/dev/null; do :; done; ip rule add from " client_subnet " table " table_id "; iptables -C FORWARD -i awg0 -o " out_if " -s " client_subnet " -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i awg0 -o " out_if " -s " client_subnet " -j ACCEPT; iptables -C FORWARD -i " out_if " -o awg0 -d " client_subnet " -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || iptables -I FORWARD 1 -i " out_if " -o awg0 -d " client_subnet " -m state --state ESTABLISHED,RELATED -j ACCEPT; iptables -t nat -C POSTROUTING -s " client_subnet " -o " out_if " -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s " client_subnet " -o " out_if " -j MASQUERADE; iptables -t mangle -C FORWARD -o " out_if " -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o " out_if " -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu; iptables -t mangle -C FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || iptables -t mangle -A FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu"
        print "PostDown = while ip rule del from " client_subnet " table " table_id " 2>/dev/null; do :; done; ip route flush table " table_id " 2>/dev/null || true; iptables -D FORWARD -i awg0 -o " out_if " -s " client_subnet " -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i " out_if " -o awg0 -d " client_subnet " -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s " client_subnet " -o " out_if " -j MASQUERADE 2>/dev/null || true; iptables -t mangle -D FORWARD -o " out_if " -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true; iptables -t mangle -D FORWARD -o awg0 -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true"
        hooks_added = 1
      }
      in_interface = 0
      print
      next
    }

    in_interface && /^Table[[:space:]]*=/ { next }
    in_interface && /^MTU[[:space:]]*=/ { next }
    in_interface && /^Post(Up|Down)[[:space:]]*=/ { next }
    /^AllowedIPs[[:space:]]*=/ { print "AllowedIPs = 0.0.0.0/0"; next }
    { print }
  ' "$source" > "$result"

  if ! grep -q '^AllowedIPs[[:space:]]*=' "$result"; then
    sed -i '/^\[Peer\]/a AllowedIPs = 0.0.0.0/0' "$result"
  fi
  chmod 600 "$result"
}

backup_container_files() {
  mkdir -p "$BACKUP_DIR"
  docker cp "${CONTAINER}:${START_SCRIPT}" "$BACKUP_DIR/start.sh"
  if container_exec test -f "$OUT_CONF"; then
    docker cp "${CONTAINER}:${OUT_CONF}" "$BACKUP_DIR/${OUT_IF}.conf"
    touch "$BACKUP_DIR/had-out-conf"
  fi
  log "Резервная копия сохранена в: $BACKUP_DIR"
}

install_out_config() {
  local config="$1"
  container_exec awg-quick down "$OUT_CONF" >/dev/null 2>&1 || true
  docker cp "$config" "${CONTAINER}:${OUT_CONF}"
  container_exec chmod 600 "$OUT_CONF"
}

patch_container_start() {
  local original patched
  original="$(mktemp)"
  patched="$(mktemp)"
  docker cp "${CONTAINER}:${START_SCRIPT}" "$original"

  awk -v conf="$OUT_CONF" '
    BEGIN { managed = 0; inserted = 0 }
    /^# BEGIN awg-cascade$/ { managed = 1; next }
    /^# END awg-cascade$/ { managed = 0; next }
    managed { next }
    /^tail -f \/dev\/null$/ && !inserted {
      print "# BEGIN awg-cascade"
      print "awg-quick down " conf " 2>/dev/null || true"
      print "if [ -f " conf " ]; then awg-quick up " conf "; fi"
      print "# END awg-cascade"
      inserted = 1
    }
    { print }
    END {
      if (!inserted) {
        print "# BEGIN awg-cascade"
        print "awg-quick down " conf " 2>/dev/null || true"
        print "if [ -f " conf " ]; then awg-quick up " conf "; fi"
        print "# END awg-cascade"
      }
    }
  ' "$original" > "$patched"

  docker cp "$patched" "${CONTAINER}:${START_SCRIPT}"
  container_exec chmod +x "$START_SCRIPT"
  rm -f "$original" "$patched"
}

make_rollback() {
  cat > "$ROLLBACK_FILE" <<EOFROLL
#!/usr/bin/env bash
set -e
CONTAINER='${CONTAINER}'
OUT_CONF='${OUT_CONF}'
START_SCRIPT='${START_SCRIPT}'
BACKUP_DIR='${BACKUP_DIR}'

if ! docker ps -a --format '{{.Names}}' | grep -qx "\$CONTAINER"; then
  echo "Контейнер \$CONTAINER не найден."
  exit 1
fi

docker start "\$CONTAINER" >/dev/null 2>&1 || true
docker exec "\$CONTAINER" awg-quick down "\$OUT_CONF" >/dev/null 2>&1 || true
docker cp "\$BACKUP_DIR/start.sh" "\$CONTAINER:\$START_SCRIPT"

if [[ -f "\$BACKUP_DIR/had-out-conf" ]]; then
  docker cp "\$BACKUP_DIR/${OUT_IF}.conf" "\$CONTAINER:\$OUT_CONF"
else
  docker exec "\$CONTAINER" rm -f "\$OUT_CONF"
fi

docker restart "\$CONTAINER" >/dev/null
echo "Откат каскада AWG завершён. Контейнер \$CONTAINER перезапущен."
EOFROLL
  chmod +x "$ROLLBACK_FILE"
}

start_out_interface() {
  container_exec awg-quick down "$OUT_CONF" >/dev/null 2>&1 || true
  if ! container_exec awg-quick up "$OUT_CONF"; then
    err "Не удалось запустить ${OUT_IF} внутри контейнера ${CONTAINER}."
    return 1
  fi
  if ! container_exec ip link show "$OUT_IF" >/dev/null 2>&1; then
    err "Интерфейс ${OUT_IF} не появился внутри контейнера."
    return 1
  fi
}

check_cascade() {
  local client_ip route exit_ip mtu handshake
  client_ip="$(container_exec ip -o -4 addr show dev "$SERVER_IF" | awk 'NR==1 {split($4, a, "/"); print a[1]}')"
  route="$(container_exec ip route get 1.1.1.1 from "$client_ip" 2>/dev/null || true)"

  mtu="$(container_exec ip -o link show dev "$OUT_IF" | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") {print $(i+1); exit}}')"
  if [[ "$mtu" != "1280" ]]; then
    err "Интерфейс ${OUT_IF} имеет неожиданный MTU: ${mtu:-не определён}."
    return 1
  fi

  if ! container_exec iptables -C FORWARD -i "$SERVER_IF" -o "$OUT_IF" -s "$CLIENT_SUBNET" -j ACCEPT 2>/dev/null; then
    err "Не установлено правило FORWARD из ${SERVER_IF} в ${OUT_IF}."
    return 1
  fi

  if ! container_exec iptables -t mangle -C FORWARD -o "$OUT_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; then
    err "Не установлено правило TCP MSS clamping для ${OUT_IF}."
    return 1
  fi

  if grep -q "dev ${OUT_IF}" <<< "$route"; then
    log "Policy routing направляет клиентский трафик через ${OUT_IF}."
  else
    err "Проверка policy routing не прошла: ${route:-маршрут не найден}"
    return 1
  fi

  if container_exec sh -c 'command -v curl >/dev/null 2>&1'; then
    exit_ip="$(container_exec curl --interface "$client_ip" -4 -s --max-time 10 https://ifconfig.me || true)"
    if [[ -n "$exit_ip" ]]; then
      log "Выходной IPv4-адрес каскада: ${exit_ip}"
    else
      warn "Маршрут настроен, но определить внешний IP через curl не удалось."
    fi
  fi

  handshake="$(container_exec awg show "$OUT_IF" latest-handshakes 2>/dev/null | awk 'NR==1 {print $2}')"
  if [[ -z "$handshake" || "$handshake" == "0" ]]; then
    err "Нет успешного handshake между VPS-1 и VPS-2."
    err "Проверьте Endpoint, ключи, порт AWG и firewall на VPS-2."
    return 1
  fi
  log "Handshake с VPS-2 подтверждён."
}

rollback_on_error() {
  local status=$?
  if ((status != 0)) && [[ "${SETUP_IN_PROGRESS:-0}" == "1" ]] && [[ -x "$ROLLBACK_FILE" ]]; then
    warn "Настройка завершилась с ошибкой. Выполняем автоматический откат."
    SETUP_IN_PROGRESS=0
    bash "$ROLLBACK_FILE" || warn "Автоматический откат завершился с ошибкой: $ROLLBACK_FILE"
  fi
}

main() {
  local raw_config prepared_config
  SETUP_IN_PROGRESS=0
  trap rollback_on_error EXIT

  need_root
  require_host_cmds
  check_awg_container

  echo
  echo "=== Каскад AWG: клиент -> VPS-1 -> VPS-2 -> Интернет ==="
  choose_client_subnet
  if ! valid_ipv4_subnet "$CLIENT_SUBNET"; then
    err "Некорректная подсеть IPv4: $CLIENT_SUBNET"
    exit 1
  fi

  raw_config="$(mktemp)"
  prepared_config="$(mktemp)"
  read_client_config "$raw_config"
  check_subnet_conflict "$raw_config"
  prepare_out_config "$raw_config" "$prepared_config"

  backup_container_files
  make_rollback
  SETUP_IN_PROGRESS=1
  install_out_config "$prepared_config"
  patch_container_start
  start_out_interface
  check_cascade
  SETUP_IN_PROGRESS=0

  rm -f "$raw_config" "$prepared_config"
  echo
  log "Каскад AWG настроен внутри контейнера ${CONTAINER}."
  echo "Все клиенты подсети ${CLIENT_SUBNET} будут выходить через VPS-2."
  echo "Для отката выполните: bash ${ROLLBACK_FILE}"
}

main "$@"
