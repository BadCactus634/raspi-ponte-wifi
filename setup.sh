#!/bin/bash
# Trasforma un Raspberry Pi 3 (Raspberry Pi OS Lite Bookworm/Trixie) in un ponte
# WiFi -> Ethernet con NAT: wlan0 si collega alla rete WiFi, eth0 serve DHCP allo switch.
# Con una chiavetta WiFi USB (WIFI_USB_MAC) il client lo fa la chiavetta e il chip interno
# diventa un access point (vedi wifi-ap.sh).
# Uso: sudo ./setup.sh   (con ponte.conf accanto)
set -euo pipefail
QUI="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" -eq 0 ] || { echo "Lancialo con sudo"; exit 1; }
[ -f "$QUI/ponte.conf" ] || { echo "Manca $QUI/ponte.conf: copia ponte.conf.example e compilalo"; exit 1; }
# Se i file sono passati da Windows possono avere i CRLF
sed -i 's/\r$//' "$QUI/ponte.conf" "$QUI/portale-login" "$QUI/ponte-schermo" "$QUI/ponte-guardia" "$QUI/wifi-ap.sh"
. "$QUI/ponte.conf"

echo "== Pacchetti"
# dnsmasq-base serve a NetworkManager per il DHCP/DNS in modalita' "shared", nftables per il NAT.
# Su Raspberry Pi OS Lite ci sono gia' tutti: apt solo se ne manca qualcuno.
if ! dpkg -s dnsmasq-base nftables curl iw kbd >/dev/null 2>&1; then
  apt-get update
  apt-get install -y dnsmasq-base nftables curl iw kbd
fi

echo "== Paese WiFi"
raspi-config nonint do_wifi_country "$PAESE_WIFI"
rfkill unblock wifi || true

echo "== Connessione WiFi"
nmcli con delete ponte-wifi >/dev/null 2>&1 || true
nmcli con add type wifi ifname wlan0 con-name ponte-wifi ssid "$SSID" \
  connection.autoconnect yes connection.autoconnect-priority 100 \
  connection.autoconnect-retries 0 \
  802-11-wireless.powersave 2 \
  802-11-wireless.cloned-mac-address "${MAC_CLONATO:-permanent}" \
  ipv4.method auto ipv6.method disabled
if [ -n "$WIFI_PSK" ]; then
  nmcli con modify ponte-wifi wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$WIFI_PSK"
fi

echo "== LAN verso lo switch (NAT + DHCP)"
nmcli con delete ponte-lan >/dev/null 2>&1 || true
nmcli con add type ethernet ifname eth0 con-name ponte-lan \
  connection.autoconnect yes connection.autoconnect-priority 100 \
  ipv4.method shared ipv4.addresses "$LAN_IP" ipv6.method disabled
# Nessun altro profilo cablato (es. il DHCP di cloud-init/netplan) deve contendersi eth0
nmcli -t -f NAME,TYPE con show | while IFS=: read -r nome tipo; do
  [ "$tipo" = 802-3-ethernet ] && [ "$nome" != ponte-lan ] && nmcli con delete "$nome" || true
done

echo "== Schede WiFi (client, e access point se c'e' la chiavetta)"
# Scrive anche /etc/ponte/rete.conf e il dispatcher 90-portale-login
bash "$QUI/wifi-ap.sh" "$QUI/ponte.conf"

echo "== VPN WireGuard"
nmcli con delete wg-ponte >/dev/null 2>&1 || true
rm -f /etc/NetworkManager/dispatcher.d/91-ponte-vpn
if [ -n "${VPN_CHIAVE_PRIVATA:-}" ]; then
  # NetworkManager ha WireGuard di serie: si importa un file in formato wg-quick, niente wireguard-tools.
  tmp=$(mktemp -d)
  {
    printf '[Interface]\nPrivateKey = %s\nAddress = %s\n\n' "$VPN_CHIAVE_PRIVATA" "$VPN_INDIRIZZO"
    printf '[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s\nPersistentKeepalive = 25\n' \
      "$VPN_SERVER_CHIAVE" "$VPN_SERVER" "$VPN_RETI"
    if [ -n "${VPN_CHIAVE_CONDIVISA:-}" ]; then printf 'PresharedKey = %s\n' "$VPN_CHIAVE_CONDIVISA"; fi
  } > "$tmp/wg-ponte.conf"
  chmod 600 "$tmp/wg-ponte.conf"
  nmcli con import type wireguard file "$tmp/wg-ponte.conf"
  rm -rf "$tmp"
  nmcli con modify wg-ponte connection.autoconnect yes ipv6.method disabled
  # La tabella nm-shared-eth0 di NetworkManager rifiuta le connessioni nuove verso lo switch
  # che non nascono dallo switch; NM la ricrea a ogni attivazione, quindi le regole vanno
  # rimesse ogni volta: dalla VPN si entra nello switch, ma dallo switch non si apre niente
  # verso la VPN (altrimenti chi sta sullo switch entrerebbe nella VPN col NAT del ponte).
  cat > /etc/NetworkManager/dispatcher.d/91-ponte-vpn <<'EOF'
#!/bin/sh
case "$2" in up) ;; *) exit 0 ;; esac
case "$1" in eth0|wg-ponte) ;; *) exit 0 ;; esac
C="ip nm-shared-eth0 filter_forward"
R=$(/usr/sbin/nft list chain $C 2>/dev/null) || exit 0
echo "$R" | grep -q 'iifname "wg-ponte" oifname "eth0" accept' ||
  /usr/sbin/nft insert rule $C iifname wg-ponte oifname eth0 accept
echo "$R" | grep -q 'oifname "wg-ponte" ct state new drop' ||
  /usr/sbin/nft insert rule $C iifname eth0 oifname wg-ponte ct state new drop
exit 0
EOF
  chmod 755 /etc/NetworkManager/dispatcher.d/91-ponte-vpn
fi

echo "== Login automatico sul portale"
install -m 755 "$QUI/portale-login" /usr/local/sbin/portale-login
install -d -m 700 /etc/ponte
umask 077
printf 'PORTALE_USER=%q\nPORTALE_PASS=%q\n' "$PORTALE_USER" "$PORTALE_PASS" > /etc/ponte/portale.conf
umask 022
vpn_controlli=""; [ -n "${VPN_CHIAVE_PRIVATA:-}" ] && vpn_controlli="${VPN_CONTROLLI:-}"
printf 'NON_CONTARE_MAC=%q\nSCHERMO_ACCESO_PER=%q\nSCHERMO_SPENTO_DALLE=%q\nSCHERMO_SPENTO_ALLE=%q\nVPN_CONTROLLI=%q\n' \
  "${NON_CONTARE_MAC:-}" "${SCHERMO_ACCESO_PER:-0}" "${SCHERMO_SPENTO_DALLE:-}" "${SCHERMO_SPENTO_ALLE:-}" \
  "$vpn_controlli" > /etc/ponte/schermo.conf

cat > /etc/systemd/system/portale-login.service <<'EOF'
[Unit]
Description=Login al captive portal della rete WiFi
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/portale-login
EOF

cat > /etc/systemd/system/portale-login.timer <<'EOF'
[Unit]
Description=Controlla ogni 2 minuti che il Pi sia autenticato sul portale

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable portale-login.timer

echo "== Guardia del WiFi"
# Se il chip WiFi si pianta: ricollega, ricarica il driver, al limite riavvia (vedi ponte-guardia)
install -m 755 "$QUI/ponte-guardia" /usr/local/sbin/ponte-guardia
cat > /etc/systemd/system/ponte-guardia.service <<'EOF'
[Unit]
Description=Guardia del WiFi: ricollega, ricarica il driver o riavvia se wlan0 perde la rete
After=NetworkManager.service

[Service]
ExecStart=/usr/local/sbin/ponte-guardia
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ponte-guardia.service

echo "== Schermino 3,5\" (ILI9486 + XPT2046, overlay tft35a)"
BOOT=/boot/firmware
install -m 755 "$QUI/ponte-schermo" /usr/local/sbin/ponte-schermo
if [ -f "$QUI/tft35a.dtbo" ]; then
  install -m 644 "$QUI/tft35a.dtbo" $BOOT/overlays/tft35a.dtbo
  if ! grep -q '^dtoverlay=tft35a' $BOOT/config.txt; then
    printf '\n[all]\n# Schermino 3,5" sui GPIO\ndtparam=spi=on\ndtoverlay=tft35a:rotate=90\n' >> $BOOT/config.txt
  fi
  # Console tty1 sullo schermino (fb1), senza cursore
  if ! grep -q 'fbcon=map' $BOOT/cmdline.txt; then
    sed -i '1 s/$/ fbcon=map:10 vt.global_cursor_default=0/' $BOOT/cmdline.txt
  fi
fi
cat > /etc/systemd/system/ponte-schermo.service <<'EOF'
[Unit]
Description=Pagina di stato del ponte sullo schermino
After=systemd-user-sessions.service
Conflicts=getty@tty1.service

[Service]
ExecStart=/usr/local/sbin/ponte-schermo
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1
TTYReset=yes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl enable ponte-schermo.service

echo "== Resistenza ai blackout"
# Watchdog hardware: se il sistema si pianta, il Pi si riavvia da solo
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/ponte-watchdog.conf <<'EOF'
[Manager]
RuntimeWatchdogSec=15s
RebootWatchdogSec=2min
EOF
# Log solo in RAM: meno scritture sulla SD, meno rischi se salta la corrente
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ponte.conf <<'EOF'
[Journal]
Storage=volatile
RuntimeMaxUse=20M
EOF

echo "== Servizi inutili"
systemctl disable --now bluetooth.service hciuart.service 2>/dev/null || true
systemctl disable apt-daily.timer apt-daily-upgrade.timer man-db.timer 2>/dev/null || true

echo
echo "Fatto. La configurazione diventa attiva al prossimo avvio."
echo "NON riavviare collegato alla rete di casa: il Pi farebbe da server DHCP sulla tua LAN."
echo "Spegni con 'sudo poweroff', portalo sul posto, collega eth0 allo switch e accendi."
