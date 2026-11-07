#!/usr/bin/env python3

import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parent

DISCOVER_SCRIPT = SCRIPT_DIR / "discover.sh"
HEALTH_SCRIPT = SCRIPT_DIR / "health.sh"

HEALTH_EXIT_CODES = {0, 1, 2}

STATUS_SEVERITY = {
    "HEALTHY": 0,
    "UNKNOWN": 1,
    "DEGRADED": 2,
    "DOWN": 3,
}


def run_json_script(script, accepted_exit_codes, timeout=180):
    """Run a script and return its parsed JSON report."""

    try:
        result = subprocess.run(
            ["bash", str(script), "--json"],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, str(error)

    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        detail = result.stderr.strip() or result.stdout.strip()
        return None, (
            f"{script.name} returned invalid JSON: {error}. "
            f"Output: {detail[:500]}"
        )

    if result.returncode not in accepted_exit_codes:
        detail = result.stderr.strip() or "No error details provided"
        return None, (
            f"{script.name} exited with code {result.returncode}: {detail}"
        )

    return report, None


def aggregate_status(services):
    """Return the worst service status in the report."""

    if not services:
        return "UNKNOWN"

    return max(
        (service.get("status", "UNKNOWN").upper() for service in services),
        key=lambda status: STATUS_SEVERITY.get(status, 1),
    )


def build_report():
    """Combine discovery and health reports."""

    discovery, discovery_error = run_json_script(
        DISCOVER_SCRIPT,
        {0},
    )

    health, health_error = run_json_script(
        HEALTH_SCRIPT,
        HEALTH_EXIT_CODES,
    )

    if discovery is not None and (
        not isinstance(discovery, dict)
        or not isinstance(discovery.get("containers"), list)
        or not all(
            isinstance(container, dict)
            for container in discovery["containers"]
        )
        or not isinstance(discovery.get("summary", {}), dict)
    ):
        discovery = None
        discovery_error = (
            "discover.sh returned valid JSON with an invalid structure"
        )

    if health is not None and (
        not isinstance(health, dict)
        or not isinstance(health.get("services"), list)
        or not all(
            isinstance(service, dict)
            for service in health["services"]
        )
    ):
        health = None
        health_error = (
            "health.sh returned valid JSON with an invalid structure"
        )

    errors = [
        error
        for error in (discovery_error, health_error)
        if error
    ]

    discovered_containers = (
        discovery.get("containers", []) if discovery else []
    )

    container_lookup = {
        container.get("name"): container
        for container in discovered_containers
    }

    services = []

    if health:
        for service in health.get("services", []):
            container = container_lookup.get(
                service.get("container"),
                {},
            )

            service_status = service.get("status", "UNKNOWN").upper()

            if service_status not in STATUS_SEVERITY:
                service_status = "UNKNOWN"

            if not container:
                service_status = "UNKNOWN"

            services.append({
                "name": service.get("name", "Unknown"),
                "container": service.get("container", "unknown"),
                "status": service_status,
                "container_match": "MATCHED" if container else "NOT FOUND",
                "role": container.get("role", "NOT DISCOVERED"),
                "container_state": container.get("state", "unknown"),
                "current_version": container.get(
                    "current_version", "unknown"
                ),
                "version_source": container.get(
                    "version_source", "unknown"
                ),
                "checks": service.get("checks", []),
            })

    health_status = aggregate_status(services)

    if errors:
        overall_status = "ERROR"
    else:
        overall_status = health_status

    discovery_summary = (
        discovery.get("summary", {}) if discovery else {}
    )

    summary = {
        "services_total": len(services),
        "healthy": sum(
            service["status"] == "HEALTHY" for service in services
        ),
        "degraded": sum(
            service["status"] == "DEGRADED" for service in services
        ),
        "down": sum(
            service["status"] == "DOWN" for service in services
        ),
        "unknown": sum(
            service["status"] == "UNKNOWN" for service in services
        ),
        "containers_total": discovery_summary.get("total", 0),
        "containers_running": discovery_summary.get("running", 0),
        "containers_stopped": discovery_summary.get("stopped", 0),
        "rollback_containers": sum(
            container.get("role") == "ROLLBACK"
            for container in discovered_containers
        ),
    }

    return {
        "host": (
            health.get("host", "unknown") if health else "unknown"
        ),
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "status": overall_status,
        "health_status": health_status,
        "summary": summary,
        "discovery_status": "ERROR" if discovery_error else "OK",
        "health_report_status": "ERROR" if health_error else "OK",
        "health_duration_seconds": (
            health.get("duration_seconds") if health else None
        ),
        "errors": errors,
        "services": services,
        "containers": discovered_containers,
        "read_only": True,
    }


def print_text_report(report):
    """Print a human-readable consolidated report."""

    print("=" * 72)
    print("HOMELAB INFRASTRUCTURE MONITOR")
    print("=" * 72)
    print(f"Host:              {report['host']}")
    print(f"Generated:         {report['timestamp']}")
    print(f"Overall status:    {report['status']}")
    print(f"Health status:     {report['health_status']}")
    print(f"Discovery:         {report['discovery_status']}")
    print(f"Health report:     {report['health_report_status']}")

    summary = report["summary"]

    print()
    print("SUMMARY")
    print("-" * 72)
    print(f"Services monitored:  {summary['services_total']}")
    print(f"Healthy:             {summary['healthy']}")
    print(f"Degraded:            {summary['degraded']}")
    print(f"Down:                {summary['down']}")
    print(f"Unknown:             {summary['unknown']}")
    print(f"Containers:          {summary['containers_total']}")
    print(f"Running:             {summary['containers_running']}")
    print(f"Stopped:             {summary['containers_stopped']}")
    print(f"Rollback containers: {summary['rollback_containers']}")

    print()
    print("SERVICE DETAILS")
    print("-" * 72)

    for service in report["services"]:
        print(
            f"{service['name']} - {service['status']}"
        )
        print(f"  Container: {service['container']}")
        print(f"  Match:     {service['container_match']}")
        print(f"  State:     {service['container_state']}")
        print(f"  Version:   {service['current_version']}")

        for check in service["checks"]:
            print(
                f"  [{check.get('status', 'UNKNOWN')}] "
                f"{check.get('name', 'Unnamed check')}: "
                f"{check.get('detail', '')}"
            )

        print()

    print("CONTAINER INVENTORY")
    print("-" * 72)

    for container in report["containers"]:
        print(
            "{:<35} {:<8} {:<10} {}".format(
                container.get("name", "unknown"),
                container.get("role", "unknown"),
                container.get("state", "unknown"),
                container.get("current_version", "unknown"),
            )
        )

    if report["errors"]:
        print()
        print("MONITORING ERRORS")
        print("-" * 72)
        for error in report["errors"]:
            print(f"- {error}")

    print()
    print("Read-only monitoring. No infrastructure changes were made.")


def main():
    parser = argparse.ArgumentParser(
        description="Consolidated read-only homelab monitoring"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON",
    )

    args = parser.parse_args()
    report = build_report()

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print_text_report(report)

    if report["status"] == "ERROR":
        return 3
    if report["status"] in {"DOWN", "DEGRADED"}:
        return 1
    if report["status"] == "UNKNOWN":
        return 2

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nMonitoring interrupted.", file=sys.stderr)
        sys.exit(130)
