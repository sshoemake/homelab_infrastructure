
#!/usr/bin/env python3

import ipaddress
import os
import sys
from datetime import datetime
from zoneinfo import ZoneInfo

import requests

LOCAL_TZ = ZoneInfo("America/Phoenix")

# ==========================================================
# CONFIGURATION
# ==========================================================

API_TOKEN = os.environ["CLOUDFLARE_API_TOKEN"]
ZONE_ID = os.environ["CLOUDFLARE_ZONE_ID"]
RECORD_ID = os.environ["CLOUDFLARE_RECORD_ID"]
RECORD_NAME = os.environ.get(
    "CLOUDFLARE_RECORD_NAME", "sshoemake.com"
)

RECORD_TYPE = "A"

from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent

IP_FILE = SCRIPT_DIR / "last_ip.txt"
IP_CHECK_URL = "https://api.ipify.org"

CLOUDFLARE_URL = (
    f"https://api.cloudflare.com/client/v4/zones/"
    f"{ZONE_ID}/dns_records/{RECORD_ID}"
)

# ==========================================================
# FUNCTIONS
# ==========================================================

def tprint(*args):
    timestamp = datetime.now(LOCAL_TZ).strftime(
        "%Y-%m-%d %H:%M:%S"
    )
    print(f"[{timestamp}]", *args, flush=True)


def get_public_ip():
    try:
        response = requests.get(IP_CHECK_URL, timeout=10)
        response.raise_for_status()

        ip = response.text.strip()

        # Validate that the returned address is IPv4.
        parsed_ip = ipaddress.ip_address(ip)

        if parsed_ip.version != 4:
            raise ValueError("Expected an IPv4 address")

        return ip

    except (requests.RequestException, ValueError) as exc:
        tprint(f"Failed to get valid public IP: {exc}")
        sys.exit(1)


def get_last_ip():
    try:
        with open(IP_FILE, "r") as file:
            return file.read().strip()
    except FileNotFoundError:
        return None


def save_ip(ip):
    with open(IP_FILE, "w") as file:
        file.write(ip)


def update_cloudflare(ip):
    headers = {
        "Authorization": f"Bearer {API_TOKEN}",
        "Content-Type": "application/json",
    }

    payload = {
        "type": RECORD_TYPE,
        "name": RECORD_NAME,
        "content": ip,
        "ttl": 1,
        "proxied": True,
    }

    try:
        response = requests.put(
            CLOUDFLARE_URL,
            headers=headers,
            json=payload,
            timeout=15,
        )

        response.raise_for_status()

        result = response.json()

        if not result.get("success"):
            tprint("Cloudflare update failed:")
            tprint(result.get("errors", result))
            sys.exit(1)

        tprint("Cloudflare DNS record updated successfully.")

    except (requests.RequestException, ValueError) as exc:
        tprint(f"Cloudflare API error: {exc}")
        sys.exit(1)


# ==========================================================
# MAIN
# ==========================================================

def main():
    current_ip = get_public_ip()
    last_ip = get_last_ip()

    if current_ip == last_ip:
        tprint(f"No change detected ({current_ip}).")
        return

    tprint(f"IP changed: {last_ip} -> {current_ip}")

    update_cloudflare(current_ip)

    # Only save after a successful Cloudflare update.
    save_ip(current_ip)


if __name__ == "__main__":
    main()
