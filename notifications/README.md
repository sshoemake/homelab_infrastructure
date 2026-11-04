

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

