# Network topology — Oracle Cloud VCN

Reference: this host `mercury` lives inside an Oracle Cloud Infrastructure
(OCI) Virtual Cloud Network (VCN). All subnets, route tables, and security
lists are managed in the OCI Console.

## Host identity

| Field | Value |
|---|---|
| Hostname | `mercury` |
| Primary private IPv4 | `10.0.0.171/24` |
| Primary interface | `enp0s6` |
| IPv6 link-local | `fe80::17ff:fe05:6263/64` |
| Default gateway | `10.0.0.1` (DHCP-provided) |

## Network interfaces

```
$ ip -brief addr show
lo               UNKNOWN        127.0.0.1/8 ::1/128
enp0s6           UP             10.0.0.171/24 metric 100 fe80::17ff:fe05:6263/64
```

```
$ ip route
default via 10.0.0.1 dev enp0s6 proto dhcp src 10.0.0.171 metric 100
10.0.0.0/24 dev enp0s6 proto kernel scope link src 10.0.0.171 metric 100
10.0.0.1 dev enp0s6 proto dhcp scope link src 10.0.0.1 metric 100
169.254.0.0/16 dev enp0s6 proto dhcp scope link metric 100
169.254.169.254 dev enp0s6 proto dhcp scope link metric 100   # OCI metadata endpoint
```

## DNS / IMDS

- **Metadata service (IMDS)**: `169.254.169.254` — standard OCI link-local endpoint.
  Used by `oracle-cloud-agent` snap to report instance health, custom logs,
  and compute monitoring (all enabled per the IMDS response we captured).
- **Public DNS resolution**: not configured via DHCP on this host; uses the
  VCN's default DNS resolver (Oracle's `10.0.0.2` and `10.0.0.3` based on
  OCI conventions).

## VCN layout (high level)

This host is in a single VCN with at least one subnet. The exact VCN CIDR,
subnet CIDR, and security-list rules are visible in the OCI Console:

- **Console → Networking → Virtual Cloud Networks → `<this VCN>`**

What we DO know from the live state:

- The host is reachable at `10.0.0.171/24` (RFC1918 private space — this is
  a private subnet, not a public one).
- The default gateway `10.0.0.1` is OCI's standard router IP for `/24` subnets.
- Public ingress for all `*.mercury.garden` subdomains goes through:
  - DNS: public A/AAAA records at the registrar pointing at the VCN's
    reserved public IP (the IP that the internet-facing nginx terminates on).
  - TLS: Let's Encrypt certs (see `secrets/inventory.yaml → letsencrypt-*`).
  - Reverse proxy: nginx on port 443 (see `inventory.yaml → services.nginx`).
- OAuth flow: oauth2-proxy at `127.0.0.1:4180` (see
  `inventory.yaml → services.oauth2-proxy`), fronted by nginx
  `auth_request` directives (see `nginx/snippets/oauth2-proxy-*.conf`).

## Files in this directory

| File | What it tracks | How to capture | How to restore |
|---|---|---|---|
| `hostname` | `/etc/hostname` (just `mercury`) | `scripts/capture.sh` | `sudo cp network/hostname /etc/hostname` |
| `hosts` | `/etc/hosts` | `scripts/capture.sh` | `sudo cp network/hosts /etc/hosts` |
| `vcn-topology.md` | This file (hand-written reference) | manual edits only | n/a |

## Things NOT tracked here (and why)

- **IP address** (`10.0.0.171`) — already in `host.yaml` as `private_ipv4`.
  Subject to change if the instance is rebuilt.
- **OCI VCN CIDR / subnet / route table IDs** — these are OCI-managed and
  visible only in the OCI Console. Document them here if they change.
- **Public IP** (the one that maps to `mercury.garden`) — OCI-assigned,
  visible in the instance details page. Not in this repo because it can
  change when the instance is rebuilt.
- **TLS certs / private keys** — see `secrets/inventory.yaml` for pointer,
  `/etc/letsencrypt/live/` for storage.
- **DNS records** (A/AAAA/CNAME for `*.mercury.garden`) — managed at the
  registrar, not in this host.