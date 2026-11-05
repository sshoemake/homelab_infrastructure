
# Remote Backup Synchronization

This directory contains the scripts and configuration for synchronizing Meal_Project database backups and encrypted infrastructure configuration files from the M2 to the remote C5 backup host.

## Overview

`sync.sh` performs two backup operations under the shared Meal_Project operation lock:

1. Synchronizes completed PostgreSQL `.dump` files to the remote host.
2. Creates an encrypted archive of sensitive configuration files using `age` and synchronizes that archive to the remote host.

The shared lock prevents synchronization from interfering with database backup, deployment, or restore operations.

Remote files are never automatically deleted.

## Backup Architecture

### 1. Meal_Project database backups

Completed PostgreSQL backups are read from:

```text
/home/odroid/backups/meal_project/
```

Only completed `.dump` files are synchronized.

Remote destination:

```text
/home/odroid/homelab_backups/meal_project/
```

### 2. Sensitive configuration backups

Sensitive configuration files are listed in `paths.conf`.

The synchronization script:

1. Validates each configured path.
2. Creates a tar archive containing the selected files.
3. Encrypts the archive locally using `age`.
4. Sets the encrypted archive permissions to `600`.
5. Transfers the encrypted archive to the C5.

Remote destination:

```text
/home/odroid/homelab_backups/encrypted/
```

Only the encrypted archive is transferred. Unencrypted configuration files are never sent to the remote host.

The local encrypted archive is retained in the local backup directory.

## Prerequisites

Install the required packages on the M2:

```bash
sudo apt update
sudo apt install age rsync
```

The following utilities must also be available:

- bash
- tar
- ssh
- flock

Verify age installation:

```bash
age --version
```

## Configuration

### 1. Remote connection settings

Copy the example configuration:

```bash
cp .env.example .env
chmod 600 .env
```

Configure the following values:

| Variable | Description |
|---|---|
| `REMOTE_HOST` | Remote backup hostname |
| `REMOTE_USER` | SSH username |
| `REMOTE_BASE_DIR` | Remote backup root directory |
| `SSH_KEY` | Private SSH key used for authentication |
| `SSH_PORT` | SSH port (default 22) |
| `LOCAL_BACKUP_DIR` | Local Meal_Project backup directory |
| `AGE_RECIPIENT` | Public age encryption recipient |
| `LOCK_WAIT_SECONDS` | Maximum time to wait for the shared operation lock |

The private age identity must never be stored in `.env`, GitHub, or on the remote backup host.

Keep the matching private identity offline or on a separate trusted recovery device.

### 2. Sensitive file manifest

Copy the example manifest:

```bash
cp paths.conf.example paths.conf
chmod 600 paths.conf
```

`paths.conf` contains one sensitive-file path per line.

Blank lines and comments beginning with `#` are ignored.

Two types of paths are supported.

**Repository-relative paths**

Paths are relative to the `homelab_infrastructure` repository root.

Examples:

```text
meal_project/compose/.env.prod
traefik/.env
traefik/data/acme.json
portainer/compose/.env
```

**Approved absolute paths**

Absolute paths are supported for external configuration files located under the user's `~/.config/` directory.

Example:

```text
/home/odroid/.config/msmtp/config
```

The script applies the following validation:

- Repository-relative paths cannot contain directory traversal (`..`).
- Absolute paths must be inside the user's `.config` directory.
- Absolute paths must exist and be regular files.
- Symbolic links are not accepted for absolute paths.
- Unauthorized absolute paths are rejected.

Do not use `~` in paths. Specify the complete absolute path instead.

The live `paths.conf` file is local configuration and is not tracked by Git.

## Running the Synchronization

Run manually whenever an ad-hoc remote synchronization is needed:

```bash
cd ~/homelab_infrastructure/backups/remote

./sync.sh
```

The script can also be executed from another directory using its full path.

### Expected execution sequence

1. Load `.env` and validate configuration.
2. Acquire the shared Meal_Project operation lock.
3. Identify completed database backups.
4. Validate sensitive-file paths.
5. Create and encrypt the sensitive-file archive.
6. Establish the SSH connection to the C5.
7. Synchronize database dumps.
8. Synchronize the encrypted configuration archive.
9. Release the operation lock.

Successful execution ends with:

```text
Remote synchronization completed successfully.
Synchronized X backup(s).
Synchronized one encrypted sensitive-file archive.
```

## Remote Backup Structure

The expected directory structure on the C5 is:

```text
/home/odroid/homelab_backups/
├── meal_project/
│   ├── meal_project_weekly_YYYYMMDD_HHMMSS.dump
│   └── ...
│
└── encrypted/
    ├── sensitive_files_YYYYMMDD_HHMMSS_PID.tar.age
    └── ...
```

Both remote directories are created automatically and assigned permissions of `700`.

## Verifying Backups

List the remote database backups:

```bash
ssh odroid@odroidc5.local \
  "ls -lh ~/homelab_backups/meal_project/"
```

List encrypted configuration archives:

```bash
ssh odroid@odroidc5.local \
  "ls -lh ~/homelab_backups/encrypted/"
```

### Verify encrypted archive contents

Copy an encrypted archive to a trusted recovery location.

Decrypt it using the private age identity:

```bash
age --decrypt \
  --identity /path/to/age-identity.txt \
  --output sensitive_files.tar \
  sensitive_files_YYYYMMDD_HHMMSS_PID.tar.age
```

List the archive contents without extracting:

```bash
tar -tvf sensitive_files.tar
```

The listing should include both repository-relative configuration files and external configuration files.

For example:

```text
meal_project/compose/.env.prod
traefik/data/acme.json
home/odroid/.config/msmtp/config
```

## Recovery

The age private identity is required to recover encrypted configuration files.

Keep it separate from both the M2 and C5.

After decrypting an archive, inspect its contents before extracting anything.

Repository-relative files should be restored to the `homelab_infrastructure` repository root.

External configuration files are stored relative to the filesystem root. For example:

```text
home/odroid/.config/msmtp/config
```

Restore external files to their original filesystem locations, preserving appropriate ownership and restrictive permissions.

For the msmtp configuration:

```bash
mkdir -p ~/.config/msmtp

chmod 700 ~/.config/msmtp
chmod 600 ~/.config/msmtp/config
```

Do not blindly extract an entire archive as root. Restore only the intended files to their appropriate destinations.

After recovery, verify application configuration and functionality before restarting affected services.

## Security Considerations

- Never commit `.env`, `paths.conf`, private SSH keys, or age private identities to GitHub.
- Keep `.env` and `paths.conf` permissions restricted.
- Sensitive configuration files are encrypted locally before remote transfer.
- The remote C5 stores encrypted configuration archives, not plaintext secrets.
- The age private identity must be protected separately.
- Remote backups are not automatically deleted.
- Preserve the shared operation lock when modifying backup or synchronization scripts.
- Test restoration periodically rather than relying exclusively on successful synchronization logs.

## Related Components

- `backups/meal_project/` - PostgreSQL backup and restore scripts.
- `backups/remote/` - Remote synchronization and encrypted configuration backups.
- `notifications/` - Backup and infrastructure notification scripts.
- `cron/` - Scheduled infrastructure tasks.
