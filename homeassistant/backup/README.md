# Home Assistant Backup Synchronization

This directory contains the script used to synchronize native Home Assistant
backup archives from the M2 to the C5.

## Overview

Home Assistant creates its own backup archives in:

    /home/odroid/homeassistant/config/backups

The synchronization script copies completed `.tar` archives to:

    odroidc5.local:/home/odroid/homelab_backups/homeassistant

The native Home Assistant backup archives are copied unchanged.

No additional encryption is performed by this script. Home Assistant's
backup format and its existing protection are preserved.

## Files

| File | Purpose |
|---|---|
| `sync.sh` | Synchronizes and verifies Home Assistant backup archives |
| `README.md` | Documents the backup synchronization process |

## Configuration

The script reuses the existing remote configuration:

    backups/remote/.env

Required settings:

- `REMOTE_HOST`
- `REMOTE_USER`
- `REMOTE_BASE_DIR`
- `SSH_KEY`

Optional setting:

- `SSH_PORT` (defaults to 22)

The script uses the shared notification utility:

    notifications/notify.sh

No separate email or SSH configuration is required.

## Local Backup Location

    /home/odroid/homeassistant/config/backups

Only regular `.tar` files modified more than 15 minutes ago are selected.

Before transferring each archive, the script checks its outer tar archive
integrity.

## Remote Backup Location

    /home/odroid/homelab_backups/homeassistant

The remote directory is created if necessary and assigned permissions of 700.

Remote backup files are never automatically deleted.

## Synchronization and Verification

The script:

1. Loads the existing remote connection configuration.
2. Acquires a dedicated Home Assistant synchronization lock.
3. Finds completed Home Assistant `.tar` archives.
4. Checks the integrity of each selected archive.
5. Connects to the C5 using the existing SSH key.
6. Synchronizes the archives using rsync.
7. Compares local and remote SHA256 checksums.
8. Sends a success or failure email notification.

A successful run means the selected files were transferred and their
SHA256 checksums matched.

This does not constitute a full Home Assistant restore test.

## Logging

Log file:

    ~/backups/homeassistant/remote_sync.log

The synchronization lock is:

    ~/backups/homeassistant/sync.lock

The log directory is private to the odroid user.

## Manual Execution

From the infrastructure repository:

    ./homeassistant/backup/sync.sh

The script can also be run from another working directory.

## Permissions

The script should be executable:

    chmod 750 homeassistant/backup/sync.sh

## Retention

The script does not delete local or remote backups.

Home Assistant manages its own local automatic backup retention.
Remote retention is managed separately and should only be introduced after
the synchronization process has been validated.

## Recovery Considerations

The remote archives are an additional copy of Home Assistant's native backups.

A successful synchronization and checksum comparison verifies that the
remote copy matches the local archive. It does not prove that Home Assistant
can successfully restore that backup.

Periodically verify that a backup can be restored using Home Assistant's
supported restore process.