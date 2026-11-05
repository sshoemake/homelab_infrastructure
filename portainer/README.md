# Portainer CE

This directory contains the Docker Compose configuration and deployment helper for Portainer Community Edition on the Odroid M2.

Portainer is used to manage the Docker environment. Its application data is stored in the external Docker volume `portainer_data`, separate from the Compose configuration and deployment script.

## Directory layout

```text
portainer/
├── README.md
├── deploy.sh
└── compose/
    ├── docker-compose.yml
    ├── .env.example
    └── .env                 # Local only; ignored by Git
```

- `deploy.sh` retrieves available stable Portainer CE tags and deploys a selected version.
- `compose/docker-compose.yml` defines the Portainer container.
- `compose/.env.example` documents the required version setting and is tracked by Git.
- `compose/.env` contains the version used by this host. It is local configuration and must not be committed.

## Requirements

The M2 host must have:

- Docker Engine running.
- Docker Compose v2 (`docker compose`).
- Bash.
- `curl` and `jq` for retrieving and parsing Docker Hub tags.
- The standard Linux utilities used by the script, including `flock`, `sort`, `grep`, `sed`, `tail`, `tac`, `seq`, and `mktemp`.
- Internet access to Docker Hub when listing or pulling versions.

The deployment script checks for its required commands before running.

## Initial setup

Run these commands from the repository root:

```bash
cd ~/homelab_infrastructure

# Create the local version file if it does not already exist.
cp portainer/compose/.env.example portainer/compose/.env

# Restrict access to the local environment file.
chmod 600 portainer/compose/.env

# Ensure the deployment script is executable.
chmod 755 portainer/deploy.sh
```

Edit `portainer/compose/.env` if the desired version differs from the example:

```bash
PORTAINER_VERSION=2.45.3
```

Use a stable `X.Y.Z` release tag. The value in `.env` is the version Compose uses when creating the container.

The root `.gitignore` excludes `.env` and `.env.*` while allowing `.env.example` to be tracked. Do not add the live `.env` file to Git.

## Configuration

The Compose file uses the version from `.env`:

```yaml
image: portainer/portainer-ce:${PORTAINER_VERSION:?PORTAINER_VERSION must be set}
```

The service:

- Uses the container name `portainer`.
- Restarts automatically with Docker's `always` restart policy.
- Publishes ports `8000` and `9443`.
- Mounts `/var/run/docker.sock` so Portainer can manage Docker.
- Mounts the external `portainer_data` volume at `/data`.

The volume is declared external:

```yaml
volumes:
  portainer_data:
    external: true
```

This is intentional. Normal deployments recreate the container but retain the existing Portainer data volume. **Do not remove `portainer_data` during an upgrade.**

Portainer is normally accessed over HTTPS at:

```text
https://<M2-LAN-address>:9443
```

## Deployment commands

Run commands from the repository root.

### Show help

```bash
./portainer/deploy.sh --help
```

### Show current status

```bash
./portainer/deploy.sh status
```

Displays the version configured in `.env` and the image tag used by the existing `portainer` container.

### List available stable versions

```bash
./portainer/deploy.sh versions
```

Queries the Docker Hub tags API, filters for stable tags matching `X.Y.Z`, and displays up to the 15 newest versions returned by the API.

This command does not pull an image or change the running container.

### Interactive deployment

```bash
./portainer/deploy.sh
```

Displays the available stable versions and asks you to select one. The script then asks for confirmation before making changes.

### Deploy a specific version

```bash
./portainer/deploy.sh 2.46.0
```

Replace `2.46.0` with the exact stable version you intend to deploy. The script validates the version format and asks for confirmation.

Do not assume that a version exists just because it matches the version format; Docker Hub must have the corresponding image tag for the pull to succeed.

## What a deployment does

For a selected version, the script:

1. Checks required commands and configuration.
2. Creates the Portainer deployment lock directory and obtains an exclusive `flock` lock. The default lock file is:
   `~/backups/portainer/portainer-deploy.lock`
3. Confirms that the existing Portainer container exists and is running.
4. Shows the configured, running, and selected versions and requests confirmation.
5. Validates the Compose configuration.
6. Pulls the selected image directly from Docker Hub **before changing the live container**.
7. Updates `compose/.env` to the selected version.
8. Recreates only the Portainer service with `docker compose up -d --no-deps --force-recreate portainer`.
9. Checks that the replacement container reaches the running state and uses the requested image.
10. Reports completion.

The deployment does not run `docker compose down`, does not remove the external `portainer_data` volume, and does not recreate unrelated services.

### Current failure-handling limitation

If the image pull fails, the script exits before changing `.env` or replacing the running container.

If the Compose recreation command itself fails, the current script restores the previous version setting in `.env`, but it does **not** automatically guarantee that the previous container has been restored. If the replacement container fails its later running-state check, the script reports an error but does not perform an automatic rollback.

After any deployment error, inspect the configuration, container state, and logs before retrying:

```bash
./portainer/deploy.sh status

docker ps -a --filter name=portainer

docker logs --tail 100 portainer
```

Do not assume that restoring the `.env` value alone restores the previous running container.

## Post-deployment verification

After a successful deployment:

```bash
./portainer/deploy.sh status

docker inspect portainer \
  --format 'Image: {{.Config.Image}} | Status: {{.State.Status}} | Restart: {{.HostConfig.RestartPolicy.Name}}'

docker volume inspect portainer_data \
  --format 'Volume: {{.Name}} | Mountpoint: {{.Mountpoint}}'
```

Confirm that:

- Configured and running versions match.
- The container state is `running`.
- The restart policy is `always`.
- The `portainer_data` volume still exists.
- The Portainer web interface is accessible.

## Backup and recovery approach

Portainer is treated as a rebuildable management interface rather than a source of critical application data. A dedicated recurring backup of `portainer_data` is not currently part of the backup plan.

The deployment configuration is stored in Git, while the live version setting is kept locally in `compose/.env`. The local `.env` is included in the remote infrastructure backup manifest (`backups/remote/paths.conf`) so the configured version can be recovered.

If Portainer's data volume is lost, Portainer can be redeployed and its initial setup recreated. This means its Portainer-specific users, settings, and UI configuration may need to be set up again. Removing Portainer's data volume is not part of a normal upgrade.

Losing Portainer's data volume does not, by itself, delete the other Docker containers or their separately stored application data, such as the Meal_Project database or Home Assistant configuration. Those services and their data require their own backup and recovery procedures.

## Routine update procedure

1. Review the Portainer release information and decide which stable version to install.
2. From the repository root, run `./portainer/deploy.sh versions`.
3. Run `./portainer/deploy.sh status` and confirm the configured and running versions agree.
4. Deploy the selected version interactively or by exact tag.
5. Confirm the deployment when prompted.
6. Verify the version, container state, volume, and web interface.
7. If anything fails, inspect the container and logs before taking further action.

Keep the live `.env` file private and do not commit it. Commit changes to the Compose definition, deployment script, `.env.example`, or this README through the normal repository workflow.
