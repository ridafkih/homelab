# 0009. NVIDIA driver and CDI for Jellyfin

## Context

Jellyfin uses the RTX 4080 Super for NVENC. Arch ran the 615 open driver through `runtime: nvidia` and Arch-only units; nixos-26.05 ships the 595 production driver and native CDI support in Docker.

## Decision

- `modules/nvidia.nix`, under `homelab.gpu.enable`: the open kernel module, the nixpkgs production driver, the persistence daemon, `nvidia` and `nvidia_uvm` loaded at boot, and the NVIDIA container toolkit's CDI generator. The CDI generator runs after module loading and the persistence daemon; Docker wants both but never requires them.
- Unfree NVIDIA packages are allowed by name through `homelab.unfreeAllow`.
- Jellyfin gets the GPU through `devices: [ "nvidia.com/gpu=all" ]`. `apps/jellyfin/compose.nogpu.yaml` removes it for the test VM.

## Consequences

- The driver steps down from 615 to 595. If NVENC fails after cutover, the fallback is pinning 615 with `mkDriver`.
- A GPU or CDI failure degrades Jellyfin only.
