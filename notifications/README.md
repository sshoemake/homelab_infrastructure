# Infrastructure Notifications

Centralized email notification utility for homelab infrastructure.

Notifications are sent through Gmail SMTP using msmtp.

## Components

- `notify.sh`: Shared notification utility.
- `msmtp/config.example`: Example Gmail SMTP configuration.

## SMTP Configuration

sudo apt update
sudo apt install msmtp msmtp-mta ca-certificates

mkdir -p ~/.config/msmtp
chmod 700 ~/.config/msmtp

nano ~/.config/msmtp/config
or
cp ~/homelab_infrastructure/notifications/msmtp/config.example ~/.config/msmtp/config

Replace:
- YOUR_GMAIL_ADDRESS@gmail.com with your Gmail address.
- YOUR_16_CHARACTER_APP_PASSWORD with the App Password Google generated.

chmod 600 ~/.config/msmtp/config

ls -ld ~/.config/msmtp
ls -l ~/.config/msmtp/config

msmtp --version

printf 'To: YOUR_DESTINATION_EMAIL\nSubject: Odroid M2 SMTP Test\n\nGmail SMTP notification test successful.\n' | msmtp -a gmail YOUR_DESTINATION_EMAIL

tail -20 ~/.config/msmtp/msmtp.log

## Usage

Send a success notification:

    ./notifications/notify.sh success \
        "Backup Completed" \
        "Meal_Project backup completed successfully."

Send a failure notification:

    ./notifications/notify.sh failure \
        "Backup Failed" \
        "Meal_Project backup encountered an error."

## Logging

Notification activity is logged to:

    ~/.local/state/homelab/notifications.log

SMTP delivery details are logged separately to:

    ~/.config/msmtp/msmtp.log

## Security

- SMTP credentials remain outside the repository.
- Gmail authentication uses an App Password.
- TLS is enabled for SMTP connections.
- Notification logs are restricted to the owner.