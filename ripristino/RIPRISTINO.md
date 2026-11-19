# Ricostruire il ponte da zero (SD rotta o da rifare)

Ricetta di ricostruzione, scritta il 19/11/2026 guardando il ponte acceso e funzionante. Parte dall'immagine
pulita di Raspberry Pi OS e arriva al ponte in servizio. Nessun segreto in questa cartella: i valori veri stanno
nei file che il repo non contiene (elencati al passo 0).

La parte principale (rete, access point, portale, VPN, schermino, guardia, watchdog) la fa `setup.sh`, gia' nel repo
(vedi `README.md`, "Installazione"). Questa cartella aggiunge quello che `setup.sh` non copre: la partizione dati,
OctoPrint, il battito verso Kuma e un paio di unita' systemd.

| Cosa | Dove |
|---|---|
| `ricrea.sh` | applica la parte non coperta da `setup.sh` (idempotente) |
| `file/` | copie dei file reali del ponte (unita' systemd, `vita.sh`, config di OctoPrint con segnaposto) |
| `riferimento/` | cosa c'e' sul ponte vivo: pacchetti, unita' abilitate, regole nft, profili NetworkManager ripuliti, `pip freeze` di OctoPrint, cmdline/config.txt |

## Hardware e versioni

- Raspberry Pi 3 Model B Rev 1.2 (arm64), SD da 32 GB (basta 16).
- Raspberry Pi OS **Lite 64 bit**, Debian 13 *trixie* (immagine pi-gen 2026-10-06, kernel 6.18.50+rpt-rpi-v8). Una release piu' nuova di Trixie va bene.
- Chiavetta WiFi USB TP-Link TL-WN722N v2 (RTL8188EUS, driver `rtl8xxxu`): fa il client verso la rete WiFi. Il chip interno fa l'access point.
- Schermino 3,5" (ILI9486 + XPT2046) sul connettore GPIO, overlay `tft35a`.
- Prusa MK3S+ in USB (`/dev/ttyACM0`), per OctoPrint.
- Switch LAN su eth0.

## 0. Cosa serve prima di cominciare (fuori dal repo)

| File | Contenuto | Dove sta |
|---|---|---|
| `ponte.conf` | SSID e password WiFi, MAC clonato, MAC della chiavetta, SSID/PSK dell'AP, utente e password del portale, indirizzo VPN, chiavi WireGuard, MAC da non contare | root del repo sul PC (in `.gitignore`); copia in cassaforte: `-- CIFRATE/ponte-wifi/ponte.conf` |
| `primo-avvio/user-data` | utente `pi`, hash della password, chiave SSH autorizzata | sul PC (in `.gitignore`); copia: `-- CIFRATE/ponte-wifi/primo-avvio/user-data`; si rifa da `user-data.example` |
| `credenziali/` | chiave SSH, utente/password e chiave API di OctoPrint, note | sul PC (in `.gitignore`); copia: `-- CIFRATE/ponte-wifi/credenziali/` |
| `tft35a.dtbo` | overlay dello schermino | si scarica (comando nel `README.md`) |
| URL push di Kuma del ponte | per il battito | cassaforte: `-- CIFRATE/ponte-wifi/kuma_push.env` (copia del file del Pi), oppure Kuma (monitor del ponte) |
| peer WireGuard | il ponte e' un peer della VPN unica sulla VPS; la sua chiave e' in `ponte.conf` (`VPN_*`) | se `ponte.conf` e' perso, si genera un peer nuovo sulla VPS (`-- CIFRATE/vpn-aruba/LEGGIMI.txt`) |

La cartella `-- CIFRATE/ponte-wifi/` ha la stessa struttura del repo: basta copiarla nella cartella del repo. Se `ponte.conf` e' perso anche li': si rifa da `ponte.conf.example`; la password del portale e quella dell'AP vanno ritrovate o cambiate.

## 1. Immagine e SD

1. Scarica Raspberry Pi OS Lite 64 bit (`.img`).
2. Prepara la cartella di primo avvio e mettila nell'immagine: `README.md`, "2a. SD pronta dal PC" (`strumenti/prepara-img.py`), poi scrivi con `strumenti/scrivi-sd.ps1` (PowerShell amministratore, verifica SHA-256). Verifica che i file siano ancora sulla SD prima di toglierla.
3. Per la partizione dati (passo 3) conviene che l'immagine **non** si espanda a tutta la SD: vedi sotto.

## 2. Primo avvio (cloud-init lancia `setup.sh` e riavvia)

**Sul posto, o con il cavo di rete staccato**: da qui il Pi fa da server DHCP su eth0 e, collegato al router di casa, distribuirebbe indirizzi sulla tua LAN.

Colloca il Pi con chiavetta, schermino e switch, accendi, aspetta 2-3 minuti (c'e' un riavvio). Log in `/var/log/ponte-setup.log`.
Il portale WiFi riconosce il ponte dal MAC (quello del chip interno, che e' sempre lo stesso: il Pi e' lo stesso): non serve un login nuovo, ma se serve `portale-login` lo tenta da solo.

Verifica minima: `nmcli con show --active` (ponte-wifi, ponte-lan, wg-ponte) e `systemctl is-active ponte-ap ponte-guardia ponte-reti ponte-schermo`.

## 3. Partizione dati `/srv/dati` (NON provata da zero in questa forma)

Layout del ponte funzionante: `p1` FAT32 512 MB (`/boot/firmware`), `p2` ext4 8 GB (root), `p3` ext4 il resto (`/srv/dati`).
`/srv/dati` ospita OctoPrint (venv di ~250 MB e dati) e lo stato del battito: e' l'unica parte scrivibile quando la root e' in sola lettura.

Due strade:

- **Prima di scrivere la SD** (consigliata): da Linux, riduci la partizione root dell'immagine (`e2fsck -f`, `resize2fs`, riscrivi la tabella con `sfdisk` lasciando lo stesso label-id) in modo che resti spazio libero in fondo; poi crea `p3` sullo spazio libero.
- **Dopo** il primo avvio: serve ridurre la root da un altro sistema (con la root montata non si riduce).

Poi, sul Pi:

```bash
sudo mkfs.ext4 /dev/mmcblk0p3
sudo mkdir -p /srv/dati
ID=$(sudo blkid -s PTUUID -o value /dev/mmcblk0)        # id del disco: i PARTUUID sono <ID>-01, -02, -03
echo "PARTUUID=${ID}-03  /srv/dati  ext4  defaults,noatime,nofail,commit=60,errors=remount-ro  0  2" | sudo tee -a /etc/fstab
sudo mount /srv/dati && findmnt /srv/dati
```

(Con l'`fstab` originale `PARTUUID=<ID>-01` e `-02` gia' scritti da pi-gen: il tuo `<ID>` e' quello della SD nuova, non quello del ponte vecchio.)

## 4. Parte non coperta da `setup.sh`

```bash
git clone https://github.com/BadCactus634/raspi-ponte-wifi.git && cd raspi-ponte-wifi/ripristino
sudo bash ricrea.sh
```

Fa: pacchetti (`python3-venv`, `hostapd`, `iw`, `curl`), `hostapd` mascherato, unita' `octoprint`, `enjoybuds-vita`, `wlap-powersave`, override di `systemd-remount-fs` (con la root in overlay il rimontaggio esce sempre con status 1: non e' un guasto), `vita.sh`, venv di OctoPrint 1.11.8 con le versioni del ponte vivo, `config.yaml` e profilo stampante da modello.

A mano, perche' sono segreti:

1. `/srv/dati/stato/kuma_push.env`: metti l'URL push vero (`KUMA_PUSH_URL=...`).
2. `/srv/dati/octoprint/base/config.yaml`: sostituisci `api.key` con quella in `credenziali/octoprint-apikey.txt`.
3. Utente OctoPrint (nome e password in `credenziali/octoprint.txt`):
   `sudo -u pi /srv/dati/octoprint/venv/bin/octoprint --basedir /srv/dati/octoprint/base user add <utente> --password '<password>' --admin`
4. Riavvia: `sudo reboot`.

## 5. Collegare la stampante

`autoconnect` e' spento apposta (collegarsi resetta la stampante). Con la Prusa accesa e in USB:

```bash
curl -s -X POST http://10.42.0.1:5000/api/connection -H "X-Api-Key: <chiave API>" -H "Content-Type: application/json" \
  -d '{"command":"connect","port":"/dev/ttyACM0","baudrate":115200}'
```

OctoPrint ascolta sulla porta 5000 di LAN (10.42.0.1), AP (10.42.1.1) e VPN; l'unita' mette una regola nft che la blocca da `wlwan` (la rete dello studentato). Se la stampante risulta "Offline" dopo un riavvio, e' normale: va ricollegata come sopra.

## 6. Reti di riserva (facoltativo)

L'hotspot del telefono (priorita' 50) e' un profilo aggiunto a mano con `strumenti/aggiungi-rete.sh` (vedi `README.md`, "Aggiungere una rete"); non sta in `ponte.conf`.

## 7. SD in sola lettura (a servizio funzionante)

```bash
sudo raspi-config nonint do_overlayfs 0 && sudo reboot      # attiva
grep -o 'overlayroot=[^ ]*' /boot/firmware/cmdline.txt     # deve essere  overlayroot=tmpfs:recurse=0
```

**Trappola**: in `cmdline.txt` serve `overlayroot=tmpfs:recurse=0`. Senza `recurse=0` l'overlay copre `/srv/dati` e OctoPrint parte senza dati. Se manca, modificalo (con `/boot/firmware` rimontata in scrittura: `sudo mount -o remount,rw /boot/firmware`) e riavvia.
Per modificare qualcosa poi: `do_overlayfs 1`, riavvio, modifica, `do_overlayfs 0`, riavvio; oppure `strumenti/installa-a-caldo.sh` (vedi `README.md`). Il `cmdline.txt` del ponte e' in `riferimento/boot-cmdline-config.txt`.

## 8. Verifica finale

```bash
findmnt /                 # overlay su overlayroot
findmnt /srv/dati         # /dev/mmcblk0p3, rw
cat /proc/cmdline         # contiene overlayroot=tmpfs:recurse=0
nmcli con show --active   # ponte-wifi (su wlwan), ponte-lan (eth0), wg-ponte
ip -br a                  # eth0 10.42.0.1, wlap 10.42.1.1, wlwan col DHCP della rete, wg-ponte
systemctl is-active ponte-ap ponte-guardia ponte-reti ponte-schermo octoprint enjoybuds-vita
journalctl -t portale-login -n 5 --no-pager      # esito dell'ultimo login
sudo nft list ruleset | grep -E "ponte-ap|octoprint|nm-shared-eth0"    # confronta con riferimento/nft-ruleset-vivo.txt
curl -s http://10.42.0.1:5000/api/version -H "X-Api-Key: <chiave API>"  # OctoPrint 1.11.8
ping -c1 <un indirizzo dentro la VPN>             # la VPN e' su
```

Dal PC: dal WiFi `ponte` e dallo switch si arriva a internet; dallo switch e dal WiFi **non** si arriva alla VPN (regola voluta). Lo schermino mostra la pagina di stato e si spegne dalle 23:00 alle 7:30.

## Cosa NON si ritrova dopo un rifacimento

- File G-code caricati in OctoPrint, cronologia, utenti e sessioni (l'utente si ricrea al passo 4).
- Chiavi host SSH del Pi: nuove; sul PC `ssh-keygen -R 10.42.0.1` (e l'alias) e conferma l'impronta nuova.
- Profili WiFi aggiunti con `aggiungi-rete.sh` (passo 6).
- Il log del ponte (volatile per scelta).

## Non provato

`ricrea.sh` e' controllato solo con `bash -n` e `shellcheck`: non e' stato eseguito su un Pi pulito. Il passo 3 (creazione della partizione dati) e' descritto, non provato da zero in questa forma.
