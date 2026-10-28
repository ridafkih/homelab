# 0007. Network identity, DNS and firewall

## Context

The box must come back on 10.0.0.98, because the LAN's DNS points at AdGuard there, keep today's reachability, and not let networkd undo the egress rules. Identifiers like the machine-id and MAC addresses must not end up in a public repo.

## Decision

- `hosts/homelab/hardware.nix`: the initrd modules for the NVMe and USB disks, `kvm-amd`, kernel 6.18, systemd-boot with ten generations, AMD microcode and redistributable firmware. No kernel parameters, no blacklist.
- `modules/network.nix`: systemd-networkd, DHCP on `eno1` with the same client identity as Arch (vendor DUID, the same IAID, and the machine-id copied over at cutover), router advertisements for IPv6, no DNS from DHCP or RA, temporary addresses off, Wi-Fi unmanaged. networkd leaves foreign rules and routes alone.
- `modules/dns.nix`: resolved off, nameservers `127.0.0.1` (AdGuard) then `1.1.1.1`. The Docker daemon has no `dns` key.
- `modules/firewall.nix`: the NixOS firewall on (iptables-nft), `tailscale0` trusted, TCP 22, 53, 80, 443, 3000, 3389, 4317, 4318, 4327, 4328, 8006 and UDP 53, 3389 open, as on Arch. nftables mode stays off.
- `modules/ipv6-ingress.nft` is the Arch IPv6 ingress table unchanged, loaded by a oneshot before the network and Docker.

## Consequences

- The name `eno1` is load-bearing.
- Closing RDP, the Windows web viewer and OTLP to the LAN is offered in the runbook as an unapplied diff.
- Ports Docker publishes bypass the NixOS firewall, as on Arch.
- If DHCP hands out a different address at cutover, the runbook falls back to a static 10.0.0.98/24.
