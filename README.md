# Homelab Infrastructure

Configuration, deployment helpers, and operational automation for the home lab.

## Hosts

| Host | Role |
|---|---|
| Odroid M2 | Primary Docker host for Traefik, Portainer, and application services; runs scheduled automation and backups |
| Odroid N2 | Application hosting and supporting services |
| Odroid C5 | Supporting Linux host and remote backup destination |

## Services and automation

| Area | What it does | Documentation |
|---|---|---|
| Cloudflare DDNS | Updates the `sshoemake.com` DNS record when the home public IPv4 address changes; scheduled every five minutes on the M2 | [Cloudflare README](cloudflare/README.md) |
| Traefik | Reverse proxy and HTTPS certificate management for services on the M2 | [Traefik README](traefik/README.md), [deployment guide](traefik/DEPLOYMENT.md) |
| Portainer CE | Docker management UI, deployed from a versioned Compose configuration | [Portainer README](portainer/README.md) |
| Meal Project | Docker Compose application deployment and PostgreSQL backup/restore tools | [Compose files and scripts](meal_project/compose/), [backup guide](backups/meal_project/README.md) |
| Remote backups | Weekly PostgreSQL dumps plus age-encrypted archives of locally configured sensitive files, synced to the C5 | [Backup overview](backups/README.md), [remote backup guide](backups/remote/README.md) |
| Notifications | Email notifications for scheduled backup results | [Notifications README](notifications/README.md) |
| Cron | M2 schedules for DDNS and the weekly backup cycle | [Cron README](cron/README.md) |

Home Assistant runs on the M2 using host networking and is routed through Traefik. Its routing and trusted-proxy notes are in the [Traefik deployment guide](traefik/DEPLOYMENT.md); its own Compose deployment and persistent configuration are not currently maintained in this repository.

## Repository layout

- `backups/` — PostgreSQL backup and restore scripts, remote encrypted sync, and weekly backup orchestration
- `cloudflare/` — Dynamic DNS script, runtime setup, and log rotation configuration
- `cron/` — M2 crontab configuration
- `meal_project/compose/` — Meal Project Compose configurations and deployment helpers
- `notifications/` — Backup notification script and mail configuration example
- `portainer/` — Portainer CE Compose configuration and deployment helper
- `traefik/` — Reverse proxy Compose configuration, static and dynamic settings, and deployment documentation

## Configuration and recovery

- Compose definitions, scripts, and operational documentation are maintained in Git.
- Live credentials and environment-specific settings stay in local `.env` files and are excluded from Git; tracked `.env.example` files document required settings.
- Runtime data and logs live outside the repository.
- The weekly backup cycle creates PostgreSQL dumps, syncs them to the C5, and encrypts configured sensitive files with age before remote sync. The age public recipient is configured locally; the private identity must be kept separately from both hosts.
- See the service-specific guides for deployment, backup, and recovery steps before rebuilding a host or removing a persistent Docker volume.
