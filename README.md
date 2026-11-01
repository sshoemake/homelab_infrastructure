# homelab_infrastructure

Infrastructure configuration for the home lab. The initial project here manages
Traefik as a standalone Docker Compose project, independent of Meal Project.

## Repository layout

```text
homelab_infrastructure/
├── .env.example
├── .gitignore
├── README.md
└── traefik/
    ├── docker-compose.yml
    ├── traefik.yml
    ├── dynamic/
    │   └── security-headers.yml
    └── data/
        └── .gitkeep
```

## Important: migration scaffold, not an immediate deployment

This repository is a starting point for separating Traefik from the existing
Meal Project Compose project. **Do not run `docker compose up -d` yet** while
the current Traefik container is running and owns host ports 80 and 443.

The intended migration keeps the existing Traefik container name, static
configuration, middleware, Cloudflare DNS challenge, and ACME data, while
renaming the shared Docker network from `compose_public` to `traefik_public`.

The existing live ACME file must be preserved. Do not replace it with a blank
file or commit it to Git.

## Host layout

The intended deployment location is:

```text
/home/odroid/homelab_infrastructure/
```

Traefik's Compose project is in its `traefik/` subdirectory. The Compose file
uses paths relative to that directory.

## Initial preparation

1. Create a private or public GitHub repository named `homelab_infrastructure`
   and push this scaffold.
2. Clone it on the Odroid into `/home/odroid/homelab_infrastructure`.
3. Create the local environment file:

   ```bash
   cp .env.example .env
   chmod 600 .env
   nano .env
   ```

   Replace the placeholder with the Cloudflare API token. Do not commit `.env`.

4. Create the ACME storage file:

   ```bash
   mkdir -p traefik/data
   touch traefik/data/acme.json
   chmod 600 traefik/data/acme.json
   ```

   **Do not populate this with a new empty ACME store during migration.**
   The existing `/home/odroid/Meal_Project/traefik/acme.json` contains live
   certificate/account data. During the planned cutover, copy that exact file
   into `traefik/data/acme.json` and preserve its contents and restrictive
   permissions. Keep the original as a rollback copy until the new Traefik
   instance has been verified.

5. Ensure the shared network exists before starting Traefik:

   ```bash
   docker network create traefik_public
   ```

   If it already exists, do not recreate it.

## Compose validation

From the `traefik/` directory, after creating `.env`:

```bash
docker compose config --quiet
```

This validates the Compose configuration without printing the resolved
configuration (which can contain environment values).

Do not start this Compose project until the old Traefik service has been
stopped as part of the coordinated migration. Both instances cannot bind
ports 80 and 443 at the same time.

## Network design

The standalone Traefik project attaches to the externally managed Docker
network `traefik_public`. Meal Project's production Compose configuration
will also attach its web service to this network and use the label:

```yaml
- "traefik.docker.network=traefik_public"
```

Meal Project's private `compose_internal` network remains separate and
continues to connect the application to PostgreSQL.

The `traefik_public` network is deliberately external to both Compose
projects. Neither project's `docker compose down` should remove it.

## Current routing

The initial configuration retains the existing HTTP and HTTPS entry points,
Docker provider, file provider, Cloudflare DNS challenge, and Let's Encrypt
resolver. The existing Meal Project router labels will remain on the Meal
Project web service.

Home Assistant is intentionally not configured here yet. It will be a
separate follow-up phase after the Traefik migration and existing website
verification are complete.

## Security notes

- Keep `.env` and `traefik/data/acme.json` out of Git.
- Keep `acme.json` permissioned `600`.
- The Cloudflare token should have narrowly scoped DNS permissions.
- The Docker socket is mounted read-only, but read-only mounting alone does
  not make Docker API access harmless. Consider a restricted Docker socket
  proxy as a later hardening improvement.
- The Traefik dashboard is enabled in the API configuration but is not
  published through an insecure entry point or host port.
- Do not expose Home Assistant's port 8123 directly to the internet.
