# Scheduled Tasks - Odroid M2

Cron jobs are maintained in this repository.

## View current configuration

crontab -l

## Install repository configuration

crontab cron/odroidm2.crontab

## Edit scheduled tasks

Edit cron/odroidm2.crontab in GitHub repository.

After pulling changes:

crontab cron/odroidm2.crontab

## Verify installation

crontab -l

## View cron logs

sudo journalctl -u cron