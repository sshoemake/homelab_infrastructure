# Scheduled Tasks - Odroid M2

Cron jobs are maintained in this repository in:

```text
cron/odroidm2.crontab
```

## Current schedule

| Task | Schedule | Script |
|---|---|---|
| Cloudflare Dynamic DNS | Every 5 minutes | `cloudflare/run_ddns.sh` |
| Weekly infrastructure backup | Sunday 11:00 PM Arizona time (Monday 06:00 UTC) | `backups/run_weekly_backup.sh` |

The weekly backup wrapper runs the Meal_Project PostgreSQL backup, remote synchronization, Home Assistant archive synchronization, and consolidated email notification.

## View current configuration

```bash
crontab -l
```

## Install repository configuration

After reviewing changes to the tracked crontab:

```bash
cd ~/homelab_infrastructure
crontab cron/odroidm2.crontab
```

Installing the crontab replaces the user's current crontab. Review the file before applying it.

## Verify installation

```bash
crontab -l
```

## Logs

Cloudflare DDNS log:

```text
~/homelab_infrastructure/cloudflare/cloudflare_ddns.log
```

Weekly backup logs:

```text
~/backups/meal_project/backup.log
~/backups/meal_project/remote_sync.log
~/backups/meal_project/backup_cycle.log
~/backups/homeassistant/remote_sync.log
```

Email notification log:

```text
~/.local/state/homelab/notifications.log
```

See [Infrastructure Backup Overview](../backups/README.md) for backup stages, destinations, and verification.
