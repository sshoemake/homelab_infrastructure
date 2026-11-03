# Traefik Deployment Guide

This document describes how to initially deploy, configure, maintain,
and recover Traefik on the Odroid M2.

Traefik provides reverse proxy functionality and HTTPS access for
services running in the homelab.

Traefik is deployed as an independent Docker Compose project,
separate from application deployments such as Meal Project.

## 1. Architecture

### Host

- Server: Odroid M2
- Operating system: Ubuntu
- Container runtime: Docker
- Deployment method: Docker Compose

### Network

Traefik provides access to services through a shared Docker network.

| Component | Purpose |
|---|---|
| Traefik | Reverse proxy and HTTPS termination |
| `compose_public` | Shared network for Traefik and web-facing services |
| `compose_internal` | Private application/database communication |
| Cloudflare | DNS management and DNS challenge authentication |
| Let's Encrypt | TLS certificate authority |

Traefik publishes the following ports:

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | HTTP access and redirection |
| 443 | TCP | HTTPS access |

Only Traefik needs to publish these ports to the host.

### Application routing

Applications connect to Traefik through the shared `compose_public`
network.

Meal Project uses:
- `compose_public` for reverse proxy communication.
- `compose_internal` for private application/database communication.

Home Assistant runs separately using Docker host networking.
Traefik forwards requests to Home Assistant through the Odroid M2
host address.

## 2. Prerequisites

Before deploying Traefik, verify the following:

- Odroid M2 is running and accessible over SSH.
- Docker Engine is installed.
- Docker Compose plugin is installed.
- The `homelab_infrastructure` repository is available.
- The domain is managed through Cloudflare.
- The router is accessible for port forwarding.
- The Odroid M2 has a stable LAN IP address.

Verify Docker:

```bash
docker --version
docker compose version
```

Verify the repository:

```bash
cd ~/homelab_infrastructure
git status
```

3. Configure Cloudflare
Traefik uses the Cloudflare DNS challenge to obtain and renew
Let's Encrypt certificates.

Create a Cloudflare API token with these permissions:
- Zone / DNS / Edit
- Zone / Zone / Read
Restrict the token to the appropriate domain.

Configure the DNS records for services that will be accessible
through Traefik.

For Meal Project:
- sshoemake.com
- www.sshoemake.com
The DNS records should point to the public IP address of the home
network. Cloudflare proxying can remain enabled.
4. Configure router port forwarding
Configure the router to forward incoming traffic to the Odroid M2.
External port	Internal port	Protocol
80	80	TCP
443	443	TCP

Use the Odroid M2's reserved LAN IP address as the destination.

Port 80 supports HTTP access and redirection.
Port 443 handles HTTPS access.

The Cloudflare DNS challenge itself does not require inbound
port 80.
5. Prepare Traefik configuration
Navigate to the Traefik directory:

cd ~/homelab_infrastructure/traefik


Verify the configuration files:
ls -la


Expected files:
- docker-compose.yml
- traefik.yml
- dynamic/security-headers.yml
Configure environment variables
Create the environment file:
vi .env


Add the Cloudflare API token using the variable name expected
by docker-compose.yml:
TRAEFIK_CF_API_TOKEN=your_cloudflare_api_token


Secure the file:
chmod 600 .env


Never commit .env to Git.
Prepare certificate storage
Create the Let's Encrypt certificate storage file:
touch acme.json
chmod 600 acme.json


Traefik uses this file to store certificate and account information.

Do not commit acme.json to Git or delete it during routine
deployments.

6. Create the shared Docker network
Traefik uses an external Docker network named compose_public.

Check whether it already exists:
docker network inspect compose_public


If the network does not exist, create it:
docker network create compose_public


Verify:
docker network ls


Application containers that require reverse proxy access must
also join this network.

7. Validate configuration
From the Traefik directory:
docker compose config --quiet


Resolve any configuration errors before proceeding.
8. Initial Traefik deployment
Start Traefik:
docker compose up -d


Check container status:
docker compose ps


Review startup logs:
docker compose logs --tail=100 traefik


Confirm that:
- The Traefik container is running.
- The Docker provider initializes successfully.
- Cloudflare authentication is configured.
- The Let's Encrypt certificate resolver initializes.
- Dynamic configuration loads successfully.
- No persistent startup errors appear.
9. Connect applications
Traefik discovers Docker services through the Docker provider.

Web-facing applications must:
1. Join the external compose_public network.
2. Define Traefik routing labels.
3. Specify the hostname rule.
4. Specify the HTTPS entrypoint.
5. Specify the certificate resolver.
6. Specify the internal application port.
Meal Project
Meal Project uses:
Setting	Value
Hostnames	sshoemake.com, www.sshoemake.com
Entrypoint	websecure
Certificate resolver	letsencrypt
Middleware	security-headers@file
Application port	8000

Meal Project routing labels remain in its own Compose configuration.

Deploy Meal Project using the deployment instructions in:

meal_project/
Home Assistant
Home Assistant runs separately using Docker host networking.

Traefik forwards requests to Home Assistant through the Odroid M2
host address on port 8123.

Home Assistant must trust the reverse proxy through its
http: trusted_proxies configuration.
10. Verify deployment
Once an application has been connected, verify public HTTPS access.

For Meal Project:
curl -I https://sshoemake.com
curl -I https://www.sshoemake.com


Check DNS resolution:
dig sshoemake.com
dig www.sshoemake.com


Review Traefik logs:
docker compose logs --since=30m traefik


Verify:
- DNS resolves correctly.
- Router port forwarding is working.
- Traefik recognizes the application router.
- A valid Let's Encrypt certificate is issued.
- HTTPS access works externally.
Testing from a device using cellular data is recommended to
avoid potential local DNS or router hairpin NAT issues.
11. Normal operations
Run commands from:
cd ~/homelab_infrastructure/traefik


Check status
docker compose ps


View logs
docker compose logs -f traefik


Restart Traefik
docker compose restart traefik


Apply configuration changes
docker compose config --quiet
docker compose up -d


Stop Traefik
docker compose down


Stopping Traefik does not require deleting certificate storage.
12. Updates and maintenance
Traefik is deployed independently of Meal Project.

For routine configuration updates:
1. Pull the latest repository changes.
2. Review the changed configuration files.
3. Validate the Compose configuration.
4. Apply the changes.
5. Verify container status and logs.
6. Test external HTTPS access.
Example:
cd ~/homelab_infrastructure
git pull

cd traefik
docker compose config --quiet
docker compose up -d

docker compose ps
docker compose logs --tail=100 traefik


Do not delete acme.json or recreate the Docker network during
routine updates.
Backups
Important files to preserve:
File	Purpose	Git
docker-compose.yml	Container configuration	Yes
traefik.yml	Static configuration	Yes
dynamic/	Dynamic configuration	Yes
.env	Cloudflare API token	No
acme.json	Certificate storage	No

Back up .env and acme.json securely.
13. Recovery
Recreate the Traefik container
If the container needs to be recreated:
cd ~/homelab_infrastructure/traefik
docker compose up -d --force-recreate


Verify:
docker compose ps
docker compose logs --tail=100 traefik


Certificate storage should remain intact because acme.json
is maintained outside the container.
Rebuild on a new host
When rebuilding the Odroid M2:
1. Install Docker Engine and Docker Compose.
2. Clone the infrastructure repository.
3. Recreate the .env file.
4. Restore acme.json from a secure backup.
5. Set acme.json permissions to 600.
6. Create the external compose_public network.
7. Validate the Traefik configuration.
8. Start Traefik.
9. Verify container health and logs.
10. Verify application routing and external HTTPS access.
If the host's LAN IP changes, update router port forwarding and
any application configurations that reference the old address.
Certificate recovery
If acme.json is lost or corrupted:
1. Stop Traefik.
2. Check for a valid backup.
3. Restore the backup if available.
4. Verify ownership and permissions.
5. Restart Traefik.
6. Review ACME logs.
Avoid repeatedly deleting certificate storage and restarting
Traefik. Let's Encrypt enforces certificate issuance limits.
14. Troubleshooting
Traefik container will not start
docker compose config --quiet
docker compose ps
docker compose logs --tail=100 traefik


Check:
- Missing environment variables.
- Incorrect file paths or mounts.
- Invalid YAML.
- File permissions.
- Docker socket access.
- Port conflicts on 80 or 443.
Application is not reachable
docker ps
docker network inspect compose_public


Confirm:
- Traefik and the application are running.
- Both containers are attached to compose_public.
- Traefik labels are correct.
- Hostname rules are correct.
- The backend application port is correct.
HTTPS certificate is not issued
docker compose logs --since=30m traefik


Check:
- Cloudflare API token is valid.
- Token permissions are correct.
- Environment variable name matches Compose configuration.
- DNS zone and domain are correct.
- acme.json exists.
- acme.json permissions are 600.
- Certificate resolver name matches application labels.
HTTP works but HTTPS does not
Verify:
- Port 443 is forwarded to the Odroid M2.
- Traefik publishes port 443.
- The application router uses websecure.
- The certificate resolver is configured correctly.
- A valid certificate is available.
Traefik cannot reach an application
docker network inspect compose_public


Confirm that both containers share the network.

Verify the application's internal listening port.

Traefik communicates with application containers through the
Docker network, not through their host-published ports.
Home Assistant reports an untrusted proxy
Check the trusted_proxies setting in Home Assistant's
configuration.yaml.

The trusted address must match the source address Home Assistant
sees for Traefik.

Restart Home Assistant after making changes.
15. Security considerations
- Keep Cloudflare API tokens out of Git.
- Keep acme.json out of Git.
- Restrict permissions on secret files.
- Use a read-only Docker socket where supported.
- Avoid exposing application containers directly to the internet.
- Publish only the ports required by Traefik.
- Keep Docker images and Traefik updated.
- Back up certificate storage and secrets securely.

### Certificate recovery

Traefik stores Let's Encrypt account information, certificates,
and private keys in `acme.json`.

If this file is lost or corrupted, certificates cannot be retrieved
from Cloudflare. However, Traefik can request replacement certificates
from Let's Encrypt using the existing Cloudflare DNS challenge
configuration.

#### Recovery procedure

1. Stop Traefik:

   ```bash
   docker compose down
   ```
2. Preserve the corrupted file if one exists:
   mv acme.json acme.json.corrupt
3. Recreate certificate storage:
   touch acme.json
   chmod 600 acme.json
4. Verify that .env still exists and contains the valid
   Cloudflare API token.
5. Start Traefik:
   docker compose up -d
6. Monitor certificate activity:
   docker compose logs -f traefik
7. Verify that acme.json has been populated and test
   external HTTPS access.
Traefik should automatically request new certificates for
application routers configured with the letsencrypt resolver.
Important precautions
- Do not delete Cloudflare DNS records.
- Do not delete or regenerate the Cloudflare API token unless
  it is invalid or compromised.
- Do not repeatedly recreate acme.json or restart Traefik.
- Let's Encrypt enforces certificate issuance limits.
- If certificate issuance fails, troubleshoot the DNS challenge
  and Cloudflare authentication before retrying.
- Restore a valid backup of acme.json instead of requesting
  new certificates whenever possible.   