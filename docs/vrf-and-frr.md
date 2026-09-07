# VRF and FRR

> **Prerequisites:** This document assumes familiarity with VRF concepts and Linux kernel VRF. See [VRF Fundamentals](vrf-fundamentals.md) for background on routing tables, VRF isolation, and use cases. See [VRF in Linux](vrf-in-linux.md) for the Linux kernel implementation. For a hands-on FRR lab, see [FRR-LabNet](https://github.com/ManiAm/FRR-LabNet).

This document covers how FRR discovers VRFs from the Linux kernel, how to configure per-VRF routing protocol instances (BGP, OSPF, static), the complete route flow from protocol to packet forwarding, and how to leak routes between VRFs.

## How FRR Discovers VRFs

FRR does not create VRFs. It relies entirely on the Linux kernel. Whether you create a VRF manually (`ip link add`) or through an orchestrator — FRR discovers it the same way: via netlink from the kernel.

The discovery flow:

```
Administrator / Orchestrator
  │
  │  ip link add VRF-Blue type vrf table 1001
  │  ip link set VRF-Blue up
  ▼
Linux Kernel
  Creates VRF master device
  │
  │  netlink event: RTM_NEWLINK (type: vrf)
  ▼
FRR (zebra daemon)
  Receives netlink notification
  Registers VRF-Blue as a VRF context
  │
  ▼
BGP / OSPF / other daemons
  Can now create per-VRF instances
  (e.g., router bgp 65001 vrf VRF-Blue)
```

Key points:

1. **Zebra watches the kernel via netlink.** Zebra listens for `RTM_NEWLINK` events with the `vrf` device type. When a new VRF master device appears, zebra automatically registers it as a VRF context that other daemons can use.

2. **Interface binding works the same way.** When an interface is set as a slave of a VRF master device (`ip link set eth2 master VRF-Blue`), zebra detects this via netlink and associates the interface with the correct VRF context.

3. **VRF removal is also detected.** If a VRF device is deleted from the kernel (`ip link del VRF-Blue`), zebra receives an `RTM_DELLINK` event and removes the VRF context. Any per-VRF routing instances (BGP, OSPF) configured for that VRF become inactive — they remain in FRR's configuration but have no effect until the VRF is recreated in the kernel.

### Verifying VRF Discovery

To confirm that FRR has detected your VRFs, use vtysh:

```
show vrf
```

If no VRFs have been created in the kernel yet, the output is empty — `show vrf` only lists explicitly created VRFs, not the default VRF.

After creating VRFs in the kernel (see [Creating a VRF](vrf-in-linux.md#creating-a-vrf)), FRR detects them automatically:

```
vrf VRF-Blue id 285 table 1001
vrf VRF-Red  id 286 table 1002
```

If a VRF you created in the kernel does not appear here, check that the VRF device is up (`ip link set VRF-Blue up`) and that zebra is running (`systemctl status frr`).


## Configuring Per-VRF Routing in FRR

Once FRR has discovered a VRF from the kernel, you can create per-VRF instances of routing protocols. Each instance operates independently — with its own neighbors, routes, and policies.

You can run **multiple protocols in the same VRF** (e.g., both BGP and OSPF inside VRF-Blue), and you can use **different AS numbers** for BGP instances in different VRFs. Each VRF is a fully independent routing domain.

### Per-VRF BGP Instance

In BGP configuration, the number after `router bgp` is the **AS number** (Autonomous System number) — a unique identifier for your network in the BGP domain. The `remote-as` is the AS number of the neighbor you are peering with. When both sides use the same AS number, it is called **iBGP** (internal BGP); when they differ, it is called **eBGP** (external BGP).

```
router bgp 65001 vrf VRF-Blue
  neighbor 10.0.0.2 remote-as 65002
  address-family ipv4 unicast
    network 10.0.0.0/24
```

Breaking this down:
- `router bgp 65001 vrf VRF-Blue` — Start a BGP instance with AS 65001, scoped to VRF-Blue.
- `neighbor 10.0.0.2 remote-as 65002` — Peer with the router at 10.0.0.2 (which is in AS 65002).
- `address-family ipv4 unicast` — Enter the IPv4 unicast address family. BGP organizes routes by **address family** — a category that specifies the type of routing information (e.g., IPv4 unicast for standard IPv4 routing, IPv6 unicast for IPv6). Commands entered under an address family apply only to that type of traffic.
- `network 10.0.0.0/24` — Advertise the 10.0.0.0/24 prefix to BGP neighbors.

This BGP instance operates entirely within VRF-Blue:
- It only peers with neighbors reachable through VRF-Blue's interfaces.
- It only advertises routes from VRF-Blue's routing table.
- It is completely independent from the default VRF's BGP instance or any other VRF's BGP instance.

### Per-VRF OSPF Instance

```
router ospf vrf VRF-Blue
  network 10.0.0.0/24 area 0
```

This creates an OSPF process inside VRF-Blue. The `network` command tells OSPF to enable on interfaces whose IP addresses fall within `10.0.0.0/24`, and to place them in OSPF area 0 (the backbone area).

### Per-VRF Static Route

```
ip route 192.168.1.0/24 10.0.0.2 vrf VRF-Blue
```

This installs a static route inside VRF-Blue: to reach `192.168.1.0/24`, send traffic to `10.0.0.2` (which must be reachable within VRF-Blue).

### Verifying Per-VRF Routing State

**Routes:**

```
show ip route vrf VRF-Blue          # All routes in VRF-Blue's routing table
show bgp vrf VRF-Blue ipv4 unicast  # Only BGP-learned routes in VRF-Blue
show ip route vrf all               # Routes across all VRFs at once
```

**BGP peering status:**

```
show bgp vrf VRF-Blue summary
```

This shows whether BGP neighbors in VRF-Blue are established, how many prefixes have been received, and how long the session has been up. If a neighbor shows a state like `Active` or `Connect` instead of a prefix count, the peering session has not come up — check interface reachability and configuration on both sides.

**OSPF neighbor status:**

```
show ip ospf vrf VRF-Blue neighbor
```

This shows OSPF adjacencies within VRF-Blue. Neighbors in the `Full` state have successfully exchanged routing information. A neighbor stuck in `Init` or `2-Way` indicates a configuration mismatch (e.g., area mismatch, subnet mismatch, or hello/dead timer mismatch).


## How Routes Flow: From Protocol to Packet Forwarding

The previous sections showed how to configure routing protocols per VRF. This section explains what happens under the hood — the complete path a route takes from the moment it is learned by a routing protocol to the moment it is used to forward a packet.

### The Per-VRF Route Flow

This example traces a BGP route learned inside VRF-Blue:

```
                                                ┌──────────────────────┐
                                                │  RIB (control plane) │
FRR bgpd (VRF-Blue)                             │                      │
  Learns 10.1.0.0/24 from peer                  │  Route learning      │
  │                                             │  and selection       │
  ▼                                             └──────────────────────┘
FRR zebra (VRF-Blue RIB)
  Selects best route (by administrative distance)
  │
  │  netlink: install into kernel table 1001
- ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈ ┈
  │                                             ┌──────────────────────┐
  ▼                                             │  FIB (data plane)    │
Linux Kernel (table 1001 / LC-trie)             │                      │
  10.1.0.0/24 via 10.0.0.2 dev eth2             │  Packet forwarding   │
                                                └──────────────────────┘
```

Walking through each step:

1. **bgpd learns the route.** The BGP daemon running inside VRF-Blue receives a route for `10.1.0.0/24` from a peer. At this point the route exists only inside bgpd's own per-VRF RIB.

2. **bgpd sends the route to zebra.** bgpd passes the route to zebra, which maintains the master per-VRF RIB. If multiple protocols (BGP, OSPF, static) all offer a route to the same prefix, zebra selects the best one by administrative distance.

3. **Zebra installs the route into the kernel.** Zebra uses netlink to install the winning route into the kernel's routing table for VRF-Blue (table 1001). This table is the per-VRF FIB — the data structure the kernel uses to forward packets.

4. **The kernel forwards packets.** When a packet arrives on a VRF-Blue interface destined for `10.1.0.0/24`, the kernel looks up the destination in table 1001 and forwards accordingly.

### Per-VRF RIB and FIB

The route flow diagram above annotates each layer as "per-VRF." This is the defining property of VRF — every layer maintains a completely separate set of routing and forwarding entries for each VRF:

| Layer | What Each VRF Gets | Implementation Detail |
|---|---|---|
| **FRR (routing suite)** | A separate RIB inside zebra. BGP, OSPF, and other daemons run per-VRF instances that feed routes into their respective VRF's RIB. | Each VRF is a `struct zebra_vrf` with its own `route_table[AFI][SAFI]` array — a completely independent set of routing tables per address family. |
| **Linux kernel** | A separate FIB. Each routing table ID (e.g., `1001`) holds its own forwarding entries, searched independently during packet forwarding. | Each table is a `struct fib_table` backed by its own LC-trie (Level-Compressed trie — a memory-efficient tree structure optimized for longest-prefix-match lookups). |

### Why Full Isolation Requires Both

If the RIB were shared, route selection would break — a BGP route learned in VRF-Blue could compete with an OSPF route in VRF-Red for the same prefix, defeating the purpose of isolation. If the FIB were shared, forwarding would break — a packet arriving in VRF-Blue could match a route from VRF-Red and be sent to the wrong destination.

- **Separate RIBs** ensure that route *learning* and *selection* are independent per VRF.
- **Separate FIBs** ensure that packet *forwarding* is independent per VRF.


## Route Leaking Between VRFs

By default, VRFs are **fully isolated** — no traffic can cross VRF boundaries. **Route leaking** is the deliberate, configured act of sharing specific routes between VRFs.

Route leaking can also be done at the kernel level using cross-table routes and `ip rule` (see [Route Leaking at the Kernel Level](vrf-in-linux.md#route-leaking-at-the-kernel-level)), but FRR's methods are more manageable and the recommended approach for anything beyond a quick one-off route.

### Why Route Leaking?

Common scenarios:

- A management VRF needs to reach a monitoring service in the production VRF.
- Two departments need access to a shared DNS or authentication server.
- A test VRF needs temporary access to a production API.

Route leaking is always an explicit action. There is no accidental cross-VRF traffic.

### Method 1: BGP `import vrf`

FRR's BGP daemon can import routes from one VRF into another. This is the most common method.

#### How It Works

By default, a BGP instance only knows about routes learned from BGP peers. It does not automatically include the VRF's own directly-connected subnets (the networks attached to its interfaces). To make these local subnets available for other VRFs to import, you must tell BGP to **redistribute** them.

**Redistribute** means taking routes that BGP did not learn itself (e.g., connected routes, OSPF routes, static routes) and injecting them into BGP's routing table so it can advertise or share them. The `redistribute connected` command specifically takes the VRF's directly-connected subnets and treats them as BGP routes.

#### Configuration

Each VRF must have a BGP instance that redistributes its connected routes. Then each VRF imports the other:

```
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
```

After this configuration:
- VRF-Blue sees VRF-Red's subnets as BGP-learned routes.
- VRF-Red sees VRF-Blue's subnets as BGP-learned routes.
- Hosts in either VRF can now reach hosts in the other.

#### Filtering Leaked Routes with a Route-Map

You can filter leaked routes using a **route-map** — a programmable filter in FRR that matches routes by criteria (such as prefix, community, or next hop) and then permits or denies them. This enables selective leaking — importing only the specific routes you need rather than everything.

First, define a **prefix-list** that specifies which prefixes to match, and a **route-map** that references it:

```
ip prefix-list MONITORING-PREFIX seq 10 permit 10.100.0.0/24

route-map ALLOW-MONITORING-ONLY permit 10
  match ip address prefix-list MONITORING-PREFIX
exit

route-map ALLOW-MONITORING-ONLY deny 20
exit
```

Breaking this down:
- The prefix-list `MONITORING-PREFIX` matches only the `10.100.0.0/24` subnet.
- The route-map `ALLOW-MONITORING-ONLY` has two entries (called **sequences**, numbered by the value after `permit`/`deny`). Sequence 10 permits routes that match the prefix-list. Sequence 20 denies everything else. Route-map entries are evaluated in order — the first match wins.

Then apply the route-map to the import:

```
router bgp 65000 vrf VRF-Blue
  address-family ipv4 unicast
    import vrf VRF-Red
    import vrf route-map ALLOW-MONITORING-ONLY
  exit-address-family
```

> **Important:** The `import vrf route-map` applies to **all** VRF imports under that address family, not to a specific source VRF. If you import from multiple VRFs, the same route-map filters routes from all of them.

#### Verifying Leaked Routes

After configuring route leaking, confirm that the imported routes appear:

```
show ip route vrf VRF-Blue
```

Leaked routes appear with the protocol identifier `B` (BGP) and show the source VRF in the route details. For example:

```
B>* 10.0.2.0/24 [20/0] is directly connected, dummy1 (vrf VRF-Red), ...
```

The `(vrf VRF-Red)` annotation confirms this route was imported from VRF-Red.

### Method 2: Static Route with Cross-VRF Nexthop

You can install a static route in one VRF with a next hop resolved through another VRF:

```
ip route 10.1.0.0/24 10.0.0.2 nexthop-vrf VRF-Red vrf VRF-Blue
```

This installs a route in VRF-Blue for `10.1.0.0/24`, but the next hop (`10.0.0.2`) is looked up in VRF-Red's routing table. This method is useful for one-off routes but does not scale as well as BGP import.

### Removing Route Leaking

To restore full isolation, remove the import statements:

```
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
```

After removal, cross-VRF routes disappear and isolation is fully restored.
