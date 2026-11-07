
# Infrastructure Discovery and Monitoring

This directory contains read-only tools for discovering Docker infrastructure,
checking application health, and eventually monitoring available software updates.

The monitoring system is designed to:

- Discover active Docker containers and their configuration.
- Identify currently running application versions.
- Check container, application, and dependency health.
- Compare installed versions against available upstream releases (planned).
- Produce consolidated reports.
- Send notifications when problems or updates are detected (planned).

Monitoring scripts do not deploy updates, restart containers, or modify application
configuration.

## Components

| Component | File | Purpose |
|---|---|---|
| Discovery | `discover.sh` / `discover.py` | Discover Docker containers, images, versions, and metadata |
| Health monitoring | `health.sh` / `health.py` | Check container, application, and dependency health |
| Update monitoring | Planned | Compare running versions against upstream releases |
| Notifications | Planned integration | Deliver consolidated reports and alerts |

## Discovery

Discovery inventories Docker containers and gathers information including:

- Container name and state.
- Docker Compose project and service.
- Image name and tag.
- Detected application version.
- Image ID and available repository digest.
- Image operating system and architecture.
- Docker health status.
- Active versus rollback container classification.

Version detection uses application-reported versions where available, followed by
image metadata and image tags as fallbacks.

A digest identifies an image build but is not necessarily a semantic application
version.

### Run discovery

From any directory:

```bash
~/homelab_infrastructure/updates/discover.sh
```

Discovery is read-only.

## Health Monitoring

The health checker evaluates five active services on the Odroid M2.

| Service | Container | Health checks |
|---|---|---|
| Home Assistant | `homeassistant` | Container state, HTTP response |
| Portainer | `portainer` | Container state, API response |
| Meal Project | `compose-web-1` | Container state, primary and secondary HTTPS routes, Django database query |
| PostgreSQL | `myapp-db` | Container state, Docker health, PostgreSQL readiness |
| Traefik | `traefik` | Container state, TCP listeners on ports 80 and 443 |

Docker healthchecks are included when configured. Services without Docker
healthchecks are evaluated using their application-specific checks.

### Run health monitoring

Human-readable report:

```bash
~/homelab_infrastructure/updates/health.sh
```

Machine-readable JSON:

```bash
~/homelab_infrastructure/updates/health.sh --json
```

The JSON report includes the host, timestamp, individual service results,
check details, and execution duration.

### Service status definitions

| Status | Meaning |
|---|---|
| `HEALTHY` | All required checks passed |
| `DEGRADED` | Application remains available, but a noncritical check failed or a warning was reported |
| `DOWN` | A critical check failed |
| `UNKNOWN` | Monitoring could not reliably determine service health |

Critical checks determine whether a service is considered down. Noncritical
failures identify partial problems without overstating a complete outage.

For Meal Project, the primary `sshoemake.com` route and database dependency
are critical. The `www.sshoemake.com` route is secondary.

### Exit codes

| Exit code | Meaning |
|---|---|
| `0` | All monitored services are healthy |
| `1` | One or more services are degraded or down |
| `2` | One or more services have an unknown status |

### Health check limitations

- HTTPS route checks use local Traefik routing and bypass certificate verification.
  They verify application responsiveness, not certificate trust or expiration.
- Traefik TCP checks verify that ports 80 and 443 accept connections. They do
  not independently validate all proxy routing behavior.
- Meal Project route checks provide additional evidence that Traefik routing works.
- A successful PostgreSQL readiness check does not replace the Django database
  dependency check.
- Services without Docker healthchecks rely on their application-specific checks.

## Design Principles

- **Read-only:** Monitoring does not change infrastructure.
- **Discovery first:** Current versions and container details are obtained from
  the running system rather than manually maintained version fields.
- **Application-aware:** Container status alone is insufficient to establish
  application health.
- **Explicit criticality:** Critical and noncritical checks are distinguished.
- **Extensible:** New services can be added with service-specific checks.
- **Consolidated reporting:** Health and version information will eventually
  be combined into a single report.

## Future Development

Planned improvements:

1. Add upstream version discovery for monitored images and applications.
2. Compare running, configured, and latest available versions.
3. Combine discovery, version, and health results into a consolidated report.
4. Integrate the existing infrastructure email notification system.
5. Schedule a daily monitoring report.
6. Add lightweight recurring health checks with outage and recovery notifications.
7. Consider independent monitoring from the Odroid C5.

Updates will remain informational. Deployment decisions will remain manual.
