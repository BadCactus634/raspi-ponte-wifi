#!/bin/bash
# Schede WiFi del ponte: chi fa il client della rete WiFi e, con una chiavetta USB, l'access point.
# Lo lanciano setup.sh e strumenti/installa-a-caldo.sh, con ponte-ap accanto.
# Uso: sudo bash wifi-ap.sh <ponte.conf> [--subito]
#
# Senza WIFI_USB_MAC: wlan0 (il chip interno) e' il client, nessun AP. Come prima.
# Con WIFI_USB_MAC: la chiavetta si chiama wlwan e fa il client col MAC del chip interno (o
# MAC_CLONATO), cosi' il portale riconosce il Pi senza un login nuovo; il chip interno si chiama
# wlap e fa l'AP AP_SSID su AP_IP con hostapd (ponte-ap.service, vedi ponte-ap per il perche' non
# NetworkManager). Due radio separate: il driver della chiavetta (rtl8xxxu per le RTL8188EUS) non
# sa fare l'AP, il chip interno si'. I nomi li danno due file .link per MAC permanente, quindi non
# dipendono dall'ordine di avvio. Dal WiFi si raggiunge lo switch ma non la VPN, come dallo switch.
#
# --subito: su un ponte acceso con la SD in sola lettura. Rinomina le schede (ip link), si
# ricollega e solo se torna online scrive gli stessi file anche sotto /media/root-ro.
# Se non torna online riavvia: la SD non e' stata toccata e il Pi riparte come prima.
# Va lanciato con systemd-run (o da un PC sullo switch), perche' la SSH dal WiFi cade.
set -euo pipefail
CONF=${1:?manca ponte.conf}
SUBITO=0; [ "${2:-}" = --subito ] && SUBITO=1
QUI="$(cd "$(dirname "$0")" && pwd)"
sed -i 's/\r$//' "$CONF" "$QUI/ponte-ap"
. "$CONF"
WIFI_USB_MAC=${WIFI_USB_MAC,,}
SOTTO=/media/root-ro
NMC=/etc/NetworkManager/system-connections
LINK_WAN=/etc/systemd/network/10-ponte-wan.link
LINK_AP=/etc/systemd/network/10-ponte-ap.link
NM_AP=/etc/NetworkManager/conf.d/90-ponte-ap.conf
UNIT=/etc/systemd/system/ponte-ap.service
VUOLE=/etc/systemd/system/multi-user.target.wants/ponte-ap.service
# I file dell'AP: sulla SD si copiano se c'e' l'AP, si tolgono se non c'e'
FILE_AP=($LINK_AP $NM_AP $UNIT $VUOLE /etc/ponte/hostapd.conf /usr/local/sbin/ponte-ap
  /etc/NetworkManager/dispatcher.d/92-ponte-ap)

# MAC permanente di una scheda (ip lo mostra come permaddr quando gliene e' stato dato un altro)
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
# L'AP ha un MAC suo, quello del chip col bit "amministrato localmente": il MAC del chip lo usa
# gia' la chiavetta verso il portale
AP_MAC="$(printf '%02x' $((0x${MAC_INTERNO:0:2} | 2)))${MAC_INTERNO:2}"
AP_IP=${AP_IP:-10.42.1.1/24}

if [ -n "$WIFI_USB_MAC" ]; then
  usb=$(scheda_con_mac "$WIFI_USB_MAC") || { echo "nessuna scheda WiFi col MAC $WIFI_USB_MAC"; exit 1; }
  [ ${#AP_PSK} -ge 8 ] || { echo "AP_PSK deve avere almeno 8 caratteri"; exit 1; }
  [ -x /usr/sbin/hostapd ] || { echo "manca hostapd: apt install hostapd (con la SD in sola lettura, prima togli l'overlay)"; exit 1; }
  WAN=wlwan; AP=wlap; WAN_DRIVER=$(driver $usb)
  printf '[Match]\nPermanentMACAddress=%s\n[Link]\nName=wlwan\n' "$WIFI_USB_MAC" > $LINK_WAN
  printf '[Match]\nPermanentMACAddress=%s\n[Link]\nName=wlap\nMACAddress=%s\n' "$MAC_INTERNO" "$AP_MAC" > $LINK_AP
else
  WAN=wlan0; AP=""; WAN_DRIVER=brcmfmac
  rm -f $LINK_WAN $LINK_AP
fi
install -d -m 755 /etc/ponte
printf 'WAN=%q\nAP=%q\nWAN_DRIVER=%q\nAP_IP=%q\nAP_MAC=%q\n' "$WAN" "$AP" "$WAN_DRIVER" "$AP_IP" "$AP_MAC" \
  > /etc/ponte/rete.conf
chmod 644 /etc/ponte/rete.conf

cat > /etc/NetworkManager/dispatcher.d/90-portale-login <<'EOF'
#!/bin/sh
WAN=wlan0
[ -f /etc/ponte/rete.conf ] && . /etc/ponte/rete.conf
[ "$1" = "$WAN" ] && [ "$2" = up ] && systemctl start --no-block portale-login.service
exit 0
EOF
chmod 755 /etc/NetworkManager/dispatcher.d/90-portale-login

nmcli con modify ponte-wifi connection.interface-name $WAN \
  802-11-wireless.cloned-mac-address "${MAC_CLONATO:-$([ -n "$AP" ] && echo $MAC_INTERNO || echo permanent)}"
# Fino al 20/10 l'AP era un profilo di NetworkManager
nmcli con delete ponte-ap >/dev/null 2>&1 || true

if [ -n "$AP" ]; then
  # NetworkManager lascia stare wlap: lo usa hostapd
  printf '[keyfile]\nunmanaged-devices=interface-name:wlap\n' > $NM_AP
  umask 077
  cat > /etc/ponte/hostapd.conf <<EOF
interface=wlap
driver=nl80211
ssid=$AP_SSID
country_code=$PAESE_WIFI
hw_mode=g
channel=${AP_CANALE:-11}
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
ieee80211w=0
wpa_passphrase=$AP_PSK
EOF
  umask 022
  install -m 755 "$QUI/ponte-ap" /usr/local/sbin/ponte-ap
  cat > $UNIT <<'EOF'
[Unit]
Description=Access point WiFi del ponte (hostapd sul chip interno)
After=NetworkManager.service
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/local/sbin/ponte-ap avvia
ExecStopPost=/usr/local/sbin/ponte-ap ferma
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  # Il NetworkManager dello switch rifiuta le connessioni nuove verso eth0 che non nascono da li':
  # al WiFi serve un accept, da rimettere ogni volta che NM ricrea la tabella.
  cat > /etc/NetworkManager/dispatcher.d/92-ponte-ap <<'EOF'
#!/bin/sh
[ "$1" = eth0 ] && [ "$2" = up ] || exit 0
C="ip nm-shared-eth0 filter_forward"
R=$(/usr/sbin/nft list chain $C 2>/dev/null) || exit 0
echo "$R" | grep -q 'iifname "wlap" oifname "eth0" accept' ||
  /usr/sbin/nft insert rule $C iifname wlap oifname eth0 accept
exit 0
EOF
  chmod 755 /etc/NetworkManager/dispatcher.d/92-ponte-ap
  systemctl daemon-reload
  systemctl enable ponte-ap.service 2>/dev/null
else
  systemctl disable --now ponte-ap.service 2>/dev/null || true
  rm -f $NM_AP $UNIT /etc/ponte/hostapd.conf /usr/local/sbin/ponte-ap \
    /etc/NetworkManager/dispatcher.d/92-ponte-ap
  systemctl daemon-reload
fi
echo "WiFi: client su $WAN${AP:+, access point $AP_SSID su $AP}"

[ $SUBITO = 1 ] || exit 0

online() { [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://connectivitycheck.gstatic.com/generate_204)" = 204 ]; }
fallito() {
  echo "$*: riavvio, la SD non e' stata toccata"
  journalctl -b --since -5min --no-pager -t NetworkManager -t kernel -t wpa_supplicant -t hostapd | tail -n 60
  systemctl reboot
  exit 1
}
# Da qui il WiFi si spegne: qualunque errore deve finire nel riavvio, non in un ponte isolato
trap 'fallito "errore alla riga $LINENO"' ERR

guardia=0
systemctl is-active -q ponte-guardia && { systemctl stop ponte-guardia; guardia=1; }
systemctl stop ponte-ap.service 2>/dev/null || true
udevadm control --reload
nmcli con down ponte-wifi >/dev/null 2>&1 || true
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
# ripartono lui e NetworkManager, che le ritrovano coi nomi nuovi (e rileggono conf.d)
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
  systemctl restart ponte-ap.service
  ok=0
  for i in $(seq 1 20); do
    iw dev $AP info 2>/dev/null | grep -q 'type AP' && { ok=1; break; }
    sleep 1
  done
  [ $ok = 1 ] || fallito "access point non partito"
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
for f in $LINK_WAN "${FILE_AP[@]}"; do
  if [ -e $f ] || [ -L $f ]; then copia $f; else togli+=("$f"); fi
done
copia /etc/NetworkManager/dispatcher.d/90-portale-login
copia /etc/ponte/rete.conf
# Connessione di NetworkManager: sulla SD va il file di adesso, qualunque nome abbia
uuid=$(nmcli -g connection.uuid con show ponte-wifi)
copia "$(grep -l "^uuid=$uuid$" $NMC/*.nmconnection | head -1)"

mount -o remount,rw $SOTTO
# Senza drop_caches l'overlay tiene i file sostituiti e il remount in sola lettura da' "busy"
trap 'sync; echo 2 > /proc/sys/vm/drop_caches; mount -o remount,ro $SOTTO || echo "ATTENZIONE: $SOTTO resta in scrittura"' EXIT
for f in "${togli[@]}"; do rm -f "$SOTTO$f"; done
for f in $SOTTO$NMC/*.nmconnection; do
  [ -e "$f" ] && grep -q -E '^id=ponte-(wifi|ap)$' "$f" && rm -f "$f"
done
# File per file: le cartelle della SD tengono i loro permessi (system-connections e' 700)
(cd $APP && find . -type f -o -type l) | while read -r f; do
  mkdir -p "$(dirname "$SOTTO/${f#./}")"
  cp -P -p "$APP/$f" "$SOTTO/${f#./}"
done
rm -rf $APP
sync
echo "scritto anche sulla SD"
