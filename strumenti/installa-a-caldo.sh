#!/bin/bash
# Aggiorna schermo e VPN su un ponte gia' in funzione con la SD in sola lettura, senza riavvio e
# senza togliere l'overlay: scrive sia nel sistema vivo sia sotto /media/root-ro.
# Uso (sul Pi): metti in una cartella questo script, ponte.conf, ponte-schermo e setup.sh, poi
#   sudo bash installa-a-caldo.sh <cartella>
# Alla fine cancella la copia di ponte.conf dalla cartella (contiene le chiavi).
set -euo pipefail
cd "${1:-$(dirname "$0")}"
sed -i 's/\r$//' ponte.conf ponte-schermo setup.sh
. ./ponte.conf
[ -n "${VPN_CHIAVE_PRIVATA:-}" ] || { echo "VPN_CHIAVE_PRIVATA vuota: questo script e' per un ponte con la VPN"; exit 1; }
SOTTO=/media/root-ro

# Le stesse righe di setup.sh, prese da li' per non avere due versioni.
dispatcher=$(sed -n "/cat > \/etc\/NetworkManager\/dispatcher.d\/91-ponte-vpn <<'EOF'/,/^EOF/p" setup.sh | sed '1d;$d')
[ -n "$dispatcher" ] || { echo "dispatcher non trovato in setup.sh"; exit 1; }

mount -o remount,rw $SOTTO
trap 'mount -o remount,ro $SOTTO || echo "ATTENZIONE: $SOTTO resta in scrittura"' EXIT

systemctl stop ponte-schermo
for r in "" $SOTTO; do
  install -m 755 ponte-schermo $r/usr/local/sbin/ponte-schermo
  printf 'NON_CONTARE_MAC=%q\nSCHERMO_ACCESO_PER=%q\nSCHERMO_SPENTO_DALLE=%q\nSCHERMO_SPENTO_ALLE=%q\nVPN_CONTROLLI=%q\n' \
    "${NON_CONTARE_MAC:-}" "${SCHERMO_ACCESO_PER:-0}" "${SCHERMO_SPENTO_DALLE:-}" "${SCHERMO_SPENTO_ALLE:-}" \
    "${VPN_CONTROLLI:-}" > $r/etc/ponte/schermo.conf
  printf '%s\n' "$dispatcher" > $r/etc/NetworkManager/dispatcher.d/91-ponte-vpn
  chmod 755 $r/etc/NetworkManager/dispatcher.d/91-ponte-vpn
done

nmcli con delete wg-ponte >/dev/null 2>&1 || true
rm -f $SOTTO/etc/NetworkManager/system-connections/wg-ponte.nmconnection
t=$(mktemp -d)
{
  printf '[Interface]\nPrivateKey = %s\nAddress = %s\n\n' "$VPN_CHIAVE_PRIVATA" "$VPN_INDIRIZZO"
  printf '[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s\nPersistentKeepalive = 25\n' \
    "$VPN_SERVER_CHIAVE" "$VPN_SERVER" "$VPN_RETI"
  if [ -n "${VPN_CHIAVE_CONDIVISA:-}" ]; then printf 'PresharedKey = %s\n' "$VPN_CHIAVE_CONDIVISA"; fi
} > $t/wg-ponte.conf
chmod 600 $t/wg-ponte.conf
nmcli con import type wireguard file $t/wg-ponte.conf
rm -rf $t
nmcli con modify wg-ponte connection.autoconnect yes ipv6.method disabled
nmcli con up wg-ponte
install -m 600 /etc/NetworkManager/system-connections/wg-ponte.nmconnection \
  $SOTTO/etc/NetworkManager/system-connections/wg-ponte.nmconnection

# La regola nella tabella di NM la mette il dispatcher a ogni "up"; ora eth0 e' gia' su.
/etc/NetworkManager/dispatcher.d/91-ponte-vpn wg-ponte up
systemctl start ponte-schermo
rm -f ponte.conf
echo "installato"
