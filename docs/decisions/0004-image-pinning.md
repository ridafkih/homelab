# 0004. Every image pinned to the digest that runs today

## Context

Most images on Arch were floating tags (`latest`, `main`, version variables). A fresh NixOS box pulling them at cutover would run different software from what runs today, and the box fails closed when the Mullvad exit is down (0006), so it should not depend on a registry to start.

## Decision

Every `image:` in every Compose file is `repo:tag@sha256:<digest>`, where the digest is the one the running container uses. Digests were read on the box with `docker inspect` and `docker image inspect` (`RepoDigests`), never by pulling. The tag and registry spelling stay as they were.

## Consequences

- Upgrades are deliberate digest bumps.
- A registry can garbage-collect an old digest. The cutover runbook saves the pinned images to the data disk first and loads them on NixOS before the first start.
- The lint rule in 0003 rejects any unpinned image.
