#!/bin/bash
# ========================
# Account Credentials List
# ========================
USERS=("" "")    # Add more usernames as needed
PASSWORDS=("" "")  # Make sure each password matches the username

# ========================
# Constants
# ========================
CHECK_URL="http://www.gstatic.com/generate_204"
LOGIN_URL="" # Add the captive portal login URL here
ORIGIN="" # Add the origin URL here
DELAY=30  # Seconds between checks

# ========================
# Global Account Index Tracker
# ========================
ACCOUNT_INDEX=0

# ========================
# Functions
# ========================

# Try to login with given user/pass on a specific interface
perform_login() {
    local IFACE="$1"
    local USERNAME="$2"
    local PASSWORD="$3"
    local DATA="auth_user=${USERNAME}&auth_pass=${PASSWORD}&redirurl=&accept=Login"

    curl -k -s --interface "$IFACE" \
        -X POST "$LOGIN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: ${ORIGIN}" \
        -H "Referer: ${LOGIN_URL}" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36" \
        --data "$DATA"
}

# Check connectivity and login with sequential account rotation
login_iface() {
    local IFACE="$1"

    # Check if interface exists and is up
    if ! ip link show "$IFACE" > /dev/null 2>&1; then
        echo "[$IFACE] ⚠️ Interface does not exist. Skipping..."
        return
    fi

    if ! ip link show "$IFACE" | grep -q "state UP"; then
        echo "[$IFACE] ⚠️ Interface is down. Skipping..."
        return
    fi

    # Proceed with connectivity check
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" "$CHECK_URL")

    if [ "$HTTP_CODE" = "204" ]; then
        echo "[$IFACE] Internet available ✅"
        return
    fi

    echo "[$IFACE] Internet blocked ❌, trying to log in..."

    local SUCCESS=0
    local ATTEMPTS=0
    local MAX_ATTEMPTS=${#USERS[@]}

    # Try accounts sequentially starting from current index
    while [ $ATTEMPTS -lt $MAX_ATTEMPTS ]; do
        local USERNAME="${USERS[$ACCOUNT_INDEX]}"
        local PASSWORD="${PASSWORDS[$ACCOUNT_INDEX]}"

        echo "[$IFACE] Attempting login with account: $USERNAME (index: $ACCOUNT_INDEX)"

        RESPONSE=$(perform_login "$IFACE" "$USERNAME" "$PASSWORD")

        if echo "$RESPONSE" | grep -q "You are already logged in 3 times"; then
            echo "[$IFACE] ❌ $USERNAME: Login limit reached. Trying next account..."
            # Move to next account
            ACCOUNT_INDEX=$(( (ACCOUNT_INDEX + 1) % ${#USERS[@]} ))
            ATTEMPTS=$((ATTEMPTS + 1))
        elif echo "$RESPONSE" | grep -iq "login failed"; then
            echo "[$IFACE] ❌ $USERNAME: Login failed (wrong credentials?)."
            # Move to next account
            ACCOUNT_INDEX=$(( (ACCOUNT_INDEX + 1) % ${#USERS[@]} ))
            ATTEMPTS=$((ATTEMPTS + 1))
        else
            echo "[$IFACE] ✅ $USERNAME: Login successful."
            SUCCESS=1
            # Move to next account for next interface
            ACCOUNT_INDEX=$(( (ACCOUNT_INDEX + 1) % ${#USERS[@]} ))
            break
        fi
    done

    if [ $SUCCESS -eq 0 ]; then
        echo "[$IFACE] ❌ All accounts failed. No internet access."
    fi
}

# ========================
# Interface List
# ========================
INTERFACES=("enp0s31f6" "wan1" "wan2" "wan3") # Add or modify interfaces as needed

# ========================
# Run Login for Each Interface
# ========================
for IFACE in "${INTERFACES[@]}"; do
    login_iface "$IFACE"
done
