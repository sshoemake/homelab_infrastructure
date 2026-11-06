#!/usr/bin/env python3
"""
Read-only health checks for homelab infrastructure.

Exit codes:
  0 = all services healthy
  1 = one or more services degraded or down
  2 = monitoring could not complete reliably
"""

import argparse
import json
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import ssl
from datetime import datetime, timezone


TIMEOUT = 10

CONTAINERS = {
    "Home Assistant": "homeassistant",
    "Portainer": "portainer",
    "Meal Project": "compose-web-1",
    "PostgreSQL": "myapp-db",
    "Traefik": "traefik",
}


def command(args, timeout=TIMEOUT):
    """Run a command and return (success, stdout, stderr)."""
    try:
        result = subprocess.run(
            args,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
        return (
            result.returncode == 0,
            result.stdout.strip(),
            result.stderr.strip(),
        )
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return False, "", str(exc)


def add_check(service, name, status, detail):
    service["checks"].append({
        "name": name,
        "status": status,
        "detail": detail,
    })


def inspect_container(name):
    """Read container state and Docker health status."""
    ok, output, error = command([
        "docker", "inspect", name,
        "--format",
        '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}',
    ])

    if not ok:
        return None, None, error or "Container not found or Docker unavailable"

    parts = output.split("|", 1)
    if len(parts) != 2:
        return None, None, f"Unexpected Docker inspect response: {output}"

    return parts[0], parts[1], None


def check_http(url, name, verify_tls=True):
    """Check an HTTP endpoint and return a check result."""
    context = None
    if url.startswith("https://") and not verify_tls:
        context = ssl._create_unverified_context()

    request = urllib.request.Request(
        url,
        headers={"User-Agent": "homelab-health-check/1.0"},
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=TIMEOUT,
            context=context,
        ) as response:
            code = response.status
            if 200 <= code < 400:
                return "PASS", f"HTTP {code}"
            return "FAIL", f"HTTP {code}"

    except urllib.error.HTTPError as exc:
        return "FAIL", f"HTTP {exc.code}"
    except Exception as exc:
        return "FAIL", f"{type(exc).__name__}: {exc}"


def check_tcp(host, port):
    """Check whether a TCP listener accepts connections."""
    try:
        with socket.create_connection((host, port), timeout=5):
            return "PASS", f"TCP connection accepted on {host}:{port}"
    except OSError as exc:
        return "FAIL", f"{type(exc).__name__}: {exc}"


def check_meal_route(hostname):
    """
    Check the Meal Project route through the local Traefik listener.

    --resolve directs the hostname to localhost while preserving HTTPS
    hostname/SNI behavior.
    """
    args = [
        "curl",
        "--silent",
        "--show-error",
        "--insecure",
        "--noproxy", "*",
        "--max-time", str(TIMEOUT),
        "--resolve", f"{hostname}:443:127.0.0.1",
        "--output", "/dev/null",
        "--write-out", "%{http_code}",
        f"https://{hostname}/",
    ]

    ok, output, error = command(args, timeout=TIMEOUT + 2)

    if not ok:
        return "FAIL", error or "curl failed"

    try:
        code = int(output)
    except ValueError:
        return "FAIL", f"Unexpected HTTP response: {output!r}"

    if 200 <= code < 400:
        return "PASS", f"HTTP {code} through local Traefik"

    return "FAIL", f"HTTP {code} through local Traefik"


def check_postgres():
    ok, output, error = command([
        "docker", "exec", "myapp-db", "pg_isready"
    ])

    if ok:
        return "PASS", output or "PostgreSQL accepting connections"

    return "FAIL", error or output or "pg_isready failed"


def check_django_database():
    """Execute a read-only SELECT 1 through Django's configured connection."""
    ok, output, error = command([
        "docker", "exec", "compose-web-1",
        "python", "manage.py", "shell", "-c",
        (
            "from django.db import connection; "
            "cursor = connection.cursor(); "
            "cursor.execute('SELECT 1'); "
            "print(cursor.fetchone()[0])"
        ),
    ], timeout=20)

    if ok and output.splitlines()[-1:] == ["1"]:
        return "PASS", "Django database query succeeded (SELECT 1)"

    return "FAIL", error or output or "Django database query failed"


def service_status(service):
    statuses = [check["status"] for check in service["checks"]]

    if "FAIL" in statuses:
        return "DOWN"

    if "WARN" in statuses:
        return "DEGRADED"

    if not statuses or all(status == "SKIP" for status in statuses):
        return "UNKNOWN"

    return "HEALTHY"


def build_report():
    report = {
        "host": socket.gethostname(),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "services": [],
    }

    for service_name, container_name in CONTAINERS.items():
        service = {
            "name": service_name,
            "container": container_name,
            "status": "UNKNOWN",
            "checks": [],
        }

        state, docker_health, error = inspect_container(container_name)

        if error:
            add_check(
                service,
                "Container",
                "FAIL",
                error,
            )
            service["status"] = service_status(service)
            report["services"].append(service)
            continue

        if state != "running":
            add_check(
                service,
                "Container",
                "FAIL",
                f"Container state is {state}",
            )
            service["status"] = service_status(service)
            report["services"].append(service)
            continue

        add_check(
            service,
            "Container",
            "PASS",
            "Container is running",
        )

        if docker_health == "healthy":
            add_check(service, "Docker health", "PASS", "Docker reports healthy")
        elif docker_health == "unhealthy":
            add_check(service, "Docker health", "FAIL", "Docker reports unhealthy")
        elif docker_health == "starting":
            add_check(service, "Docker health", "WARN", "Docker healthcheck is starting")
        else:
            add_check(
                service,
                "Docker health",
                "INFO",
                "No Docker healthcheck configured",
            )

        if service_name == "Home Assistant":
            status, detail = check_http("http://127.0.0.1:8123/", "Home Assistant")
            add_check(service, "Application HTTP", status, detail)

        elif service_name == "Portainer":
            status, detail = check_http(
                "https://127.0.0.1:9443/api/status",
                "Portainer API",
                verify_tls=False,
            )
            add_check(service, "Application API", status, detail)

        elif service_name == "Meal Project":
            for hostname in ("sshoemake.com", "www.sshoemake.com"):
                status, detail = check_meal_route(hostname)
                add_check(
                    service,
                    f"HTTPS route ({hostname})",
                    status,
                    detail,
                )

            status, detail = check_django_database()
            add_check(service, "Database dependency", status, detail)

        elif service_name == "PostgreSQL":
            status, detail = check_postgres()
            add_check(service, "PostgreSQL readiness", status, detail)

        elif service_name == "Traefik":
            for port in (80, 443):
                status, detail = check_tcp("127.0.0.1", port)
                add_check(
                    service,
                    f"Listener port {port}",
                    status,
                    detail,
                )

        service["status"] = service_status(service)
        report["services"].append(service)

    return report


def print_report(report):
    print("=" * 68)
    print("HOMELAB HEALTH REPORT")
    print(f"Host:      {report['host']}")
    print(f"Timestamp: {report['timestamp']}")
    print("=" * 68)

    for service in report["services"]:
        print()
        print(f"{service['name']} [{service['status']}]")
        print(f"  Container: {service['container']}")

        for check in service["checks"]:
            print(
                f"  {check['status']:<6} "
                f"{check['name']}: {check['detail']}"
            )

    counts = {}
    for service in report["services"]:
        status = service["status"]
        counts[status] = counts.get(status, 0) + 1

    print()
    print("-" * 68)
    print("SUMMARY")
    print(f"Services checked: {len(report['services'])}")
    for status in ("HEALTHY", "DEGRADED", "DOWN", "UNKNOWN"):
        print(f"{status:<10} {counts.get(status, 0)}")
    print("=" * 68)


def main():
    parser = argparse.ArgumentParser(
        description="Read-only homelab infrastructure health checks"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON instead of a text report",
    )
    args = parser.parse_args()

    started = time.monotonic()
    report = build_report()
    report["duration_seconds"] = round(time.monotonic() - started, 2)

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_report(report)

    statuses = [service["status"] for service in report["services"]]

    if "UNKNOWN" in statuses:
        return 2
    if any(status in ("DOWN", "DEGRADED") for status in statuses):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
