# Build host

The NixOS configuration in this repository targets an x86_64-linux machine. The machine that writes the code is an aarch64-darwin Mac with no Nix and little free disk, so builds and NixOS VM tests run on the homelab box itself while it is still on Arch. In this document that box is `<build-host>`: an ssh destination that logs in as the box's regular user.

This setup is temporary. Everything below lives on the Arch install and disappears when the box is reinstalled as NixOS at cutover. Until then the box is live, so the build host is add-only and low priority: it must never disturb a running container or service.

Decision record: [0002, build host and how code reaches it](decisions/0002-build-host-and-checkout-transport.md).

## Install

Nix is installed in multi-user mode with the Determinate installer (nix-installer 3.24.1), asking for upstream Nix rather than the Determinate distribution. The binary is downloaded to a fresh directory and run directly, not piped into a shell, and every setting is passed as its own `--extra-conf` so the daemon never starts unconfigured:

```sh
curl -fsSL -o nix-installer https://install.determinate.systems/nix/nix-installer-x86_64-linux
chmod +x nix-installer
./nix-installer install linux --help | grep -e --prefer-upstream-nix
sudo ./nix-installer install linux --prefer-upstream-nix --no-confirm \
  --extra-conf 'max-jobs = 2' \
  --extra-conf 'cores = 4' \
  --extra-conf 'system-features = kvm nixos-test big-parallel benchmark' \
  --extra-conf 'experimental-features = nix-command flakes' \
  --extra-conf 'min-free = 53687091200' \
  --extra-conf 'max-free = 107374182400'
```

If a future installer drops `--prefer-upstream-nix`, use the official nixos.org multi-user installer instead (`sh <(curl -L https://nixos.org/nix/install) --daemon --yes --nix-extra-conf-file extra.conf`, with the same six settings in `extra.conf`). The Determinate Nix distribution is not used either way.

The install aborts unless every preflight check passes:

- `df -B1 --output=avail /` shows more than 100 GB free. The store shares the root disk with Docker's data.
- `/nix` and `/etc/nix` do not exist.
- There is no `nixbld` group or `nixbld1` user, and GID 30000 and UIDs 30001 to 30032 are free.
- `sudo -n true` works and `/dev/kvm` is present and writable.

`trusted-users` is left unset, so it stays at its default of `root` alone. The build user gets no extra privileges over the daemon.

The first install put upstream Nix 2.35.4 on the box. The installer writes its own defaults to `/etc/nix/nix.conf`, including `max-jobs = auto`, `auto-optimise-store = true` and FlakeHub as an extra trusted substituter, then includes `/etc/nix/nix.custom.conf`, which holds the settings above and wins. The FlakeHub cache is only used when a trusted user asks for it, and no one is trusted but root. `nix config show` lists `fetch-tree` among the experimental features too: Nix turns it on with `flakes`.

## Limits

`/etc/nix/nix.custom.conf`, written by the installer from the `--extra-conf` flags:

| Setting | Why |
| --- | --- |
| `max-jobs = 2` | Two derivations at a time keeps CPU and memory pressure bounded next to the live containers. |
| `cores = 4` | Four cores per derivation, so at most eight of the box's sixteen threads go to builds. |
| `system-features = kvm nixos-test big-parallel benchmark` | Lets NixOS VM tests run with KVM. This list replaces the defaults rather than adding to them, so all four are named. |
| `experimental-features = nix-command flakes` | The configuration is a flake. |
| `min-free = 53687091200` | When free space drops below 50 GiB, Nix collects garbage during a build. |
| `max-free = 107374182400` | It stops collecting once 100 GiB is free. |

systemd drop-in `/etc/systemd/system/nix-daemon.service.d/50-build-host.conf`:

```ini
[Service]
Nice=19
IOSchedulingClass=idle
CPUSchedulingPolicy=batch
MemoryHigh=16G
MemoryMax=24G
```

- `Nice=19` and `CPUSchedulingPolicy=batch` put every build behind the containers for CPU.
- `IOSchedulingClass=idle` gives builds disk time only when nothing else wants it.
- `MemoryHigh=16G` throttles and reclaims the daemon's cgroup before it gets large. `MemoryMax=24G` is the hard ceiling, so a runaway build is killed inside its own cgroup and never pushes the containers into the OOM killer. The box has no swap.

The daemon and its builders, including the VMs of `nixosTest` checks, run inside this cgroup.

## Never restart anything else

The only unit that may ever be restarted on the box is `nix-daemon`, and only to apply its own configuration. Never restart, stop or reload `docker`, `containerd`, `tailscaled`, any container, or any other service, and never touch boot or network configuration. No pattern kills (`pkill -f`, `killall`).

Never build, test or run `nix` inside `~/homelab`. That checkout is what the live box runs. All work happens in `~/homelab-nixos-build`.

## Getting code to the box

Code reaches the box as git commits, not copied files. Flakes then evaluate exactly what git sees, and an uncommitted file simply is not there. The box holds a bare repository at `~/homelab-nixos-build/repo.git`, made once with `git init --bare`, and each task builds in its own clone next to it, so parallel builds never overwrite each other.

```sh
git push --force <build-host>:homelab-nixos-build/repo.git HEAD:refs/heads/<task-id>
ssh <build-host> 'set -eu; cd ~/homelab-nixos-build; test -d <task-id> || git clone -q repo.git <task-id>; git -C <task-id> fetch -q origin <task-id>; git -C <task-id> checkout -q -f --detach FETCH_HEAD'
ssh <build-host> 'cd ~/homelab-nixos-build/<task-id> && nice -n19 ionice -c3 nix build -L .#checks.x86_64-linux.<name>'
```

Build only the check you need. A full `nix flake check` runs once, at integration.

## Running commands on the box

Run every heavy command under `nice -n19 ionice -c3`, including commands the daemon does not run itself.

QEMU started from `nixos-rebuild build-vm` or the VM smoke script runs as the login user, outside the daemon's cgroup, so `MemoryMax=24G` does not cover it. Start it under its own cap:

```sh
systemd-run --user --scope -p MemoryMax=6G nice -n19 ionice -c3 ./result/bin/run-<name>-vm
```

Every test node sets `virtualisation.memorySize` explicitly (1024 to 2048 MiB unless the test needs more), so no VM inherits a default that does not fit.

Remove `result*` symlinks and any `*.qcow2` disk images when a run finishes.

## Garbage collection

`min-free` and `max-free` keep the store from filling the disk on their own. To reclaim space by hand:

```sh
nice -n19 ionice -c3 nix store gc
```

## Checking the host

```sh
ssh <build-host> 'nix --version'
ssh <build-host> 'nice -n19 ionice -c3 nix run nixpkgs#hello'
ssh <build-host> 'systemctl show nix-daemon -p Nice -p IOSchedulingClass -p CPUSchedulingPolicy -p MemoryHigh -p MemoryMax'
ssh <build-host> "nix config show | grep -E '^(max-jobs|cores|system-features|experimental-features|min-free|max-free|trusted-users) '"
```

`nix --version` prints `nix (Nix) <version>`, hello prints `Hello, world!`, and the daemon shows `Nice=19`, `IOSchedulingClass=3`, `CPUSchedulingPolicy=3`, `MemoryHigh=17179869184` and `MemoryMax=25769803776`.

`scripts/tests/build-host-live.sh <evidence-dir> ssh <build-host>` repeats these checks and compares running containers, services, network state and the `~/homelab` checkout against the snapshots taken before the install. `scripts/tests/build-host-doc.sh` checks this document.

## Uninstall

Cutover removes all of this along with the Arch install. To remove it sooner:

```sh
sudo /nix/nix-installer uninstall
sudo rm -rf /etc/systemd/system/nix-daemon.service.d
sudo systemctl daemon-reload
rm -rf ~/.nix-profile ~/.local/state/nix ~/.cache/nix ~/homelab-nixos-build
```

The uninstaller removes `/nix`, `/etc/nix`, the daemon units, the `nixbld` users and group, and the shell profile hooks it added. If the nixos.org fallback installer was used instead, follow the multi-user uninstall steps in the Nix manual, then remove the same paths.
