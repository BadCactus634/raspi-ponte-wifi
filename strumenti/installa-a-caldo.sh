#!/bin/bash
# Aggiorna schermo, guardia, portale, VPN e schede WiFi su un ponte gia' in funzione con la SD in
# sola lettura, senza riavvio e senza togliere l'overlay: scrive sia nel sistema vivo sia sotto
# /media/root-ro.
# Uso (sul Pi): metti in una cartella questo script, ponte.conf, ponte-schermo, ponte-guardia,
# portale-login, ponte-reti, wifi-ap.sh, ponte-ap e setup.sh, poi
#   sudo systemd-run --unit installa-a-caldo bash installa-a-caldo.sh <cartella>
# e segui con journalctl -fu installa-a-caldo: l'ultimo passo (wifi-ap.sh --subito) ricollega il
# WiFi e la SSH cade. Se il ponte non torna online, wifi-ap.sh riavvia prima di toccare la SD.
# Alla fine, anche se qualcosa va storto, cancella la copia di ponte.conf (contiene le chiavi).
# La VPN nuova si importa con un nome provvisorio: se l'import fallisce quella vecchia resta com'e'.
set -euo pipefail
cd "${1:-$(dirname "$0")}"
DIR=$PWD
SOTTO=/media/root-ro
CONN=/etc/NetworkManager/system-connections
montato=0
schermo_fermo=0
# Senza drop_caches l'overlay tiene i file sostituiti sotto di lui e il remount da' "busy"
sola_lettura() { sync; echo 2 > /proc/sys/vm/drop_caches; mount -o remount,ro $SOTTO; }
finale() {
  rm -f "$DIR/ponte.conf"
  [ $schermo_fermo = 1 ] && { systemctl start ponte-schermo ponte-guardia; systemctl start ponte-reti 2>/dev/null || true; }
  [ $montato = 1 ] && { sola_lettura || echo "ATTENZIONE: $SOTTO resta in scrittura"; }
  return 0
}
trap finale EXIT

sed -i 's/\r$//' ponte.conf ponte-schermo ponte-guardia ponte-reti portale-login wifi-ap.sh ponte-ap setup.sh
. ./ponte.conf
for v in VPN_CHIAVE_PRIVATA VPN_INDIRIZZO VPN_SERVER_CHIAVE VPN_SERVER VPN_RETI; do
  [ -n "${!v:-}" ] || { echo "$v vuota in ponte.conf: questo script e' per un ponte con la VPN"; exit 1; }
done

# Le stesse righe di setup.sh, prese da li' per non avere due versioni.
dispatcher=$(sed -n "/cat > \/etc\/NetworkManager\/dispatcher.d\/91-ponte-vpn <<'EOF'/,/^EOF/p" setup.sh | sed '1d;$d')
[ -n "$dispatcher" ] || { echo "dispatcher non trovato in setup.sh"; exit 1; }

# Il ponte-guardia sul Pi puo' avere modifiche locali che il repo non ha (per esempio il controllo
# di OctoPrint prima del riavvio): non si sovrascrive alla cieca.
if grep -q octoprint /usr/local/sbin/ponte-guardia && ! grep -q octoprint ponte-guardia; then
  echo "il ponte-guardia sul Pi ha il controllo OctoPrint che questo non ha: riportalo qui"
  echo "(insieme al cambio conn_attiva) e rilancia"
  exit 1
fi
# L'unita' di ponte-reti e' quella di setup.sh, presa da li' per non avere due versioni.
unita_reti=$(sed -n "/cat > \/etc\/systemd\/system\/ponte-reti.service <<'EOF'/,/^EOF/p" setup.sh | sed '1d;$d')
[ -n "$unita_reti" ] || { echo "unita' ponte-reti non trovata in setup.sh"; exit 1; }

mount -o remount,rw $SOTTO
montato=1

# Fermi mentre se ne sostituisce il file sotto l'overlay: un file cancellato ancora aperto
# lascia /media/root-ro "busy" e non torna in sola lettura
systemctl stop ponte-schermo ponte-guardia ponte-reti 2>/dev/null || true
schermo_fermo=1
for r in "" $SOTTO; do
  install -m 755 ponte-schermo $r/usr/local/sbin/ponte-schermo
  install -m 755 ponte-guardia $r/usr/local/sbin/ponte-guardia
  install -m 755 portale-login $r/usr/local/sbin/portale-login
  install -m 755 ponte-reti $r/usr/local/sbin/ponte-reti
  printf 'SEGNALE_MIN=%q
SEGNALE_DOPO=%q
SEGNALE_MARGINE=%q
'     "${SEGNALE_MIN:-60}" "${SEGNALE_DOPO:-20}" "${SEGNALE_MARGINE:-15}" > $r/etc/ponte/reti.conf
  printf '%s\n' "$unita_reti" > $r/etc/systemd/system/ponte-reti.service
  mkdir -p $r/etc/systemd/system/multi-user.target.wants
  ln -sf /etc/systemd/system/ponte-reti.service $r/etc/systemd/system/multi-user.target.wants/ponte-reti.service
  printf 'NON_CONTARE_MAC=%q\nSCHERMO_ACCESO_PER=%q\nSCHERMO_SPENTO_DALLE=%q\nSCHERMO_SPENTO_ALLE=%q\nVPN_CONTROLLI=%q\n' \
    "${NON_CONTARE_MAC:-}" "${SCHERMO_ACCESO_PER:-0}" "${SCHERMO_SPENTO_DALLE:-}" "${SCHERMO_SPENTO_ALLE:-}" \
    "${VPN_CONTROLLI:-}" > $r/etc/ponte/schermo.conf
  printf '%s\n' "$dispatcher" > $r/etc/NetworkManager/dispatcher.d/91-ponte-vpn
  chmod 755 $r/etc/NetworkManager/dispatcher.d/91-ponte-vpn
done

# VPN: prima si importa la nuova come wg-nuova; la vecchia wg-ponte si tocca solo se l'import riesce.
t=$(mktemp -d)
{
  printf '[Interface]\nPrivateKey = %s\nAddress = %s\n\n' "$VPN_CHIAVE_PRIVATA" "$VPN_INDIRIZZO"
  printf '[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s\nPersistentKeepalive = 25\n' \
    "$VPN_SERVER_CHIAVE" "$VPN_SERVER" "$VPN_RETI"
  if [ -n "${VPN_CHIAVE_CONDIVISA:-}" ]; then printf 'PresharedKey = %s\n' "$VPN_CHIAVE_CONDIVISA"; fi
} > $t/wg-nuova.conf
chmod 600 $t/wg-nuova.conf
nmcli con delete wg-nuova >/dev/null 2>&1 || true
if ! nmcli con import type wireguard file $t/wg-nuova.conf; then
  rm -rf $t
  echo "import della VPN nuova fallito: la VPN di prima e' rimasta com'era"
  exit 1
fi
rm -rf $t
nmcli con down wg-nuova >/dev/null 2>&1 || true   # l'import la accende: due tunnel con la stessa chiave no

nmcli con delete wg-ponte >/dev/null 2>&1 || true
nmcli con modify wg-nuova connection.id wg-ponte connection.interface-name wg-ponte \
  connection.autoconnect yes ipv6.method disabled
nmcli con up wg-ponte

# Sulla SD va il file della connessione nuova, qualunque nome gli abbia dato NetworkManager.
uuid=$(nmcli -g connection.uuid con show wg-ponte)
nuovo=$(grep -l "^uuid=$uuid$" $CONN/*.nmconnection | head -1)
for f in $SOTTO$CONN/*.nmconnection; do
  if [ -e "$f" ] && grep -q -E '^interface-name=wg-(ponte|nuova)$' "$f"; then rm -f "$f"; fi
done
install -m 600 "$nuovo" "$SOTTO$CONN/$(basename "$nuovo")"

# La regola nella tabella di NM la mette il dispatcher a ogni "up"; ora eth0 e' gia' su.
/etc/NetworkManager/dispatcher.d/91-ponte-vpn wg-ponte up

# Per ultimo le schede WiFi: ricollega il WiFi e scrive sulla SD solo se torna online
sola_lettura
montato=0
systemctl daemon-reload
# ponte-reti resta fermo mentre il WiFi si ricollega: non deve cambiare rete a meta'
bash wifi-ap.sh "$DIR/ponte.conf" --subito
systemctl restart ponte-guardia
systemctl start ponte-reti
echo "installato"
