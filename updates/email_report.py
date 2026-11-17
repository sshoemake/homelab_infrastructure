#!/usr/bin/env python3
"""Render the consolidated homelab monitor JSON as HTML and plain text."""

import argparse
import html
import json
from pathlib import Path


def esc(value):
    return html.escape(str(value if value is not None else ""))


def render(report):
    summary = report.get("summary") or {}
    services = report.get("services") or []
    updates = report.get("updates") or []

    monitor_status = str(report.get("status", "UNKNOWN")).upper()
    health = str(report.get("health_status", "UNKNOWN")).upper()
    update_status = str(report.get("update_check_status", "UNKNOWN")).upper()
    discovery_status = str(report.get("discovery_status", "UNKNOWN")).upper()
    health_report_status = str(
        report.get("health_report_status", "UNKNOWN")
    ).upper()

    # Monitoring failures are distinct from update-check failures.
    if (
        monitor_status == "ERROR"
        or discovery_status == "ERROR"
        or health_report_status == "ERROR"
    ):
        overall_label = "ERROR"
        overall_color = "#b42318"
        overall_bg = "#fdecea"
    elif health in ("DOWN", "ERROR"):
        overall_label = "DOWN"
        overall_color = "#b42318"
        overall_bg = "#fdecea"
    elif health == "DEGRADED":
        overall_label = "DEGRADED"
        overall_color = "#946200"
        overall_bg = "#fff4d6"
    elif health == "HEALTHY":
        overall_label = "HEALTHY"
        overall_color = "#16803c"
        overall_bg = "#e8f5ec"
    else:
        overall_label = "STATUS UNKNOWN"
        overall_color = "#946200"
        overall_bg = "#fff4d6"

    available = [
        item for item in updates
        if str(item.get("status", "")).upper() == "UPDATE_AVAILABLE"
    ]
    unknown_updates = [
        item for item in updates
        if str(item.get("status", "")).upper() not in
        ("UPDATE_AVAILABLE", "UP_TO_DATE", "CURRENT_AHEAD")
    ]

    service_rows = []
    text_services = []

    for service in services:
        name = service.get("name", "Unknown")
        status = str(service.get("status", "UNKNOWN")).upper()
        version = service.get("current_version", "")

        if status == "HEALTHY":
            color, symbol = "#16803c", "✓"
        elif status in ("DEGRADED", "DOWN", "ERROR"):
            color, symbol = "#b42318", "!"
        else:
            color, symbol = "#946200", "?"

        version_html = (
            f'<span style="color:#667085;font-size:12px;">'
            f'{esc(version)}</span>'
            if version and version != "unknown" else ""
        )

        service_rows.append(
            f'<tr><td style="padding:10px 0;border-bottom:1px solid #edf0f2;">'
            f'<strong style="font-size:14px;color:#202a35;">{esc(name)}</strong>'
            f'<br>{version_html}</td>'
            f'<td align="right" valign="middle" style="padding:10px 0;'
            f'border-bottom:1px solid #edf0f2;white-space:nowrap;">'
            f'<span style="color:{color};font-weight:700;font-size:13px;">'
            f'{symbol} {esc(status)}</span></td></tr>'
        )
        text_services.append(f"{name}: {status}" +
                             (f" ({version})" if version else ""))

    update_rows = []
    text_updates = []

    for item in available:
        name = item.get("service", "Unknown")
        current = item.get("current_version", "?")
        latest = item.get("latest_version", "?")
        update_rows.append(
            '<tr><td style="padding:9px 0;border-bottom:1px solid #f4e6c5;">'
            f'<strong style="color:#694b00;">{esc(name)}</strong><br>'
            f'<span style="font-size:13px;color:#667085;">'
            f'{esc(current)} &rarr; {esc(latest)}</span></td>'
            '<td align="right" valign="middle" style="white-space:nowrap;">'
            '<span style="background:#fff1cc;color:#805b00;padding:4px 8px;'
            'border-radius:12px;font-size:11px;font-weight:700;">UPDATE</span>'
            '</td></tr>'
        )
        text_updates.append(f"{name}: {current} -> {latest}")

    if available:
        updates_html = (
            '<h3 style="margin:22px 0 8px;font-size:16px;color:#202a35;">'
            'Updates available</h3>'
            '<table role="presentation" width="100%" cellspacing="0" '
            'cellpadding="0">' + "".join(update_rows) + '</table>'
        )
    elif update_status == "OK":
        updates_html = (
            '<p style="margin:18px 0 0;color:#16803c;font-size:13px;">'
            '✓ All checked images are up to date.</p>'
        )
    else:
        updates_html = (
            '<p style="margin:18px 0 0;color:#946200;font-size:13px;">'
            'Update status could not be fully verified.</p>'
        )

    if unknown_updates:
        updates_html += (
            '<p style="font-size:12px;color:#946200;">'
            'Some update checks returned an unknown status.</p>'
        )

    if report.get("update_error"):
        updates_html += (
            f'<p style="font-size:12px;color:#b42318;">'
            f'Update check error: {esc(report["update_error"])}</p>'
        )

    errors = report.get("errors") or []
    error_html = ""
    if errors:
        error_html = (
            '<h3 style="font-size:15px;color:#b42318;">Monitoring errors</h3>'
            '<ul style="padding-left:20px;color:#b42318;font-size:13px;">'
            + "".join(f"<li>{esc(error)}</li>" for error in errors)
            + "</ul>"
        )

    host = report.get("host", "unknown")
    timestamp = report.get("timestamp", "")
    healthy = summary.get("healthy", 0)
    total_services = summary.get("services_total", len(services))
    running = summary.get("containers_running", 0)
    total_containers = summary.get("containers_total", 0)
    rollback = summary.get("rollback_containers", 0)

    html_report = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light">
<title>Homelab Daily Status</title>
</head>
<body style="margin:0;padding:0;background:#f3f5f7;
font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Arial,sans-serif;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"
style="background:#f3f5f7;padding:18px 8px;">
<tr><td align="center">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"
style="max-width:560px;background:#ffffff;border-radius:12px;
overflow:hidden;">
<tr><td style="background:#172b4d;padding:22px 20px;color:#ffffff;">
<div style="font-size:20px;font-weight:700;">Homelab Infrastructure</div>
<div style="font-size:13px;color:#d7e1ef;margin-top:4px;">
Daily Status Report &nbsp;·&nbsp; {esc(host)}
</div>
</td></tr>
<tr><td style="padding:20px;">
<div style="display:inline-block;background:{overall_bg};
color:{overall_color};padding:7px 12px;border-radius:16px;
font-size:12px;font-weight:700;letter-spacing:.3px;">
{esc(overall_label)}
</div>
<div style="font-size:12px;color:#667085;margin-top:9px;">
{esc(timestamp)}
</div>

<table role="presentation" width="100%" cellspacing="0" cellpadding="0"
style="margin-top:18px;">
<tr>
<td width="33%" style="padding:10px 5px;background:#f7f9fb;
border-radius:8px;text-align:center;">
<div style="font-size:23px;font-weight:700;color:#16803c;">
{healthy}/{total_services}</div>
<div style="font-size:11px;color:#667085;">Healthy services</div>
</td>
<td width="5"></td>
<td width="33%" style="padding:10px 5px;background:#f7f9fb;
border-radius:8px;text-align:center;">
<div style="font-size:23px;font-weight:700;color:#202a35;">
{running}/{total_containers}</div>
<div style="font-size:11px;color:#667085;">Running containers</div>
</td>
<td width="5"></td>
<td width="33%" style="padding:10px 5px;background:#fff8e8;
border-radius:8px;text-align:center;">
<div style="font-size:23px;font-weight:700;color:#946200;">
{len(available)}</div>
<div style="font-size:11px;color:#667085;">Updates available</div>
</td>
</tr></table>

<h3 style="margin:24px 0 5px;font-size:16px;color:#202a35;">
Service health</h3>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0">
{''.join(service_rows)}
</table>
{updates_html}
{error_html}
<p style="font-size:12px;color:#667085;margin:22px 0 0;">
Containers: {running} running of {total_containers}.
{rollback} rollback container(s) excluded from active service health.
</p>
</td></tr>
<tr><td style="background:#f7f9fb;padding:14px 20px;
font-size:11px;color:#667085;line-height:1.5;">
Automated daily report from {esc(host)}.<br>
Read-only monitoring: no updates or deployments were performed.
</td></tr>
</table>
</td></tr></table>
</body></html>"""

    text_lines = [
        "HOMELAB INFRASTRUCTURE — DAILY STATUS",
        f"Host: {host}",
        f"Generated: {timestamp}",
        f"Overall: {overall_label}",
        "",
        f"Services healthy: {healthy}/{total_services}",
        f"Containers running: {running}/{total_containers}",
        f"Updates available: {len(available)}",
        "",
        "SERVICE HEALTH",
        *text_services,
        "",
        "UPDATES",
        *(text_updates or (
            ["All checked images are up to date."]
            if update_status == "OK"
            else ["Update status could not be fully verified."]
        )),
    ]

    if rollback:
        text_lines += ["", f"Rollback containers: {rollback}"]
    if errors:
        text_lines += ["", "MONITORING ERRORS", *[str(e) for e in errors]]
    if report.get("update_error"):
        text_lines += ["", f"Update check error: {report['update_error']}"]

    text_lines += [
        "",
        "Read-only monitoring: no updates or deployments were performed."
    ]

    return html_report, "\n".join(text_lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--html-out", required=True, type=Path)
    parser.add_argument("--text-out", required=True, type=Path)
    args = parser.parse_args()

    with args.input.open(encoding="utf-8") as handle:
        report = json.load(handle)

    html_report, text_report = render(report)

    args.html_out.write_text(html_report, encoding="utf-8")
    args.text_out.write_text(text_report, encoding="utf-8")


if __name__ == "__main__":
    main()
