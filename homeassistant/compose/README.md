# Home Assistant Compose Deployment

This directory contains the Docker Compose definition and image configuration for Home Assistant on the Odroid M2.

## Deployment design

Home Assistant is managed as its own Compose project:

```text
homeassistant
```

The Compose service uses:

- The official Home Assistant container image.
- A pinned image digest supplied through the local `.env` file.
- Host networking.
- `restart: unless-stopped`.
- The existing persistent configuration directory.

The Compose project does not move or recreate the existing Home Assistant configuration.

## Persistent configuration

The host directory:

```text
/home/odroid/homeassistant/config
```

is mounted into the container at:

```text
/config
```

This directory contains Home Assistant's configuration, integrations, and backup archives. It remains outside the Git repository.

Do not delete, move, or replace this directory as part of a routine container update.

## Local access

Home Assistant remains accessible on the local network at:

```text
http://192.168.0.112:8123
```

The container uses host networking. Do not add Docker port mappings while `network_mode: host` is configured.

Remote access through Traefik and Cloudflare is a separate follow-on phase and is not configured by this Compose project.

## Configuration

The tracked `.env.example` documents the required settings.

Create the local environment file if it does not already exist:

```bash
cd ~/homelab_infrastructure/homeassistant/compose
cp .env.example .env
chmod 600 .env
```

The local `.env` file is excluded from Git.

| Variable | Purpose |
|---|---|
| `HA_IMAGE` | Home Assistant image reference, pinned to a specific digest |
| `TZ` | Container timezone; currently `US/Arizona` |

The image digest is deliberately pinned. Do not change it to a floating image reference as part of routine maintenance.

## Inspect the Compose configuration

From this directory:

```bash
docker compose config
docker compose ps
```

Review the rendered configuration before applying changes.

## Start or recreate the service

After reviewing the configuration and confirming the intended image:

```bash
docker compose up -d
```

Check container status:

```bash
docker compose ps
```

Check recent logs:

```bash
docker compose logs --tail=100 homeassistant
```

Verify local access:

```bash
curl -I http://192.168.0.112:8123
```

Do not perform an image update simply by pulling `stable`. Update the pinned image digest deliberately and follow a backup and rollback plan.

## Backup and recovery

Home Assistant's native backup archives are stored under the persistent configuration directory.

The separate synchronization script copies completed archives to the C5:

```text
../backup/sync.sh
```

See [Home Assistant Backup Synchronization](../backup/README.md).

The container deployment and the Home Assistant configuration are separate concerns. Recreating the container should not require replacing the persistent configuration directory.
