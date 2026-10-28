# Cutover

How the box moves from Arch to the NixOS config in this repo, and how it goes back if it has to. The window is Rida's to pick; nothing here runs until he has picked it.

Conventions:

- `<box>` is an ssh destination that logs in as `rida` on the box. On the NixOS installer the commands run as root on its console over the GL.iNet KVM.
- Each step is a command, what it should print, and a marker. **STOP** means don't go on: fix the cause, or go to [Rollback](#rollback). **FIX-FORWARD** means the box is usable; fix it on NixOS and carry on.
- Everything the cutover writes to the data disks goes under `/mnt/disk2/migration` (images, copies, rollback images) or `/data/windows` (the Windows VM disk). Nothing else on the data disks is touched.
- Secrets are only ever moved, by path, with `umask 077`. No step prints, decrypts or pastes one.
- **The first NixOS boot is the point of no return.** Until then, rollback puts Arch back exactly as it was. From the first boot on, the services write new data to `/data` and the restic repos, which a rollback keeps (see [Rollback](#rollback)).

## The one exception to "the entire box through Mullvad"

Everything on the box, host and containers alike, goes out through Mullvad via the Tailscale exit node, with one exception: the two Cloudflare tunnels (Authentik and rida.sh) connect straight to Cloudflare's tunnel edge. Cloudflare's tunnel edge refuses connections from every Mullvad relay we tested, so a tunnel forced through Mullvad never comes up. Cloudflare already knows this box, because the tunnels log in to it with their tokens, so going direct reveals nothing new. The exception covers only Cloudflare's published tunnel-edge prefixes (`homelab.cloudflareTunnelEdge` in `modules/options.nix`, rule 5200 in `egress-policy`). Everything else fails closed: if tailscaled or the Mullvad exit is down, the kill switch leaves traffic unreachable instead of letting it leak to the ISP ([0008](decisions/0008-whole-box-mullvad-egress.md)).

## Pre-flight

All on Arch, while it is still serving. Nothing here is destructive.

1. **Dry-run the virtual media once, a few days ahead.** In the KVM's web UI, attach the NixOS 26.05 minimal ISO as virtual media, reboot, and pick the virtual drive in the firmware's one-time boot menu. Expected: the installer reaches a root shell, `ip -4 addr show eno1` has a LAN address and `curl -sI https://github.com` answers. Reboot into Arch and detach the ISO. This costs about ten minutes of downtime. **STOP** if the ISO won't boot: the install has no other path that avoids kexec, and kexec is never used on this GPU box.

2. **Free space on disk2.**

   ```sh
   df -BG --output=avail /mnt/disk2
   sudo du -sh /var/lib/docker/volumes /home/rida/homelab/.data /home/rida/homelab/.authentik /home/rida/windows
   sudo df -BG --output=used /
   ```

   The migration area needs about 20 GB of images, about 70 GB of volumes, about 15 GB of `.data` once the dropped dirs are left out, and a compressed image of the NVMe no larger than the used space on `/`. Expected: at least 600 GB available. **STOP** below that.

3. **Make the working area and capture the boot entries.**

   ```sh
   sudo install -d -m 0700 /mnt/disk2/migration /mnt/disk2/migration/rollback /mnt/disk2/migration/state
   sudo efibootmgr -v | sudo tee /mnt/disk2/migration/rollback/efibootmgr-v.txt
   ```

   Expected: a `BootOrder` line and a GRUB entry pointing at the NVMe's ESP. Rollback uses this file to put Arch first again.

4. **List what the Arch checkout holds outside git.**

   ```sh
   git -C /home/rida/homelab status --short --ignored
   ```

   Expected: only the env files and their `*.before-*`/`*.bak` copies, `.data/` and `.authentik/`. **STOP** if some other untracked directory holds state: it has to be added to the copy in [State](#state) first.

5. **Run the Arch backup once more, then restore from it and diff.**

   ```sh
   sudo systemctl start homelab-backup.service
   sudo restic -r /mnt/disk1/backup/restic --password-file /root/.config/restic/homelab.pass snapshots --latest 1
   sudo restic -r /mnt/disk2/backup/restic --password-file /root/.config/restic/homelab.pass snapshots --latest 1
   sudo restic -r /mnt/disk2/backup/restic --password-file /root/.config/restic/homelab.pass restore latest --target /var/tmp/restore-test --include /etc/ssh
   sudo diff -rq /var/tmp/restore-test/etc/ssh /etc/ssh
   sudo rm -rf /var/tmp/restore-test
   ```

   Expected: both repos show a snapshot from a few minutes ago with host `homelab`, and `diff -rq` prints nothing. **STOP** if either repo has no fresh snapshot or the diff shows differences.

6. **Re-encrypt the secrets in case a live value changed.** On the box's build clone (see `docs/build-host.md`), run `scripts/migrate-secrets.sh` the way [0004](decisions/0004-secrets-sops-layout-and-rendered-env-files.md) describes, in this order: `--preflight`, `--fidelity`, `--encrypt`, `--check-leaks`. The script never prints a value, and `--encrypt` streams ciphertext back to the machine that holds the admin key.

   ```sh
   nix shell --inputs-from . nixpkgs#sops nixpkgs#python3 -c scripts/migrate-secrets.sh --fidelity --env /home/rida/homelab/.env --openseo-env /home/rida/homelab/openseo/.env --restic-pass /root/.config/restic/homelab.pass
   ```

   Expected: `--fidelity` passes. If `--encrypt` changes `secrets/homelab.yaml`, commit it and push `nixos` before the window. **STOP** on a fidelity failure.

7. **Check the host age key, then put it on the box.** On the admin machine (the one with 1Password access and the sops admin key), `tests/secrets-age-keys.sh <vault>` checks that the `homelab sops host age key` item exists in 1Password and matches the host recipient in `.sops.yaml`, without printing it. Then copy it straight to its path on Arch, where [State](#state) picks it up:

   ```sh
   tests/secrets-age-keys.sh '<vault>'
   op read 'op://<vault>/homelab sops host age key/<field>' | ssh <box> 'sudo install -d -m 0700 /var/lib/sops-nix && sudo sh -c "umask 077 && cat > /var/lib/sops-nix/key.txt"'
   ```

   On the box, confirm the key's public half is the host recipient:

   ```sh
   AGE=$(nix build --no-link --print-out-paths nixpkgs#age)
   sudo "$AGE/bin/age-keygen" -y /var/lib/sops-nix/key.txt | grep -qxF "$(curl -fsSL https://raw.githubusercontent.com/ridafkih/homelab/nixos/.sops.yaml | sed -nE 's/.*&host (age1[a-z0-9]+).*/\1/p')" && echo host key matches
   ```

   Expected: `ok: age keys are in 1Password and match .sops.yaml`, then `host key matches`. **STOP** otherwise: without this key no secret decrypts on NixOS.

8. **Re-run the Mullvad and Cloudflare edge probes.** Arch already routes through the Mullvad exit node, so from the host:

   ```sh
   curl -fsS https://am.i.mullvad.net/json
   for ip in 198.41.192.7 198.41.200.13; do timeout 5 bash -c "</dev/tcp/$ip/7844" && echo "$ip open via Mullvad" || echo "$ip refused via Mullvad"; done
   ```

   Expected: the JSON has `"mullvad_exit_ip":true`, and both edge addresses are refused. If an edge address is open through Mullvad, the carve-out may no longer be needed; note it for Rida and carry on (FIX-FORWARD, after cutover).

9. **Re-check Cloudflare's published tunnel prefixes against the config.**

   ```sh
   nix eval --raw github:ridafkih/homelab/nixos#nixosConfigurations.homelab.config.homelab.cloudflareTunnelEdge --apply 'e: builtins.concatStringsSep "\n" (e.ipv4 ++ e.ipv6)'
   curl -fsSL https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-with-firewall/ | grep -oE '198\.41\.[0-9.]+/[0-9]+|2606:4700:[0-9a-f:]+/[0-9]+' | sort -u
   for name in region1.v2.argotunnel.com region2.v2.argotunnel.com; do getent ahosts "$name" | awk '{print $1}' | sort -u; done
   ```

   Expected: the page lists exactly the prefixes in `homelab.cloudflareTunnelEdge`, and every address the two region names resolve to sits inside one of them. **STOP** if the page lists a prefix the config lacks: update `modules/options.nix` first, or the tunnels can't reach the edge after cutover.

10. **Save the pinned images.** On a fresh clone of the `nixos` branch, list every pinned image and save the set:

    ```sh
    git clone -q --depth 1 --branch nixos https://github.com/ridafkih/homelab /var/tmp/homelab-nixos
    grep -rhoE 'image: *[^ ]+@sha256:[0-9a-f]{64}' /var/tmp/homelab-nixos/apps | awk '{print $2}' | sort -u > /var/tmp/pinned-images.txt
    sudo docker save -o /mnt/disk2/migration/images.tar $(cat /var/tmp/pinned-images.txt)
    docker images --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}} {{.ID}}' > /var/tmp/image-tags.txt
    sudo cp /var/tmp/pinned-images.txt /var/tmp/image-tags.txt /mnt/disk2/migration/
    rm -rf /var/tmp/homelab-nixos
    ```

    Expected: `docker save` finishes without "No such image" (about 20 GB). This is insurance, not the normal path: NixOS pulls the pinned digests on first start. A save from Arch's image store doesn't keep registry digests, so loading it later needs a `docker tag` per image from `image-tags.txt` and a one-off removal of that service's `@sha256` pin until it can be re-pinned ([0006](decisions/0006-image-pinning.md)). **STOP** if any pinned image is missing locally: the box isn't running what the repo pins.

11. **Record the Tailscale identity.**

    ```sh
    tailscale status --self --json | jq -r '.Self.HostName, .Self.TailscaleIPs[0]' | sudo tee /mnt/disk2/migration/tailscale-self.txt
    ```

    Post-boot compares against this to prove the node kept its identity.

## Windows VM

The VM's disk sits on the NVMe at `~/windows/windows-storage`, which the install wipes, and restic excludes it. It moves to `/data/windows`, where `apps/windows/compose.yaml` mounts it.

```sh
docker stop -t 120 windows11
docker inspect -f '{{.State.Status}}' windows11
sudo install -d -m 0755 /data/windows
sudo find /data/windows -mindepth 1 -maxdepth 1 | wc -l
sudo cp --sparse=always -a /home/rida/windows/windows-storage/. /data/windows/
(cd /home/rida/windows/windows-storage && sudo find . -type f -exec sha256sum {} +) | sudo tee /mnt/disk2/migration/windows.sha256
(cd /data/windows && sudo sha256sum -c --quiet /mnt/disk2/migration/windows.sha256) && echo windows copy verified
sudo du -sh --apparent-size /data/windows && sudo du -sh /data/windows
```

Expected: the container reports `exited` after Windows shuts itself down; `/data/windows` starts empty (`0`); the checksum check prints `windows copy verified`; and the two `du` lines show about 64 GB apparent but only the used space (about 13 GB) on disk. **STOP** if the directory wasn't empty or any checksum fails.

## State

Downtime starts here. Arch's `~/homelab` is left exactly as it is, so a rollback before the first NixOS boot finds it unchanged. The copy goes to `/mnt/disk2/migration/state` and is restored into the new root in [Install](#install).

1. **Check Docker's layout.** Volumes are plain directories under the data root, whatever the storage driver, and NixOS keeps Docker's default data root.

   ```sh
   docker info --format '{{.DockerRootDir}} {{.Driver}}'
   ```

   Expected: `/var/lib/docker overlay2`. **STOP** if the data root isn't `/var/lib/docker`: the volume copy below would miss the volumes. The storage driver only affects images, which are pulled again.

2. **Stop everything.**

   ```sh
   M=/mnt/disk2/migration
   docker volume ls -q | sort | sudo tee $M/state/volumes.txt
   sudo systemctl stop homelab-backup.timer
   docker compose -p homelab down
   docker compose -p openseo down
   docker compose -p windows down
   docker ps -a --format '{{.Names}}'
   sudo systemctl stop docker.socket docker.service
   ```

   Expected: `docker ps -a` prints nothing, then Docker stops. `down` keeps every volume. The backup timer is only stopped, so it is still enabled if Arch comes back.

3. **Copy the state.**

   ```sh
   test ! -e /home/rida/homelab/.data/authentik && echo no clash
   sudo rsync -aHAX --numeric-ids /var/lib/docker/volumes/ $M/state/docker-volumes/
   sudo test -s $M/state/docker-volumes/metadata.db && echo volume metadata copied
   sudo rsync -aHAX --numeric-ids --exclude=/llama-cpp --exclude=/vllm --exclude=/pihole --exclude=/pihole-tailscale --exclude=/mitmproxy /home/rida/homelab/.data/ $M/state/homelab-data/
   sudo rsync -aHAX --numeric-ids /home/rida/homelab/.authentik/ $M/state/homelab-data/authentik/
   sudo rsync -aHAX --numeric-ids /var/lib/sops-nix/ $M/state/sops-nix/
   sudo rsync -aHAX --numeric-ids /etc/ssh/ssh_host_* $M/state/ssh/
   sudo cp /etc/machine-id $M/state/machine-id
   ```

   This carries every Docker volume together with `metadata.db` (Docker's record of them), `.data` minus the dropped dirs listed in [hardware.md](hardware.md), Authentik's data moved from `.authentik` to `.data/authentik` where the new compose files look for it, the host age key, the ssh host keys, and `/etc/machine-id` (the DHCP client ID is derived from it, which keeps 10.0.0.98). Expected: `no clash` and `volume metadata copied`. **STOP** on either missing.

4. **Copy Tailscale's state last, from the KVM console.** Stopping tailscaled drops any ssh session that came in over the tailnet.

   ```sh
   M=/mnt/disk2/migration
   sudo systemctl stop tailscaled
   sudo rsync -aHAX --numeric-ids /var/lib/tailscale/ $M/state/tailscale/
   sudo rsync -aHAXn --checksum --itemize-changes /var/lib/docker/volumes/ $M/state/docker-volumes/
   sudo poweroff
   ```

   Expected: the checksum dry run prints nothing, which means the volume copy matches the source byte for byte. Restoring the Tailscale state keeps the same node, so NixOS needs no auth key.

## Install

From the NixOS 26.05 minimal ISO over the GL.iNet KVM's virtual media, exactly as in the pre-flight dry run. Never kexec: kexec doesn't reset this GPU, and the network may not come back after it.

1. **Boot the installer.** Attach the ISO as virtual media, power on, and pick the virtual drive in the firmware's one-time boot menu. If the console is garbled, add `nomodeset` to the installer's boot entry (installer only; the installed system takes no kernel parameters). Then:

   ```sh
   sudo -i
   export NIX_CONFIG='experimental-features = nix-command flakes'
   ip -4 addr show eno1
   curl -sI https://github.com | head -n1
   ```

   Expected: a LAN address and an HTTP status line. **STOP** without a network: the install fetches the flake from GitHub.

2. **Mount disk2 by UUID, away from `/mnt`.** `/mnt` becomes the new root, so the migration disk goes elsewhere.

   ```sh
   mount --mkdir /dev/disk/by-uuid/62a0f9e6-258d-4ae7-a952-78c462d51c49 /srv/disk2
   export M=/srv/disk2/migration
   ls $M/state
   ```

   Expected: `docker-volumes homelab-data machine-id sops-nix ssh tailscale volumes.txt`. On disk2, only `$M` is written from here on.

3. **Confirm the target disk.** Nothing destructive runs until the by-id path resolves to the NVMe and its serial matches `hosts/homelab/disks.nix`.

   ```sh
   export NVME=/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23523B800268
   readlink -f $NVME
   lsblk -dno MODEL,SERIAL $NVME
   lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS $NVME
   ```

   Expected: `/dev/nvme0n1`; model `WD_BLACK SN850X 2000GB` with serial `23523B800268`; two partitions, a vfat ESP of about 512 MB and an ext4 root of about 1.8 TB, neither mounted. **STOP** on any difference.

4. **Take the rollback image of the NVMe, before disko.**

   ```sh
   nix shell nixpkgs#partclone nixpkgs#zstd nixpkgs#efibootmgr
   sfdisk -d $NVME > $M/rollback/nvme.sfdisk
   dd if=${NVME}-part1 of=$M/rollback/esp.img bs=4M conv=fsync status=progress
   partclone.ext4 -c -s ${NVME}-part2 --output - | zstd -T0 -3 -o $M/rollback/root.pc.zst
   zstd -t $M/rollback/root.pc.zst
   cd $M/rollback && sha256sum nvme.sfdisk esp.img root.pc.zst efibootmgr-v.txt > SHA256SUMS && sha256sum -c SHA256SUMS && cd /
   ```

   Expected: partclone ends with `Cloned successfully`, `zstd -t` reports the file OK, and every checksum line says `OK`. **STOP** on any error: without this image there is no rollback.

5. **Partition and mount the NVMe with disko**, from the flake. Its config names only the NVMe by-id path and an assertion refuses anything else.

   ```sh
   nix run --inputs-from github:ridafkih/homelab/nixos disko -- --mode destroy,format,mount --flake github:ridafkih/homelab/nixos#homelab
   findmnt -R /mnt
   ```

   Expected: disko asks to confirm wiping the NVMe only; afterwards `/mnt` is the new ext4 root and `/mnt/boot` the new 1 GB ESP, both on `nvme0n1`. From here, a failure means [Rollback](#rollback) (before the point of no return).

6. **Restore the state into the new root.**

   ```sh
   install -d -m 0755 /mnt/var/lib/docker /mnt/etc/ssh /mnt/home/rida
   rsync -aHAX --numeric-ids $M/state/docker-volumes/ /mnt/var/lib/docker/volumes/
   rsync -aHAX --numeric-ids $M/state/tailscale/ /mnt/var/lib/tailscale/
   rsync -aHAX --numeric-ids $M/state/ssh/ /mnt/etc/ssh/
   install -m 0444 $M/state/machine-id /mnt/etc/machine-id
   git clone -q --branch nixos https://github.com/ridafkih/homelab /mnt/home/rida/homelab
   rsync -aHAX --numeric-ids $M/state/homelab-data/ /mnt/home/rida/homelab/.data/
   find /mnt/home/rida/homelab -path /mnt/home/rida/homelab/.data -prune -o -exec chown -h 1000:1000 {} +
   chown 1000:1000 /mnt/home/rida && chmod 0700 /mnt/home/rida
   (umask 077 && install -d -m 0700 /mnt/var/lib/sops-nix && install -m 0600 $M/state/sops-nix/key.txt /mnt/var/lib/sops-nix/key.txt)
   test -s /mnt/var/lib/sops-nix/key.txt && stat -c '%a %U' /mnt/var/lib/sops-nix/key.txt
   rsync -aHAXn --checksum --itemize-changes $M/state/docker-volumes/ /mnt/var/lib/docker/volumes/
   ```

   The volumes, `.data` (with Authentik under `.data/authentik`), Tailscale's state, the ssh host keys, the machine ID and the host age key are all in place before the first boot, so the compose units come up on the real databases, not empty ones. Uid 1000 is `homelab.uid` in `modules/options.nix`. Expected: `600 root`, and the checksum dry run prints nothing. **STOP** otherwise.

7. **Install.** Record which commit is going on, then install from the `nixos` branch. Don't push to `nixos` during the window.

   ```sh
   nix flake metadata github:ridafkih/homelab/nixos --json | jq -r .locked.rev | tee $M/installed-rev.txt
   nixos-install --flake github:ridafkih/homelab/nixos#homelab --no-root-passwd
   ```

   Expected: the build finishes (the NVIDIA module is built locally, which takes a few minutes) and ends with `installation finished!`. `rida` logs in with ssh keys only, so no password is set. **STOP** on a build or activation error; nothing has booted yet.

8. **Cold boot.** Detach the virtual media, `umount -R /mnt && umount /srv/disk2`, then `poweroff` and power on from the KVM. Watch the console: systemd-boot, then the NixOS login prompt.

**Fallback, only if `nixos-install` can't be run from the ISO console** (for example the KVM keyboard stops working) **while the ISO itself is up and reachable:** finish steps 2 to 6 above, then drive just the install phase from another Linux machine with Nix on the LAN. It runs without kexec or disko, builds on the box, and needs root's ssh key in the installer's `/root/.ssh/authorized_keys`.

```sh
nix run github:nix-community/nixos-anywhere -- --phases install --build-on remote --flake github:ridafkih/homelab/nixos#homelab root@<installer-address>
```

## Post-boot

Run these in order on the new system. **The first NixOS boot is the point of no return:** from here, rollback still restores Arch, but whatever the services wrote since stays on the data disks (see [Rollback](#rollback)).

1. **Mounts.**

   ```sh
   findmnt /mnt/disk1 /mnt/disk2 /data
   systemctl is-active mnt-disk1.mount mnt-disk2.mount data.mount
   ls /data
   ```

   Expected: both disks by UUID, `/data` as `fuse.mergerfs` with source `mergerfs`, all three `active`, and the usual top-level dirs. **STOP** if a disk is missing: Docker is bound to these mounts and won't start.

2. **Address.**

   ```sh
   networkctl status eno1
   ip -4 addr show eno1
   ```

   Expected: `10.0.0.98/24`, from DHCP. FIX-FORWARD if it differs: LAN clients use this address for DNS, so add a static `10.0.0.98/24` to the `20-wired` network in `modules/network.nix`.

3. **Tailscale and the kill switch.**

   ```sh
   tailscale status --self --json | jq -r '.Self.HostName, .Self.TailscaleIPs[0]'
   sudo cat /mnt/disk2/migration/tailscale-self.txt
   tailscale status --json | jq -r '.ExitNodeStatus.Online'
   systemctl is-active egress-policy tailscaled
   ip rule show | grep -E '^5(200|205|280|300):'
   ip -6 rule show | grep -E '^5(200|205|280|300):'
   curl -fsS https://am.i.mullvad.net/json | jq .mullvad_exit_ip
   ```

   Expected: the same host name and tailnet address as before; the exit node online; both units `active`; for each family, four `5200` rules for the edge prefixes, one `5205` fwmark rule, `5280 lookup main suppress_prefixlength 0` and `5300 unreachable`; and `true`. **STOP** if the node is new or the exit node isn't online (see [If Tailscale won't come up](#if-tailscale-wont-come-up)).

   Then the kill switch. Wait until `homelab-compose` has finished its first start (`systemctl is-active homelab-compose` says `active`) so this doesn't interrupt the first image pull:

   ```sh
   sudo systemctl stop tailscaled
   curl -m 5 -sS https://1.1.1.1 ; echo "curl exit $?"
   ping -c 1 -W 2 10.0.0.1
   docker logs --since 2m ridash-cloudflared 2>&1 | grep -c 'Registered tunnel connection\|Connection.*registered'
   sudo systemctl start tailscaled
   curl -fsS https://am.i.mullvad.net/json | jq .mullvad_exit_ip
   ```

   Expected: curl fails (`Network is unreachable`, non-zero exit); the LAN ping answers; the rida.sh tunnel stays connected (its count doesn't drop to 0 on a later `docker logs` check); after the start, `true` again. **STOP** if curl succeeds while tailscaled is down: the box would leak.

4. **GPU.**

   ```sh
   nvidia-smi
   ls /var/run/cdi
   systemctl is-active nvidia-persistenced nvidia-container-toolkit-cdi-generator
   ```

   Expected: the RTX 4080 SUPER with driver 595, a CDI spec file for `nvidia.com/gpu`, and both units `active`. FIX-FORWARD: everything but Jellyfin's hardware transcoding works without it.

5. **Volumes and image digests.**

   ```sh
   docker volume ls -q | sort | sudo diff /mnt/disk2/migration/state/volumes.txt -
   systemctl is-active homelab-compose openseo-compose windows-compose
   docker ps --format '{{.Names}} {{.Image}}' | grep -v '@sha256:'
   ```

   Expected: the volume diff has no line starting with `<` (a volume Arch had is missing); all three units `active`; and every running container's image reference carries its `@sha256` pin, so the grep prints nothing. The first start pulls about 20 GB through Mullvad, so the units can sit in `activating` for a while; `journalctl -u homelab-compose -f` shows progress. **STOP** if a volume is missing (it would come up empty).

6. **Caddy routes.**

   ```sh
   for host in $(sed -nE 's/.*@[a-z]+ host ([a-z-]+)\.\{env\.DOMAIN\}.*/\1/p' /home/rida/homelab/apps/caddy/Caddyfile); do
     printf '%s %s\n' "$host" "$(curl -sk -o /dev/null -w '%{http_code}' --resolve "$host.rida.sh:443:127.0.0.1" "https://$host.rida.sh/")"
   done
   ```

   Expected: each host answers 200, 301, 302 or 401. A 502 names a container that isn't up (`docker ps -a`); FIX-FORWARD.

7. **Authentik and its tunnel.**

   ```sh
   docker logs --since 30m authentik-cloudflared 2>&1 | grep -c 'Registered tunnel connection\|Connection.*registered'
   docker network inspect homelab_authentik-network -f '{{(index .IPAM.Config 0).Gateway}}'
   curl -sS -o /dev/null -w '%{http_code}\n' https://authentik.rida.sh/
   ```

   Expected: a count of at least 1 within a minute of start, gateway `172.19.0.1`, and 200 or 302 through the tunnel. Sign in once in a browser. **STOP** if Authentik shows its first-run setup page: its database came up empty.

8. **rida.sh WebFinger.**

   ```sh
   docker logs --since 30m ridash-cloudflared 2>&1 | grep -c 'Registered tunnel connection\|Connection.*registered'
   curl -sS -o /dev/null -w '%{http_code}\n' https://rida.sh/.well-known/webfinger
   ```

   Expected: at least 1, and a status from the app (200, 400 or 404), not Cloudflare's 502 or 530. FIX-FORWARD.

9. **Jellyfin NVENC and the arr stack.**

   ```sh
   docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -f lavfi -i testsrc2=duration=5:size=1920x1080:rate=30 -c:v h264_nvenc -f null -
   docker ps --filter name=sonarr --filter name=radarr --filter name=prowlarr --filter name=bazarr --filter name=qbittorrent --filter name=qui --filter name=jellyseerr --format '{{.Names}} {{.Status}}'
   docker exec qbittorrent curl -fsS https://am.i.mullvad.net/json
   ```

   Expected: ffmpeg encodes 150 frames with `h264_nvenc` and exits 0; the arr containers (Sonarr, Radarr, Prowlarr, Bazarr, qBittorrent, Jellyseerr) are `Up` (qui too: Arch had it stopped by hand, and the compose unit starts every service); and qBittorrent's traffic shows `"mullvad_exit_ip":true`. Then play something in Jellyfin with transcoding forced and watch `nvidia-smi` list the ffmpeg process. In Prowlarr, test the indexers. FIX-FORWARD.

10. **Seafile.**

    ```sh
    docker ps --filter name=seafile --filter name=seadoc --format '{{.Names}} {{.Status}}'
    curl -sk -o /dev/null -w '%{http_code}\n' --resolve seafile.rida.sh:443:127.0.0.1 https://seafile.rida.sh/
    ```

    Expected: `seafile`, `seafile-db`, `seafile-redis` and `seadoc` up, and 200 or 302. Sign in and open a file from a library. **STOP** if the libraries are missing: the database volume didn't carry over.

11. **Observability.**

    ```sh
    docker ps --filter name=signoz --filter name=grafana --filter name=prometheus --filter name=loki --filter name=tempo --filter name=otel-collector --format '{{.Names}} {{.Status}}'
    ```

    Expected: all up. In Grafana and SigNoz, the last few minutes have data. FIX-FORWARD.

12. **AdGuard resolves for the LAN.** From another machine on the LAN, and on the box itself:

    ```sh
    dig @10.0.0.98 rida.sh +short
    getent hosts github.com
    ```

    Expected: an answer from both. FIX-FORWARD, but tell Rida: LAN clients that use the box for DNS fail until it works.

13. **OpenSEO.**

    ```sh
    curl -sk -o /dev/null -w '%{http_code}\n' --resolve open-seo.rida.sh:443:127.0.0.1 https://open-seo.rida.sh/
    ```

    Expected: 200 or 302, and its projects are there after sign-in. FIX-FORWARD.

14. **Windows on 8006.**

    ```sh
    docker inspect -f '{{.State.Status}}' windows11
    curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8006/
    ```

    Expected: `running` and 200. In the web viewer on 8006, Windows boots to its existing desktop, not a fresh install. If it starts installing, the disk wasn't found: stop `windows-compose`, check `/data/windows` against `/mnt/disk2/migration/windows.sha256`, and FIX-FORWARD.

15. **Both backups, by hand.**

    ```sh
    sudo systemctl start restic-backups-disk1
    systemctl status restic-backups-disk2 --no-pager
    journalctl -u restic-backups-disk1 -u restic-backups-disk2 -b --no-pager | tail -n 20
    systemctl list-timers restic-backups-disk1.timer
    sudo restic-disk1 snapshots --latest 2
    sudo restic-disk2 snapshots --latest 2
    sudo restic-disk1 ls latest | grep -c '^/data/'
    sudo restic-disk2 ls latest | grep -c '^/data/'
    ```

    `restic-backups-disk1` dumps the databases, backs up to `/mnt/disk2/backup/restic`, and pulls in `restic-backups-disk2`, which backs up to `/mnt/disk1/backup/restic`. Expected: both finish without errors; each repo has a new snapshot with host `homelab` next to the Arch ones; the timer is set for 03:30; and both counts are `0`, so nothing under `/data`, `/data/media` included, is in a snapshot. **STOP** if the repos won't open: the restic password in sops doesn't match.

### If Tailscale won't come up

With tailscaled down, the kill switch blocks everything except the LAN, Docker and the Cloudflare edge, so the box is still reachable over LAN ssh at 10.0.0.98.

- `journalctl -u tailscaled -b` shows why. If it asks for a login, the restored state wasn't picked up; compare `/var/lib/tailscale` with `/mnt/disk2/migration/state/tailscale`. A fresh sign-in is Rida's to do.
- Image pulls fail while it's down. If a compose unit failed for that reason, start it again once Tailscale is up. As a last resort, `sudo docker load -i /mnt/disk2/migration/images.tar` and re-tag from `image-tags.txt`, as in pre-flight step 10.

## Rollback

Puts Arch back on the NVMe from the images in `/mnt/disk2/migration/rollback`. It never writes to the data disks: disk2 is mounted read-only, and the only data-disk writes the whole cutover made are under `/mnt/disk2/migration` and `/data/windows`. `~/windows` comes back with the NVMe.

1. Boot the NixOS ISO over the KVM's virtual media as in [Install](#install) step 1.

2. Mount disk2 read-only and check the images:

   ```sh
   mount --mkdir -o ro /dev/disk/by-uuid/62a0f9e6-258d-4ae7-a952-78c462d51c49 /srv/disk2
   export M=/srv/disk2/migration
   export NVME=/dev/disk/by-id/nvme-WD_BLACK_SN850X_2000GB_23523B800268
   readlink -f $NVME
   (cd $M/rollback && sha256sum -c SHA256SUMS)
   nix shell nixpkgs#partclone nixpkgs#zstd nixpkgs#efibootmgr
   ```

   Expected: `/dev/nvme0n1` and every line `OK`. Make sure nothing on the NVMe is mounted (`umount -R /mnt` if it is).

3. Restore the partition table, the ESP and the root filesystem:

   ```sh
   sfdisk $NVME < $M/rollback/nvme.sfdisk
   partprobe $NVME
   dd if=$M/rollback/esp.img of=${NVME}-part1 bs=4M conv=fsync status=progress
   zstd -dc $M/rollback/root.pc.zst | partclone.ext4 -r -s - -o ${NVME}-part2
   ```

   Expected: sfdisk reports the old two-partition layout, and partclone ends with `Restored successfully`. Partition and filesystem UUIDs are back to Arch's, so GRUB finds its root.

4. Put GRUB first again:

   ```sh
   grep -E '^BootOrder' $M/rollback/efibootmgr-v.txt
   efibootmgr -v
   efibootmgr -o <BootOrder from the capture>
   ```

   NixOS added a "Linux Boot Manager" entry, which now points at nothing; delete it with `efibootmgr -b <its number> -B`. If the firmware refuses the write or the GRUB entry is gone, set a one-time boot with `efibootmgr -n <GRUB entry>` (BootNext), or pick the NVMe's GRUB entry from the firmware's one-time boot menu over the KVM.

5. Detach the virtual media and cold boot into Arch. Then:

   ```sh
   cd /home/rida/homelab && docker compose up -d
   cd /home/rida/homelab/openseo && docker compose up -d
   cd /home/rida/windows && docker compose up -d
   tailscale status --self
   curl -fsS https://am.i.mullvad.net/json
   ```

   Expected: everything comes back as it was before [State](#state), and the backup timer runs at 03:30 as before.

**Before the point of no return** (NixOS never booted): Arch is exactly as it was. Nothing on the data disks changed except the copies under `/mnt/disk2/migration` and `/data/windows`.

**After the point of no return** (NixOS booted and ran): Arch comes back with its databases as they were at [State](#state), but what NixOS wrote to the data disks stays:

- Files uploaded to Seafile after cutover have blocks under `/data/seafile` that Arch's older database doesn't know. Before rolling back, if NixOS still runs, start `restic-backups-disk1` once so the newer state is in both repos; after rolling back, Seafile's garbage collection can clear the orphaned blocks.
- Media the arr stack downloaded stays in `/data/media`; Arch's older arr databases pick it up on their next library scan.
- The NixOS restic snapshots stay in both repos next to Arch's, under the same host and tag, and prune with them.
- If the Windows VM was used on NixOS, copy `/data/windows` back over `~/windows/windows-storage` with `cp --sparse=always` before starting it on Arch.

## Optional firewall

Not applied. This is Rida's choice: the build keeps today's LAN reachability exactly ([0009](decisions/0009-network-dns-and-firewall.md)). The 2026-10-26 audit suggested closing RDP (3389), the Windows web viewer (8006) and OTLP (4317, 4318, 4327, 4328) to the LAN, leaving them reachable over the tailnet only.

Docker publishes those ports itself and its IPv4 forwarding runs before the host firewall's input rules, so removing them from `allowedTCPPorts` alone would only close them on IPv6. The diff does both:

```diff
--- a/modules/firewall.nix
+++ b/modules/firewall.nix
@@
   networking.firewall = {
     enable = true;
     trustedInterfaces = [ "tailscale0" ];
-    allowedTCPPorts = [ 22 53 80 443 3000 3389 4317 4318 4327 4328 8006 ];
-    allowedUDPPorts = [ 53 3389 ];
+    allowedTCPPorts = [ 22 53 80 443 3000 ];
+    allowedUDPPorts = [ 53 ];
+    extraCommands = ''
+      iptables -N DOCKER-USER 2>/dev/null || true
+      for port in 3389 4317 4318 4327 4328 8006; do
+        iptables -D DOCKER-USER -i ${config.homelab.lan.interface} -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport "$port" -j DROP 2>/dev/null || true
+        iptables -I DOCKER-USER -i ${config.homelab.lan.interface} -p tcp -m conntrack --ctdir ORIGINAL --ctorigdstport "$port" -j DROP
+      done
+      iptables -D DOCKER-USER -i ${config.homelab.lan.interface} -p udp -m conntrack --ctdir ORIGINAL --ctorigdstport 3389 -j DROP 2>/dev/null || true
+      iptables -I DOCKER-USER -i ${config.homelab.lan.interface} -p udp -m conntrack --ctdir ORIGINAL --ctorigdstport 3389 -j DROP
+    '';
   };
```

If Rida wants it: apply the diff, update the port list in `tests/dns-firewall.nix` and record a decision that supersedes 0009's port list, then `sudo nixos-rebuild switch --flake github:ridafkih/homelab/nixos#homelab` once it's pushed. Check from another LAN machine that `nc -vz 10.0.0.98 8006` is refused while `tailscale ping` and the web viewer over the tailnet still work.

## Cleanup

1. **Stale secrets.** The Arch checkout's `.env` still held an unused `HF_TOKEN`, and the box had `*.before-*`/`*.bak` copies of the real env files. Neither was copied: the NixOS checkout is a fresh clone and its secrets come from sops, which never had `HF_TOKEN`. Confirm nothing slipped through, then delete any that did:

   ```sh
   sudo find /home/rida/homelab \( -name '*.before-*' -o -name '*.bak' -o -name '.env' \) -print
   git -C /home/rida/homelab ls-files -z --others -- ':!:.data' | (cd /home/rida/homelab && xargs -0r grep -l HF_TOKEN --)
   sudo grep -rl HF_TOKEN /run/secrets/rendered
   sudo find /home/rida/homelab \( -name '*.before-*' -o -name '*.bak' \) -delete
   ```

   Expected: the first three print nothing. The second searches only files git doesn't track (ignored ones included, `.data/` left out since it holds app state, not env files): the clone's tracked docs, modules and tests mention `HF_TOKEN` by name, so a plain `grep -r` over the checkout always matches and proves nothing. Copies remain in two places: the NVMe rollback image (deleted in step 3) and Arch-era restic snapshots of `/home/rida`, which age out under the 7 daily, 4 weekly and 6 monthly retention. If the Arch box ever comes back by rollback, also run `sed -i '/^HF_TOKEN=/d' /home/rida/homelab/.env` and delete the `*.before-*` and `*.bak` files there.

2. **Revoke the token at Hugging Face.** It was never in the repo, but it is still live. Revoking it under Settings, Access Tokens needs Rida's sign-in, so it's his to do.

3. **The migration area.** After a week of good nightly backups (`restic-backups-disk1.timer` ran and both repos have new snapshots), delete the copies, the images and the rollback image:

   ```sh
   sudo rm -rf /mnt/disk2/migration
   ```

   This also removes the last copy of the old env files and `HF_TOKEN` outside restic. Rollback is no longer possible after this.

The window is Rida's to pick, and the runbook waits until he does.
