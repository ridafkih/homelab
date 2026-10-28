# 0014. Cutover from Arch

## Context

The box moves from Arch to NixOS in one downtime window, with every container, volume, network and piece of state carried over and a way back if the first boot goes wrong.

## Decision

- [docs/cutover.md](../cutover.md) is the runbook: pre-flight, the Windows VM, state, install, post-boot checks, rollback, an optional firewall tightening and cleanup.
- All state (Docker volumes, `.data` with Authentik's files moved under it, `/var/lib/tailscale`, the ssh host keys, `/etc/machine-id` and the host age key) is restored onto the new root before the first reboot, so the Compose units never start against empty data. The first NixOS boot is the point of no return.
- Data-disk writes during cutover happen only under `/mnt/disk2/migration` and `/data/windows`. Rollback images and the EFI boot entries are saved there first.
- The install runs from the NixOS ISO over the KVM's virtual media with `nixos-install --flake github:ridafkih/homelab/nixos#homelab`.
- Everything that only matters until cutover lives in `migration/`, and the runbook's last cleanup step deletes it.
