#!/bin/bash
set -e

echo "=== VRF Router Setup ==="

# Enable IP forwarding
sysctl -w net.ipv4.ip_forward=1

# ---------- Create VRF devices ----------

echo "Creating VRF-Blue (table 1001)..."
ip link add VRF-Blue type vrf table 1001
ip link set VRF-Blue up
ip route add table 1001 unreachable default metric 4278198272

echo "Creating VRF-Red (table 1002)..."
ip link add VRF-Red type vrf table 1002
ip link set VRF-Red up
ip route add table 1002 unreachable default metric 4278198272

# ---------- Helper functions ----------

# Find the interface name that carries a given IP address.
get_iface() {
    ip -4 -o addr show | grep "$1/" | awk '{print $2}'
}

# Bind an interface to a VRF, preserving its IP address.
# Setting the VRF master flushes addresses, so we save and re-add.
bind_to_vrf() {
    local iface=$1
    local vrf=$2
    local addr
    addr=$(ip -4 -o addr show dev "$iface" | awk '{print $4}')
    echo "  $iface ($addr) -> $vrf"
    ip addr flush dev "$iface"
    ip link set "$iface" master "$vrf"
    ip addr add "$addr" dev "$iface"
    ip link set "$iface" up
}

# ---------- Identify interfaces by IP ----------

BLUE1_IFACE=$(get_iface "10.10.10.2")
BLUE2_IFACE=$(get_iface "10.10.20.2")
RED1_IFACE=$(get_iface "10.20.10.2")
RED2_IFACE=$(get_iface "10.20.20.2")

echo ""
echo "Interface mapping:"
echo "  VRF-Blue: $BLUE1_IFACE (10.10.10.0/24), $BLUE2_IFACE (10.10.20.0/24)"
echo "  VRF-Red:  $RED1_IFACE (10.20.10.0/24), $RED2_IFACE (10.20.20.0/24)"
echo ""

# ---------- Bind interfaces to VRFs ----------

echo "Binding interfaces to VRF-Blue..."
bind_to_vrf "$BLUE1_IFACE" VRF-Blue
bind_to_vrf "$BLUE2_IFACE" VRF-Blue

echo "Binding interfaces to VRF-Red..."
bind_to_vrf "$RED1_IFACE" VRF-Red
bind_to_vrf "$RED2_IFACE" VRF-Red

# ---------- Verify ----------

echo ""
echo "=== VRF devices ==="
ip vrf show
echo ""
echo "=== VRF-Blue interfaces ==="
ip link show master VRF-Blue
echo ""
echo "=== VRF-Red interfaces ==="
ip link show master VRF-Red
echo ""
echo "=== VRF-Blue routing table (table 1001) ==="
ip route show vrf VRF-Blue
echo ""
echo "=== VRF-Red routing table (table 1002) ==="
ip route show vrf VRF-Red
echo ""

# ---------- Start FRR ----------

CONF_DIR="/etc/frr/hosts/$HOSTNAME"
if [ -d "$CONF_DIR" ]; then
    cp "$CONF_DIR/frr.conf" /etc/frr/frr.conf
fi

cp /etc/frr/hosts/daemons /etc/frr/daemons
chown frr:frr /etc/frr/daemons /etc/frr/frr.conf

echo "Starting FRR..."
/usr/lib/frr/frrinit.sh start

echo ""
echo "=== Router ready ==="
exec tail -f /dev/null
