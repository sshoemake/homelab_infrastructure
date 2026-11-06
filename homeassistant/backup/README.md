# Home Assistant Backup Synchronization

This directory contains the script used to synchronize native Home Assistant backup archives from the M2 to the C5.

## Overview

Home Assistant creates its own backup archives in:

```text
/home/odroid/homeassistant/config/backups/
```

The synchronization script copies completed `.tar` archives to:

```text
odroidc5.local:/home/odroid/homelab_backups/homeassistant/
```

The native Home Assistant backup archives are copied unchanged. No additional encryption is performed by this script. The Home Assistant backup format and its existing protection are preserved.

Protect Home Assistant backup credentials and recovery material separately from both hosts.

## Files

| File | Purpose |
|---|---|
| `sync.sh` | Synchronizes and verifies Home Assistant backup archives |
| `README.md` | Documents the backup synchronization process |

## Configuration

The script reuses the remote connection configuration:

```text
backups/remote/.env
```

Required settings:

- `REMOTE_HOST`
- `REMOTE_USER`
- `REMOTE_BASE_DIR`
- `SSH_KEY`

Optional setting:

- `SSH_PORT` (defaults to 22)

The script also uses:

```text
notifications/notify.sh
```

No separate SSH configuration is required.

## Local backup selection

Local backup directory:

```text
/home/odroid/homeassistant/config/backups/
```

Only regular `.tar` files modified more than 15 minutes ago are selected. This avoids copying an archive while Home Assistant may still be writing it.

Before transfer, the script checks each selected archive using `tar -tf`.

## Remote backup location

```text
/home/odroid/homelab_backups/homeassistant/
```

The remote directory is created if necessary and assigned permissions of `700`.

Remote backup files are never automatically deleted.

## Synchronization and verification

The script:

1. Loads the existing remote connection configuration.
2. Acquires a dedicated Home Assistant synchronization lock.
3. Finds completed Home Assistant `.tar` archives.
4. Checks the integrity of each selected outer tar archive.
5. Connects to the C5 using the configured SSH key.
6. Synchronizes the archives using rsync.
7. Compares local and remote SHA256 checksums.
8. Sends a success or failure email notification.

A successful run means the selected files were transferred and their SHA256 checksums matched.

This does not constitute a full Home Assistant restore test.

## Manual execution

From the infrastructure repository:

```bash
cd ~/homelab_infrastructure
./homeassistant/backup/sync.sh
```

The script can also be run from another working directory.

When run manually, it sends its own success or failure notification.

During the weekly infrastructure backup cycle, the wrapper sets `HA_SYNC_NOTIFY=0` so only one consolidated email is sent.

## Weekly integration

The weekly wrapper:

```text
backups/run_weekly_backup.sh
```

runs Home Assistant synchronization after the Meal_Project backup and remote synchronization stages.

The existing cron schedule remains:

- Sunday at 11:00 PM Arizona time.
- Monday at 06:00 UTC.

See [Infrastructure Backup Overview](../../backups/README.md) and [Cron README](../../cron/README.md).

## Logging and locking

Log file:

```text
~/backups/homeassistant/remote_sync.log
```

Synchronization lock:

```text
~/backups/homeassistant/sync.lock
```

The log directory is private to the `odroid` user.

## Retention

The synchronization script does not delete local or remote backups.

Home Assistant manages its own local automatic backup retention. Remote retention is managed separately.

Do not add automatic remote pruning until the retention policy and recovery process have been tested.

## Recovery considerations

The remote archives are an additional copy of Home Assistant's native backups.

A successful synchronization and checksum comparison verifies that the remote copy matches the local archive. It does not prove that Home Assistant can successfully restore that backup.

Use Home Assistant's supported restore process and the appropriate backup credentials or recovery material.

A full restore test has not yet been completed for this deployment. Treat restore validation as outstanding until it has been performed successfully.
