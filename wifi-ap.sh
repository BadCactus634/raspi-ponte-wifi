#!/bin/bash
# Schede WiFi del ponte: chi fa il client della rete WiFi e, con una chiavetta USB, l'access point.
# Lo lanciano setup.sh e strumenti/installa-a-caldo.sh.
# Uso: sudo bash wifi-ap.sh <ponte.conf> [--subito]
#
# Senza WIFI_USB_MAC: wlan0 (il chip interno) e' il client, nessun AP. Come prima.
# Con WIFI_USB_MAC: la chiavetta si chiama wlwan e fa il client col MAC del chip interno (o
# MAC_CLONATO), cosi' il portale riconosce il Pi senza un login nuovo; il chip interno si chiama
# wlap e fa l'AP AP_SSID su AP_IP, con NAT e DHCP come lo switch. Due radio separate: il driver
# della chiavetta (rtl8xxxu per le RTL8188EUS) non sa fare l'AP, il chip interno si'.
# I nomi li danno due file .link per MAC permanente, quindi non dipendono dall'ordine di avvio.
# Dal WiFi nuovo si raggiunge lo switch ma non si aprono connessioni verso la VPN, come dallo switch.
#
# --subito: su un ponte acceso con la SD in sola lettura. Rinomina le schede (ip link), si ricollega e solo se torna online scrive gli stessi file anche sotto /media/root-ro.
# Se non torna online riavvia: la SD non e' stata toccata e il Pi riparte come prima.
# Va lanciato con systemd-run, perche' la connessione SSH cade mentre il WiFi si ricollega.
set -euo pipefail
CONF=${1:?manca ponte.conf}
SUBITO=0; [ "${2:-}" = --subito ] && SUBITO=1
sed -i 's/\r$//' "$CONF"
. "$CONF"
WIFI_USB_MAC=${WIFI_USB_MAC,,}
SOTTO=/media/root-ro
NMC=/etc/NetworkManager/system-connections
LINK_WAN=/etc/systemd/network/10-ponte-wan.link
LINK_AP=/etc/systemd/network/10-ponte-ap.link

# MAC permanente di una scheda (ip lo mostra come permaddr quando NetworkManager ne clona un altro)
mac_vero() {
  local p
  p=$(ip -o link show "$1" | sed -n 's/.*permaddr \([0-9a-f:]*\).*/\1/p')
  echo "${p:-$(cat /sys/class/net/$1/address)}"
}
driver() { basename "$(readlink /sys/class/net/$1/device/driver)"; }
scheda_con_mac() {
  local n
  for n in /sys/class/net/*; do
    [ -e $n/phy80211 ] && [ "$(mac_vero ${n##*/})" = "$1" ] && { echo ${n##*/}; return 0; }
  done
  return 1
}

interno=""
for n in /sys/class/net/*; do
  [ -e $n/phy80211 ] && [ "$(driver ${n##*/})" = brcmfmac ] && { interno=${n##*/}; break; }
done
[ -n "$interno" ] || { echo "chip WiFi interno (brcmfmac) non trovato"; exit 1; }
MAC_INTERNO=$(mac_vero $interno)

if [ -n "$WIFI_USB_MAC" ]; then
  usb=$(scheda_con_mac "$WIFI_USB_MAC") || { echo "nessuna scheda WiFi col MAC $WIFI_USB_MAC"; exit 1; }
  [ ${#AP_PSK} -ge 8 ] || { echo "AP_PSK deve avere almeno 8 caratteri"; exit 1; }
  WAN=wlwan; AP=wlap; WAN_DRIVER=$(driver $usb)
  printf '[Match]\nPermanentMACAddress=%s\n[Link]\nName=wlwan\n' "$WIFI_USB_MAC" > $LINK_WAN
  printf '[Match]\nPermanentMACAddress=%s\n[Link]\nName=wlap\n' "$MAC_INTERNO" > $LINK_AP
else
  WAN=wlan0; AP=""; WAN_DRIVER=brcmfmac
  rm -f $LINK_WAN $LINK_AP
fi
install -d -m 755 /etc/ponte
printf 'WAN=%q\nAP=%q\nWAN_DRIVER=%q\n' "$WAN" "$AP" "$WAN_DRIVER" > /etc/ponte/rete.conf
chmod 644 /etc/ponte/rete.conf

cat > /etc/NetworkManager/dispatcher.d/90-portale-login <<'EOF'
#!/bin/sh
WAN=wlan0
[ -f /etc/ponte/rete.conf ] && . /etc/ponte/rete.conf
[ "$1" = "$WAN" ] && [ "$2" = up ] && systemctl start --no-block portale-login.service
exit 0
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/90-portale-login

# Le tabelle nm-shared-* NetworkManager le ricrea a ogni attivazione: le regole vanno rimesse ogni
# volta. Ogni tabella rifiuta le connessioni nuove verso la propria rete che non nascono da li':
# serve un accept per far entrare il WiFi nello switch. Verso la VPN invece la tabella del WiFi
# lascia passare tutto, e lo si chiude come per lo switch (91-ponte-vpn).
rm -f /etc/NetworkManager/dispatcher.d/92-ponte-ap
if [ -n "$AP" ]; then
  cat > /etc/NetworkManager/dispatcher.d/92-ponte-ap <<'EOF'
#!/bin/sh
case "$2" in up) ;; *) exit 0 ;; esac
case "$1" in eth0|wlap) ;; *) exit 0 ;; esac
C="ip nm-shared-eth0 filter_forward"
R=$(/usr/sbin/nft list chain $C 2>/dev/null) &&
  { echo "$R" | grep -q 'iifname "wlap" oifname "eth0" accept' ||
    /usr/sbin/nft insert rule $C iifname wlap oifname eth0 accept; }
C="ip nm-shared-wlap filter_forward"
R=$(/usr/sbin/nft list chain $C 2>/dev/null) &&
  { echo "$R" | grep -q 'oifname "wg-ponte" ct state new drop' ||
    /usr/sbin/nft insert rule $C iifname wlap oifname wg-ponte ct state new drop; }
exit 0
EOF
  chmod 755 /etc/NetworkManager/dispatcher.d/92-ponte-ap
fi

nmcli con modify ponte-wifi connection.interface-name $WAN \
  802-11-wireless.cloned-mac-address "${MAC_CLONATO:-$([ -n "$AP" ] && echo $MAC_INTERNO || echo permanent)}"
nmcli con delete ponte-ap >/dev/null 2>&1 || true
if [ -n "$AP" ]; then
  # Il BCM43430 rifiuta le chiavi con PMF (WPA-PSK-SHA256, "key setting validation failed"):
  # va spento. L'AP ha un MAC suo: quello del chip lo usa gia' la chiavetta verso il portale.
  nmcli con add type wifi ifname wlap con-name ponte-ap ssid "$AP_SSID" \
    connection.autoconnect yes connection.autoconnect-retries 0 \
    802-11-wireless.mode ap 802-11-wireless.band bg 802-11-wireless.channel "${AP_CANALE:-11}" \
    802-11-wireless.cloned-mac-address "$(printf '%02x' $((0x${MAC_INTERNO:0:2} | 2)))${MAC_INTERNO:2}" \
    802-11-wireless.powersave 2 \
    wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$AP_PSK" wifi-sec.proto rsn \
    wifi-sec.pairwise ccmp wifi-sec.group ccmp wifi-sec.pmf disable \
    ipv4.method shared ipv4.addresses "${AP_IP:-10.42.1.1/24}" ipv6.method disabled >/dev/null
fi
echo "WiFi: client su $WAN${AP:+, access point $AP_SSID su $AP}"

[ $SUBITO = 1 ] || exit 0

online() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://connectivitycheck.gstatic.com/generate_204)" = 204 ]; }
fallito() {
  echo "$*: riavvio, la SD non e' stata toccata"
  journalctl -b --since -5min --no-pager -t NetworkManager -t kernel -t wpa_supplicant | tail -n 60
  systemctl reboot
  exit 1
}
# Da qui il WiFi si spegne: qualunque errore deve finire nel riavvio, non in un ponte isolato
trap 'fallito "errore alla riga $LINENO"' ERR

guardia=0
systemctl is-active -q ponte-guardia && { systemctl stop ponte-guardia; guardia=1; }
udevadm control --reload
nmcli con down ponte-wifi >/dev/null 2>&1 || true
nmcli con down ponte-ap >/dev/null 2>&1 || true
# I nomi nuovi subito, rinominando le schede spente: i file .link valgono dal prossimo avvio.
# Mai unbind/bind della chiavetta mentre e' collegata: il 20/10 ha bloccato il kernel (ping si',
# SSH no), e senza riavvio automatico, perche' il watchdog vede un sistema vivo.
rinomina() {
  [ "$1" = "$2" ] && return 0
  ip link set "$1" down
  ip link set "$1" name "$2"
}
if [ -n "$AP" ]; then
  rinomina $usb wlwan
  rinomina $interno wlap
else
  # Torna a wlan0; se il nome l'ha preso la chiavetta, lei si sposta
  if [ "$interno" != wlan0 ] && [ -e /sys/class/net/wlan0 ]; then rinomina wlan0 wlusb; fi
  rinomina $interno wlan0
fi
ip -br link | grep '^wl'
[ -e /sys/class/net/$WAN ] || fallito "$WAN non comparsa"
# wpa_supplicant tiene le schede col nome di prima ("Could not connect to kernel driver"):
# ripartono lui e NetworkManager, che le ritrovano coi nomi nuovi
systemctl restart wpa_supplicant NetworkManager
nm-online -s -q -t 60 || true
[ -z "$AP" ] || [ -e /sys/class/net/$AP ] || fallito "$AP non comparsa"

timeout 60 nmcli --wait 50 con up ponte-wifi >/dev/null 2>&1 || true
ok=0
for i in $(seq 1 18); do
  online && { ok=1; break; }
  systemctl start portale-login.service || true
  sleep 5
done
[ $ok = 1 ] || fallito "niente internet da $WAN"
if [ -n "$AP" ]; then
  timeout 40 nmcli --wait 30 con up ponte-ap >/dev/null || fallito "access point non partito"
fi
[ $guardia = 1 ] && systemctl start ponte-guardia
echo "online da $WAN${AP:+, access point su}"
trap - ERR

# Ora sulla SD vera, sotto l'overlay. Prima tutto in una cartella in RAM e da li' sulla SD: copiare
# da / a /media/root-ro lo stesso file vuol dire cambiare lo strato sotto l'overlay mentre lo si
# legge, e install ha tolto il file vecchio senza scrivere il nuovo ("replaced while being copied").
APP=/run/wifi-ap-sd
rm -rf $APP
copia() { mkdir -p "$APP$(dirname "$1")"; cp -a "$1" "$APP$1"; }
togli=()
for f in $LINK_WAN $LINK_AP /etc/NetworkManager/dispatcher.d/92-ponte-ap; do
  if [ -e $f ]; then copia $f; else togli+=("$f"); fi
done
copia /etc/NetworkManager/dispatcher.d/90-portale-login
copia /etc/ponte/rete.conf
# Connessioni di NetworkManager: sulla SD va il file di adesso, qualunque nome abbia
for c in ponte-wifi ${AP:+ponte-ap}; do
  uuid=$(nmcli -g connection.uuid con show $c)
  copia "$(grep -l "^uuid=$uuid$" $NMC/*.nmconnection | head -1)"
done

mount -o remount,rw $SOTTO
# Senza drop_caches l'overlay tiene i file sostituiti e il remount in sola lettura da' "busy"
trap 'sync; echo 2 > /proc/sys/vm/drop_caches; mount -o remount,ro $SOTTO || echo "ATTENZIONE: $SOTTO resta in scrittura"' EXIT
for f in "${togli[@]}"; do rm -f "$SOTTO$f"; done
for f in $SOTTO$NMC/*.nmconnection; do
  [ -e "$f" ] && grep -q -E '^id=ponte-(wifi|ap)$' "$f" && rm -f "$f"
done
# File per file: le cartelle della SD tengono i loro permessi (system-connections e' 700)
(cd $APP && find . -type f) | while read -r f; do cp -p "$APP/$f" "$SOTTO/${f#./}"; done
rm -rf $APP
sync
echo "scritto anche sulla SD"
