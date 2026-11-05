# 0015. Reverse-path filtering and the egress floor

## Context

On the first NixOS boot tailscaled stayed logged out: every control-plane connection timed out. NixOS's firewall drops inbound packets in `nixos-fw-rpfilter` unless a reverse-path lookup for their source succeeds (`rpfilter --loose --validmark`). Replies from the control plane and DERP arrive on `eno1` unmarked, so the lookup skips rule 5205, finds no default route under 5280's `suppress_prefixlength 0`, and lands on the 5300 `unreachable` floor. The reply is dropped. Tailscale's own connmark rules, which carry its `0x80000` mark onto replies, are only installed once it is up, so it can never get there. Arch had no reverse-path filter, which is why the VM tests and the Arch box never showed it.

## Decision

`modules/egress-policy.nix` inserts `-m conntrack --ctstate ESTABLISHED,RELATED -j RETURN` at the top of `nixos-fw-rpfilter`, for IPv4 and IPv6, whenever the reverse-path check is on. Replies to connections the box opened skip the check; new inbound flows are still checked. The firewall flushes and rebuilds the chain on every reload, so the rule is never duplicated. `tests/egress.nix` checks it is there.

## Consequences

- tailscaled reaches the control plane and DERP through rule 5205 from the first second of boot, so the kill switch no longer locks out the thing it waits for.
- Anti-spoofing still applies to every new inbound flow.
