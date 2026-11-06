# Meal_Project PostgreSQL Backup and Recovery

This directory contains the PostgreSQL backup and restore scripts for Meal_Project.

## Backup

Run a database backup manually:

```bash
cd ~/homelab_infrastructure
./backups/meal_project/backup.sh
```

The script:

1. Acquires the shared Meal_Project operation lock.
2. Checks that the required Compose configuration and production environment file exist.
3. Confirms the PostgreSQL service is running.
4. Creates a PostgreSQL custom-format dump using `pg_dump`.
5. Validates the archive using `pg_restore --list`.
6. Finalizes the backup file.
7. Applies the local retention policy.

The backup uses the same Compose project and production configuration as the deployed application.

## Local backup location

Default location:

```text
/home/odroid/backups/meal_project/
```

Backups use the filename format:

```text
meal_project_weekly_YYYYMMDD_HHMMSS.dump
```

The script retains the 12 newest matching weekly dump files locally.

The backup directory is created with restrictive permissions. Backup files are created with mode `600`.

## Remote synchronization

The weekly infrastructure cycle invokes:

```text
backups/remote/sync.sh
```

This synchronizes completed PostgreSQL dump files to:

```text
/home/odroid/homelab_backups/meal_project/
```

The same remote synchronization process creates an age-encrypted archive of configured sensitive infrastructure files.

See [Remote Backup Synchronization](../remote/README.md).

Remote copies are not automatically deleted when local retention removes older dumps.

## Restore tools

The backup directory also contains:

- `restore-test.sh` — validates a backup through the test-restore workflow.
- `restore-live.sh` — performs the guarded live restoration workflow.

Inspect the scripts before use and follow their confirmation prompts. A live restore is a destructive operation and should not be performed as a routine verification step.

Before restoring:

1. Identify the exact dump to restore.
2. Confirm the backup is readable.
3. Preserve a separate copy of the current database where possible.
4. Review the restore script and its safeguards.
5. Confirm the target environment before proceeding.

Prefer a test restore before a live restore.

## Logs

The weekly wrapper redirects backup output to:

```text
~/backups/meal_project/backup.log
```

The weekly cycle status is recorded in:

```text
~/backups/meal_project/backup_cycle.log
```

Remote synchronization output is recorded in:

```text
~/backups/meal_project/remote_sync.log
```

## Related documentation

- [Infrastructure backup overview](../README.md)
- [Remote synchronization and encrypted configuration recovery](../remote/README.md)
- [Weekly backup schedule](../../cron/README.md)
