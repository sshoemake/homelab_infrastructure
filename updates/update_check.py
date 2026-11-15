#!/usr/bin/env python3
"""
Read-only upstream image update checker.

Currently checks the active Home Assistant container against the
latest stable GHCR image for its platform.

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


REGISTRY = "ghcr.io"
TAG = "stable"
VERSION_LABEL = "org.opencontainers.image.version"

ACCEPT_MANIFESTS = ", ".join([
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
])


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


def find_home_assistant(containers):
    """Find the active, running Home Assistant container."""
    matches = [
        item for item in containers
        if item.get("role") == "ACTIVE"
        and item.get("running") is True
        and (
            "home-assistant" in item.get("image", "").lower()
            or item.get("name", "").lower().startswith("homeassistant")
        )
    ]

    if len(matches) != 1:
        raise RuntimeError(
            "Expected exactly one active, running Home Assistant "
            f"container; found {len(matches)}"
        )

    return matches[0]


def image_repository(image):
    """Extract the registry repository from an image reference."""
    reference = image.split("@", 1)[0]
    final_component = reference.rsplit("/", 1)[-1]

    if ":" in final_component:
        reference = reference.rsplit(":", 1)[0]

    parts = reference.split("/")

    if len(parts) < 2 or parts[0] != REGISTRY:
        raise RuntimeError(
            f"Expected a {REGISTRY} image reference; found {image}"
        )

    return "/".join(parts[1:])


def registry_headers(repository):
    """Obtain an anonymous pull token for the GHCR repository."""
    query = urllib.parse.urlencode({
        "scope": f"repository:{repository}:pull"
    })

    url = f"https://{REGISTRY}/token?{query}"
    request = urllib.request.Request(url)

    with urllib.request.urlopen(request, timeout=20) as response:
        token_data = json.load(response)

    token = token_data.get("token") or token_data.get("access_token")

    if not token:
        raise RuntimeError("GHCR did not return an access token")

    return {
        "Authorization": f"Bearer {token}",
        "Accept": ACCEPT_MANIFESTS,
    }


def registry_json(url, headers, accept=None):
    """Read a JSON document from the container registry."""
    request_headers = headers.copy()

    if accept:
        request_headers["Accept"] = accept

    request = urllib.request.Request(url, headers=request_headers)

    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
        response_headers = response.headers

    return data, response_headers


def latest_image(repository, platform):
    """Resolve the stable image version for the requested platform."""
    headers = registry_headers(repository)
    base = f"https://{REGISTRY}/v2/{repository}"

    manifest, manifest_headers = registry_json(
        f"{base}/manifests/{TAG}",
        headers,
    )

    manifest_digest = manifest_headers.get(
        "Docker-Content-Digest"
    )

    platforms = manifest.get("manifests", [])

    if not platforms:
        raise RuntimeError(
            "Stable tag did not return a multi-platform image index"
        )

    try:
        operating_system, architecture = platform.split("/", 1)
    except ValueError as error:
        raise RuntimeError(
            f"Unrecognized platform: {platform}"
        ) from error

    matching = [
        item for item in platforms
        if item.get("platform", {}).get("os") == operating_system
        and item.get("platform", {}).get("architecture") == architecture
    ]

    if len(matching) != 1:
        raise RuntimeError(
            f"Expected one {platform} image in the stable manifest; "
            f"found {len(matching)}"
        )

    platform_digest = matching[0]["digest"]

    image_manifest, _ = registry_json(
        f"{base}/manifests/{platform_digest}",
        headers,
    )

    config_digest = image_manifest.get("config", {}).get("digest")

    if not config_digest:
        raise RuntimeError("Platform image has no configuration digest")

    config, _ = registry_json(
        f"{base}/blobs/{config_digest}",
        headers,
    )

    labels = config.get("config", {}).get("Labels") or {}
    version = labels.get(VERSION_LABEL)

    if not version:
        raise RuntimeError(
            f"Image does not contain the {VERSION_LABEL} label"
        )

    return {
        "latest_version": str(version),
        "manifest_digest": manifest_digest,
        "platform_digest": platform_digest,
        "platform": platform,
        "tag": TAG,
    }


def version_tuple(version):
    """Convert a dotted numeric version into a comparable tuple."""
    numbers = re.findall(r"\d+", str(version))

    if not numbers:
        raise ValueError(f"Cannot parse version: {version}")

    return tuple(int(number) for number in numbers)


def compare_versions(current, latest):
    """Return the update status for two version strings."""
    current_parts = version_tuple(current)
    latest_parts = version_tuple(latest)

    if current_parts < latest_parts:
        return "UPDATE_AVAILABLE"

    if current_parts == latest_parts:
        return "UP_TO_DATE"

    return "CURRENT_AHEAD"


def check_home_assistant():
    """Check the active Home Assistant installation against GHCR."""
    containers = discover_containers()
    container = find_home_assistant(containers)

    current_version = container.get("current_version")
    platform = container.get("platform")
    image = container.get("image", "")

    if not current_version or not platform:
        raise RuntimeError(
            "Discovery did not provide the installed version and platform"
        )

    repository = image_repository(image)
    upstream = latest_image(repository, platform)

    status = compare_versions(
        current_version,
        upstream["latest_version"],
    )

    return {
        "service": "Home Assistant",
        "container": container["name"],
        "image": image,
        "repository": repository,
        "platform": platform,
        "current_version": current_version,
        "latest_version": upstream["latest_version"],
        "status": status,
        "registry": REGISTRY,
        "tag": upstream["tag"],
        "manifest_digest": upstream["manifest_digest"],
        "platform_digest": upstream["platform_digest"],
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
        result = check_home_assistant()
        report = {
            "updates": [result],
            "summary": {
                "checked": 1,
                "update_available": int(
                    result["status"] == "UPDATE_AVAILABLE"
                ),
                "up_to_date": int(
                    result["status"] == "UP_TO_DATE"
                ),
                "current_ahead": int(
                    result["status"] == "CURRENT_AHEAD"
                ),
                "unknown": 0,
            },
            "read_only": True,
        }
    except (
        RuntimeError,
        ValueError,
        KeyError,
        OSError,
        subprocess.TimeoutExpired,
    ) as error:
        report = {
            "updates": [{
                "service": "Home Assistant",
                "status": "UNKNOWN",
                "error": str(error),
            }],
            "summary": {
                "checked": 1,
                "update_available": 0,
                "up_to_date": 0,
                "current_ahead": 0,
                "unknown": 1,
            },
            "read_only": True,
        }

    if args.json:
        print(json.dumps(report, indent=2))
        return 0

    print("=" * 72)
    print("HOMELAB UPSTREAM UPDATE CHECK")
    print("=" * 72)

    for item in report["updates"]:
        print(f"Service:         {item['service']}")
        print(f"Status:          {item['status']}")

        if item["status"] == "UNKNOWN":
            print(f"Error:           {item['error']}")
        else:
            print(f"Container:       {item['container']}")
            print(f"Platform:        {item['platform']}")
            print(f"Current version: {item['current_version']}")
            print(f"Latest version:  {item['latest_version']}")
            print(f"Registry:        {item['registry']}")
            print(f"Image tag:       {item['tag']}")

    print()
    print("Update check completed. No images were pulled.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nUpdate check interrupted.", file=sys.stderr)
        sys.exit(130)
