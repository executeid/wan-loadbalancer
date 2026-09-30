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
