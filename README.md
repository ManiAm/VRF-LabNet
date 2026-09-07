# VRF-LabNet

A hands-on Docker lab for learning **VRF (Virtual Routing and Forwarding)** with [FRRouting (FRR)](https://frrouting.org/). It builds a single FRR router with two isolated VRFs — **VRF-Blue** and **VRF-Red** — each serving two host containers on separate subnets. Traffic within each VRF routes normally; traffic between VRFs is completely isolated. The lab walks through routing-table inspection, per-VRF pings, Scapy-based traffic analysis, and BGP route leaking — all fully automated inside Docker.

- For background on VRF concepts, see [VRF Fundamentals](docs/vrf-fundamentals.md).
- For the Linux kernel implementation, see [VRF in the Linux Kernel](docs/vrf-in-linux.md).
- For FRR integration, per-VRF routing, and route leaking, see [FRR and VRF](docs/vrf-and-frr.md).


## Prerequisites

- **Docker Engine** (v20.10 or later) with the `docker compose` plugin.
- Basic familiarity with the Linux command line.
- No physical routers or switches are needed.


## Lab Topology

The lab creates **five containers** connected by **four Docker bridge networks**. One container (R1) acts as an FRR router with two VRFs. The other four are simple hosts — two per VRF.

```
                                              R1  (FRR Router)
┌────────────────┐                ┌────────────────────────────────────────┐
│  Host-Blue1    │                │                                        │
│  10.10.10.10   │─── br-blue1 ───┤  eth* ── VRF-Blue (table 1001)         │
└────────────────┘                │                                        │
┌────────────────┐                │                                        │
│  Host-Blue2    │                │                                        │
│  10.10.20.10   │─── br-blue2 ───┤  eth* ── VRF-Blue (table 1001)         │
└────────────────┘                │                                        │
                                  │  ─ ─ ─ ─ ─ VRF boundary ─ ─ ─ ─ ─ ─ ─  │
┌────────────────┐                │                                        │
│  Host-Red1     │                │                                        │
│  10.20.10.10   │─── br-red1  ───┤  eth* ── VRF-Red  (table 1002)         │
└────────────────┘                │                                        │
┌────────────────┐                │                                        │
│  Host-Red2     │                │                                        │
│  10.20.20.10   │─── br-red2  ───┤  eth* ── VRF-Red  (table 1002)         │
└────────────────┘                └────────────────────────────────────────┘
```

- **VRF-Blue** owns `10.10.10.0/24` and `10.10.20.0/24`. R1 routes between them.
- **VRF-Red** owns `10.20.10.0/24` and `10.20.20.0/24`. R1 routes between them.
- There is **no routing between VRF-Blue and VRF-Red** unless explicitly configured (route leaking).
- Each host uses R1 as its default gateway. Packets to unknown destinations go to R1, where VRF policy decides the outcome.

### IP Addressing

**R1 interfaces (router):**

| Network   | IP Address | VRF      |
| --------- | ---------- | -------- |
| br-blue1  | 10.10.10.2 | VRF-Blue |
| br-blue2  | 10.10.20.2 | VRF-Blue |
| br-red1   | 10.20.10.2 | VRF-Red  |
| br-red2   | 10.20.20.2 | VRF-Red  |

**Host containers:**

| Container  | Network  | IP Address  | Default Gateway |
| ---------- | -------- | ----------- | --------------- |
| Host-Blue1 | br-blue1 | 10.10.10.10 | 10.10.10.2 (R1) |
| Host-Blue2 | br-blue2 | 10.10.20.10 | 10.10.20.2 (R1) |
| Host-Red1  | br-red1  | 10.20.10.10 | 10.20.10.2 (R1) |
| Host-Red2  | br-red2  | 10.20.20.10 | 10.20.20.2 (R1) |


## Quick Start

Build the Docker image:

```bash
docker build --tag vrf-labnet docker/
```

Start the containers:

```bash
docker compose -f docker/docker-compose.yml up -d
```

The VRFs, interface bindings, and FRR are set up automatically by the entrypoint script.


## How the Lab Works

### VRF Setup (What the Entrypoint Does)

The R1 entrypoint script (`entrypoint.sh`) performs these steps in order:

1. **Enables IP forwarding** — `sysctl -w net.ipv4.ip_forward=1`.

2. **Creates VRF devices** — Two Linux VRF master devices (`VRF-Blue` with table 1001, `VRF-Red` with table 1002) using `ip link add type vrf`.

3. **Adds unreachable default routes** — Installs a catch-all `unreachable default` in each VRF's table to prevent unmatched packets from leaking into the `main` table (see [The Unreachable Default Route](docs/vrf-in-linux.md#the-unreachable-default-route)).

4. **Binds interfaces to VRFs** — Each of R1's four network interfaces is assigned to the appropriate VRF. The script identifies interfaces by their Docker-assigned IP addresses, so it works regardless of interface naming order.

5. **Starts FRR** — FRR's zebra daemon detects the VRFs and interfaces via netlink, and BGP daemon starts ready for the route leaking exercise.

> **Note:** A helper service (`bridge-nf-fix`) runs before R1 to disable `bridge-nf-call-iptables` on the Docker host. By default, the `br_netfilter` kernel module passes bridged packets through the host's iptables FORWARD chain, which can drop the cross-subnet traffic that R1 needs to route between VRF interfaces. This is a Docker host-level setting, not a VRF concept.

### FRR Integration

FRR does **not** create VRFs — it discovers them from the Linux kernel via netlink. When the entrypoint creates VRF-Blue and VRF-Red, zebra receives `RTM_NEWLINK` events and registers them automatically. This is the standard FRR + Linux VRF model described in [VRF and FRR](docs/vrf-and-frr.md).

### Configuration Files

```
docker/
├── Dockerfile              # Ubuntu 22.04 + FRR + Scapy + tcpdump + traceroute
├── docker-compose.yml      # 5 containers, 4 bridge networks, bridge-nf fix
├── entrypoint.sh           # R1: creates VRFs, binds interfaces, starts FRR
├── host-entrypoint.sh      # Hosts: sets default gateway, stays alive
├── frr-restart.sh          # Utility to restart FRR without hanging
├── configs/
│   ├── daemons             # Enables zebra, staticd, bgpd
│   └── frr-r1/
│       └── frr.conf        # Minimal FRR config (VRFs come from kernel)
└── scripts/
    └── test-isolation.py   # Scapy script for traffic isolation test
```

## Exercises

| # | Exercise | What You Learn |
|---|----------|----------------|
| 1 | [Explore the VRF Configuration](#exercise-1-explore-the-vrf-configuration) | List VRF devices, inspect bound interfaces, and view kernel routing rules. |
| 2 | [Verify Routing Table Isolation](#exercise-2-verify-routing-table-isolation) | Compare per-VRF routing tables and confirm each VRF sees only its own subnets. |
| 3 | [Test Intra-VRF Routing](#exercise-3-test-intra-vrf-routing) | Ping and traceroute between hosts in the same VRF across different subnets. |
| 4 | [Confirm Inter-VRF Isolation](#exercise-4-confirm-inter-vrf-isolation) | Prove that traffic cannot cross VRF boundaries — pings between VRFs fail. |
| 5 | [Traffic Isolation with Scapy](#exercise-5-traffic-isolation-with-scapy) | Send marked packets with Scapy and use tcpdump to prove VRF-level isolation. |
| 6 | [Route Leaking with BGP](#exercise-6-route-leaking-with-bgp) | Configure BGP `import vrf` to selectively break isolation, then restore it. |


## Exercise 1: Explore the VRF Configuration

Enter the R1 container:

```bash
docker exec -it R1 bash
```

### List VRF Devices

```bash
ip vrf show
```

Expected output:

```
Name              Table
-----------------------
VRF-Blue          1001
VRF-Red           1002
```

### Show Interfaces per VRF

```bash
ip link show master VRF-Blue
ip link show master VRF-Red
```

Each VRF should show two interfaces — the ones bound to it during startup.

### Inspect Kernel Routing Rules

```bash
ip rule show
```

Expected output:

```
0:      from all lookup local
1000:   from all lookup [l3mdev-table]
32766:  from all lookup main
32767:  from all lookup default
```

The rule at priority `1000` is the **l3mdev rule** — the kernel added it automatically when the first VRF was created. This single rule handles all VRFs: when a packet arrives on a VRF-bound interface, this rule redirects the route lookup into that VRF's routing table. For details on how this works, see [Kernel Routing Rules](docs/vrf-in-linux.md#kernel-routing-rules-l3mdev).


## Exercise 2: Verify Routing Table Isolation

Still inside R1 (if you exited, run `docker exec -it R1 bash` again):

### View per-VRF Routing Tables

> **Note:** Docker assigns interface names dynamically, so your names may differ from this example (`eth0`, `eth1`, etc.). The key observation is that each VRF sees **only its own subnets** — VRF-Blue has no knowledge of 10.20.x.x, and VRF-Red has no knowledge of 10.10.x.x.

```bash
ip route show vrf VRF-Blue
```

Expected output (interface names may differ):

```
unreachable default metric 4278198272 
10.10.10.0/24 dev eth3 proto kernel scope link src 10.10.10.2
10.10.20.0/24 dev eth0 proto kernel scope link src 10.10.20.2
```

```bash
ip route show vrf VRF-Red
```

Expected output:

```
unreachable default metric 4278198272
10.20.10.0/24 dev eth1 proto kernel scope link src 10.20.10.2
10.20.20.0/24 dev eth2 proto kernel scope link src 10.20.20.2
```

### View Raw Kernel Tables

You can also inspect the tables directly by ID:

```bash
ip route show table 1001   # VRF-Blue
ip route show table 1002   # VRF-Red
```

This shows the same routes as `ip route show vrf`, plus **local** and **broadcast** entries that `vrf` mode hides:

```
unreachable default metric 4278198272
10.10.10.0/24 dev eth3 proto kernel scope link src 10.10.10.2
local 10.10.10.2 dev eth3 proto kernel scope host src 10.10.10.2
broadcast 10.10.10.255 dev eth3 proto kernel scope link src 10.10.10.2
10.10.20.0/24 dev eth0 proto kernel scope link src 10.10.20.2
local 10.10.20.2 dev eth0 proto kernel scope host src 10.10.20.2
broadcast 10.10.20.255 dev eth0 proto kernel scope link src 10.10.20.2
```

The `local` entries handle traffic addressed to R1 itself (e.g., `10.10.10.2`). The `broadcast` entries handle subnet broadcast addresses. These are created automatically by the kernel when an IP address is assigned.

### Compare with the Main Table

```bash
ip route show table main
```

The main routing table is mostly empty — all the interesting routes live in VRF-specific tables.

### View VRF Routes in FRR

Open the FRR shell:

```bash
vtysh
```

```
show ip route vrf VRF-Blue
show ip route vrf VRF-Red
show ip route vrf all
```

FRR shows the same routes, learned via its zebra daemon watching the kernel. Type `exit` to leave vtysh when done.


## Exercise 3: Test Intra-VRF Routing

> **Note:** From this exercise onward, all commands run from your **Docker host terminal** (not from inside R1). If you are still inside R1 or vtysh, type `exit` until you return to your host shell.

This exercise confirms that R1 routes traffic **within** a VRF across its two subnets.

### Blue VRF: Host-Blue1 → Host-Blue2

```bash
docker exec Host-Blue1 ping -c 3 10.10.20.10
```

This should **succeed**. The packet path:
1. Host-Blue1 sends to 10.10.20.10 via its default gateway (R1 at 10.10.10.2).
2. R1 receives the packet on an interface in VRF-Blue.
3. R1 looks up 10.10.20.10 in VRF-Blue's routing table — finds the connected route.
4. R1 forwards to Host-Blue2.

### Red VRF: Host-Red1 → Host-Red2

```bash
docker exec Host-Red1 ping -c 3 10.20.20.10
```

This should also **succeed** — same logic, but in VRF-Red.

### Traceroute

```bash
docker exec Host-Blue1 traceroute -n 10.10.20.10
```

You should see R1 (10.10.10.2) as the intermediate hop, confirming the packet traverses the router.


## Exercise 4: Confirm Inter-VRF Isolation

This is the core VRF demonstration — traffic **cannot** cross VRF boundaries.

### Blue → Red: Should Fail

```bash
docker exec Host-Blue1 ping -c 3 -W 2 10.20.10.10
```

This should **fail** (100% packet loss). Here's why:
1. Host-Blue1 sends to 10.20.10.10 via R1 (its default gateway).
2. R1 receives the packet on an interface in VRF-Blue.
3. R1 looks up 10.20.10.10 in **VRF-Blue's** routing table.
4. VRF-Blue has no route for 10.20.x.x → **packet dropped**.

### Red → Blue: Should Also Fail

```bash
docker exec Host-Red1 ping -c 3 -W 2 10.10.10.10
```

Same result — VRF-Red has no knowledge of 10.10.x.x.

### Per-VRF Ping from the Router

On R1, you can ping through a specific VRF:

```bash
docker exec R1 ip vrf exec VRF-Blue ping -c 3 10.10.10.10   # reaches Host-Blue1
docker exec R1 ip vrf exec VRF-Red  ping -c 3 10.20.10.10   # reaches Host-Red1
```

But a cross-VRF attempt fails:

```bash
docker exec R1 ip vrf exec VRF-Blue ping -c 3 -W 2 10.20.10.10   # FAILS
```

Even though R1 has an interface on 10.20.10.0/24, VRF-Blue's routing table cannot see it.


## Exercise 5: Traffic Isolation with Scapy

This exercise uses Scapy to send marked packets and `tcpdump` to prove they stay within their VRF. You will need **two terminal windows** for this exercise.

### Step 1: Start a Packet Capture on R1

In the **first terminal**, start a packet capture on all of R1's interfaces:

```bash
docker exec R1 tcpdump -i any -n icmp
```

Leave this running. It displays every ICMP packet that crosses any of R1's interfaces, along with the interface name for each packet.

### Step 2: Send Marked Traffic from VRF-Blue

In the **second terminal**, use the Scapy test script from Host-Blue1:

```bash
docker exec Host-Blue1 python3 /scripts/test-isolation.py 10.10.20.10 BLUE
```

This sends 5 ICMP packets to Host-Blue2, each with the payload `VRF-BLUE-ISOLATION-TEST`.

### Step 3: Analyze the Capture

Switch back to the first terminal and look at the tcpdump output. You will see:
- ICMP packets on **VRF-Blue interfaces only** (traffic between 10.10.10.x and 10.10.20.x) ✓
- **No ICMP packets** on any VRF-Red interface ✓

### Step 4: Repeat from VRF-Red (Optional)

Stop the capture with `Ctrl+C`, restart it, and send traffic from VRF-Red instead:

```bash
docker exec Host-Red1 python3 /scripts/test-isolation.py 10.20.20.10 RED
```

Now tcpdump shows packets only on VRF-Red interfaces. VRF-Blue interfaces remain completely silent.

### What This Proves

Even though all four interfaces are on the **same router** (same container, same kernel), the VRF boundary is enforced at the kernel routing-table level. Packets are never forwarded across VRFs unless route leaking is explicitly configured.


## Exercise 6: Route Leaking with BGP

This exercise shows how to selectively break VRF isolation using BGP `import vrf`.

### Step 1: Verify Isolation (Before Leaking)

Confirm that Blue cannot reach Red (same test as [Exercise 4](#exercise-4-confirm-inter-vrf-isolation)):

```bash
docker exec Host-Blue1 ping -c 2 -W 2 10.20.10.10
```

Expected: **100% packet loss** — VRF-Blue has no route for 10.20.x.x.

### Step 2: Configure BGP Route Leaking

Enter R1's FRR shell:

```bash
docker exec -it R1 vtysh
```

Create a BGP instance in each VRF that redistributes its connected routes, then import across VRFs:

```
configure terminal

router bgp 65000 vrf VRF-Blue
 address-family ipv4 unicast
  redistribute connected
  import vrf VRF-Red
 exit-address-family
exit

router bgp 65000 vrf VRF-Red
 address-family ipv4 unicast
  redistribute connected
  import vrf VRF-Blue
 exit-address-family
exit

end
```

### Step 3: Verify Leaked Routes

```
show ip route vrf VRF-Blue
```

You should now see VRF-Red's subnets appear as BGP-leaked routes:

```
B>* 10.20.10.0/24 [20/0] is directly connected, VRF-Red (vrf VRF-Red), ...
B>* 10.20.20.0/24 [20/0] is directly connected, VRF-Red (vrf VRF-Red), ...
```

Check the other direction too:

```
show ip route vrf VRF-Red
```

### Step 4: Test Cross-VRF Connectivity

Exit vtysh and test:

```bash
docker exec Host-Blue1 ping -c 3 10.20.10.10
```

Expected: **success** — Host-Blue1 can now reach Host-Red1 through the leaked routes.

```bash
docker exec Host-Red1 ping -c 3 10.10.10.10
```

Expected: **success** — bidirectional.

### Step 5: Remove the Leak

To restore full isolation:

```bash
docker exec -it R1 vtysh
```

```
configure terminal

router bgp 65000 vrf VRF-Blue
 address-family ipv4 unicast
  no import vrf VRF-Red
 exit-address-family
exit

router bgp 65000 vrf VRF-Red
 address-family ipv4 unicast
  no import vrf VRF-Blue
 exit-address-family
exit

end
```

Verify isolation is restored:

```bash
docker exec Host-Blue1 ping -c 2 -W 2 10.20.10.10
```

Expected: **100% packet loss** — isolation is back.


## Cleanup

Stop and remove the containers and networks:

```bash
docker compose -f docker/docker-compose.yml down
```
