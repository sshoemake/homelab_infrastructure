
# Infrastructure Discovery and Monitoring

This directory contains read-only tools for discovering Docker infrastructure,
checking application health, and consolidating monitoring results.

The monitoring system is designed to:

- Discover active Docker containers and their configuration.
- Identify currently running application versions.
- Check container, application, and dependency health.
- Produce consolidated human-readable and JSON reports.
- Compare installed versions against available upstream releases (planned).
- Send notifications when problems or updates are detected (planned).

Monitoring scripts do not deploy updates, restart containers, or modify application
configuration.

## Components

| Component | File | Purpose |
|---|---|---|
| Discovery | `discover.sh` / `discover.py` | Discover Docker containers, images, versions, and metadata |
| Health monitoring | `health.sh` / `health.py` | Check container, application, and dependency health |
| Consolidated monitoring | `monitor.sh` / `monitor.py` | Combine discovery and health results into one report |
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

Human-readable report:

```bash
~/homelab_infrastructure/updates/discover.sh
```

Machine-readable JSON:

```bash
~/homelab_infrastructure/updates/discover.sh --json
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

### Health check exit codes

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

## Consolidated Monitoring

The consolidated monitor runs discovery and health monitoring independently,
then combines their JSON results into one report.

It does not parse human-readable terminal output. Each component remains
independently usable.

### Run consolidated monitoring

Human-readable report:

```bash
~/homelab_infrastructure/updates/monitor.sh
```

Machine-readable JSON:

```bash
~/homelab_infrastructure/updates/monitor.sh --json
```

The consolidated report includes:

- Host and report timestamp.
- Overall monitoring status.
- Individual discovery and health report status.
- Service health summary.
- Container inventory summary.
- Active and rollback container counts.
- Service-to-container matching results.
- Current detected version for each monitored service.
- Individual health check results.
- Monitoring errors, if any.
- Explicit read-only indicator.

A service without a matching discovered container is reported as `UNKNOWN`.
Unrecognized service statuses are also normalized to `UNKNOWN`.

If discovery or health report execution fails, the overall status is `ERROR`.
The other component is still executed so that partial results can be retained.

### Consolidated monitor exit codes

| Exit code | Meaning |
|---|---|
| `0` | All monitored services are healthy |
| `1` | One or more services are degraded or down |
| `2` | One or more services have an unknown status |
| `3` | Discovery or health monitoring failed, or returned an invalid report |

### JSON output

The JSON report is intended for future integrations, including version
comparison, scheduled reporting, and notifications.

Example:

```bash
~/homelab_infrastructure/updates/monitor.sh --json \
  > /tmp/monitor.json

python3 -m json.tool /tmp/monitor.json
```

The report contains top-level `summary`, `services`, `containers`, and `errors`
sections, along with host, timestamp, status, component results, and the
`read_only` indicator.

## Design Principles

- **Read-only:** Monitoring does not change infrastructure.
- **Discovery first:** Current versions and container details are obtained from
  the running system rather than manually maintained version fields.
- **Application-aware:** Container status alone is insufficient to establish
  application health.
- **Explicit criticality:** Critical and noncritical checks are distinguished.
- **Consolidated reporting:** Discovery and health results are combined into
  one machine-readable or human-readable report.
- **Extensible:** New services and monitoring capabilities can be added
  independently.

## Future Development

Planned improvements:

1. Add upstream version discovery for monitored images and applications.
2. Compare running, configured, and latest available versions.
3. Integrate the existing infrastructure email notification system.
4. Schedule a daily monitoring report.
5. Add lightweight recurring health checks with outage and recovery notifications.
6. Consider independent monitoring from the Odroid C5.

Updates will remain informational. Deployment decisions will remain manual.
