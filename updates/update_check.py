#!/usr/bin/env python3
"""
Read-only upstream image update checker.

Checks:
- Home Assistant: GHCR stable tag and OCI version label.
- Meal_Project: highest published vX.Y.Z GHCR release.
- Portainer CE: highest published X.Y.Z Docker Hub release.

Does not pull images or modify containers or configuration.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import urllib.parse
import urllib.request


VERSION_LABEL = "org.opencontainers.image.version"

ACCEPT_MANIFESTS = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])

SERVICES = [
    {
        "service": "Home Assistant",
        "kind": "stable",
        "repository": "home-assistant/home-assistant",
        "registry": "ghcr.io",
        "tag": "stable",
        "match": ("homeassistant", "home-assistant"),
    },
    {
        "service": "Meal_Project",
        "kind": "versioned",
        "repository": "sshoemake/meal_project",
        "registry": "ghcr.io",
        "tag_pattern": re.compile(r"^v\d+\.\d+\.\d+$"),
        "match": ("meal_project",),
    },
    {
        "service": "Portainer",
        "kind": "versioned",
        "repository": "portainer/portainer-ce",
        "registry": "docker.io",
        "tag_pattern": re.compile(r"^\d+\.\d+\.\d+$"),
        "match": ("portainer",),
    },
]


def discover_containers():
    """Read installed container details from the existing discovery script."""
    script = Path(__file__).resolve().with_name("discover.py")
    result = subprocess.run(
        [sys.executable, script, "--json"],
        capture_output=True,
        text=True,
        timeout=45,
        check=False,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip() or "Discovery command failed"
        )

    try:
        report = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            f"Discovery returned invalid JSON: {error}"
        ) from error

    return report.get("containers", [])


def find_container(containers, service):
    """Find exactly one active, running container for a service."""
    markers = service["match"]

    matches = [
        item for item in containers
        if item.get("role") == "ACTIVE"
        and item.get("running") is True
        and any(
            marker in item.get("image", "").lower()
            or marker in item.get("name", "").lower()
            for marker in markers
        )
    ]

    if len(matches) != 1:
        raise RuntimeError(
            f"Expected exactly one active, running "
            f"{service['service']} container; found {len(matches)}"
        )

    return matches[0]


def version_tuple(version):
    """Convert a dotted numeric version into a comparable tuple."""
    numbers = re.findall(r"\d+", str(version))

    if not numbers:
        raise ValueError(f"Cannot parse version: {version}")

    return tuple(int(number) for number in numbers)


def compare_versions(current, latest):
    """Compare two numeric versions."""
    current_parts = version_tuple(current)
    latest_parts = version_tuple(latest)

    if current_parts < latest_parts:
        return "UPDATE_AVAILABLE"

    if current_parts == latest_parts:
        return "UP_TO_DATE"

    return "CURRENT_AHEAD"


def registry_details(registry):
    """Return registry API and authentication details."""
    if registry == "ghcr.io":
        return {
            "host": "ghcr.io",
            "token_url": "https:" + "/" + "/" + "ghcr.io/token",
            "service": None,
        }

    if registry == "docker.io":
        return {
            "host": "registry-1.docker.io",
            "token_url": "https:" + "/" + "/" + "auth.docker.io/token",
            "service": "registry.docker.io",
        }

    raise RuntimeError(f"Unsupported registry: {registry}")


def registry_headers(registry, repository):
    """Obtain an anonymous pull token for a registry repository."""
    details = registry_details(registry)

    parameters = {
        "scope": f"repository:{repository}:pull"
    }

    if details["service"]:
        parameters["service"] = details["service"]

    url = (
        f"{details['token_url']}?"
        f"{urllib.parse.urlencode(parameters)}"
    )

    request = urllib.request.Request(url)

    with urllib.request.urlopen(request, timeout=20) as response:
        token_data = json.load(response)

    token = token_data.get("token") or token_data.get("access_token")

    if not token:
        raise RuntimeError(
            f"{registry} did not return an access token"
        )

    return {
        "Authorization": f"Bearer {token}",
        "Accept": ACCEPT_MANIFESTS,
    }


def registry_json(url, headers, accept=None):
    """Read a JSON document from a container registry."""
    request_headers = headers.copy()

    if accept:
        request_headers["Accept"] = accept

    request = urllib.request.Request(url, headers=request_headers)

    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
        response_headers = response.headers

    return data, response_headers


def docker_registry_tags(repository, headers):
    """Retrieve all published tags from the authenticated Docker Registry."""
    base = (
        "https:" + "/" + "/"
        + f"registry-1.docker.io/v2/{repository}/tags/list"
    )
    url = f"{base}?n=1000"
    tags = []

    while url:
        data, response_headers = registry_json(url, headers)
        tags.extend(data.get("tags") or [])

        link = response_headers.get("Link", "")
        next_url = None

        for part in link.split(","):
            if 'rel="next"' in part:
                match = re.search(r"<([^>]+)>", part)
                if match:
                    next_url = urllib.parse.urljoin(url, match.group(1))
                break

        url = next_url

    return tags


def ghcr_tags(repository, headers):
    """Retrieve published tags from GHCR."""
    base = "https:" + "/" + "/" + f"ghcr.io/v2/{repository}/tags/list"
    url = f"{base}?n=1000"

    tags = []

    while url:
        data, response_headers = registry_json(url, headers)
        tags.extend(data.get("tags") or [])

        link = response_headers.get("Link", "")
        next_url = None

        for part in link.split(","):
            if 'rel="next"' in part:
                match = re.search(r"<([^>]+)>", part)
                if match:
                    next_url = urllib.parse.urljoin(url, match.group(1))
                break

        url = next_url

    return tags


def latest_version_tag(service, headers):
    """Find the highest published stable release tag."""
    if service["registry"] == "docker.io":
        tags = docker_registry_tags(service["repository"], headers)
    else:
        tags = ghcr_tags(service["repository"], headers)

    pattern = service["tag_pattern"]
    versions = [tag for tag in tags if pattern.fullmatch(tag)]

    if not versions:
        raise RuntimeError(
            f"No matching stable release tags found for "
            f"{service['repository']}"
        )

    return max(versions, key=version_tuple)


def latest_image(service, tag, platform, headers):
    """Resolve a tag and verify that its image supports the platform."""
    registry = service["registry"]
    repository = service["repository"]
    details = registry_details(registry)

    base = "https:" + "/" + "/" + details["host"] + f"/v2/{repository}"

    manifest, manifest_headers = registry_json(
        f"{base}/manifests/{urllib.parse.quote(tag, safe='')}",
        headers,
    )

    manifest_digest = manifest_headers.get("Docker-Content-Digest")
    if not manifest_digest:
        raise RuntimeError("Registry did not return a manifest digest")

    try:
        operating_system, architecture = platform.split("/", 1)
    except ValueError as error:
        raise RuntimeError(
            f"Unrecognized platform: {platform}"
        ) from error

    platforms = manifest.get("manifests", [])

    if platforms:
        matching = [
            item for item in platforms
            if item.get("platform", {}).get("os") == operating_system
            and item.get("platform", {}).get("architecture") == architecture
        ]

        if len(matching) != 1:
            raise RuntimeError(
                f"Expected one {platform} image in the manifest; "
                f"found {len(matching)}"
            )

        platform_digest = matching[0]["digest"]

        image_manifest, _ = registry_json(
            f"{base}/manifests/{platform_digest}",
            headers,
        )
    else:
        # A single-platform manifest has no platform index to inspect.
        platform_digest = manifest_digest
        image_manifest = manifest

    config_digest = image_manifest.get("config", {}).get("digest")

    if not config_digest:
        raise RuntimeError("Platform image has no configuration digest")

    config, _ = registry_json(
        f"{base}/blobs/{config_digest}",
        headers,
    )

    labels = config.get("config", {}).get("Labels") or {}

    return {
        "manifest_digest": manifest_digest,
        "platform_digest": platform_digest,
        "platform": platform,
        "version_label": labels.get(VERSION_LABEL),
        "tag": tag,
    }


def check_service(service, containers):
    """Check one service without affecting the other service checks."""
    container = find_container(containers, service)

    current_version = container.get("current_version")
    platform = container.get("platform")
    image = container.get("image", "")

    if not current_version or not platform:
        raise RuntimeError(
            "Discovery did not provide the installed version and platform"
        )

    repository = service["repository"]
    registry = service["registry"]
    headers = registry_headers(registry, repository)

    if service["kind"] == "stable":
        tag = service["tag"]
        upstream = latest_image(service, tag, platform, headers)

        latest_version = upstream["version_label"]

        if not latest_version:
            raise RuntimeError(
                f"Image does not contain the {VERSION_LABEL} label"
            )
    else:
        tag = latest_version_tag(service, headers)
        upstream = latest_image(service, tag, platform, headers)

        # Versioned release tags are the deployment source of truth.
        latest_version = tag

    return {
        "service": service["service"],
        "container": container["name"],
        "image": image,
        "repository": repository,
        "platform": platform,
        "current_version": current_version,
        "latest_version": str(latest_version),
        "status": compare_versions(current_version, latest_version),
        "registry": registry,
        "tag": tag,
        "manifest_digest": upstream["manifest_digest"],
        "platform_digest": upstream["platform_digest"],
    }


def unknown_result(service, container=None, error="Unknown error"):
    """Build a consistent UNKNOWN result for a failed service check."""
    result = {
        "service": service["service"],
        "status": "UNKNOWN",
        "error": str(error),
    }

    if container:
        result.update({
            "container": container.get("name"),
            "image": container.get("image"),
            "platform": container.get("platform"),
            "current_version": container.get("current_version"),
            "registry": service["registry"],
            "repository": service["repository"],
        })

    return result


def build_report(results):
    """Build the summary while preserving the monitor.py JSON contract."""
    summary = {
        "checked": len(results),
        "update_available": 0,
        "up_to_date": 0,
        "current_ahead": 0,
        "unknown": 0,
    }

    status_keys = {
        "UPDATE_AVAILABLE": "update_available",
        "UP_TO_DATE": "up_to_date",
        "CURRENT_AHEAD": "current_ahead",
        "UNKNOWN": "unknown",
    }

    for item in results:
        key = status_keys.get(item["status"], "unknown")
        summary[key] += 1

    return {
        "updates": results,
        "summary": summary,
        "read_only": True,
    }


def main():
    parser = argparse.ArgumentParser(
        description="Read-only upstream image update checker"
    )
    parser.add_argument(
        "--json",
        action="store_true",
        help="Print machine-readable JSON",
    )
    args = parser.parse_args()

    try:
        containers = discover_containers()
        discovery_error = None
    except (
        RuntimeError,
        ValueError,
        KeyError,
        OSError,
        subprocess.TimeoutExpired,
    ) as error:
        containers = []
        discovery_error = str(error)

    results = []

    for service in SERVICES:
        if discovery_error:
            results.append(
                unknown_result(service, error=discovery_error)
            )
            continue

        container = None

        try:
            container = find_container(containers, service)
            results.append(check_service(service, containers))
        except (
            RuntimeError,
            ValueError,
            KeyError,
            OSError,
            subprocess.TimeoutExpired,
        ) as error:
            results.append(
                unknown_result(service, container, error)
            )

    report = build_report(results)

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    print("=" * 72)
    print("HOMELAB UPSTREAM UPDATE CHECK")
    print("=" * 72)

    for item in report["updates"]:
        print()
        print(f"Service:         {item['service']}")
        print(f"Status:          {item['status']}")

        if item["status"] == "UNKNOWN":
            if item.get("container"):
                print(f"Container:       {item['container']}")
                print(f"Current version: {item.get('current_version')}")
            print(f"Error:           {item['error']}")
        else:
            print(f"Container:       {item['container']}")
            print(f"Platform:        {item['platform']}")
            print(f"Current version: {item['current_version']}")
            print(f"Latest version:  {item['latest_version']}")
            print(f"Registry:        {item['registry']}")
            print(f"Image tag:       {item['tag']}")

    print()
    print("SUMMARY")
    print("-" * 72)

    for key, value in report["summary"].items():
        print(f"{key.replace('_', ' ').title():20} {value}")

    print()
    print("Update check completed. No images were pulled.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nUpdate check interrupted.", file=sys.stderr)
        sys.exit(130)
