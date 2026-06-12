#!/usr/bin/env bash
set -Eeuo pipefail

# Настройка каскада AWG на VPS-1
# Клиент -> AWG-сервер VPS-1 -> выходной AWG-туннель VPS-2 -> Интернет
# Работает с уже установленным AmneziaWG и не устанавливает AWG-сервер.

OUT_IF="awg-out"
TABLE_ID="200"
TABLE_NAME="awg_cascade"
RT_TABLES="/etc/iproute2/rt_tables"
OUT_CONF="/etc/amnezia/amneziawg/${OUT_IF}.conf"
BACKUP_DIR="/root/awg-cascade-backup-$(date +%Y%m%d-%H%M%S)"
ROLLBACK_FILE="/root/awg-cascade-rollback.sh"
SYSCTL_FILE="/etc/sysctl.d/99-awg-cascade.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err() { echo -e "${RED}[-]${NC} $*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Запустите скрипт от root: sudo bash $0"
    exit 1
  fi
}

cmd_exists() { command -v "$1" >/dev/null 2>&1; }

require_cmds() {
  local missing=()
  for c in ip awk sed grep tr systemctl sysctl iptables install mktemp cp chmod mkdir touch dirname ping sleep; do
    cmd_exists "$c" || missing+=("$c")
  done
  if ((${#missing[@]})); then
    err "Не найдены необходимые команды: ${missing[*]}"
    exit 1
  fi
  if ! cmd_exists awg-quick; then
    err "Команда awg-quick не найдена. Сначала установите и настройте AmneziaWG."
    exit 1
  fi
  if ! cmd_exists awg; then
    err "Команда awg не найдена. Установка AmneziaWG на VPS-1 неполная."
    exit 1
  fi
}

check_awg_on_vps1() {
  local interfaces configs=() conf

  if ! systemctl cat 'awg-quick@.service' >/dev/null 2>&1; then
    err "Не найден systemd-сервис awg-quick@.service."
    err "Установите AmneziaWG 2.0 на VPS-1 и запустите его сервер."
    exit 1
  fi

  for conf in /etc/amnezia/amneziawg/*.conf /etc/wireguard/*.conf; do
    [[ -f "$conf" ]] || continue
    [[ "${conf##*/}" == "${OUT_IF}.conf" ]] && continue
    configs+=("$conf")
  done

  if ((${#configs[@]} == 0)); then
    err "На VPS-1 не найден серверный конфиг AmneziaWG."
    err "Сначала установите и настройте сервер AWG 2.0 на VPS-1."
    exit 1
  fi

  interfaces="$(awg show interfaces 2>/dev/null || true)"
  interfaces="$(printf '%s\n' "$interfaces" | tr ' ' '\n' | grep -v "^${OUT_IF}$" | sed '/^$/d' || true)"
  if [[ -z "$interfaces" ]]; then
    err "AmneziaWG установлен, но серверный AWG-интерфейс на VPS-1 не запущен."
    err "Проверьте состояние сервера AWG и повторите запуск скрипта."
    exit 1
  fi

  log "AmneziaWG на VPS-1 установлен и запущен."
}

choose_conf_dir() {
  if [[ -d /etc/amnezia/amneziawg ]]; then
    OUT_CONF="/etc/amnezia/amneziawg/${OUT_IF}.conf"
  elif [[ -d /etc/wireguard ]]; then
    OUT_CONF="/etc/wireguard/${OUT_IF}.conf"
  else
    mkdir -p /etc/amnezia/amneziawg
    OUT_CONF="/etc/amnezia/amneziawg/${OUT_IF}.conf"
  fi
}

backup() {
  mkdir -p "$BACKUP_DIR"
  [[ -f "$RT_TABLES" ]] && cp -a "$RT_TABLES" "$BACKUP_DIR/rt_tables"
  [[ -f "$OUT_CONF" ]] && cp -a "$OUT_CONF" "$BACKUP_DIR/${OUT_IF}.conf"
  [[ -f "$SYSCTL_FILE" ]] && cp -a "$SYSCTL_FILE" "$BACKUP_DIR/99-awg-cascade.conf"
  log "Резервная копия сохранена в: $BACKUP_DIR"
}

list_awg_interfaces() {
  # Получаем интерфейсы через AWG, не полагаясь на схему их имён.
  awg show interfaces 2>/dev/null | tr ' ' '\n' | grep -v "^${OUT_IF}$" | sed '/^$/d' || true
}

detect_client_networks() {
  local iface

  while IFS= read -r iface; do
    [[ -n "$iface" ]] || continue
    ip -o -4 route show dev "$iface" scope link 2>/dev/null | \
      awk -v iface="$iface" '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ {print iface " " $1}'
  done < <(list_awg_interfaces)
}

choose_client_subnet() {
  local detected=() iface subnet entry
  while IFS= read -r entry; do
    [[ -n "$entry" ]] && detected+=("$entry")
  done < <(detect_client_networks)

  if ((${#detected[@]} == 1)); then
    read -r iface subnet <<< "${detected[0]}"
    CLIENT_SUBNET="$subnet"
    log "Клиентская подсеть определена автоматически: ${CLIENT_SUBNET} (${iface})"
    return
  fi

  if ((${#detected[@]} > 1)); then
    warn "Найдено несколько возможных клиентских подсетей:"
    for entry in "${detected[@]}"; do
      read -r iface subnet <<< "$entry"
      echo "  ${subnet} (${iface})"
    done
  else
    warn "Не удалось автоматически определить клиентскую подсеть AWG на VPS-1."
  fi

  read -rp "Введите клиентскую подсеть AWG-сервера на VPS-1 [пример: 10.77.0.0/24]: " CLIENT_SUBNET
  CLIENT_SUBNET="${CLIENT_SUBNET:-10.77.0.0/24}"
}

read_multiline_config() {
  echo
  echo "Вставьте полный клиентский конфиг AWG, созданный на VPS-2 для этого VPS-1."
  echo "После конфига введите отдельной строкой: END"
  echo
  local tmp
  tmp="$(mktemp)"
  while IFS= read -r line; do
    [[ "$line" == "END" ]] && break
    printf '%s\n' "$line" >> "$tmp"
  done

  sed -i 's/\r$//' "$tmp"
  sed -i -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$tmp"
  # Пустые I1-I5 из экспорта Amnezia могут не приниматься некоторыми версиями AWG.
  # Непустые сигнатуры сохраняются без изменений.
  sed -i -E '/^I[1-5][[:space:]]*=[[:space:]]*$/d' "$tmp"
  # Служебный туннель не должен менять системный DNS на VPS-1.
  sed -i -E '/^DNS[[:space:]]*=/d' "$tmp"

  if ! grep -q '^\[Interface\]' "$tmp" || ! grep -q '^\[Peer\]' "$tmp"; then
    err "Конфиг должен содержать секции [Interface] и [Peer]."
    rm -f "$tmp"
    exit 1
  fi
  if ! grep -q '^PrivateKey[[:space:]]*=' "$tmp" || ! grep -q '^Endpoint[[:space:]]*=' "$tmp"; then
    err "Конфиг должен содержать параметры PrivateKey и Endpoint."
    rm -f "$tmp"
    exit 1
  fi
  if [[ "$(grep -c '^\[Peer\]' "$tmp")" -ne 1 ]]; then
    err "Конфиг должен содержать ровно одну секцию [Peer] для VPS-2."
    rm -f "$tmp"
    exit 1
  fi

  install -m 600 "$tmp" "$OUT_CONF"
  rm -f "$tmp"
}

sanitize_conf() {
  # Удаляем CRLF и лишние пробелы, которые могут мешать awg-quick.
  sed -i 's/\r$//' "$OUT_CONF"
  sed -i -E 's/^[[:space:]]+//; s/[[:space:]]+$//' "$OUT_CONF"
  chmod 600 "$OUT_CONF"
}

ensure_allowed_ips() {
  if grep -q '^AllowedIPs[[:space:]]*=' "$OUT_CONF"; then
    sed -i -E 's#^AllowedIPs[[:space:]]*=.*#AllowedIPs = 0.0.0.0/0, ::/0#' "$OUT_CONF"
  else
    sed -i '/^\[Peer\]/a AllowedIPs = 0.0.0.0/0, ::/0' "$OUT_CONF"
  fi
}

configure_out_conf() {
  local tmp
  tmp="$(mktemp)"

  # Не даём awg-quick добавить маршрут по умолчанию в основную таблицу.
  # Через туннель пойдёт только клиентская подсеть VPS-1.
  awk -v table_name="$TABLE_NAME" -v out_if="$OUT_IF" -v client_subnet="$CLIENT_SUBNET" '
    BEGIN { in_interface = 0; hooks_added = 0 }

    /^\[Interface\]$/ { in_interface = 1; print; next }

    /^\[Peer\]$/ {
      if (in_interface && !hooks_added) {
        print "Table = off"
        print "PostUp = ip route replace default dev " out_if " table " table_name "; while ip rule del from " client_subnet " table " table_name " 2>/dev/null; do :; done; ip rule add from " client_subnet " table " table_name "; iptables -t nat -C POSTROUTING -s " client_subnet " -o " out_if " -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s " client_subnet " -o " out_if " -j MASQUERADE"
        print "PostDown = while ip rule del from " client_subnet " table " table_name " 2>/dev/null; do :; done; ip route flush table " table_name " 2>/dev/null || true; iptables -t nat -D POSTROUTING -s " client_subnet " -o " out_if " -j MASQUERADE 2>/dev/null || true"
        hooks_added = 1
      }
      in_interface = 0
      print
      next
    }

    in_interface && /^Table[[:space:]]*=/ { next }
    in_interface && /^Post(Up|Down)[[:space:]]*=.*awg_cascade/ { next }
    /^# Added by awg-cascade$/ { next }
    /^Post(Up|Down)[[:space:]]*=.*awg_cascade/ { next }
    { print }
  ' "$OUT_CONF" > "$tmp"

  install -m 600 "$tmp" "$OUT_CONF"
  rm -f "$tmp"
}

add_table() {
  mkdir -p "$(dirname "$RT_TABLES")"
  touch "$RT_TABLES"
  if ! grep -Eq "^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}$" "$RT_TABLES"; then
    # Удаляем конфликтующие записи с таким именем или номером таблицы.
    sed -i -E "/^[[:space:]]*${TABLE_ID}[[:space:]]+/d; /[[:space:]]${TABLE_NAME}$/d" "$RT_TABLES"
    echo "${TABLE_ID} ${TABLE_NAME}" >> "$RT_TABLES"
  fi
}

enable_forwarding() {
  cat > "$SYSCTL_FILE" <<SYSCTL
net.ipv4.ip_forward=1
SYSCTL
  sysctl --system >/dev/null
}

make_rollback() {
  cat > "$ROLLBACK_FILE" <<EOFROLL
#!/usr/bin/env bash
set -e
systemctl disable --now awg-quick@${OUT_IF}.service 2>/dev/null || true
while ip rule del from ${CLIENT_SUBNET} table ${TABLE_NAME} 2>/dev/null; do :; done
ip route flush table ${TABLE_NAME} 2>/dev/null || true
iptables -t nat -D POSTROUTING -s ${CLIENT_SUBNET} -o ${OUT_IF} -j MASQUERADE 2>/dev/null || true
if [[ -f ${BACKUP_DIR}/99-awg-cascade.conf ]]; then
  cp -a ${BACKUP_DIR}/99-awg-cascade.conf ${SYSCTL_FILE}
else
  rm -f ${SYSCTL_FILE}
fi
sysctl --system >/dev/null || true
if [[ -f ${BACKUP_DIR}/${OUT_IF}.conf ]]; then
  cp -a ${BACKUP_DIR}/${OUT_IF}.conf ${OUT_CONF}
else
  rm -f ${OUT_CONF}
fi
if [[ -f ${BACKUP_DIR}/rt_tables ]]; then
  cp -a ${BACKUP_DIR}/rt_tables ${RT_TABLES}
else
  sed -i -E '/^[[:space:]]*${TABLE_ID}[[:space:]]+${TABLE_NAME}$/d' ${RT_TABLES}
fi
echo "Откат настроек каскада AWG завершён."
EOFROLL
  chmod +x "$ROLLBACK_FILE"
}

configure_routes() {
  ip route replace default dev "$OUT_IF" table "$TABLE_NAME"
  while ip rule del from "$CLIENT_SUBNET" table "$TABLE_NAME" 2>/dev/null; do :; done
  ip rule add from "$CLIENT_SUBNET" table "$TABLE_NAME"

  # Выполняем NAT клиентской подсети в выходной AWG-туннель.
  iptables -t nat -C POSTROUTING -s "$CLIENT_SUBNET" -o "$OUT_IF" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$CLIENT_SUBNET" -o "$OUT_IF" -j MASQUERADE

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

start_out_if() {
  systemctl enable "awg-quick@${OUT_IF}.service" >/dev/null 2>&1 || true
  if ! systemctl restart "awg-quick@${OUT_IF}.service"; then
    err "Не удалось запустить ${OUT_IF}. Проверьте: journalctl -u awg-quick@${OUT_IF} -xe"
    exit 1
  fi
  sleep 2
  if ! ip link show "$OUT_IF" >/dev/null 2>&1; then
    err "Интерфейс ${OUT_IF} не запустился. Проверьте: journalctl -u awg-quick@${OUT_IF} -xe"
    exit 1
  fi
}

check_exit_ip() {
  log "Проверяем подключение к Интернету через ${OUT_IF}..."
  if ping -I "$OUT_IF" -c 2 -W 3 1.1.1.1 >/dev/null 2>&1; then
    log "Ping через ${OUT_IF}: успешно"
  else
    warn "Ping через ${OUT_IF} не прошёл. Некоторые VPS блокируют ICMP, поэтому это не всегда ошибка."
  fi

  if cmd_exists curl; then
    local ip_out
    ip_out="$(curl --interface "$OUT_IF" -4 -s --max-time 8 https://ifconfig.me || true)"
    if [[ -n "$ip_out" ]]; then
      log "Выходной IPv4-адрес через ${OUT_IF}: ${ip_out}"
    else
      warn "Не удалось определить выходной IP через curl --interface ${OUT_IF}."
    fi
  else
    warn "Команда curl не найдена, проверка выходного IP пропущена."
  fi
}

main() {
  need_root
  require_cmds
  check_awg_on_vps1
  choose_conf_dir

  echo "=== Настройка каскада AWG: клиент -> VPS-1 -> VPS-2 -> Интернет ==="
  echo
  log "Скрипт добавит выходной туннель через VPS-2 к существующему серверу AWG."

  local interfaces
  interfaces="$(list_awg_interfaces)"
  echo
  echo "Обнаруженные AWG/WG-интерфейсы на VPS-1:"
  echo "${interfaces:-не найдены}"
  echo

  choose_client_subnet

  if ! valid_ipv4_subnet "$CLIENT_SUBNET"; then
    err "Некорректная подсеть IPv4: $CLIENT_SUBNET"
    exit 1
  fi

  backup
  read_multiline_config
  sanitize_conf
  ensure_allowed_ips
  configure_out_conf
  add_table
  enable_forwarding
  make_rollback
  start_out_if
  configure_routes
  check_exit_ip

  echo
  log "Каскад AWG настроен."
  echo "Трафик подсети ${CLIENT_SUBNET} будет направлен через ${OUT_IF} -> VPS-2."
  echo "Для отката выполните: bash ${ROLLBACK_FILE}"
}

main "$@"
