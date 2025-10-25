#!/bin/bash

# Wait for interfaces to get IP addresses
MAX_WAIT=30
WAIT_COUNT=0

echo "Waiting for wan1 and wan2 to get IP addresses..."

while [ $WAIT_COUNT -lt $MAX_WAIT ]; do
    WAN1_IP=$(ip -4 addr show wan1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    WAN2_IP=$(ip -4 addr show wan2 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    WAN3_IP=$(ip -4 addr show wan3 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    WAN4_IP=$(ip -4 addr show enp0s31f6 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')

    if [ -n "$WAN1_IP" ] && [ -n "$WAN2_IP" ] && [ -n "$WAN3_IP" ] && [ -n "$WAN4_IP" ]; then
        echo "Found IPs: wan1=$WAN1_IP, wan2=$WAN2_IP, wan3=$WAN3_IP, wan3=$WAN4_IP"
        break
    fi

    echo "Waiting for IPs... ($WAIT_COUNT/$MAX_WAIT)"
    sleep 1
    WAIT_COUNT=$((WAIT_COUNT + 1))
done

if [ -z "$WAN1_IP" ] || [ -z "$WAN2_IP" ] || [ -z "$WAN3_IP" ] || [ -z "$WAN4_IP" ]; then
    echo "ERROR: Failed to get IP addresses for wan interfaces"
    echo "wan1 IP: ${WAN1_IP:-NOT FOUND}"
    echo "wan2 IP: ${WAN2_IP:-NOT FOUND}"
    echo "wan3 IP: ${WAN3_IP:-NOT FOUND}"
    echo "wan4 IP: ${WAN4_IP:-NOT FOUND}"
    exit 1
fi

# Start go-dispatch-proxy with the discovered IPs
echo "Starting go-dispatch-proxy with IPs: $WAN1_IP $WAN2_IP $WAN3_IP $WAN4_IP"
exec /home/user/go-dispatch-proxy -lhost 127.0.0.1 -lport 1080 $WAN1_IP $WAN2_IP $WAN3_IP $WAN4_IP
