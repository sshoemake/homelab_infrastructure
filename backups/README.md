# Infrastructure Backup Overview

This directory contains the backup scripts and orchestration used to protect Meal_Project and infrastructure configuration.

## Weekly backup cycle

The full weekly cycle is run by:

```bash
cd ~/homelab_infrastructure
./backups/run_weekly_backup.sh
```

The wrapper executes the following stages in order:

1. Create and validate a Meal_Project PostgreSQL backup.
2. Synchronize PostgreSQL backups and the encrypted infrastructure configuration archive to the C5.
3. Synchronize completed Home Assistant backup archives to the C5 and verify their SHA256 checksums.
4. Send one consolidated success notification.

The wrapper exits when a required stage fails and sends a failure notification identifying the failed stage.

The Home Assistant synchronization script normally supports its own notifications. During the weekly cycle, its individual notification is suppressed so the wrapper can send one overall result.

## Schedule

The weekly cycle is scheduled through `cron/odroidm2.crontab`.

Current schedule:

- Sunday at 11:00 PM Arizona time.
- Corresponds to Monday at 06:00 UTC.
- The cron entry invokes `backups/run_weekly_backup.sh`.

See [Cron README](../cron/README.md).

## Backup components

| Component | Script | Purpose |
|---|---|---|
| Meal_Project | `meal_project/backup.sh` | Creates and validates PostgreSQL custom-format dumps |
| Remote synchronization | `remote/sync.sh` | Copies database dumps and age-encrypted sensitive configuration archives to C5 |
| Home Assistant | `../homeassistant/backup/sync.sh` | Copies native Home Assistant backup archives and verifies SHA256 checksums |
| Weekly orchestration | `run_weekly_backup.sh` | Runs the stages and sends one consolidated notification |

See the individual guides:

- [Meal_Project backup and recovery](meal_project/README.md)
- [Remote synchronization and encrypted configuration recovery](remote/README.md)
- [Home Assistant backup synchronization](../homeassistant/backup/README.md)

## Local logs

The scripts keep runtime logs outside the Git repository.

| Log | Location |
|---|---|
| Meal_Project backup | `~/backups/meal_project/backup.log` |
| Meal_Project remote synchronization | `~/backups/meal_project/remote_sync.log` |
| Weekly cycle | `~/backups/meal_project/backup_cycle.log` |
| Home Assistant remote synchronization | `~/backups/homeassistant/remote_sync.log` |
| Email notifications | `~/.local/state/homelab/notifications.log` |

Inspect the latest weekly cycle:

```bash
tail -60 ~/backups/meal_project/backup_cycle.log
```

Inspect Home Assistant synchronization:

```bash
tail -40 ~/backups/homeassistant/remote_sync.log
```

## Remote backup host

The remote destination is the Odroid C5.

```text
/home/odroid/homelab_backups/
├── meal_project/
├── encrypted/
└── homeassistant/
```

The directories are private to the remote backup account.

Verify remote file counts:

```bash
ssh -i /home/odroid/.ssh/homelab_backup \
    odroid@odroidc5.local \
    'for d in meal_project encrypted homeassistant; do
        echo "===== ${d} ====="
        find "/home/odroid/homelab_backups/${d}" -maxdepth 1 -type f | wc -l
    done'
```

The SSH command must specify the dedicated backup key.

## Retention and deletion

- Meal_Project keeps the 12 newest local weekly PostgreSQL dumps.
- Home Assistant controls its own local automatic backup retention.
- Remote synchronization does not automatically delete old remote copies.
- Encrypted infrastructure archives are retained according to the remote backup process.

Do not introduce remote deletion or pruning without first defining and testing a recovery and retention policy.

## Recovery

Use the service-specific recovery documentation before restoring data.

- Meal_Project: see [Meal_Project backup and recovery](meal_project/README.md).
- Encrypted infrastructure configuration: see [Remote backup synchronization](remote/README.md).
- Home Assistant: see [Home Assistant backup synchronization](../homeassistant/backup/README.md).

Successful backup creation, transfer, and checksum verification do not prove that an application can be restored successfully. Perform restore tests periodically.
