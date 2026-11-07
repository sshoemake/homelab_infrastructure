#!/usr/bin/env python3

"""
Read-only Docker infrastructure discovery.

Reports all containers, including stopped containers.
Does not deploy, restart, pull, remove, or modify anything.
"""

import argparse
import json
import re
import ssl
import subprocess
import sys
import urllib.request


def docker(*args, timeout=20):
    result = subprocess.run(
        ["docker", *args],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Docker command failed")
    return result.stdout.strip()


def docker_exec(container, *command):
    try:
        return docker(
            "exec", container, *command, timeout=15
        )
    except (RuntimeError, subprocess.TimeoutExpired):
        return None


def image_tag(image):
    if "@" in image:
        return image.rsplit("@", 1)[1]

    final_component = image.rsplit("/", 1)[-1]
    if ":" in final_component:
        return final_component.rsplit(":", 1)[1]

    return "untagged"


def inspect_image(image_id, cache):
    if image_id in cache:
        return cache[image_id]

    try:
        data = json.loads(docker("image", "inspect", image_id))[0]
    except (RuntimeError, json.JSONDecodeError, IndexError):
        data = {}

    cache[image_id] = data
    return data


def portainer_version(container, container_data):
    ports = (
        container_data.get("NetworkSettings", {})
        .get("Ports", {})
    )

    host_port = None

    for bindings in ports.values():
        if not bindings:
            continue

        for binding in bindings:
            if binding.get("HostPort") == "9443":
                host_port = binding["HostPort"]
                break

        if host_port:
            break

    if not host_port:
        return None

    url = f"https://127.0.0.1:{host_port}/api/status"
    request = urllib.request.Request(url)

    try:
        context = ssl._create_unverified_context()
        with urllib.request.urlopen(
            request, context=context, timeout=5
        ) as response:
            data = json.loads(response.read().decode())
            version = data.get("Version")
            if version:
                return str(version), "Portainer API"
    except Exception:
        pass

    return None


def detect_version(container, container_data, image_data):
    config = container_data.get("Config", {})
    image = config.get("Image", "")
    name = container_data.get("Name", "").lstrip("/")
    labels = image_data.get("Config", {}).get("Labels") or {}

    image_version = labels.get("org.opencontainers.image.version")

    if container_data.get("State", {}).get("Running"):
        if "home-assistant" in image or name.startswith("homeassistant"):
            version = docker_exec(
                name, "python", "-m", "homeassistant", "--version"
            )
            if version:
                match = re.search(r"\d{4}\.\d+\.\d+", version)
                if match:
                    return match.group(0), "Home Assistant CLI"

        if "portainer" in image or "portainer" in name:
            result = portainer_version(name, container_data)
            if result:
                return result

        if "postgres" in image or name == "myapp-db":
            version = docker_exec(name, "postgres", "--version")
            if version:
                match = re.search(r"\d+(?:\.\d+)+", version)
                if match:
                    return match.group(0), "PostgreSQL executable"

        if "traefik" in image or name == "traefik":
            version = docker_exec(name, "traefik", "version")
            if version:
                match = re.search(
                    r"Version:\s*v?(\d+(?:\.\d+)+)", version
                )
                if match:
                    return match.group(1), "Traefik executable"

    if image_version:
        return image_version, "OCI image label"

    return image_tag(image), "Configured image tag"



def main():
    parser = argparse.ArgumentParser(
        description="Read-only Docker infrastructure discovery"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON instead of a text report",
    )
    args = parser.parse_args()

    try:
        container_ids = docker("ps", "-aq", "--no-trunc").split()
    except (RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"ERROR: Unable to query Docker: {error}", file=sys.stderr)
        return 1

    try:
        containers = (
            json.loads(docker("inspect", *container_ids))
            if container_ids
            else []
        )
    except (RuntimeError, json.JSONDecodeError) as error:
        print(f"ERROR: Unable to inspect containers: {error}", file=sys.stderr)
        return 1

    image_cache = {}
    counts = {
        "running": 0,
        "stopped": 0,
        "healthy": 0,
        "unhealthy": 0,
        "no_healthcheck": 0,
    }
    records = []

    for container in sorted(
        containers,
        key=lambda item: item.get("Name", "").lower(),
    ):
        name = container.get("Name", "").lstrip("/")
        config = container.get("Config", {})
        state = container.get("State", {})
        labels = config.get("Labels") or {}

        image = config.get("Image", "unknown")
        image_id = container.get("Image", "unknown")
        image_data = inspect_image(image_id, image_cache)

        status = state.get("Status", "unknown")
        running = state.get("Running", False)

        if running:
            counts["running"] += 1
        else:
            counts["stopped"] += 1

        health = state.get("Health", {}).get("Status")
        if health == "healthy":
            counts["healthy"] += 1
        elif health == "unhealthy":
            counts["unhealthy"] += 1
        elif not health:
            counts["no_healthcheck"] += 1

        project = labels.get("com.docker.compose.project", "-")
        service = labels.get("com.docker.compose.service", "-")

        rollback = (
            "rollback" in name.lower()
            or labels.get("homelab.role") == "rollback"
        )

        version, version_source = detect_version(
            name, container, image_data
        )

        repo_digests = image_data.get("RepoDigests") or []
        digest = (
            repo_digests[0].rsplit("@", 1)[-1]
            if repo_digests
            else "not available locally"
        )

        architecture = image_data.get("Architecture", "unknown")
        operating_system = image_data.get("Os", "unknown")

        records.append({
            "name": name,
            "role": "ROLLBACK" if rollback else "ACTIVE",
            "compose_project": project,
            "compose_service": service,
            "state": status,
            "running": running,
            "docker_health": health or "not configured",
            "image": image,
            "current_version": version,
            "version_source": version_source,
            "image_id": image_id,
            "image_digest": digest,
            "platform": f"{operating_system}/{architecture}",
            "exit_code": state.get("ExitCode") if not running else None,
        })

    report = {
        "containers": records,
        "summary": {
            "total": len(records),
            **counts,
        },
        "read_only": True,
    }

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    print("=" * 72)
    print("HOMELAB INFRASTRUCTURE DISCOVERY")
    print("=" * 72)
    print(f"Containers discovered: {len(records)}")
    print()

    for record in records:
        print("-" * 72)
        print(f"Container:       {record['name']}")
        print(f"Role:            {record['role']}")
        print(f"Compose project: {record['compose_project']}")
        print(f"Compose service: {record['compose_service']}")
        print(f"State:           {record['state']}")
        print(f"Docker health:   {record['docker_health']}")
        print(f"Image:           {record['image']}")
        print(f"Current version: {record['current_version']}")
        print(f"Version source:  {record['version_source']}")
        print(f"Image ID:        {record['image_id']}")
        print(f"Image digest:    {record['image_digest']}")
        print(f"Platform:        {record['platform']}")

        if not record["running"]:
            print(f"Exit code:       {record['exit_code']}")

    print()
    print("=" * 72)
    print("DISCOVERY SUMMARY")
    print("=" * 72)
    print(f"Total containers:       {len(records)}")
    print(f"Running:                {counts['running']}")
    print(f"Stopped:                {counts['stopped']}")
    print(f"Docker healthy:         {counts['healthy']}")
    print(f"Docker unhealthy:       {counts['unhealthy']}")
    print(f"No Docker healthcheck:  {counts['no_healthcheck']}")
    print()
    print("Discovery completed. No infrastructure changes were made.")

    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nDiscovery interrupted.", file=sys.stderr)
        sys.exit(130)
