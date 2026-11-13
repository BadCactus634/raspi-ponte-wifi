#!/bin/bash
# Prova la logica di scelta rete di ponte-reti con nmcli, curl e orologio finti (nessun hardware).
# Uso: bash strumenti/prova-reti.sh
set -u
QUI="$(cd "$(dirname "$0")/.." && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export PONTE_RETI_TEST=1
IN_ATTESA=$T/log
# shellcheck source=../ponte-reti
. "$QUI/ponte-reti"
IN_ATTESA=$T/log
LOG_SD=$T/sd.log
: > "$T/cur"; : > "$T/vis"; : > "$T/chiamate"
SECONDS=0

# Reti salvate: nome|priorita|ssid
cat > "$T/profili" <<'EOF'
ponte-wifi|100|Rete Principale
ponte-wifi-2|50|Hotspot - del telefono
ponte-wifi-3|40|Terza: con due punti
EOF
# Reti con internet (nomi dei profili), una per riga
: > "$T/inet"

nmcli() {
  case "$*" in
    "-t -f NAME,TYPE con show") awk -F'|' '{print $1":802-11-wireless"}' "$T/profili"; echo "wg-ponte:wireguard" ;;
    "-t -f NAME con show") awk -F'|' '{print $1}' "$T/profili"; echo wg-ponte ;;
    "-g connection.autoconnect-priority con show id "*) awk -F'|' -v n="${@: -1}" '$1==n{print $2}' "$T/profili" ;;
    "-g 802-11-wireless.ssid con show id "*) awk -F'|' -v n="${@: -1}" '$1==n{print $3}' "$T/profili" ;;
    "-g GENERAL.CONNECTION dev show "*) cat "$T/cur" ;;
    "-t -f IN-USE,SIGNAL,SSID dev wifi list ifname "*)
      # righe di vis: ssid | segnale (default 70) | * se e' l'access point in uso
      awk -F'|' '{ g = $2 == "" ? 70 : $2; u = $3 == "*" ? "*" : " "; gsub(/:/, "\\:", $1); print u ":" g ":" $1 }' "$T/vis" ;;
    "con up id wg-ponte"*|"--wait 30 con up id wg-ponte"*) echo "vpn su" >> "$T/chiamate" ;;
    "con down id wg-ponte") echo "vpn giu" >> "$T/chiamate" ;;
    *"con up id "*) local tutto="$*"; local n=${tutto#*con up id }; n=${n%% *}; echo "su $n" >> "$T/chiamate"; echo "$n" > "$T/cur" ;;
    *) echo "nmcli finto: $*" >&2; return 1 ;;
  esac
}
timeout() { shift; "$@"; }
sleep() { SECONDS=$((SECONDS + ${1:-1})); }
logger() { :; }
con_ip() { [ -s "$T/cur" ]; }
online() { [ -s "$T/cur" ] && grep -qx "$(cat "$T/cur")" "$T/inet"; }
echo 80 > "$T/seg"
segnale_corrente() { cat "$T/seg"; }
mountpoint() { return 1; }
systemctl() { echo "systemctl $*" >> "$T/chiamate"; }

ok=0; ko=0
verifica() {  # descrizione, atteso, ottenuto
  if [ "$2" = "$3" ]; then ok=$((ok + 1)); echo "ok   $1"; else ko=$((ko + 1)); echo "KO   $1 (atteso '$2', ottenuto '$3')"; fi
}
passa() { local fine=$((SECONDS + $1)); while [ $SECONDS -lt $fine ]; do SECONDS=$((SECONDS + PASSO)); ciclo; done; }
ultima() { grep '^su ' "$T/chiamate" | tail -n1 | cut -d' ' -f2-; }
cambi() { grep -c '^su ' "$T/chiamate"; }

echo "== 1. principale con internet: niente cambi"
echo ponte-wifi > "$T/cur"; echo ponte-wifi > "$T/inet"
printf 'Rete Principale\nHotspot - del telefono\n' > "$T/vis"
passa 40
verifica "nessun cambio" 0 "$(cambi)"

echo "== 2. internet cade sulla principale, il telefono e' visibile"
: > "$T/inet"; echo ponte-wifi-2 > "$T/inet"
passa 25
verifica "prima di 30 s non cambia" 0 "$(cambi)"
verifica "login del portale lanciato sulla principale" 1 "$(grep -c 'start --no-block portale-login' "$T/chiamate")"
passa 30
verifica "passa al telefono" ponte-wifi-2 "$(ultima)"
verifica "VPN riavviata" "vpn giu" "$(grep '^vpn' "$T/chiamate" | head -n1)"
n=$(cambi)
passa 200
verifica "resta sul telefono finche' funziona (nessun ritorno)" "$n" "$(cambi)"

echo "== 3. il telefono perde internet: la rotazione prova la terza, poi la principale"
: > "$T/inet"; echo ponte-wifi-3 > "$T/inet"
printf 'Rete Principale\nHotspot - del telefono\nTerza: con due punti\n' > "$T/vis"
passa 45
verifica "passa alla terza (la successiva)" ponte-wifi-3 "$(ultima)"
echo ponte-wifi > "$T/inet"
passa 60
verifica "dalla terza torna alla principale (a rotazione)" ponte-wifi "$(ultima)"

echo "== 4. rete successiva non visibile: salta"
echo ponte-wifi-3 > "$T/cur"; : > "$T/inet"; echo ponte-wifi-2 > "$T/inet"
printf 'Rete Principale\nHotspot - del telefono\n' > "$T/vis"
giu_da=-1
passa 45
verifica "dalla terza (corrente) va alla successiva visibile: la principale" "ponte-wifi" "$(ultima)"
passa 60
verifica "principale senza internet: prosegue al telefono" ponte-wifi-2 "$(ultima)"

echo "== 5. nessun'altra rete visibile: resta e non cambia"
echo ponte-wifi-2 > "$T/cur"; : > "$T/inet"
printf 'Hotspot - del telefono\n' > "$T/vis"
giu_da=-1; n=$(cambi)
passa 300
verifica "nessun cambio" "$n" "$(cambi)"

echo "== 6. nessuna rete ha internet: ruota con pausa e log limitato"
: > "$T/chiamate"; : > "$T/log"; fallimenti=0; ultimo_log_rip=-999999; giu_da=-1
printf 'Rete Principale\nHotspot - del telefono\nTerza: con due punti\n' > "$T/vis"
echo ponte-wifi > "$T/cur"; : > "$T/inet"
passa 600
c=$(cambi)
[ "$c" -ge 8 ] && [ "$c" -le 20 ] && r=ok || r="$c"
verifica "cambi in 10 minuti ragionevoli (un cambio ogni ~30+ s)" ok "$r"
righe=$(wc -l < "$T/log")
[ "$righe" -le 40 ] && r=ok || r="$righe"
verifica "righe di log limitate" ok "$r"

echo "== 7. segnale debole sulla principale, un altro access point della stessa rete e' molto meglio"
: > "$T/chiamate"; : > "$T/log"; giu_da=-1; debole_da=-1; ultima_ricerca_segnale=-999999
printf 'ponte-wifi\nponte-wifi-2\nponte-wifi-3\n' > "$T/inet"; echo ponte-wifi > "$T/cur"
printf 'Rete Principale|35|*\nRete Principale|70\nHotspot - del telefono|20\n' > "$T/vis"; echo 35 > "$T/seg"
passa 15
verifica "prima di 20 s non cambia" 0 "$(cambi)"
passa 20
verifica "riassocia alla rete col segnale migliore" ponte-wifi "$(ultima)"
verifica "una sola scelta" 1 "$(cambi)"
verifica "VPN riavviata" "vpn giu" "$(grep '^vpn' "$T/chiamate" | head -n1)"
echo 80 > "$T/seg"; passa 200
verifica "poi resta (segnale buono)" 1 "$(cambi)"

echo "== 8. segnale debole ma nessuno chiaramente migliore: non cambia"
: > "$T/chiamate"; debole_da=-1; ultima_ricerca_segnale=-999999
printf 'Rete Principale|35|*\nRete Principale|45\nHotspot - del telefono|48\n' > "$T/vis"; echo 35 > "$T/seg"
passa 100
verifica "+10 non basta" 0 "$(cambi)"
printf 'Rete Principale|30|*\nRete Principale|45\n' > "$T/vis"; echo 30 > "$T/seg"; debole_da=-1; ultima_ricerca_segnale=-999999
passa 100
verifica "sotto la soglia minima non vale nemmeno se +15" 0 "$(cambi)"
printf 'Rete Principale|35|*\n' > "$T/vis"; echo 35 > "$T/seg"; debole_da=-1; ultima_ricerca_segnale=-999999
passa 100
verifica "un solo access point: niente" 0 "$(cambi)"

echo "== 9. segnale debole, l'hotspot e' molto meglio: ci passa e ci resta"
printf 'Rete Principale|35|*\nHotspot - del telefono|75\n' > "$T/vis"; debole_da=-1; ultima_ricerca_segnale=-999999
echo ponte-wifi > "$T/cur"; echo 35 > "$T/seg"
passa 30
verifica "passa all'hotspot" ponte-wifi-2 "$(ultima)"
echo 80 > "$T/seg"; printf 'Rete Principale|90\nHotspot - del telefono|80|*\n' > "$T/vis"
n=$(cambi); passa 300
verifica "resta sull'hotspot con segnale sopra la soglia" "$n" "$(cambi)"

echo
echo "Risultato: $ok ok, $ko ko"
[ $ko = 0 ]
