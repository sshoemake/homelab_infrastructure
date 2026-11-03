
# Cloudflare Dynamic DNS

Maintains the public IPv4 address for `sshoemake.com`
using the Cloudflare DNS API.

The automation runs every five minutes through cron on
the Odroid M2.

## Directory Structure

All Cloudflare automation files are contained in this directory.

```text
cloudflare/
├── cloudflare_ddns.py
├── run_ddns.sh
├── requirements.txt
├── .env.example
├── .env                  # Actual credentials (not committed)
├── last_ip.txt           # Runtime state (not committed)
├── cloudflare_ddns.log   # Runtime log (not committed)
├── .venv/                # Python environment (not committed)
└── README.md
```

## System prerequisites

The Cloudflare DDNS script requires Python 3.14 and the
Python venv package.

Install the system dependencies:

```bash
sudo apt update
sudo apt install python3.14 python3.14-venv

## Configuration

Copy `.env.example` to `.env` and populate the
Cloudflare credentials:

- `CLOUDFLARE_API_TOKEN`
- `CLOUDFLARE_ZONE_ID`
- `CLOUDFLARE_RECORD_ID`
- `CLOUDFLARE_RECORD_NAME`

The API token should have DNS Edit permissions restricted
to the `sshoemake.com` zone.

Protect the configuration file:

```bash
chmod 600 .env
```

**Never commit `.env` to GitHub.**

## Installation

Run from the Cloudflare directory:

```bash
python3 -m venv .venv

.venv/bin/pip install -r requirements.txt

chmod 750 run_ddns.sh
```

## Execution

The `run_ddns.sh` script:

1. Loads credentials from `.env`.
2. Activates the required environment variables.
3. Executes `cloudflare_ddns.py` using the virtual environment.

The Python script:

1. Retrieves the current public IPv4 address.
2. Compares it against `last_ip.txt`.
3. Updates Cloudflare DNS only when the IP changes.
4. Saves the new IP after a successful update.

## Manual Execution

Run the automation manually:

```bash
./run_ddns.sh
```

## Cron Scheduling

The automation is managed through the repository's
centralized cron configuration:

`../cron/odroidm2.crontab`

Current schedule:

```cron
*/5 * * * * /home/odroid/homelab_infrastructure/cloudflare/run_ddns.sh >> /home/odroid/homelab_infrastructure/cloudflare/cloudflare_ddns.log 2>&1
```

After modifying the repository crontab, install it with:

```bash
cd ~/homelab_infrastructure

crontab cron/odroidm2.crontab
```

## Logs

View the latest log entries:

```bash
tail -f cloudflare_ddns.log
```

View the complete log:

```bash
cat cloudflare_ddns.log
```

## Troubleshooting

Check that the environment file exists:

```bash
ls -l .env
```

Check that the wrapper is executable:

```bash
ls -l run_ddns.sh
```

Check the Python environment:

```bash
.venv/bin/pip check
```

Run manually to see errors:

```bash
./run_ddns.sh
```

## Security

- API credentials are stored locally in `.env`.
- `.env` is excluded from Git.
- Runtime IP state and logs are excluded from Git.
- Python dependencies are isolated in `.venv`.
- Cloudflare API access is restricted to DNS editing.
