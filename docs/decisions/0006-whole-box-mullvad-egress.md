# 0006. Whole-box Mullvad egress with a kill switch

## Context

The whole box, host and containers, should leave the internet through Mullvad, and fail closed rather than leak when Mullvad or Tailscale is down. On Arch only some traffic went through the Tailscale exit node, and nothing stopped a leak while tailscaled was down (a 14-second leak at boot was measured).

Cloudflare's tunnel edge refuses connections from every Mullvad relay tested (198.41.192.x, 198.41.200.x, 2606:4700:a0::), so the two cloudflared tunnels can't come up through Mullvad.

## Decision

Mullvad through a Tailscale exit node, with policy routing as a kill switch and one carve-out for Cloudflare's tunnel edge.

- `modules/tailscale.nix`: Tailscale as a routing client, `--exit-node-allow-lan-access`, `--accept-dns=false`, `TS_DEBUG_MTU=1500`. No auth key: `/var/lib/tailscale` is carried over at cutover.
- The exit node is always a Mullvad relay. `--exit-node=auto:any` is not used: Tailscale's automatic choice ranks ordinary tailnet exit nodes above Mullvad ones, so any machine that later advertised itself as an exit node would quietly carry the box's traffic out through its own ISP. Instead, `mullvad-exit.service` runs every minute (`mullvad-exit.timer`). If the current exit node is not an online peer tagged `tag:mullvad-exit-node`, or automatic selection is on, it pins one: the current Mullvad node if there is one, else Tailscale's suggestion if that is a Mullvad node, else the online Mullvad node with the highest location priority. With no online Mullvad node it changes nothing and fails, so the unit shows red while the kill switch keeps traffic in.
- `modules/egress-policy.nix` declares `homelab.egress.enable` (default `true`) and `egress-policy.service`, which runs at `sysinit`, before the network, tailscaled and Docker, and never stops. Its rules, for IPv4 and IPv6:

| Priority | Selector | Action |
| --- | --- | --- |
| 5200 | to each Cloudflare tunnel edge prefix (`homelab.cloudflareTunnelEdge`) | `lookup main` |
| 5205 | `fwmark 0x80000/0xff0000` (Tailscale's own control traffic) | `lookup main` |
| 5280 | all | `lookup main suppress_prefixlength 0` |
| 5300 | all | `unreachable` |

- Rule 5280 lets through only main's non-default routes, so LAN, Docker bridges and on-link addresses keep working while every other destination falls to Tailscale's table 52 or to the 5300 floor.
- The service adds the floor first, adds each missing rule, then prunes stale ones. It never deletes and re-adds, so a restart never opens a gap.
- systemd-networkd is told not to manage foreign rules or routes, so it never removes these.

## Consequences

- With tailscaled or Mullvad down, nothing leaves the box except LAN and Docker traffic, Tailscale's control bootstrap and the Cloudflare tunnel edge.
- The Cloudflare tunnel edge is the one flow that skips Mullvad. Cloudflare already knows this box from the tunnel tokens, so it reveals nothing new, but it is an exception to "the whole box".
- `tests/egress.nix` proves the up and down states for host and container traffic on both families, that the rules survive networkd reloads and restarts, and, by watching `ip monitor rule`, that the floor is never deleted while the service restarts. `tests/mullvad-exit.nix` proves the exit-node choice against a fake Tailscale.
- If the router ever forwards WAN ports to the box, replies would go out through Mullvad or hit the floor.
