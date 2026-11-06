# Homelab Infrastructure

Configuration, deployment helpers, and operational automation for the home lab.

## Hosts

| Host | Role |
|---|---|
| Odroid M2 | Primary Docker host for Traefik, Portainer, Home Assistant, and application services; runs scheduled automation and backups |
| Odroid N2 | Application hosting and supporting services |
| Odroid C5 | Supporting Linux host and remote backup destination |

## Services and automation

| Area | What it does | Documentation |
|---|---|---|
| Cloudflare DDNS | Updates the `sshoemake.com` DNS record when the home public IPv4 address changes; scheduled every five minutes on the M2 | [Cloudflare README](cloudflare/README.md) |
| Traefik | Reverse proxy and HTTPS certificate management for services on the M2 | [Traefik README](traefik/README.md), [deployment guide](traefik/DEPLOYMENT.md) |
| Portainer CE | Docker management UI, deployed from a versioned Compose configuration | [Portainer README](portainer/README.md) |
| Home Assistant | Docker Compose deployment using host networking and the existing persistent configuration directory | [Home Assistant Compose](homeassistant/compose/README.md), [backup guide](homeassistant/backup/README.md) |
| Meal Project | Docker Compose application deployment and PostgreSQL backup/restore tools | [Compose files and scripts](meal_project/compose/), [backup guide](backups/meal_project/README.md) |
| Backups | Weekly PostgreSQL backup, encrypted infrastructure configuration archive, and Home Assistant backup synchronization to the C5 | [Backup overview](backups/README.md), [remote backup guide](backups/remote/README.md) |
| Notifications | Email notifications for scheduled backup results | [Notifications README](notifications/README.md) |
| Cron | M2 schedules for DDNS and the weekly infrastructure backup cycle | [Cron README](cron/README.md) |

## Home Assistant

Home Assistant is managed from this repository using Docker Compose.

- Compose project: `homeassistant`
- Compose directory: `homeassistant/compose/`
- Persistent configuration: `/home/odroid/homeassistant/config`
- Local access: `http://192.168.0.112:8123`
- Network mode: host
- Image: configured using a pinned image digest in the local `.env` file

The existing Home Assistant configuration remains outside the repository. Phase 1 moved container management into the infrastructure project while preserving local access.

Remote access through Traefik and Cloudflare is a separate follow-on task and is not part of the current Phase 1 deployment.

## Repository layout

- `backups/` — PostgreSQL backup and restore scripts, remote encrypted sync, and weekly backup orchestration
- `cloudflare/` — Dynamic DNS script, runtime setup, and log rotation configuration
- `cron/` — M2 crontab configuration
- `homeassistant/` — Home Assistant Compose deployment and backup synchronization
- `meal_project/compose/` — Meal Project Compose configurations and deployment helpers
- `notifications/` — Backup notification script and mail configuration example
- `portainer/` — Portainer CE Compose configuration and deployment helper
- `traefik/` — Reverse proxy Compose configuration, static and dynamic settings, and deployment documentation

## Backup architecture

The weekly backup cycle is orchestrated by:

```text
backups/run_weekly_backup.sh
```

It performs three operations in sequence:

1. Creates and validates a PostgreSQL custom-format backup of Meal_Project.
2. Synchronizes Meal_Project database backups and an age-encrypted archive of configured sensitive infrastructure files to the C5.
3. Synchronizes completed native Home Assistant backup archives to the C5 and verifies their SHA256 checksums.

The cycle stops if a required stage fails. One consolidated email reports the overall result.

### Backup destinations

| Backup | Local location | Remote location |
|---|---|---|
| Meal_Project PostgreSQL | `~/backups/meal_project/` | `/home/odroid/homelab_backups/meal_project/` |
| Encrypted infrastructure configuration | `~/backups/remote/` (see remote backup configuration) | `/home/odroid/homelab_backups/encrypted/` |
| Home Assistant archives | `/home/odroid/homeassistant/config/backups/` | `/home/odroid/homelab_backups/homeassistant/` |

Remote backups are stored on the C5 (`odroidc5.local`).

The Meal_Project backup script retains the 12 newest local weekly database dumps. Home Assistant manages its own local backup retention. Remote copies are not automatically deleted by the synchronization scripts.

A successful synchronization and checksum verification does not replace a full restore test. See the service-specific backup guides before performing recovery.

## Configuration and recovery

- Compose definitions, scripts, and operational documentation are maintained in Git.
- Live credentials and environment-specific settings stay in local `.env` files and are excluded from Git; tracked `.env.example` files document required settings.
- Runtime data and logs live outside the repository.
- Sensitive infrastructure configuration files are encrypted with age before remote transfer. The private age identity must be kept separately from both hosts.
- Home Assistant native backup archives are copied unchanged. Protect the Home Assistant backup credentials and recovery material separately.
- See the service-specific guides for deployment, backup, and recovery steps before rebuilding a host or removing a persistent Docker volume.
