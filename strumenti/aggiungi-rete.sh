#!/bin/bash
# Aggiunge una rete WiFi di riserva al ponte, anche con la SD in sola lettura (overlayroot).
# Uso (sul Pi, da root):
#   sudo bash aggiungi-rete.sh <SSID> <PSK> [priorita]     priorita' 0-99, default 50
#   sudo bash aggiungi-rete.sh <SSID> -  [priorita]        la password si digita (non resta nella history)
#   sudo bash aggiungi-rete.sh <SSID> "" [priorita]        rete aperta
# Variabili: NASCOSTA=1 (SSID nascosto), ATTIVA=1 (collegati subito anche se sei gia' online).
#
# Crea il profilo NetworkManager "ponte-wifi-<ssid>" (lo stesso SSID lo sostituisce), con
# autoconnect, senza limite di tentativi e sulla scheda client del ponte (/etc/ponte/rete.conf).
# La priorita' resta sotto quella della principale (100): all'accensione vince la principale,
# se e' in aria; ponte-reti passa da una rete nota all'altra quando una resta senza internet.
# Sulle reti di riserva non parte il login sul captive portal.
#
# Overlayroot: nmcli scrive in RAM (si perde al riavvio). Qui il file viene copiato anche sulla
# SD vera (/media/root-ro) con un remount in scrittura, sync e di nuovo in sola lettura.
# La password non viene stampata.
set -eu
[ "$(id -u)" -eq 0 ] || { echo "Lancialo con sudo"; exit 1; }
[ $# -ge 2 ] && [ $# -le 3 ] || { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }
SSID=$1
PSK=$2
PRIO=${3:-50}
[ -n "$SSID" ] || { echo "SSID vuoto"; exit 1; }
case "$PRIO" in ''|*[!0-9]*) echo "priorita' non numerica: $PRIO"; exit 1 ;; esac
[ "$PRIO" -lt 100 ] || { echo "la priorita' deve essere sotto 100 (la principale)"; exit 1; }
if [ "$PSK" = "-" ]; then
  read -rsp "Password di '$SSID': " PSK; echo
fi
if [ -n "$PSK" ] && { [ ${#PSK} -lt 8 ] || [ ${#PSK} -gt 63 ]; }; then
  echo "la password WPA deve avere da 8 a 63 caratteri"; exit 1
fi

WAN=wlan0
[ -f /etc/ponte/rete.conf ] && . /etc/ponte/rete.conf
SOTTO=/media/root-ro
NMC=/etc/NetworkManager/system-connections
# Nome del profilo: ponte-wifi- + SSID in minuscolo con tutto cio' che non e' lettera o cifra -> '-'
slug=$(printf '%s' "$SSID" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\{1,\}/-/g; s/^-//; s/-$//' | cut -c1-40)
[ -n "$slug" ] || slug=rete
NOME=ponte-wifi-$slug

nmcli con delete id "$NOME" >/dev/null 2>&1 || true
args=(type wifi ifname "$WAN" con-name "$NOME" ssid "$SSID"
  connection.autoconnect yes connection.autoconnect-priority "$PRIO"
  connection.autoconnect-retries 0
  802-11-wireless.powersave 2
  ipv4.method auto ipv6.method disabled)
[ "${NASCOSTA:-0}" = 1 ] && args+=(802-11-wireless.hidden yes)
if [ -n "$PSK" ]; then
  args+=(wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PSK")
fi
nmcli con add "${args[@]}" >/dev/null
unset PSK args
echo "Profilo '$NOME' creato (SSID '$SSID', priorita' $PRIO, scheda $WAN)."

# --- Sulla SD vera, se c'e' l'overlay
uuid=$(nmcli -g connection.uuid con show id "$NOME")
file=$(grep -l "^uuid=$uuid$" $NMC/*.nmconnection | head -n1)
[ -n "$file" ] || { echo "ATTENZIONE: file del profilo non trovato in $NMC"; exit 1; }
if mountpoint -q $SOTTO; then
  # Prima in RAM e da li' sulla SD: copiare da / a /media/root-ro lo stesso file lo cancella
  tmp=$(mktemp -d /run/aggiungi-rete.XXXXXX)
  cp -p "$file" "$tmp/profilo"
  mount -o remount,rw $SOTTO
  ro() { sync; echo 2 > /proc/sys/vm/drop_caches; mount -o remount,ro $SOTTO || echo "ATTENZIONE: $SOTTO resta in scrittura"; rm -rf "$tmp"; }
  trap ro EXIT
  # Un eventuale profilo vecchio con lo stesso nome, anche con un altro nome di file
  for f in "$SOTTO$NMC"/*.nmconnection; do
    [ -e "$f" ] && grep -q "^id=$NOME$" "$f" && rm -f "$f"
  done
  install -m 600 "$tmp/profilo" "$SOTTO$NMC/$(basename "$file")"
  echo "Scritto anche sulla SD (resta dopo il riavvio)."
else
  echo "Nessun overlay attivo: il profilo e' gia' sulla SD."
fi

# --- Collegamento subito, se serve
stato=$(nmcli -g GENERAL.STATE dev show "$WAN" 2>/dev/null | head -n1)
case "$stato" in
  100*) [ "${ATTIVA:-0}" = 1 ] || { echo "Gia' collegato a una rete ($WAN): ponte-reti passa a questa solo se resta senza internet. Per collegarti ora: ATTIVA=1 o 'sudo nmcli con up id $NOME'."; exit 0; } ;;
esac
echo "Mi collego a '$SSID' (fino a 40 s)..."
if timeout 55 nmcli --wait 40 con up id "$NOME" ifname "$WAN" >/dev/null 2>&1; then
  echo "Collegato. Stato: $(nmcli -g GENERAL.CONNECTION,IP4.ADDRESS dev show "$WAN" | tr '\n' ' ')"
else
  echo "Non collegato (rete non visibile? 2,4 GHz? password?). NetworkManager riprovera' da solo; stato: nmcli dev wifi list ifname $WAN --rescan yes"
fi
