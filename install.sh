#!/usr/bin/env bash
# =============================================================================
#  Carry — личный VPN-сервер одной командой
#  VLESS + Reality (Xray-core), по желанию Hysteria2. Без веб-панели.
#
#  Установка (Ubuntu 22.04 / 24.04, от root):
#    bash <(curl -fsSL https://raw.githubusercontent.com/cookiefbi/carry/main/install.sh)
#
#  Лицензия: MIT
# =============================================================================
#
# Весь код лежит в функциях, а запуск стоит в последней строке. Bash читает
# файл целиком до вызова main, поэтому оборванная загрузка через curl не
# выполнит половину скрипта. Эти же функции потом сохраняются в
# /usr/local/bin/carry (через `declare -f`), так что команда `carry` — это
# тот же самый код.

carry_vars() {
  CARRY_VERSION="1.0.0"
  CARRY_DIR="/etc/carry"
  CARRY_CONF="$CARRY_DIR/carry.conf"
  CARRY_CLIENTS="$CARRY_DIR/clients"
  CARRY_TXT="/root/carry.txt"
  CARRY_LOG="/var/log/carry.log"
  CARRY_BIN="/usr/local/bin/carry"
  CARRY_LOCK="/run/carry.lock"

  XRAY_BIN="/usr/local/bin/xray"
  XRAY_DIR="/usr/local/etc/xray"
  XRAY_CONF="$XRAY_DIR/config.json"
  XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

  HY2_BIN="/usr/local/bin/hysteria"
  HY2_DIR="/etc/hysteria"
  HY2_CONF="$HY2_DIR/config.yaml"
  HY2_CERT="$HY2_DIR/carry.crt"
  HY2_KEY="$HY2_DIR/carry.key"
  HY2_INSTALL_URL="https://get.hy2.sh/"
  HY2_SERVICE="hysteria-server.service"

  # Сайты для маскировки Reality: крупные, TLS 1.3 + HTTP/2, не за Cloudflare.
  # www.microsoft.com и www.apple.com не берём: сам Xray предупреждает, что
  # с ними сервер чаще попадает под блокировку. Берётся первый сайт,
  # который отвечает с сервера. Свой сайт: --sni example.com
  SNI_CANDIDATES="www.samsung.com www.nvidia.com www.intel.com www.oracle.com"

  SHARE_TTL=900   # сколько секунд живёт временная ссылка `carry share`

  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
  export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
}

# ----------------------------------------------------------------------------
#  Вывод и журнал
# ----------------------------------------------------------------------------

ui_init() {
  if [[ -t 1 ]]; then
    B=$'\e[1m'; R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; N=$'\e[0m'
  else
    B=""; R=""; G=""; Y=""; C=""; D=""; N=""
  fi
  STEP_OPEN=0
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$CARRY_LOG" 2>/dev/null || true
}

say() { printf '%s\n' "$*"; log "$*"; }

step() {
  printf '%s→%s %s… ' "$C" "$N" "$1"
  STEP_OPEN=1
  log "ШАГ: $1"
}

ok() {
  printf '%s%s%s\n' "$G" "${1:-готово}" "$N"
  STEP_OPEN=0
}

warn() {
  ((STEP_OPEN)) && { printf '\n'; STEP_OPEN=0; }
  printf '%s! %s%s\n' "$Y" "$*" "$N" >&2
  log "ВНИМАНИЕ: $*"
}

die() {
  ((STEP_OPEN)) && printf '%sне получилось%s\n' "$R" "$N" >&2
  printf '\n%sОшибка:%s %s\n' "$R$B" "$N" "$*" >&2
  printf 'Подробности в журнале: %s\n' "$CARRY_LOG" >&2
  printf 'Запустите установку ещё раз — это безопасно, всё сделанное сохранится.\n\n' >&2
  log "ОШИБКА: $*"
  exit 1
}

# Запустить команду, весь её вывод — в журнал.
run() {
  log "КОМАНДА: $*"
  "$@" >>"$CARRY_LOG" 2>&1
}

# ----------------------------------------------------------------------------
#  Проверки окружения
# ----------------------------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    printf 'Нужны права root. Выполните сначала:  sudo -i\nи затем повторите команду.\n' >&2
    exit 1
  fi
}

init_log() {
  mkdir -p "$(dirname "$CARRY_LOG")"
  touch "$CARRY_LOG" && chmod 600 "$CARRY_LOG"
}

take_lock() {
  exec 9>"$CARRY_LOCK"
  flock -n 9 || die "Carry уже выполняется в другом окне. Дождитесь окончания и повторите."
}

check_os() {
  local force=$1
  [[ -r /etc/os-release ]] || die "Не удалось определить систему. Нужна Ubuntu 22.04 или 24.04."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    ubuntu:22.04|ubuntu:24.04) ;;
    ubuntu:26.04)
      warn "Ubuntu 26.04 официально не проверялась, но должна работать. Продолжаю." ;;
    *)
      if [[ $force == 1 ]]; then
        warn "Система ${PRETTY_NAME:-неизвестна} не поддерживается. Продолжаю из-за --force."
      else
        die "Carry работает на Ubuntu 22.04 и 24.04, а здесь ${PRETTY_NAME:-неизвестная система}.
Переустановите сервер на Ubuntu 24.04 в панели хостера (или добавьте --force на свой риск)."
      fi ;;
  esac
  command -v systemctl >/dev/null 2>&1 || die "Нет systemd. Нужна обычная Ubuntu, не контейнер."
  case "$(uname -m)" in
    x86_64|amd64|aarch64|arm64) ;;
    *) die "Процессор $(uname -m) не поддерживается (нужен x86_64 или arm64)." ;;
  esac
}

# Кто держит порт 443 (кроме xray/hysteria). Пусто — свободен.
port_owner() {
  local proto=$1 out
  if [[ $proto == tcp ]]; then
    out=$(ss -Htlnp 'sport = :443' 2>/dev/null)
  else
    out=$(ss -Hulnp 'sport = :443' 2>/dev/null)
  fi
  [[ -z $out ]] && return 0
  local other name
  other=$(grep -vE '"(xray|hysteria)"' <<<"$out")
  [[ -z $other ]] && return 0
  name=$(grep -oE 'users:\(\("[^"]+' <<<"$other" | head -n1 | cut -d'"' -f2)
  printf '%s' "${name:-неизвестная программа}"
  return 0
}

check_ports() {
  local hy2=$1 who
  who=$(port_owner tcp)
  [[ -n $who ]] && die "Порт 443/tcp уже занят программой «$who». Carry нужен этот порт.
Удалите или остановите её (например: systemctl disable --now $who) и повторите."
  if [[ $hy2 == 1 ]]; then
    who=$(port_owner udp)
    [[ -n $who ]] && die "Порт 443/udp уже занят программой «$who». Он нужен для Hysteria2."
  fi
  return 0
}

# Подождать, пока apt освободится: на свежем VPS в первые минуты
# часто идут автообновления.
wait_apt() {
  local i=0
  # Не путать с фоновым unattended-upgrade-shutdown, который висит всегда.
  while pgrep -x apt-get >/dev/null || pgrep -x apt >/dev/null || pgrep -x dpkg >/dev/null \
        || pgrep -f /usr/bin/unattended-upgrade >/dev/null; do
    if ((i == 0)); then
      ((STEP_OPEN)) && printf '\n'
      printf '  %sсистема ставит обновления, жду (до 10 минут)…%s ' "$D" "$N"
      STEP_OPEN=1
    fi
    ((i++ >= 120)) && return 0
    sleep 5
  done
}

apt_install() {
  local missing=() p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "install ok installed" || missing+=("$p")
  done
  ((${#missing[@]} == 0)) && return 0
  wait_apt
  run apt-get -o DPkg::Lock::Timeout=600 update -q || log "apt-get update завершился с ошибкой, пробую дальше"
  wait_apt
  run apt-get -o DPkg::Lock::Timeout=600 install -y -q --no-install-recommends \
    -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "${missing[@]}"
}

# Linux-консоль (веб-KVM хостера) по умолчанию часто не умеет кириллицу
# и символы ▀▄█ для QR. Пробуем включить подходящий шрифт.
is_vt() {
  local t
  t=$(tty 2>/dev/null) || return 1
  [[ $t == /dev/tty[0-9]* ]]
}

vt_font() {
  is_vt || return 0
  command -v setfont >/dev/null 2>&1 || return 0
  local f
  for f in "$@"; do
    if [[ -e /usr/share/consolefonts/$f.psf.gz ]] && setfont "/usr/share/consolefonts/$f.psf.gz" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

fix_console() {
  vt_font Uni2-TerminusBold16 Uni2-Terminus16 Uni2-Fixed16 || true
}

# ----------------------------------------------------------------------------
#  Состояние: /etc/carry/carry.conf и /etc/carry/clients
# ----------------------------------------------------------------------------

load_state() {
  [[ -f $CARRY_CONF ]] || return 1
  # shellcheck disable=SC1090
  . "$CARRY_CONF"
  : "${SERVER_HOST:=}" "${SNI:=}" "${PRIVATE_KEY:=}" "${PUBLIC_KEY:=}" "${HY2:=0}" "${HY2_OBFS:=}"
  touch "$CARRY_CLIENTS"
  return 0
}

save_state() {
  mkdir -p "$CARRY_DIR"
  chmod 700 "$CARRY_DIR"
  (
    umask 077
    {
      echo "# Carry $CARRY_VERSION — состояние сервера. Не публикуйте этот файл."
      printf 'SERVER_HOST=%q\n' "$SERVER_HOST"
      printf 'SNI=%q\n' "$SNI"
      printf 'PRIVATE_KEY=%q\n' "$PRIVATE_KEY"
      printf 'PUBLIC_KEY=%q\n' "$PUBLIC_KEY"
      printf 'HY2=%q\n' "$HY2"
      printf 'HY2_OBFS=%q\n' "$HY2_OBFS"
    } >"$CARRY_CONF.tmp"
  ) && mv -f "$CARRY_CONF.tmp" "$CARRY_CONF"
}

need_installed() {
  load_state || die "Carry ещё не установлен. Сначала выполните установку."
  [[ -s $CARRY_CLIENTS ]] || die "Список устройств пуст. Запустите установку ещё раз."
}

valid_name() { [[ $1 =~ ^[a-z0-9_-]{1,32}$ ]]; }

# Строка клиента: имя|uuid|shortId|пароль-hy2
client_line() { grep -m1 "^$1|" "$CARRY_CLIENTS" 2>/dev/null; }

first_client() { head -n1 "$CARRY_CLIENTS" | cut -d'|' -f1; }

client_names() { cut -d'|' -f1 "$CARRY_CLIENTS"; }

new_client() {
  local name=$1 uuid sid pass
  if [[ -x $XRAY_BIN ]]; then uuid=$("$XRAY_BIN" uuid 2>/dev/null); fi
  [[ $uuid =~ ^[0-9a-f-]{36}$ ]] || uuid=$(cat /proc/sys/kernel/random/uuid)
  sid=$(openssl rand -hex 4)
  pass=$(openssl rand -hex 16)
  printf '%s|%s|%s|%s\n' "$name" "$uuid" "$sid" "$pass" >>"$CARRY_CLIENTS"
  chmod 600 "$CARRY_CLIENTS"
}

host_for_uri() {
  if [[ $SERVER_HOST == *:* ]]; then printf '[%s]' "$SERVER_HOST"; else printf '%s' "$SERVER_HOST"; fi
}

vless_link() {
  local name uuid sid pass
  IFS='|' read -r name uuid sid pass <<<"$(client_line "$1")"
  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#Carry-%s' \
    "$uuid" "$(host_for_uri)" "$SNI" "$PUBLIC_KEY" "$sid" "$name"
}

hy2_link() {
  local name uuid sid pass
  IFS='|' read -r name uuid sid pass <<<"$(client_line "$1")"
  printf 'hy2://%s:%s@%s:443/?obfs=salamander&obfs-password=%s&sni=%s&insecure=1#Carry-%s-hy2' \
    "$name" "$pass" "$(host_for_uri)" "$HY2_OBFS" "$SNI" "$name"
}

# ----------------------------------------------------------------------------
#  Адрес сервера и сайт для маскировки
# ----------------------------------------------------------------------------

detect_ip() {
  local ip u
  for u in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]')
    if [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then printf '%s' "$ip"; return 0; fi
  done
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  if [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then printf '%s' "$ip"; return 0; fi
  ip=$(curl -6 -fsS --max-time 6 https://api64.ipify.org 2>/dev/null | tr -d '[:space:]')
  if [[ $ip == *:* ]]; then printf '%s' "$ip"; return 0; fi
  return 1
}

normalize_domain() {
  local d=${1,,}
  d=${d#http://}; d=${d#https://}; d=${d%%/*}; d=${d%%:*}
  printf '%s' "$d"
}

valid_domain() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Reality требует от сайта TLS 1.3 и HTTP/2. Проверяем прямо с сервера.
sni_ok() {
  local v
  v=$(curl -sS -o /dev/null --max-time 8 --tlsv1.3 --http2 -w '%{http_version}' "https://$1/" 2>/dev/null)
  [[ $v == 2 ]]
}

pick_sni() {
  local d
  for d in $SNI_CANDIDATES; do
    if sni_ok "$d"; then printf '%s' "$d"; return 0; fi
  done
  return 1
}

# ----------------------------------------------------------------------------
#  Xray (VLESS + Reality)
# ----------------------------------------------------------------------------

install_xray() {
  local script
  script=$(curl -fsSL --max-time 60 "$XRAY_INSTALL_URL") || return 1
  run bash -c "$script" @ install
}

gen_reality_keys() {
  local out
  out=$("$XRAY_BIN" x25519 2>&1) || return 1
  # Новый формат: "PrivateKey: …" / "Password (PublicKey): …"
  # Старый формат: "Private key: …" / "Public key: …"
  PRIVATE_KEY=$(awk -F': *' 'tolower($1) ~ /private/ {print $2; exit}' <<<"$out" | tr -d '[:space:]')
  PUBLIC_KEY=$(awk -F': *' 'tolower($1) ~ /password|public/ {print $2; exit}' <<<"$out" | tr -d '[:space:]')
  [[ $PRIVATE_KEY =~ ^[A-Za-z0-9_-]{43}$ && $PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]]
}

derive_public_key() {
  local out
  out=$("$XRAY_BIN" x25519 -i "$PRIVATE_KEY" 2>&1) || return 1
  PUBLIC_KEY=$(awk -F': *' 'tolower($1) ~ /password|public/ {print $2; exit}' <<<"$out" | tr -d '[:space:]')
  [[ $PUBLIC_KEY =~ ^[A-Za-z0-9_-]{43}$ ]]
}

render_xray() {
  local name uuid sid pass clients="" sids="" sep="" tmp
  while IFS='|' read -r name uuid sid pass; do
    [[ -z $name ]] && continue
    clients+="$sep"$'\n'"          { \"id\": \"$uuid\", \"flow\": \"xtls-rprx-vision\", \"email\": \"$name\" }"
    sids+="$sep\"$sid\""
    sep=","
  done <"$CARRY_CLIENTS"

  tmp=$(mktemp "$XRAY_DIR/carry-XXXXXX.json") || return 1
  cat >"$tmp" <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "carry-vless-reality",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [$clients
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "target": "$SNI:443",
          "serverNames": ["$SNI"],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [$sids]
        }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic"], "routeOnly": true }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" },
    { "tag": "block", "protocol": "blackhole" }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "ip": ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
               "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"],
        "outboundTag": "block"
      },
      { "type": "field", "protocol": ["bittorrent"], "outboundTag": "block" }
    ]
  }
}
EOF
  if ! run "$XRAY_BIN" run -test -c "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  mv -f "$tmp" "$XRAY_CONF"
  # Новые версии Xray работают от пользователя xray (каталог root:xray, 0640).
  if getent group xray >/dev/null; then
    chown root:xray "$XRAY_CONF"; chmod 640 "$XRAY_CONF"
  else
    chmod 644 "$XRAY_CONF"
  fi
}

restart_service() {
  local svc=$1 i
  run systemctl enable "$svc" || true
  run systemctl restart "$svc" || return 1
  for i in 1 2 3 4 5 6; do
    sleep 1
    systemctl is-active --quiet "$svc" && return 0
  done
  run journalctl -u "$svc" -n 30 --no-pager
  return 1
}

# ----------------------------------------------------------------------------
#  Hysteria2 (запасной протокол на 443/udp)
# ----------------------------------------------------------------------------

install_hy2() {
  local script
  script=$(curl -fsSL --max-time 60 "$HY2_INSTALL_URL") || return 1
  run bash -c "$script"
}

hy2_owner() {
  if id hysteria >/dev/null 2>&1; then echo hysteria; else echo root; fi
}

make_hy2_cert() {
  [[ -s $HY2_CERT && -s $HY2_KEY ]] && return 0
  mkdir -p "$HY2_DIR"
  run openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
    -keyout "$HY2_KEY" -out "$HY2_CERT" -days 3650 \
    -subj "/CN=$SNI" -addext "subjectAltName=DNS:$SNI"
}

render_hy2() {
  local name uuid sid pass users="" owner
  while IFS='|' read -r name uuid sid pass; do
    [[ -z $name ]] && continue
    users+=$'\n'"    \"$name\": \"$pass\""
  done <"$CARRY_CLIENTS"
  mkdir -p "$HY2_DIR"
  (
    umask 077
    cat >"$HY2_CONF.tmp" <<EOF
# Создано Carry. Файл перезаписывается при каждом изменении — не правьте вручную.
listen: :443

tls:
  cert: $HY2_CERT
  key: $HY2_KEY
  sniGuard: disable

auth:
  type: userpass
  userpass:$users

obfs:
  type: salamander
  salamander:
    password: "$HY2_OBFS"
EOF
  ) || return 1
  mv -f "$HY2_CONF.tmp" "$HY2_CONF"
  owner=$(hy2_owner)
  chown "$owner:$owner" "$HY2_CONF" "$HY2_CERT" "$HY2_KEY"
  chmod 600 "$HY2_CONF" "$HY2_KEY"
  chmod 644 "$HY2_CERT"
}

disable_hy2() {
  run systemctl disable --now "$HY2_SERVICE" || true
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
    run ufw delete allow 443/udp || true
  fi
}

# ----------------------------------------------------------------------------
#  Защита сервера
# ----------------------------------------------------------------------------

setup_firewall() {
  local hy2=$1 p ports
  ports=$(ss -Htlnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -u)
  for p in 22 $ports; do
    run ufw allow "$p/tcp" || return 1
  done
  run ufw allow 443/tcp || return 1
  if [[ $hy2 == 1 ]]; then run ufw allow 443/udp || return 1; fi
  run ufw --force enable
}

setup_bbr() {
  modprobe tcp_bbr >/dev/null 2>&1 || true
  cat >/etc/sysctl.d/99-carry.conf <<'EOF'
# Carry: BBR ускоряет TCP, большие буферы нужны Hysteria2 (QUIC).
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  run sysctl --system || true
  [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]
}

setup_autoupdates() {
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
  run systemctl enable --now unattended-upgrades || true
}

# Сохранить себя как команду `carry`.
install_self() {
  {
    echo '#!/usr/bin/env bash'
    echo "# Carry $CARRY_VERSION — команда управления личным VPN-сервером."
    echo "# Создано установщиком $(date '+%F %T'). Справка: carry help"
    echo 'set -uo pipefail'
    declare -f
    echo 'main "$@"'
  } >"$CARRY_BIN.tmp" && chmod 755 "$CARRY_BIN.tmp" && mv -f "$CARRY_BIN.tmp" "$CARRY_BIN"
}

# ----------------------------------------------------------------------------
#  Итоговый экран
# ----------------------------------------------------------------------------

banner_done() {
  if [[ ${LANG:-}${LC_ALL:-} == *[Uu][Tt][Ff]* ]] || [[ -z ${LANG:-}${LC_ALL:-} ]]; then
    printf '%s%s\n' "$G" "$B"
    printf '  █████   ███   █████   ███   ████    ███ \n'
    printf '  █      █   █    █    █   █  █   █  █   █\n'
    printf '  █      █   █    █    █   █  ████   █   █\n'
    printf '  █      █   █    █    █   █  █   █  █   █\n'
    printf '  █       ███     █     ███   ████    ███ \n'
    printf '%s\n' "$N"
  else
    printf '\n%s%s  ===  ГОТОВО  ===%s\n\n' "$G" "$B" "$N"
  fi
}

apps_text() {
  cat <<'EOF'
Какое приложение скачать:
  Android ............ v2rayNG или Hiddify (Google Play / GitHub)
  iPhone, iPad ....... Streisand или V2Box (App Store)
  Windows, Mac ....... Hiddify (hiddify.com)

Как добавить: в приложении нажмите «+» → «Сканировать QR-код»
или скопируйте ссылку и выберите «Импорт из буфера обмена».
EOF
}

commands_text() {
  cat <<'EOF'
Команды на сервере:
  carry show [имя]       показать QR-код снова
  carry add <имя>        ещё одно устройство или человек
  carry list             все устройства
  carry remove <имя>     отключить устройство
  carry share [имя]      короткая ссылка, если QR не сканируется
  carry uninstall        удалить всё
EOF
}

print_qr() {
  qrencode -t ansiutf8 -m 2 "$1" 2>/dev/null || {
    warn "Не удалось нарисовать QR-код. Используйте ссылку ниже или: carry share"
  }
}

# В веб-консоли (KVM) экран маленький: уменьшаем шрифт, чтобы QR влез.
fit_qr_on_vt() {
  is_vt || return 0
  local need rows
  need=$(( ($(qrencode -t ascii -m 2 "$1" 2>/dev/null | wc -l) + 1) / 2 + 3 ))
  rows=$(stty size 2>/dev/null </dev/tty | cut -d' ' -f1)
  [[ -n $rows ]] || return 0
  ((rows >= need)) && return 0
  vt_font Uni2-Terminus12x6 Uni2-VGA8 Uni2-Fixed13 Uni2-Terminus14 || true
}

# Ссылки и подсказки для одного устройства (без QR).
print_links() {
  local name=$1
  printf '%sУстройство:%s %s\n\n' "$B" "$N" "$name"
  printf '%sОсновная ссылка (VLESS + Reality):%s\n' "$B" "$N"
  vless_link "$name"; printf '\n'
  if [[ $HY2 == 1 ]]; then
    printf '\n%sЗапасная ссылка (Hysteria2) — если основная перестанет работать:%s\n' "$B" "$N"
    hy2_link "$name"; printf '\n'
  fi
  printf '\n'
}

print_summary() {
  local name=$1
  print_links "$name"
  apps_text
  printf '\n'
  commands_text
  printf '\nВсё это сохранено в файле %s\n\n' "$CARRY_TXT"
  fit_qr_on_vt "$(vless_link "$name")"
  print_qr "$(vless_link "$name")"
  printf '%s↑ Отсканируйте QR-код в приложении на телефоне.%s\n' "$B" "$N"
  printf 'Не сканируется или вы на телефоне? Скопируйте ссылку выше или выполните:  carry share\n\n'
}

write_txt() {
  local name
  (
    umask 077
    {
      echo "Carry — ваш личный VPN-сервер"
      echo "Адрес: $SERVER_HOST   Маскировка: $SNI   Создано: $(date '+%F %T')"
      echo "Храните этот файл в секрете: по ссылкам ниже можно подключиться к серверу."
      echo
      while read -r name; do
        [[ -z $name ]] && continue
        echo "=================================================================="
        echo "Устройство: $name"
        echo
        echo "Основная ссылка (VLESS + Reality):"
        vless_link "$name"; echo
        if [[ $HY2 == 1 ]]; then
          echo
          echo "Запасная ссылка (Hysteria2):"
          hy2_link "$name"; echo
        fi
        echo
        qrencode -t utf8 -m 2 "$(vless_link "$name")" 2>/dev/null
        echo
      done < <(client_names)
      echo "=================================================================="
      apps_text
      echo
      commands_text
    } >"$CARRY_TXT.tmp"
  ) && mv -f "$CARRY_TXT.tmp" "$CARRY_TXT"
}

# Применить текущий список устройств: конфиги, перезапуск, файл с итогами.
apply_clients() {
  step "Обновляю настройки Xray"
  render_xray || die "Xray не принял настройки. Это ошибка Carry — пришлите журнал разработчику."
  restart_service xray || die "Xray не запустился после изменения настроек."
  ok
  if [[ $HY2 == 1 ]]; then
    step "Обновляю настройки Hysteria2"
    render_hy2 || die "Не удалось записать настройки Hysteria2."
    restart_service "$HY2_SERVICE" || die "Hysteria2 не запустилась после изменения настроек."
    ok
  fi
  write_txt
}

# ----------------------------------------------------------------------------
#  Команды
# ----------------------------------------------------------------------------

usage() {
  cat <<EOF
Carry $CARRY_VERSION — личный VPN-сервер одной командой.

Установка или повторный запуск (безопасно):
  bash install.sh [--hy2] [--sni сайт] [--name имя] [--host адрес]

  --hy2          добавить запасной протокол Hysteria2 (443/udp)
  --no-hy2       выключить Hysteria2
  --sni сайт     сайт для маскировки, например www.apple.com
  --name имя     имя первого устройства (латиница, цифры, - и _)
  --host адрес   свой домен или IP вместо автоматически найденного
  --force        запускать даже не на Ubuntu 22.04/24.04

$(commands_text)
EOF
}

cmd_install() {
  local opt_hy2="" opt_sni="" opt_name="main" opt_host="" force=0 first_run=1 d who

  while (($#)); do
    case "$1" in
      --hy2|--hysteria|--hysteria2) opt_hy2=1 ;;
      --no-hy2) opt_hy2=0 ;;
      --sni|--site|--dest|--target)
        [[ -n ${2:-} ]] || die "После $1 укажите сайт, например: $1 www.apple.com"
        opt_sni=$(normalize_domain "$2"); shift ;;
      --sni=*) opt_sni=$(normalize_domain "${1#*=}") ;;
      --name)
        [[ -n ${2:-} ]] || die "После --name укажите имя устройства."
        opt_name=${2,,}; shift ;;
      --name=*) opt_name=${1#*=}; opt_name=${opt_name,,} ;;
      --host)
        [[ -n ${2:-} ]] || die "После --host укажите домен или IP."
        opt_host=$2; shift ;;
      --host=*) opt_host=${1#*=} ;;
      --force) force=1 ;;
      -h|--help) usage; return 0 ;;
      *) die "Непонятный параметр: $1. Справка: bash install.sh --help" ;;
    esac
    shift
  done

  require_root
  init_log
  take_lock
  fix_console
  log "===== Carry $CARRY_VERSION: установка, параметры: hy2=${opt_hy2:-как было} sni=${opt_sni:-авто} ====="

  printf '\n%sCarry %s%s — личный VPN-сервер. Займёт 1–3 минуты, вопросов не будет.\n\n' "$B" "$CARRY_VERSION" "$N"

  check_os "$force"
  [[ -n $opt_sni ]] && ! valid_domain "$opt_sni" && die "«$opt_sni» не похоже на адрес сайта. Пример: --sni www.apple.com"
  valid_name "$opt_name" || die "Имя «$opt_name» не подходит: только латиница, цифры, - и _, до 32 символов."

  if load_state; then
    first_run=0
    say "Carry уже установлен — проверяю и обновляю. Ключи и устройства сохраняются."
    echo
  else
    SERVER_HOST=""; SNI=""; PRIVATE_KEY=""; PUBLIC_KEY=""; HY2=0; HY2_OBFS=""
    mkdir -p "$CARRY_DIR"; chmod 700 "$CARRY_DIR"
    : >"$CARRY_CLIENTS"; chmod 600 "$CARRY_CLIENTS"
  fi
  [[ -n $opt_hy2 ]] && HY2=$opt_hy2

  check_ports "$HY2"

  step "Устанавливаю нужные программы"
  apt_install curl ca-certificates openssl qrencode ufw unattended-upgrades python3 iproute2 kbd \
    || die "Не удалось установить пакеты. Проверьте интернет на сервере и повторите."
  ok

  step "Определяю адрес сервера"
  if [[ -n $opt_host ]]; then
    SERVER_HOST=$opt_host
  elif [[ -z $SERVER_HOST ]]; then
    SERVER_HOST=$(detect_ip) || die "Не удалось узнать внешний IP-адрес. Укажите его вручную: --host 1.2.3.4"
  fi
  ok "$SERVER_HOST"

  step "Выбираю сайт для маскировки"
  if [[ -n $opt_sni ]]; then
    sni_ok "$opt_sni" || die "Сайт $opt_sni не подходит: с сервера он не открывается по TLS 1.3 + HTTP/2.
Выберите другой (например www.apple.com) или запустите без --sni."
    SNI=$opt_sni
  elif [[ -z $SNI ]]; then
    if ! SNI=$(pick_sni); then
      SNI=${SNI_CANDIDATES%% *}
      warn "Ни один сайт из списка не ответил с сервера. Беру $SNI — если не заработает, укажите --sni."
    fi
  fi
  ok "$SNI"

  step "Устанавливаю Xray (официальный скрипт XTLS)"
  install_xray || die "Не удалось установить Xray. Проверьте, что сервер видит github.com, и повторите."
  [[ -x $XRAY_BIN ]] || die "Xray не найден после установки."
  ok "$("$XRAY_BIN" version 2>/dev/null | head -n1 | awk '{print $1" "$2}')"

  step "Готовлю ключи"
  if [[ -z $PRIVATE_KEY ]]; then
    gen_reality_keys || die "Не удалось создать ключи Reality."
  elif [[ -z $PUBLIC_KEY ]]; then
    derive_public_key || die "Не удалось восстановить публичный ключ Reality."
  fi
  if [[ ! -s $CARRY_CLIENTS ]]; then
    new_client "$opt_name"
  fi
  if [[ $HY2 == 1 && -z $HY2_OBFS ]]; then
    HY2_OBFS=$(openssl rand -hex 16)
  fi
  save_state || die "Не удалось сохранить настройки в $CARRY_DIR."
  ok

  if [[ $HY2 == 1 ]]; then
    step "Устанавливаю Hysteria2 (официальный скрипт)"
    install_hy2 || die "Не удалось установить Hysteria2. Проверьте доступ к get.hy2.sh и github.com."
    [[ -x $HY2_BIN ]] || die "Hysteria2 не найдена после установки."
    make_hy2_cert || die "Не удалось создать сертификат для Hysteria2."
    ok
  elif [[ -f $HY2_CONF ]] && systemctl is-enabled --quiet "$HY2_SERVICE" 2>/dev/null; then
    step "Выключаю Hysteria2"
    disable_hy2
    ok
  fi

  apply_clients

  step "Настраиваю файрвол (ufw)"
  setup_firewall "$HY2" || die "Не удалось настроить ufw."
  ok

  step "Включаю BBR"
  if setup_bbr; then ok; else ok "ядро не поддерживает, пропускаю"; fi

  step "Включаю автоматические обновления безопасности"
  setup_autoupdates
  ok

  install_self || warn "Не удалось создать команду carry в $CARRY_BIN."
  save_state

  # Проверка, что Xray действительно слушает 443.
  who=$(ss -Htlnp 'sport = :443' 2>/dev/null)
  grep -q '"xray"' <<<"$who" || warn "Xray запущен, но порт 443 не слушает. Смотрите: journalctl -u xray"

  log "Установка завершена (первый запуск: $first_run)"
  banner_done
  d=$(first_client)
  print_summary "$d"
}

cmd_show() {
  local name="" proto="vless" link
  while (($#)); do
    case "$1" in
      hy2|--hy2|hysteria|hysteria2) proto=hy2 ;;
      *) name=${1,,} ;;
    esac
    shift
  done
  require_root
  need_installed
  [[ -n $name ]] || name=$(first_client)
  valid_name "$name" && client_line "$name" >/dev/null || die "Устройства «$name» нет. Список: carry list"
  if [[ $proto == hy2 ]]; then
    [[ $HY2 == 1 ]] || die "Hysteria2 не включена. Включить: запустите установку с --hy2"
    link=$(hy2_link "$name")
  else
    link=$(vless_link "$name")
  fi
  fix_console
  if is_vt; then
    # В веб-консоли показываем только QR, чтобы он влез в экран целиком.
    clear
    fit_qr_on_vt "$link"
    print_qr "$link"
    printf '%s — %s. Ссылки текстом: cat %s\n' "$name" "$proto" "$CARRY_TXT"
    return 0
  fi
  echo
  print_links "$name"
  print_qr "$link"
  printf '%s↑ Отсканируйте QR-код в приложении.%s Не сканируется? carry share %s\n\n' "$B" "$N" "$name"
}

cmd_add() {
  local name=${1:-}
  name=${name,,}
  require_root
  init_log
  take_lock
  need_installed
  [[ -n $name ]] || die "Укажите имя, например:  carry add mama"
  valid_name "$name" || die "Имя «$name» не подходит: только латиница, цифры, - и _, до 32 символов."
  client_line "$name" >/dev/null && die "Устройство «$name» уже есть. Показать его: carry show $name"
  log "Добавляю устройство $name"
  new_client "$name"
  apply_clients
  echo
  say "${G}Добавлено устройство «$name».${N}"
  echo
  print_links "$name"
  fit_qr_on_vt "$(vless_link "$name")"
  print_qr "$(vless_link "$name")"
  printf '%s↑ Отсканируйте QR-код на новом устройстве.%s Не сканируется? carry share %s\n\n' "$B" "$N" "$name"
}

cmd_remove() {
  local name=${1:-}
  name=${name,,}
  require_root
  init_log
  take_lock
  need_installed
  [[ -n $name ]] || die "Укажите имя, например:  carry remove mama"
  valid_name "$name" && client_line "$name" >/dev/null || die "Устройства «$name» нет. Список: carry list"
  (($(wc -l <"$CARRY_CLIENTS") > 1)) || die "Это последнее устройство. Удалить сервер целиком: carry uninstall"
  log "Удаляю устройство $name"
  grep -v "^$name|" "$CARRY_CLIENTS" >"$CARRY_CLIENTS.tmp" && mv -f "$CARRY_CLIENTS.tmp" "$CARRY_CLIENTS"
  chmod 600 "$CARRY_CLIENTS"
  apply_clients
  say "${G}Устройство «$name» отключено.${N} Его ссылки больше не работают."
}

cmd_list() {
  require_root
  need_installed
  printf '%sУстройства на сервере %s:%s\n' "$B" "$SERVER_HOST" "$N"
  client_names | sed 's/^/  • /'
  printf '\nПоказать QR: carry show <имя>\n'
}

# Запасной вариант, если QR не сканируется: короткая временная ссылка.
# Поднимает на 15 минут крошечный веб-сервер на случайном порту.
# Ссылки отдаются в base64 (формат «подписки»), а в браузере — страницей,
# где ссылка собирается уже на телефоне. Так текст vless:// не идёт по сети открыто.
cmd_share() {
  local name=${1:-} port token tmp links png ufw_on=0 l
  name=${name,,}
  require_root
  init_log
  need_installed
  [[ -n $name ]] || name=$(first_client)
  valid_name "$name" && client_line "$name" >/dev/null || die "Устройства «$name» нет. Список: carry list"
  command -v python3 >/dev/null || die "Нужен python3: apt install python3"

  port=$(shuf -i 20000-60999 -n 1)
  token=$(openssl rand -hex 3)
  tmp=$(mktemp -d)
  chmod 700 "$tmp"

  links=$(vless_link "$name")
  [[ $HY2 == 1 ]] && links+=$'\n'$(hy2_link "$name")
  printf '%s\n' "$links" | base64 -w0 >"$tmp/sub"

  {
    cat <<'EOF'
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Carry</title><style>
body{font-family:system-ui,-apple-system,sans-serif;max-width:560px;margin:0 auto;padding:16px;background:#f6f6f4;color:#111}
h1{font-size:22px}.card{background:#fff;border-radius:12px;padding:16px;margin:16px 0;box-shadow:0 1px 3px #0002}
img{width:100%;max-width:320px;display:block;margin:8px auto;image-rendering:pixelated}
textarea{width:100%;box-sizing:border-box;height:110px;font:12px monospace;word-break:break-all}
button{width:100%;padding:14px;font-size:17px;border:0;border-radius:10px;background:#1a7f37;color:#fff;margin-top:8px}
p{line-height:1.45}
</style></head><body><h1>Carry — подключение</h1>
<p>Скопируйте ссылку и в приложении (v2rayNG, Hiddify, Streisand, V2Box) выберите
«Импорт из буфера обмена». С другого устройства можно отсканировать QR-код.</p>
EOF
    while IFS= read -r l; do
      [[ -z $l ]] && continue
      png=$(qrencode -t PNG -s 6 -m 2 -o - "$l" | base64 -w0)
      printf '<div class="card"><b>%s</b><img alt="QR" src="data:image/png;base64,%s">' \
        "$( [[ $l == vless* ]] && echo 'Основная (VLESS + Reality)' || echo 'Запасная (Hysteria2)')" "$png"
      printf '<textarea readonly data-b="%s"></textarea><button>Скопировать</button></div>\n' \
        "$(printf '%s' "$l" | base64 -w0)"
    done <<<"$links"
    cat <<'EOF'
<script>
document.querySelectorAll('textarea').forEach(function(t){t.value=atob(t.dataset.b);});
document.querySelectorAll('button').forEach(function(b){b.onclick=function(){
var t=b.previousElementSibling;t.focus();t.select();t.setSelectionRange(0,99999);
var ok=false;try{ok=document.execCommand('copy');}catch(e){}
if(!ok&&navigator.clipboard){navigator.clipboard.writeText(t.value);ok=true;}
b.textContent=ok?'Скопировано ✓':'Выделите текст и скопируйте вручную';};});
</script></body></html>
EOF
  } >"$tmp/page"

  if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
    run ufw allow "$port/tcp" comment 'carry share' && ufw_on=1
  fi
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; [[ $ufw_on == 1 ]] && ufw delete allow $port/tcp >/dev/null 2>&1; echo" EXIT
  trap 'exit 0' INT TERM

  echo
  printf '%sВременная ссылка для «%s» (работает %d минут):%s\n\n' "$B" "$name" $((SHARE_TTL / 60)) "$N"
  printf '   %shttp://%s:%s/%s%s\n\n' "$B$G" "$(host_for_uri)" "$port" "$token" "$N"
  cat <<EOF
Как пользоваться:
  • Откройте её в браузере телефона, нажмите «Скопировать»,
    затем в приложении — «Импорт из буфера обмена».
  • Или вставьте её в приложение как подписку
    («Добавить подписку» / «Import from URL»).

Если хостер включил свой файрвол в панели, порт $port может быть закрыт.
Когда устройство подключится, нажмите Ctrl+C. Ссылка перестанет работать.
EOF
  echo
  log "carry share: устройство $name, порт $port"
  python3 - "$port" "$token" "$tmp/sub" "$tmp/page" "$SHARE_TTL" <<'PY'
import sys, threading, http.server, socketserver
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass
port, token, sub_path, page_path, ttl = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
sub = open(sub_path, 'rb').read()
page = open(page_path, 'rb').read()

class H(http.server.BaseHTTPRequestHandler):
    server_version = "nginx"
    sys_version = ""
    def log_message(self, *a):
        pass
    def do_GET(self):
        p = self.path.split('?')[0].rstrip('/')
        if p == '/' + token + '/sub':
            body, ct = sub, 'text/plain; charset=utf-8'
        elif p == '/' + token:
            if 'text/html' in self.headers.get('Accept', ''):
                body, ct = page, 'text/html; charset=utf-8'
            else:
                body, ct = sub, 'text/plain; charset=utf-8'
        else:
            self.send_response(404)
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Type', ct)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'no-store')
        self.end_headers()
        self.wfile.write(body)
        kind = 'страница' if ct.startswith('text/html') else 'подписка'
        print('  ✓ ссылку открыли (%s) с %s' % (kind, self.client_address[0]), flush=True)

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

try:
    srv = S(('', port), H)
except OSError as e:
    print('Не удалось открыть порт %d: %s' % (port, e))
    sys.exit(1)
t = threading.Timer(ttl, srv.shutdown)
t.daemon = True
t.start()
try:
    srv.serve_forever()
except KeyboardInterrupt:
    pass
print('Ссылка закрыта.')
PY
}

cmd_uninstall() {
  local yes=0 a
  [[ ${1:-} == -y || ${1:-} == --yes ]] && yes=1
  require_root
  init_log
  take_lock
  if [[ $yes == 0 && -t 0 ]]; then
    printf 'Удалить Carry, Xray, Hysteria2 и все ссылки? Устройства перестанут подключаться. [y/N] '
    read -r a
    [[ $a == [yYдД]* ]] || { echo "Отменено."; return 0; }
  fi
  log "===== Удаление Carry ====="

  step "Удаляю Hysteria2"
  run systemctl disable --now "$HY2_SERVICE" || true
  if [[ -x $HY2_BIN ]]; then
    local s
    s=$(curl -fsSL --max-time 60 "$HY2_INSTALL_URL" 2>/dev/null) && run bash -c "$s" @ --remove || true
  fi
  rm -f "$HY2_BIN" /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
  rm -rf "$HY2_DIR"
  ok

  step "Удаляю Xray"
  run systemctl disable --now xray || true
  if [[ -x $XRAY_BIN ]]; then
    local x
    x=$(curl -fsSL --max-time 60 "$XRAY_INSTALL_URL" 2>/dev/null) && run bash -c "$x" @ remove --purge || true
  fi
  rm -f "$XRAY_BIN" /etc/systemd/system/xray.service /etc/systemd/system/xray@.service
  rm -rf "$XRAY_DIR" /usr/local/share/xray /var/log/xray
  run systemctl daemon-reload || true
  ok

  step "Закрываю порты 443"
  if command -v ufw >/dev/null; then
    run ufw delete allow 443/tcp || true
    run ufw delete allow 443/udp || true
  fi
  ok

  rm -rf "$CARRY_DIR" "$CARRY_TXT" /etc/sysctl.d/99-carry.conf
  rm -f "$CARRY_BIN"
  log "Carry удалён"
  echo
  say "${G}Carry удалён.${N} Файрвол ufw оставлен включённым (SSH открыт), автообновления тоже."
  say "Журнал остался: $CARRY_LOG"
}

main() {
  carry_vars
  ui_init
  local cmd=${1:-install}
  case "$cmd" in
    help|-h|--help)      usage ;;
    version|--version)   echo "Carry $CARRY_VERSION" ;;
    install)             shift || true; cmd_install "$@" ;;
    -*)                  cmd_install "$@" ;;
    show|qr)             shift; cmd_show "$@" ;;
    add|new)             shift; cmd_add "$@" ;;
    list|ls)             cmd_list ;;
    remove|rm|del|delete) shift; cmd_remove "$@" ;;
    share|link)          shift; cmd_share "$@" ;;
    uninstall)           shift; cmd_uninstall "$@" ;;
    *)                   die "Неизвестная команда «$cmd». Справка: carry help" ;;
  esac
}

set -uo pipefail
main "$@"
