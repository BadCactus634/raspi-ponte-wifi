# Sistema del ponte al 19/11/2026 (riferimento, non da applicare)

Raspberry Pi 3 Model B Rev 1.2, arm64
Raspberry Pi OS Lite 64 bit, Debian 13 (trixie), immagine pi-gen 'reference 2026-10-06', kernel 6.18.50+rpt-rpi-v8
Hostname ponte, fuso Europe/Rome, locale en_GB.UTF-8, tastiera it (pc105)
Utente pi (gruppi: adm dialout sudo audio video plugdev users input render netdev spi i2c gpio), sudo senza password
SSH: PasswordAuthentication yes (cloud-init), accesso con chiave

## Partizioni (SD da 32 GB)
p1 FAT32 512 MB  /boot/firmware (ro)
p2 ext4   8 GB    root (sola lettura sotto overlayroot, montata in /media/root-ro)
p3 ext4   ~21 GB  /srv/dati (rw, noatime, commit=60, nofail, errors=remount-ro): OctoPrint e stato

## fstab (originale, in /media/root-ro/etc/fstab; PARTUUID = id disco dell'SD + numero)
proc            /proc           proc    defaults          0       0
PARTUUID=<ID>-01  /boot/firmware  vfat    defaults,ro          0       2
PARTUUID=<ID>-02  /               ext4    defaults,noatime  0       1
PARTUUID=<ID>-03  /srv/dati  ext4  defaults,noatime,nofail,commit=60,errors=remount-ro  0  2

## Unita' abilitate (systemctl list-unit-files --state=enabled)
apparmor.service
avahi-daemon.service
cloud-config.service
cloud-final.service
cloud-init-local.service
cloud-init-main.service
cloud-init-network.service
console-setup.service
cron.service
e2scrub_reap.service
enjoybuds-vita.service
keyboard-setup.service
NetworkManager-dispatcher.service
NetworkManager-wait-online.service
NetworkManager.service
octoprint.service
ponte-ap.service
ponte-guardia.service
ponte-reti.service
ponte-schermo.service
regenerate_ssh_host_keys.service
rpi-eeprom-update.service
ssh.service
sshd-keygen.service
sshswitch.service
systemd-pstore.service
systemd-timesyncd.service
udisks2.service
wlap-powersave.service
wpa_supplicant.service
avahi-daemon.socket
cloud-init-hotplugd.socket
remote-fs.target
dpkg-db-backup.timer
e2scrub_all.timer
fstrim.timer
logrotate.timer
portale-login.timer

## Timer attivi
portale-login.timer (ogni 2 min), + quelli di serie (logrotate, fstrim, e2scrub_all, dpkg-db-backup)

## Modifiche di sistema oltre a setup.sh
- modprobe: blacklist 8192cu (la chiavetta TL-WN722N v2 usa rtl8xxxu); options rfkill default_state=0
- sysctl: solo quelli di serie (98-rpi.conf)
- nessun crontab, nessuna regola udev propria
- hostapd.service MASCHERATO (lo lancia ponte-ap.service)
