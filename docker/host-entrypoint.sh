#!/bin/bash
set -e

# Replace Docker's default gateway with R1 so that all traffic
# (including cross-subnet and cross-VRF attempts) flows through
# the router where VRF policy is enforced.
if [ -n "$GATEWAY" ]; then
    ip route del default 2>/dev/null || true
    ip route add default via "$GATEWAY"
    echo "Default gateway set to $GATEWAY"
fi

echo "Host $(hostname) ready."
exec tail -f /dev/null
