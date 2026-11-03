# Homelab Infrastructure

Infrastructure configuration, automation, and operational scripts
for my home lab.

## Environment

| Host | Purpose |
|---|---|
| Odroid M2 | Primary Docker host and application services |
| Odroid N2 | Application hosting / supporting services |
| Odroid C5 | Supporting Linux host |

## Infrastructure Components

| Component | Description | Documentation |
|---|---|---|
| Cloudflare | Dynamic DNS updates | [Cloudflare README](cloudflare/README.md) |
| Traefik | Reverse proxy and HTTPS | [Traefik README](traefik/README.md) |
| Meal Project | Application deployment | [Meal Project README](meal_project/README.md) |
| Cron | Scheduled tasks | [Cron README](cron/README.md) |

## Repository Structure

- `cloudflare/` — Cloudflare Dynamic DNS automation
- `cron/` — Scheduled task configuration
- `traefik/` — Reverse proxy configuration
- `meal_project/` — Application deployment configuration

## General Conventions

- Configuration and scripts are maintained in Git.
- Secrets and environment-specific files are excluded from Git.
- Changes should be tested before being deployed.
- Runtime data and logs are maintained separately from source configuration.