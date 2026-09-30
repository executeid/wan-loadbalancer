#!/bin/bash
# ============================================================
# Captive Portal Auto-Login Installer
# Repository: https://github.com/executeid/wan-loadbalancer
#
# Quick install:
#   curl -fsSL https://raw.githubusercontent.com/executeid/wan-loadbalancer/main/install.sh | sudo bash
#
# Non-interactive / unattended install:
#   sudo CAPTIVE_ACCOUNTS="user1@x.id:pass1
#   user2@x.id:pass2" CAPTIVE_IFACE="ens224" bash install.sh
# ============================================================

set -e

REPO_BASE="https://raw.githubusercontent.com/executeid/wan-loadbalancer/main"
SCRIPT_DEST="/usr/local/bin/captive.sh"
SERVICE_DEST="/etc/systemd/system/captive.service"
CONF_DEST="/etc/captive.conf"

# Color helpers
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Helper to check for controlling terminal
has_tty() {
    [ -t 0 ] || { [ -c /dev/tty ] && ( : < /dev/tty ) 2>/dev/null; }
}

read_tty() {
    local prompt="$1"
    local var="$2"
    local silent="${3:-0}"
    if [ "$silent" -eq 1 ]; then
        read -r -s -p "$prompt" val < /dev/tty
        echo
    else
        read -r -p "$prompt" val < /dev/tty
    fi
    eval "$var=\"\$val\""
}

# 1. Require root
if [ "$(id -u)" -ne 0 ]; then
    err "This installer must be run as root. Try: sudo bash $0"
    exit 1
fi

echo -e "${BLUE}"
cat << "EOF"
  ____            _   _            _                 _       
 / ___|__ _ _ __ | |_(_)_   _____ | |    ___   __ _(_)_ __  
| |   / _` | '_ \| __| \ \ / / _ \| |   / _ \ / _` | | '_ \ 
| |__| (_| | |_) | |_| |\ V /  __/| |__| (_) | (_| | | | | |
 \____\__,_| .__/ \__|_| \_/ \___||_____\___/ \__, |_|_| |_|
           |_|                                |___/         
EOF
echo -e "${NC}Automated Captive Portal Login Installer for Linux\n"

# 2. Check and install dependencies
info "Checking dependencies..."
MISSING_PKGS=()
for cmd in curl ip systemctl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        MISSING_PKGS+=("$cmd")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    warn "Missing tools: ${MISSING_PKGS[*]}"
    if command -v apt-get >/dev/null 2>&1; then
        info "Installing dependencies via apt..."
        apt-get update -qq && apt-get install -y -qq curl iproute2 systemd
    elif command -v yum >/dev/null 2>&1; then
        info "Installing dependencies via yum..."
        yum install -y curl iproute systemd
    elif command -v pacman >/dev/null 2>&1; then
        info "Installing dependencies via pacman..."
        pacman -Sy --noconfirm curl iproute2 systemd
    else
        err "Please install curl, iproute2, and systemd manually."
        exit 1
    fi
fi
success "Dependencies satisfied."

# 3. Locate source files (local clone vs GitHub download vs embedded fallback)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
USE_LOCAL=0
if [ -f "$SCRIPT_DIR/scripts/captive.sh" ] && [ -f "$SCRIPT_DIR/captive.service" ]; then
    USE_LOCAL=1
    info "Using local files from: $SCRIPT_DIR"
fi

# 4. Configure credentials (/etc/captive.conf)
RECONFIGURE=1
if [ -f "$CONF_DEST" ]; then
    warn "Found existing configuration at $CONF_DEST"
    if has_tty; then
        read_tty "Do you want to reconfigure credentials? [y/N]: " RECONF_ANS
        case "$RECONF_ANS" in
            [yY][eE][sS]|[yY]) RECONFIGURE=1 ;;
            *) RECONFIGURE=0; info "Keeping existing $CONF_DEST" ;;
        esac
    else
        RECONFIGURE=0
        info "Non-interactive mode: keeping existing $CONF_DEST"
    fi
fi

if [ "$RECONFIGURE" -eq 1 ]; then
    ACCOUNTS_STR="${CAPTIVE_ACCOUNTS:-}"   # multi-account: "user1:pass1\nuser2:pass2"
    SINGLE_USER="${CAPTIVE_USER:-}"
    SINGLE_PASS="${CAPTIVE_PASS:-}"
    IFACE="${CAPTIVE_IFACE:-}"
    INTERVAL="${CAPTIVE_DELAY:-30}"

    DEF_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}' || echo "eth0")

    # If no accounts provided via env, prompt interactively.
    if [ -z "$ACCOUNTS_STR" ] && { [ -z "$SINGLE_USER" ] || [ -z "$SINGLE_PASS" ]; }; then
        if ! has_tty; then
            err "Non-interactive install requires CAPTIVE_ACCOUNTS (or CAPTIVE_USER + CAPTIVE_PASS)."
            exit 1
        fi

        echo
        info "Enter your captive portal login details."
        ACCOUNTS_STR=""
        while :; do
            read_tty "  Username (e.g. user@example.edu): " U
            if [ -z "$U" ]; then
                [ -n "$ACCOUNTS_STR" ] && break
                err "Username cannot be empty."
                continue
            fi
            read_tty "  Password: " P 1
            ACCOUNTS_STR="${ACCOUNTS_STR}${U}:${P}
"
            read_tty "  Add another account? [y/N]: " MORE
            case "$MORE" in
                [yY][eE][sS]|[yY]) continue ;;
                *) break ;;
            esac
        done

        read_tty "  Network Interface [default: ${DEF_IFACE}]: " IFACE_INPUT
        IFACE="${IFACE_INPUT:-$DEF_IFACE}"

        read_tty "  Check Interval in seconds [default: 30]: " DELAY_INPUT
        INTERVAL="${DELAY_INPUT:-30}"
    else
        # Build ACCOUNTS_STR from env vars if not already set.
        if [ -z "$ACCOUNTS_STR" ] && [ -n "$SINGLE_USER" ] && [ -n "$SINGLE_PASS" ]; then
            ACCOUNTS_STR="${SINGLE_USER}:${SINGLE_PASS}"
        fi
        IFACE="${IFACE:-$DEF_IFACE}"
    fi

    info "Writing configuration to $CONF_DEST..."
    {
        echo "# ============================================================"
        echo "# Captive Portal Credentials & Config"
        echo "# Generated: $(date)"
        echo "# Mode: 0600 (owner-only readable)"
        echo "# ============================================================"
        echo "ACCOUNTS=\""
        printf '%s\n' "$ACCOUNTS_STR" | sed '/^[[:space:]]*$/d'
        echo "\""
        echo "INTERFACE=\"${IFACE}\""
        echo "DELAY=${INTERVAL}"
    } > "$CONF_DEST"
    chmod 600 "$CONF_DEST"
    chown root:root "$CONF_DEST"
    success "Configuration written with permissions 0600."
fi

# 5. Install captive.sh (local -> remote curl -> embedded)
info "Installing $SCRIPT_DEST..."
if [ "$USE_LOCAL" -eq 1 ]; then
    cp "$SCRIPT_DIR/scripts/captive.sh" "$SCRIPT_DEST"
elif curl -fsSL "$REPO_BASE/scripts/captive.sh" -o "$SCRIPT_DEST" 2>/dev/null; then
    info "Downloaded captive.sh from GitHub."
else
    info "Writing bundled captive.sh..."
    cat > "$SCRIPT_DEST" << 'EMBEDDED_SCRIPT'
#!/bin/bash
# ============================================================
# Captive Portal Auto-Login - v2.3 (standalone / single-interface)
# Target : Debian / Ubuntu / Arch / Raspberry Pi (systemd)
# Runs   : captive.service (daemon loop, Type=simple)
# Config : /etc/captive.conf  (mode 0600 recommended)
#
# Notes:
#  - Single interface (explicit). Set INTERFACES in /etc/captive.conf.
#  - Multi-account rotation (login limit aware).
#  - curl connect+total timeouts so a dead portal can never hang.
#  - Success is only declared after a real HTTP 204 is seen again.
#  - Clean shutdown on SIGTERM (systemd stop/restart).
# ============================================================

# --------------------
# Defaults (overridden by /etc/captive.conf)
# --------------------
ACCOUNTS="
user@example.edu:password
"

# Interface is explicit (NO auto-detect). Change in /etc/captive.conf.
INTERFACE="eth0"

CHECK_URL="http://www.gstatic.com/generate_204"
LOGIN_URL="https://captive.example.edu:8009/index.php?zone=misc"
ORIGIN="https://captive.example.edu:8009"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
DELAY=30              # seconds between check cycles
CONNECT_TIMEOUT=5     # curl --connect-timeout
MAX_TIME=10           # curl --max-time

# --------------------
# Load external config
# --------------------
CONFIG_FILE="/etc/captive.conf"
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"
fi

# --------------------
# Prepare account list (user:pass per line)
# --------------------
ACCOUNT_LIST=$(printf "%s\n" "$ACCOUNTS" | sed '/^[[:space:]]*$/d')
MAX_ATTEMPTS=$(printf "%s\n" "$ACCOUNT_LIST" | wc -l)
ACCOUNT_INDEX=0

# --------------------
# Clean shutdown on systemd stop
# --------------------
trap 'echo "captive: received stop signal, exiting"; exit 0' SIGTERM SIGINT

# ====================
# Minimal URL-encode for POST values
# ====================
urlenc() {
    printf '%s' "$1" \
        | sed -e 's/%/%25/g' \
              -e 's/ /%20/g' \
              -e 's/&/%26/g' \
              -e 's/+/%2B/g' \
              -e 's/</%3C/g' \
              -e 's/>/%3E/g' \
              -e 's/=/%3D/g' \
              -e 's/#/%23/g'
}

# ====================
# Connectivity check
#   204 = online (real Google). Anything else = blocked.
# ====================
check_connectivity() {
    local CODE
    CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        --interface "$INTERFACE" \
        "$CHECK_URL" 2>/dev/null)

    [ "$CODE" = "204" ]
}

# ====================
# Perform login POST
# ====================
perform_login() {
    local USERNAME="$1"
    local PASSWORD="$2"
    local DATA="auth_user=$(urlenc "$USERNAME")&auth_pass=$(urlenc "$PASSWORD")&redirurl=&accept=Login"

    curl -k -s \
        --connect-timeout "$CONNECT_TIMEOUT" \
        --max-time "$MAX_TIME" \
        --interface "$INTERFACE" \
        -X POST "$LOGIN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: ${ORIGIN}" \
        -H "Referer: ${LOGIN_URL}" \
        -A "$UA" \
        --data "$DATA" 2>/dev/null
}

# ====================
# Main login routine (multi-account rotation)
# ====================
do_login() {
    if check_connectivity; then
        echo "[$INTERFACE] Internet available."
        logger -t captive-service -p daemon.info "[$INTERFACE] Internet available"
        return 0
    fi

    echo "[$INTERFACE] Internet blocked, trying to log in..."
    logger -t captive-service -p daemon.warn "[$INTERFACE] Internet blocked, trying to log in"

    local SUCCESS=0
    local ATTEMPTS=0

    while [ "$ATTEMPTS" -lt "$MAX_ATTEMPTS" ]; do
        local ACCOUNT
        ACCOUNT=$(printf "%s\n" "$ACCOUNT_LIST" | sed -n "$((ATTEMPTS + 1))p")
        local USERNAME="${ACCOUNT%%:*}"
        local PASSWORD="${ACCOUNT#*:}"

        if [ -z "$USERNAME" ]; then
            ATTEMPTS=$((ATTEMPTS + 1))
            continue
        fi

        echo "[$INTERFACE] Attempting login: $USERNAME (attempt $((ATTEMPTS + 1))/$MAX_ATTEMPTS)"
        logger -t captive-service -p daemon.warn "[$INTERFACE] Attempting login: $USERNAME ($((ATTEMPTS + 1))/$MAX_ATTEMPTS)"

        local RESPONSE
        RESPONSE="$(perform_login "$USERNAME" "$PASSWORD")"

        if [ -z "$RESPONSE" ]; then
            echo "[$INTERFACE] $USERNAME: portal unreachable (no response). Stopping."
            logger -t captive-service -p daemon.err "[$INTERFACE] $USERNAME: portal unreachable, aborting"
            break
        fi

        if echo "$RESPONSE" | grep -q "already logged in 3 times"; then
            echo "[$INTERFACE] $USERNAME: login limit reached. Trying next account."
            logger -t captive-service -p daemon.err "[$INTERFACE] $USERNAME: login limit reached"
        elif echo "$RESPONSE" | grep -iq "invalid credential\|login failed"; then
            echo "[$INTERFACE] $USERNAME: wrong credentials. Trying next account."
            logger -t captive-service -p daemon.err "[$INTERFACE] $USERNAME: wrong credentials"
        else
            # Got a response; verify real connectivity before claiming success.
            sleep 1
            if check_connectivity; then
                echo "[$INTERFACE] $USERNAME: login success. Internet restored."
                logger -t captive-service -p daemon.notice "[$INTERFACE] $USERNAME: login success"
                SUCCESS=1
                break
            else
                echo "[$INTERFACE] $USERNAME: logged in but Internet still unavailable. Trying next account."
                logger -t captive-service -p daemon.err "[$INTERFACE] $USERNAME: logged in but still offline"
            fi
        fi

        ATTEMPTS=$((ATTEMPTS + 1))
    done

    if [ "$SUCCESS" -eq 0 ]; then
        echo "[$INTERFACE] All accounts failed. No Internet access."
        logger -t captive-service -p daemon.err "[$INTERFACE] All accounts failed"
    fi

    return 0
}

# ====================
# Main loop
# ====================
echo "captive: service started (interface: $INTERFACE, interval: ${DELAY}s)"

# Initial check on startup
do_login

while true; do
    sleep "$DELAY"
    do_login
done
EMBEDDED_SCRIPT
fi

chmod 700 "$SCRIPT_DEST"
chown root:root "$SCRIPT_DEST"
ln -sf "$SCRIPT_DEST" /usr/local/bin/captive_v2.2.sh
success "Script installed to $SCRIPT_DEST"

# 6. Install captive.service
#    Always write the canonical unit deterministically. We do NOT trust a
#    downloaded copy, because a stale/older unit in the repo would otherwise
#    override the correct settings (ExecStart path, RestartSec, Type).
info "Installing $SERVICE_DEST..."
cat > "$SERVICE_DEST" << 'EMBEDDED_SERVICE'
[Unit]
Description=Auto Login Captive Portal
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/captive.sh
Restart=always
RestartSec=10
User=root
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Clean termination
TimeoutStopSec=15
KillMode=mixed

[Install]
WantedBy=multi-user.target loadbalance.target
EMBEDDED_SERVICE

chmod 644 "$SERVICE_DEST"
chown root:root "$SERVICE_DEST"
success "Service unit installed to $SERVICE_DEST"

# 7. Enable and start service
info "Reloading systemd and starting captive.service..."
systemctl daemon-reload
systemctl enable captive.service
systemctl restart captive.service

sleep 2

# 8. Verification
if systemctl is-active --quiet captive.service; then
    success "captive.service is active and running!"
    echo
    systemctl status captive.service --no-pager
    echo
    success "Installation complete."
    info "Useful commands:"
    echo "  Check status : sudo systemctl status captive.service"
    echo "  View logs    : sudo journalctl -u captive.service -f"
    echo "  Edit config  : sudo nano /etc/captive.conf"
    echo "  Restart      : sudo systemctl restart captive.service"
else
    err "captive.service failed to start. Journal output:"
    journalctl -u captive.service --no-pager -n 20
    exit 1
fi
