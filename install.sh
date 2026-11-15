#!/usr/bin/env bash
#
# Telegram Proxy Manager  v1.0
#
#   1) MTProto proxy + FakeTLS            -> mtg            (github.com/9seconds/mtg)
#   2) Telegram Web (WebSocket) proxy     -> tg-ws-proxy-rs (github.com/valnesfjord/tg-ws-proxy-rs)
#
# Menu: install / status / uninstall.  Port is always asked manually.
# Needs: root, systemd, curl, tar (missing tools are installed automatically).
# Optional env: GH_PROXY=https://your-mirror/   (prefix for GitHub download URLs)
#
set -uo pipefail

# ----------------------------- settings -------------------------------------
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
CONF_DIR="${CONF_DIR:-/etc/tgproxy}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
SVC_USER="tgproxy"

MTG_SVC="tgproxy-mtg"
WS_SVC="tgproxy-ws"
MTG_BIN="$BIN_DIR/mtg"
WS_BIN="$BIN_DIR/tg-ws-proxy"
MTG_CONF="$CONF_DIR/mtg.toml"
MTG_INFO="$CONF_DIR/mtg.info"
WS_ENV="$CONF_DIR/ws.env"
WS_INFO="$CONF_DIR/ws.info"

MTG_REPO="9seconds/mtg"
WS_REPO="valnesfjord/tg-ws-proxy-rs"
MTG_FALLBACK_VER="2.3.0"                       # used only if "latest" can't be resolved
DEFAULT_FAKE_DOMAIN="${DEFAULT_FAKE_DOMAIN:-www.cloudflare.com}"
GH_PROXY="${GH_PROXY:-}"
WORK=""

# ----------------------------- helpers --------------------------------------
if [[ -t 1 ]]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
else
  R=""; G=""; Y=""; C=""; B=""; N=""
fi

info() { echo -e "${C}[*]${N} $*"; }
ok()   { echo -e "${G}[+]${N} $*"; }
warn() { echo -e "${Y}[!]${N} $*"; }
err()  { echo -e "${R}[x]${N} $*" >&2; }
pause() { echo; read -r -p "Press Enter to return to the menu..." _ || true; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    err "Run as root:  sudo bash $0"
    exit 1
  fi
}

need_systemd() {
  if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d /run/systemd/system ]]; then
    err "systemd is required (systemctl not found / not running)."
    exit 1
  fi
}

pkg_install() {
  # $@ = package names
  if   command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" >/dev/null 2>&1
  elif command -v dnf     >/dev/null 2>&1; then dnf install -y -q "$@" >/dev/null 2>&1
  elif command -v yum     >/dev/null 2>&1; then yum install -y -q "$@" >/dev/null 2>&1
  elif command -v apk     >/dev/null 2>&1; then apk add --no-cache "$@" >/dev/null 2>&1
  else return 1
  fi
}

ensure_deps() {
  local missing=()
  command -v curl    >/dev/null 2>&1 || missing+=(curl)
  command -v tar     >/dev/null 2>&1 || missing+=(tar)
  command -v openssl >/dev/null 2>&1 || missing+=(openssl)
  command -v sha256sum >/dev/null 2>&1 || missing+=(coreutils)
  if ((${#missing[@]})); then
    info "Installing missing packages: ${missing[*]}"
    pkg_install ca-certificates "${missing[@]}" || { err "Could not install: ${missing[*]} (install them manually)."; return 1; }
  fi
  return 0
}

# arch name per project
detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  MTG_ARCH="amd64"; WS_TARGET="x86_64-unknown-linux-musl" ;;
    aarch64|arm64) MTG_ARCH="arm64"; WS_TARGET="aarch64-unknown-linux-musl" ;;
    armv7l|armv7)  MTG_ARCH="armv7"; WS_TARGET="armv7-unknown-linux-musleabihf" ;;
    *) err "Unsupported CPU architecture: $(uname -m)"; return 1 ;;
  esac
}

gh_url() { echo "${GH_PROXY}$1"; }

download() {
  # download <url> <out>
  local url="$1" out="$2" i
  for i in 1 2 3; do
    if curl -fsSL --connect-timeout 15 --max-time 180 -o "$out" "$(gh_url "$url")"; then return 0; fi
    warn "Download failed (try $i/3): $url"
    sleep 2
  done
  return 1
}

latest_tag() {
  # resolves the latest release tag through the redirect (no GitHub API -> no rate limit)
  curl -fsSIL --connect-timeout 15 --max-time 30 -o /dev/null -w '%{url_effective}' \
    "https://github.com/$1/releases/latest" 2>/dev/null | sed -n 's#.*/tag/##p'
}

verify_sha256() {
  # verify_sha256 <file> <sums-file> <name-in-sums>
  local file="$1" sums="$2" name="$3" want got
  want="$(awk -v n="$name" '$2==n || $2=="*"n {print $1; exit}' "$sums")"
  [[ -n "$want" ]] || { warn "No checksum entry for $name - skipping verification."; return 0; }
  got="$(sha256sum "$file" | awk '{print $1}')"
  if [[ "$want" != "$got" ]]; then
    err "Checksum mismatch for $name (expected $want, got $got)."
    return 1
  fi
  ok "Checksum OK ($name)"
}

get_public_ip() {
  local svc ip
  for svc in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com https://ipv4.icanhazip.com https://checkip.amazonaws.com; do
    ip="$(curl -4 -fsS --max-time 6 "$svc" 2>/dev/null | tr -d '[:space:]')"
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then echo "$ip"; return 0; fi
  done
  return 1
}

ask_public_ip() {
  local ip
  ip="$(get_public_ip)" || ip=""
  if [[ -z "$ip" ]]; then
    warn "Could not detect the public IP automatically."
    while true; do
      read -r -p "Enter the server public IPv4: " ip
      [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
      err "Invalid IPv4."
    done
  fi
  PUBLIC_IP="$ip"
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltn "sport = :$p" 2>/dev/null | grep -q .
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null
  fi
}

info_get() { # info_get <file> <key>
  [[ -f "$1" ]] && sed -n "s/^$2=//p" "$1" | head -1
}

ask_port() {
  # ask_port <default> <other-service-port-to-avoid>
  local def="$1" avoid="${2:-}" p
  while true; do
    read -r -p "Proxy port [$def]: " p
    p="${p:-$def}"
    if ! [[ "$p" =~ ^[0-9]+$ ]] || ((p < 1 || p > 65535)); then err "Port must be 1-65535."; continue; fi
    if [[ -n "$avoid" && "$p" == "$avoid" ]]; then err "Port $p is used by the other proxy of this script."; continue; fi
    if port_in_use "$p"; then err "Port $p is already in use by another process."; continue; fi
    PORT="$p"; return 0
  done
}

ask_domain() {
  local d
  while true; do
    read -r -p "FakeTLS domain (must be a real HTTPS site) [$1]: " d
    d="${d:-$1}"
    if [[ "$d" =~ ^([A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?\.)+[A-Za-z]{2,}$ ]]; then DOMAIN="${d,,}"; return 0; fi
    err "Invalid domain."
  done
}

hex_of() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

fw_open() {
  local p="$1"
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "$p"/tcp >/dev/null 2>&1 && info "ufw: opened $p/tcp"
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --add-port="$p"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1 && info "firewalld: opened $p/tcp"
  fi
}

fw_close() {
  local p="$1"
  [[ -n "$p" ]] || return 0
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw delete allow "$p"/tcp >/dev/null 2>&1
  fi
  if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
    firewall-cmd --permanent --remove-port="$p"/tcp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1
  fi
}

ensure_user() {
  id "$SVC_USER" >/dev/null 2>&1 && return 0
  useradd --system --no-create-home --shell /usr/sbin/nologin "$SVC_USER" 2>/dev/null \
    || useradd -r -M -s /sbin/nologin "$SVC_USER" 2>/dev/null \
    || { err "Could not create system user $SVC_USER"; return 1; }
}

wait_listen() {
  # wait_listen <port> <service>
  local i
  for i in $(seq 1 15); do
    port_in_use "$1" && return 0
    systemctl is-active --quiet "$2" || return 1
    sleep 1
  done
  return 1
}

print_links() {
  # print_links <ip> <port> <secret>
  local ip="$1" port="$2" secret="$3"
  echo
  echo -e "${B}================= Telegram proxy =================${N}"
  echo -e "Server : ${G}$ip${N}"
  echo -e "Port   : ${G}$port${N}"
  echo -e "Secret : ${G}$secret${N}"
  echo
  echo -e "${B}Open in Telegram (tap the link):${N}"
  echo -e "  ${G}tg://proxy?server=$ip&port=$port&secret=$secret${N}"
  echo -e "  ${G}https://t.me/proxy?server=$ip&port=$port&secret=$secret${N}"
  echo -e "${B}==================================================${N}"
}

# ----------------------------- 1) MTProto + FakeTLS --------------------------
install_mtg() {
  WORK="$(mktemp -d)"
  do_install_mtg
  local rc=$?
  rm -rf "$WORK"
  return $rc
}

do_install_mtg() {
  local a
  detect_arch || return 1
  ensure_deps || return 1

  if [[ -f "$MTG_INFO" ]]; then
    warn "MTProto proxy is already installed."
    read -r -p "Reinstall (new secret/port)? [y/N]: " a
    [[ "${a,,}" == "y" ]] || return 0
    remove_mtg quiet
  fi
  ensure_user || return 1

  local wsport; wsport="$(info_get "$WS_INFO" PORT)"
  ask_port 443 "$wsport"
  ask_domain "$DEFAULT_FAKE_DOMAIN"
  ask_public_ip

  local tag ver tmp
  tag="$(latest_tag "$MTG_REPO")"
  [[ -n "$tag" ]] || { warn "Could not resolve latest mtg tag, using v$MTG_FALLBACK_VER"; tag="v$MTG_FALLBACK_VER"; }
  ver="${tag#v}"
  tmp="$WORK"

  info "Downloading mtg $ver ($MTG_ARCH) ..."
  local base="https://github.com/$MTG_REPO/releases/download/$tag"
  local pkg="mtg-$ver-linux-$MTG_ARCH.tar.gz"
  download "$base/$pkg" "$tmp/$pkg" || { err "Download failed."; return 1; }
  if download "$base/mtg-$ver-checksums.txt" "$tmp/sums.txt"; then
    verify_sha256 "$tmp/$pkg" "$tmp/sums.txt" "$pkg" || return 1
  else
    warn "Checksum file not available - skipping verification."
  fi
  tar -xzf "$tmp/$pkg" -C "$tmp" || { err "Extract failed."; return 1; }
  local found; found="$(find "$tmp" -type f -name mtg | head -1)"
  [[ -n "$found" ]] || { err "mtg binary not found in archive."; return 1; }
  install -m 0755 "$found" "$MTG_BIN" || return 1

  local secret; secret="$("$MTG_BIN" generate-secret --hex "$DOMAIN" 2>/dev/null | tr -d '[:space:]')"
  [[ "$secret" == ee* ]] || { err "Secret generation failed."; return 1; }

  mkdir -p "$CONF_DIR"
  cat > "$MTG_CONF" <<EOF
secret = "$secret"
bind-to = "0.0.0.0:$PORT"
prefer-ip = "prefer-ipv4"
EOF
  chown root:"$SVC_USER" "$MTG_CONF" && chmod 0640 "$MTG_CONF" || { err "Could not set permissions on $MTG_CONF"; return 1; }
  cat > "$MTG_INFO" <<EOF
PORT=$PORT
IP=$PUBLIC_IP
DOMAIN=$DOMAIN
SECRET=$secret
EOF
  chmod 0600 "$MTG_INFO"

  cat > "$UNIT_DIR/$MTG_SVC.service" <<EOF
[Unit]
Description=MTProto proxy with FakeTLS (mtg)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
ExecStart=$MTG_BIN run $MTG_CONF
Restart=always
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$MTG_SVC" >/dev/null 2>&1
  fw_open "$PORT"

  if wait_listen "$PORT" "$MTG_SVC"; then
    ok "MTProto (FakeTLS) proxy is running."
    print_links "$PUBLIC_IP" "$PORT" "$secret"
    echo "Note: if the link does not connect from your network, also open TCP $PORT in your cloud provider's firewall panel."
  else
    err "Service did not start. Logs:  journalctl -u $MTG_SVC -n 30 --no-pager"
    journalctl -u "$MTG_SVC" -n 15 --no-pager 2>/dev/null
    return 1
  fi
}

remove_mtg() {
  local quiet="${1:-}"
  local port; port="$(info_get "$MTG_INFO" PORT)"
  systemctl disable --now "$MTG_SVC" >/dev/null 2>&1
  rm -f "$UNIT_DIR/$MTG_SVC.service" "$MTG_BIN" "$MTG_CONF" "$MTG_INFO"
  systemctl daemon-reload >/dev/null 2>&1
  fw_close "$port"
  [[ "$quiet" == "quiet" ]] || ok "MTProto proxy removed."
  cleanup_if_empty
}

# ----------------------------- 2) Telegram Web (WS) proxy --------------------
install_ws() {
  WORK="$(mktemp -d)"
  do_install_ws
  local rc=$?
  rm -rf "$WORK"
  return $rc
}

do_install_ws() {
  local a
  detect_arch || return 1
  ensure_deps || return 1

  if [[ -f "$WS_INFO" ]]; then
    warn "Telegram Web proxy is already installed."
    read -r -p "Reinstall (new secret/port)? [y/N]: " a
    [[ "${a,,}" == "y" ]] || return 0
    remove_ws quiet
  fi
  ensure_user || return 1

  local mtgport; mtgport="$(info_get "$MTG_INFO" PORT)"
  ask_port 8443 "$mtgport"
  ask_public_ip

  local faketls="" ; DOMAIN=""
  read -r -p "Also enable FakeTLS (ee) on the inbound side? [y/N]: " a
  if [[ "${a,,}" == "y" ]]; then ask_domain "$DEFAULT_FAKE_DOMAIN"; faketls="$DOMAIN"; fi

  local tmp="$WORK"
  local pkg="tg-ws-proxy-$WS_TARGET.tar.gz"
  local base="https://github.com/$WS_REPO/releases/latest/download"
  info "Downloading tg-ws-proxy-rs ($WS_TARGET) ..."
  download "$base/$pkg" "$tmp/$pkg" || { err "Download failed."; return 1; }
  if download "$base/SHA256SUMS" "$tmp/sums.txt"; then
    verify_sha256 "$tmp/$pkg" "$tmp/sums.txt" "$pkg" || return 1
  else
    warn "SHA256SUMS not available - skipping verification."
  fi
  tar -xzf "$tmp/$pkg" -C "$tmp" || { err "Extract failed."; return 1; }
  local found; found="$(find "$tmp" -type f -name 'tg-ws-proxy' | head -1)"
  [[ -n "$found" ]] || { err "tg-ws-proxy binary not found in archive."; return 1; }
  install -m 0755 "$found" "$WS_BIN" || return 1

  local key; key="$(openssl rand -hex 16)"
  local extra=""; [[ -n "$faketls" ]] && extra="--listen-faketls-domain $faketls"

  mkdir -p "$CONF_DIR"
  cat > "$WS_ENV" <<EOF
PORT=$PORT
SECRET=$key
LINK_IP=$PUBLIC_IP
EXTRA_ARGS=$extra
EOF
  chown root:"$SVC_USER" "$WS_ENV" && chmod 0640 "$WS_ENV" || { err "Could not set permissions on $WS_ENV"; return 1; }

  local secret_link="dd$key"
  [[ -n "$faketls" ]] && secret_link="ee${key}$(hex_of "$faketls")"
  cat > "$WS_INFO" <<EOF
PORT=$PORT
IP=$PUBLIC_IP
DOMAIN=$faketls
SECRET=$secret_link
EOF
  chmod 0600 "$WS_INFO"

  cat > "$UNIT_DIR/$WS_SVC.service" <<EOF
[Unit]
Description=Telegram Web (WebSocket) MTProto bridge proxy (tg-ws-proxy-rs)
After=network-online.target
Wants=network-online.target

[Service]
User=$SVC_USER
Group=$SVC_USER
EnvironmentFile=$WS_ENV
ExecStart=$WS_BIN --host 0.0.0.0 --port \${PORT} --secret \${SECRET} --link-ip \${LINK_IP} \$EXTRA_ARGS
Restart=always
RestartSec=3
LimitNOFILE=65535
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$WS_SVC" >/dev/null 2>&1
  fw_open "$PORT"

  if wait_listen "$PORT" "$WS_SVC"; then
    ok "Telegram Web (WebSocket) proxy is running."
    print_links "$PUBLIC_IP" "$PORT" "$secret_link"
    echo "Note: this proxy reaches Telegram through wss://kws*.web.telegram.org. Check it with:  journalctl -u $WS_SVC -n 30 --no-pager"
  else
    err "Service did not start. Logs:  journalctl -u $WS_SVC -n 30 --no-pager"
    journalctl -u "$WS_SVC" -n 15 --no-pager 2>/dev/null
    return 1
  fi
}

remove_ws() {
  local quiet="${1:-}"
  local port; port="$(info_get "$WS_INFO" PORT)"
  systemctl disable --now "$WS_SVC" >/dev/null 2>&1
  rm -f "$UNIT_DIR/$WS_SVC.service" "$WS_BIN" "$WS_ENV" "$WS_INFO"
  systemctl daemon-reload >/dev/null 2>&1
  fw_close "$port"
  [[ "$quiet" == "quiet" ]] || ok "Telegram Web proxy removed."
  cleanup_if_empty
}

cleanup_if_empty() {
  # drop shared config dir and service user when nothing is installed anymore
  if [[ ! -f "$MTG_INFO" && ! -f "$WS_INFO" ]]; then
    rmdir "$CONF_DIR" 2>/dev/null
    id "$SVC_USER" >/dev/null 2>&1 && userdel "$SVC_USER" >/dev/null 2>&1
  fi
}

# ----------------------------- status ----------------------------------------
status_one() {
  # status_one <title> <service> <info-file> <bin>
  local title="$1" svc="$2" infof="$3" bin="$4"
  echo -e "${B}--- $title ---${N}"
  if [[ ! -f "$infof" ]]; then echo -e "  Installed : ${R}no${N}"; echo; return; fi
  local port ip secret domain state conns ver
  port="$(info_get "$infof" PORT)"; ip="$(info_get "$infof" IP)"
  secret="$(info_get "$infof" SECRET)"; domain="$(info_get "$infof" DOMAIN)"
  state="$(systemctl is-active "$svc" 2>/dev/null)"
  ver="$("$bin" --version 2>/dev/null | head -1)"
  if [[ "$state" == "active" ]]; then echo -e "  Service   : ${G}active${N}"; else echo -e "  Service   : ${R}${state:-unknown}${N}"; fi
  if port_in_use "$port"; then echo -e "  Listening : ${G}yes${N} (tcp/$port)"; else echo -e "  Listening : ${R}no${N} (tcp/$port)"; fi
  conns="$(ss -H -tn state established "( sport = :$port )" 2>/dev/null | wc -l)"
  echo "  Clients   : $conns connected now"
  echo "  Enabled   : $(systemctl is-enabled "$svc" 2>/dev/null)"
  [[ -n "$ver" ]] && echo "  Version   : $ver"
  [[ -n "$domain" ]] && echo "  FakeTLS   : $domain"
  echo "  Link      : tg://proxy?server=$ip&port=$port&secret=$secret"
  echo
}

show_status() {
  echo
  status_one "MTProto + FakeTLS (mtg)"          "$MTG_SVC" "$MTG_INFO" "$MTG_BIN"
  status_one "Telegram Web / WebSocket proxy"   "$WS_SVC"  "$WS_INFO"  "$WS_BIN"
}

# ----------------------------- uninstall menu --------------------------------
uninstall_menu() {
  echo
  echo "  1) Remove MTProto + FakeTLS proxy"
  echo "  2) Remove Telegram Web proxy"
  echo "  3) Remove everything"
  echo "  0) Back"
  read -r -p "Choice: " c
  case "$c" in
    1) remove_mtg ;;
    2) remove_ws ;;
    3) remove_mtg quiet; remove_ws quiet; ok "Everything removed." ;;
    *) ;;
  esac
}

# ----------------------------- main menu -------------------------------------
main_menu() {
  while true; do
    clear 2>/dev/null || true
    echo -e "${B}${C}=========================================${N}"
    echo -e "${B}${C}      Telegram Proxy Manager  v1.0${N}"
    echo -e "${B}${C}=========================================${N}"
    echo "  1) Install MTProto proxy + FakeTLS"
    echo "  2) Install Telegram Web (WebSocket) proxy"
    echo "  3) Status"
    echo "  4) Uninstall"
    echo "  0) Exit"
    echo
    read -r -p "Choice: " c || exit 0
    case "$c" in
      1) install_mtg; pause ;;
      2) install_ws;  pause ;;
      3) show_status; pause ;;
      4) uninstall_menu; pause ;;
      0) exit 0 ;;
      *) warn "Invalid choice."; sleep 1 ;;
    esac
  done
}

# allow sourcing for tests: TGPM_SOURCE_ONLY=1
if [[ "${TGPM_SOURCE_ONLY:-0}" != "1" ]]; then
  need_root
  need_systemd
  main_menu
fi
