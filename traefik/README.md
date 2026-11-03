# Traefik

Traefik is the central reverse proxy for the homelab. It provides
HTTPS access to services running on the Odroid M2 and manages TLS
certificates through Let's Encrypt.

Traefik runs as an independent Docker Compose project so that
application deployments can be managed separately from the reverse
proxy.

## Architecture

- Host: Odroid M2
- LAN address: 192.168.0.112
- HTTP: port 80
- HTTPS: port 443
- Docker network: `compose_public`
- Certificate provider: Let's Encrypt
- DNS provider: Cloudflare

### Network overview

Traefik and web-facing application containers communicate through
the shared Docker network `compose_public`.

Meal Project uses:
- `compose_public` for reverse proxy access
- `compose_internal` for private application/database communication

Home Assistant uses host networking and is accessed by Traefik
through the Odroid M2 host address.

Only Traefik needs to publish ports 80 and 443 to the host.

## Directory structure

```text
traefik/
├── docker-compose.yml
├── traefik.yml
├── .env
├── acme.json
├── dynamic/
│   └── security-headers.yml
└── README.md

## Documentation

- [Deployment Guide](DEPLOYMENT.md) — Initial setup, configuration,
  deployment, validation, and recovery procedures.
  