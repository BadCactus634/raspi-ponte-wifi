#!/bin/bash
# Controllo da fare sul PC PRIMA di strumenti/installa-a-caldo.sh: i file del deploy ci sono e hanno la sintassi giusta, e il ponte
# e' raggiungibile. Non cambia niente, ne' sul PC ne' sul ponte. Se il ponte e' offline (banco spento) lo dice e si esce con 2:
# il deploy si rimanda a quando il banco e' acceso, non si prova a forzarlo.
# Uso: bash strumenti/controlla-prima-del-deploy.sh [utente@indirizzo]      (predefinito pi@10.42.0.1)
#      bash strumenti/controlla-prima-del-deploy.sh --solo-file              (niente rete: solo i file)
set -uo pipefail
cd "$(dirname "$0")/.."
SOLO_FILE=0
[ "${1:-}" = "--solo-file" ] && { SOLO_FILE=1; shift; }
DEST="${1:-pi@10.42.0.1}"
FILE=(strumenti/installa-a-caldo.sh ponte.conf ponte-schermo ponte-guardia portale-login ponte-reti wifi-ap.sh ponte-ap setup.sh)

mancano=0
for f in "${FILE[@]}"; do
  [ -f "$f" ] || { echo "manca: $f"; mancano=1; }
done
[ -f ponte.conf ] || echo "  (ponte.conf si fa da ponte.conf.example: contiene le chiavi, non va nel repo)"
[ $mancano = 0 ] || { echo "file mancanti: il deploy non puo' partire"; exit 1; }
for f in "${FILE[@]}"; do
  [ "$f" = ponte.conf ] && continue
  bash -n "$f" 2>/dev/null || { echo "sintassi sbagliata in $f"; exit 1; }
done
echo "file: ok (${#FILE[@]} file, sintassi bash a posto)"
[ $SOLO_FILE = 1 ] && exit 0

host="${DEST#*@}"
if ! ping -n 1 -w 2000 "$host" >/dev/null 2>&1 && ! ping -c 1 -W 2 "$host" >/dev/null 2>&1; then
  echo "ponte $host offline: il banco e' spento o non sei sullo switch. Deploy rimandato a quando e' acceso."
  exit 2
fi
if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$DEST" true 2>/dev/null; then
  echo "ponte $host online ma la SSH non risponde con la chiave: controlla utente e chiave. Deploy rimandato."
  exit 2
fi
echo "ponte $DEST: raggiungibile. Ora si puo' fare il deploy:"
echo "  ssh $DEST 'mkdir -p ~/ponte' && scp ${FILE[*]} $DEST:~/ponte/"
echo "  ssh $DEST 'sudo systemd-run --unit installa-a-caldo bash ~/ponte/installa-a-caldo.sh ~/ponte'"
echo "  ssh $DEST 'journalctl -fu installa-a-caldo'   # l'ultimo passo ricollega il WiFi: la SSH puo' cadere"
