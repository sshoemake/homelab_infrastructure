## Remote backups

`sync.sh` has two routines under the existing shared Meal_Project operation lock:

1. It syncs completed PostgreSQL `.dump` files to `${REMOTE_BASE_DIR}/meal_project`, preserving the existing workflow.
2. It reads `paths.conf`, creates a tar archive from those repository-relative paths, encrypts the archive locally with age, then syncs the `.tar.age` file to `${REMOTE_BASE_DIR}/encrypted`.

Only the encrypted archive is sent to the remote host. The source copy is stored in `LOCAL_BACKUP_DIR` with mode `600`. Remote files are not automatically deleted. The `odroid` account must be able to read every listed source file; the archive preserves file modes for recovery.

## Prerequisite

sudo apt update
sudo apt install age
age --version

## Configuration

Copy `.env.example` to `.env` on the Odroid and set the connection values plus `AGE_RECIPIENT` to an age **public recipient**. Copy `paths.conf.example` to `paths.conf` there, then add the actual repository-relative paths to back up. Both `.env` and `paths.conf` are local configuration and are not tracked by Git. Do not put a passphrase or private identity in `.env`. The private age identity is needed only for recovery and should be stored offline or on a separate trusted device. Install `age` on the Odroid before running the sync.

`paths.conf` is a plain text manifest: one repository-relative path per line, with blank lines and `#` comments allowed. Add live secrets or irreplaceable configuration there as needed. Paths must exist and cannot be absolute or contain `..`.

## Recovery

Copy a `.tar.age` archive from the remote `encrypted` directory to a trusted recovery machine, then decrypt and extract it from the repository's parent directory so stored relative paths land in their original locations:

```sh
age --decrypt --identity /path/to/offline-age-identity.txt \
  --output sensitive_files.tar sensitive_files_YYYYMMDD_HHMMSS.tar.age
tar -xf sensitive_files.tar
chmod 600 meal_project/compose/.env.prod traefik/data/acme.json
```

Restore each file's required ownership as well as permissions on the recovered host. Keep the age identity separate from both the source and remote backup host; without it, the encrypted archives cannot be recovered.
