#!/bin/bash
# Ricrea sul ponte la parte che setup.sh NON copre: partizione dati, OctoPrint, battito verso Kuma,
# risparmio energetico dell'AP, override di systemd-remount-fs. Idempotente.
# Da lanciare DOPO setup.sh (che fa rete, AP, portale, VPN, schermo, guardia, watchdog) e PRIMA
# di attivare l'overlay (sola lettura). Uso: sudo bash ricrea.sh   (dalla cartella ripristino/ del repo)
# Non contiene segreti: la chiave API di OctoPrint e l'URL Kuma si mettono a mano (vedi RIPRISTINO.md).
set -euo pipefail
QUI="$(cd "$(dirname "$0")" && pwd)"
F="$QUI/file"
[ "$(id -u)" -eq 0 ] || { echo "Lancialo con sudo"; exit 1; }
[ -d "$F" ] || { echo "Manca $F"; exit 1; }
mountpoint -q /srv/dati || { echo "/srv/dati non e' montata: crea la partizione dati (RIPRISTINO.md, passo 4) e controlla l'fstab"; exit 1; }
UTENTE=${UTENTE:-pi}
OCTO_VER=1.11.8

echo "== Pacchetti"
pacchetti="python3-venv hostapd iw curl"
# shellcheck disable=SC2086
dpkg -s $pacchetti >/dev/null 2>&1 || { apt-get update; apt-get install -y --no-install-recommends $pacchetti; }
# Debian installa hostapd gia' mascherato: lo lancia ponte-ap, non systemd
systemctl mask hostapd.service >/dev/null 2>&1 || true

echo "== Unita' systemd"
install -m 644 "$F/etc/systemd/system/octoprint.service" /etc/systemd/system/octoprint.service
install -m 644 "$F/etc/systemd/system/enjoybuds-vita.service" /etc/systemd/system/enjoybuds-vita.service
install -m 644 "$F/etc/systemd/system/wlap-powersave.service" /etc/systemd/system/wlap-powersave.service
install -d /etc/systemd/system/systemd-remount-fs.service.d
install -m 644 "$F/etc/systemd/system/systemd-remount-fs.service.d/override.conf" \
  /etc/systemd/system/systemd-remount-fs.service.d/override.conf
systemctl daemon-reload

echo "== Battito verso Kuma"
install -d -o "$UTENTE" -g root -m 755 /srv/dati/stato
install -o "$UTENTE" -g "$UTENTE" -m 755 "$F/srv-dati/vita.sh" /srv/dati/stato/vita.sh
if [ ! -f /srv/dati/stato/kuma_push.env ]; then
  install -o "$UTENTE" -g "$UTENTE" -m 600 "$F/srv-dati/kuma_push.env.example" /srv/dati/stato/kuma_push.env
  echo "ATTENZIONE: scrivi l'URL vero in /srv/dati/stato/kuma_push.env (segnaposto messo)"
fi

echo "== OctoPrint $OCTO_VER"
D=/srv/dati/octoprint
install -d -o "$UTENTE" -g "$UTENTE" "$D" "$D/base" "$D/base/printerProfiles"
if [ ! -x "$D/venv/bin/octoprint" ]; then
  sudo -u "$UTENTE" python3 -m venv "$D/venv"
  # Versioni delle dipendenze fissate a quelle del ponte funzionante (riferimento/octoprint-pip-freeze.txt)
  sudo -u "$UTENTE" "$D/venv/bin/pip" install --no-input -c "$QUI/riferimento/octoprint-pip-freeze.txt" "OctoPrint==$OCTO_VER"
fi
if [ ! -f "$D/base/config.yaml" ]; then
  install -o "$UTENTE" -g "$UTENTE" -m 600 "$F/srv-dati/octoprint/config.yaml.template" "$D/base/config.yaml"
  echo "ATTENZIONE: in $D/base/config.yaml sostituisci api.key (credenziali/octoprint-apikey.txt)"
fi
[ -f "$D/base/printerProfiles/_default.profile" ] ||
  install -o "$UTENTE" -g "$UTENTE" -m 644 "$F/srv-dati/octoprint/_default.profile" "$D/base/printerProfiles/_default.profile"
if ! sudo -u "$UTENTE" "$D/venv/bin/octoprint" --basedir "$D/base" user list 2>/dev/null | grep -q 'name:'; then
  echo "NOTA: nessun utente OctoPrint. Crealo (utente e password in credenziali/octoprint.txt):"
  echo "  sudo -u $UTENTE $D/venv/bin/octoprint --basedir $D/base user add <utente> --password '<password>' --admin"
fi

echo "== Abilitazione"
systemctl enable octoprint.service enjoybuds-vita.service wlap-powersave.service
echo
echo "Fatto. Controlli: systemctl is-enabled octoprint enjoybuds-vita ponte-ap; poi riavvia e segui RIPRISTINO.md, passo 7."
echo "Collegamento stampante a mano (autoconnect spento apposta): vedi RIPRISTINO.md."
