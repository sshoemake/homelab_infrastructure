
## Log Management

Cloudflare DDNS logs are managed through logrotate.

Configuration is maintained in:

`cloudflare/logrotate/cloudflare-ddns`

Installed on the Odroid at:

`/etc/logrotate.d/cloudflare-ddns`

### Rotation Policy

- Rotate weekly.
- Retain four previous logs.
- Compress older logs.
- Rotate early if the log exceeds 1 MB when logrotate runs.
- Create replacement logs with restricted permissions.
- Preserve the active log file without restarting cron jobs.

### Install Configuration

```bash
sudo cp logrotate/cloudflare-ddns /etc/logrotate.d/cloudflare-ddns

sudo chmod 644 /etc/logrotate.d/cloudflare-ddns
```

### Test Configuration

```bash
sudo logrotate -d /etc/logrotate.d/cloudflare-ddns
```

### View Logs

```bash
tail -f cloudflare_ddns.log
```

List rotated logs:

```bash
ls -lh cloudflare_ddns.log*
```

View a compressed log:

```bash
zcat cloudflare_ddns.log.2.gz
```
