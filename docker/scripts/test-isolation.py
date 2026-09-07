#!/usr/bin/env python3
"""
VRF Traffic Isolation Test — Scapy Packet Generator

Sends ICMP packets with a VRF-identifying payload so you can confirm,
via tcpdump on the router, that traffic stays within its VRF.

Usage (run inside a host container):

    # From Host-Blue1 — send to Host-Blue2
    python3 /scripts/test-isolation.py 10.10.20.10 BLUE

    # From Host-Red1 — send to Host-Red2
    python3 /scripts/test-isolation.py 10.20.20.10 RED

Verification (run on the Docker host):

    # Watch ALL interfaces on R1 for ICMP traffic
    docker exec R1 tcpdump -i any -n -c 20 icmp

    # Watch only a VRF-Red interface — should see nothing when
    # traffic is sent from a Blue host
    docker exec R1 ip vrf exec VRF-Red tcpdump -i any -n -c 5 icmp
"""
import sys
from scapy.all import IP, ICMP, Raw, send


def main():
    if len(sys.argv) < 3:
        print("Usage: python3 test-isolation.py <dest_ip> <vrf_label>")
        print()
        print("Examples:")
        print("  python3 /scripts/test-isolation.py 10.10.20.10 BLUE")
        print("  python3 /scripts/test-isolation.py 10.20.20.10 RED")
        sys.exit(1)

    dest = sys.argv[1]
    label = sys.argv[2].upper()
    payload = f"VRF-{label}-ISOLATION-TEST"
    count = int(sys.argv[3]) if len(sys.argv) > 3 else 5

    pkt = IP(dst=dest) / ICMP() / Raw(load=payload.encode())

    print(f"Sending {count} ICMP packets to {dest}")
    print(f"Payload marker: {payload}")
    print("-" * 50)

    send(pkt, count=count, verbose=True)

    print("-" * 50)
    print("Done.")
    print()
    print("To verify isolation, run tcpdump on R1:")
    print("  docker exec R1 tcpdump -i any -n -X icmp")


if __name__ == "__main__":
    main()
