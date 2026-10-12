# raspi-ponte-wifi

Un Raspberry Pi 3 che trasforma una rete WiFi con **captive portal** in una presa
Ethernet da collegare a uno switch, con NAT. Pensato per reti tipo studentato, hotel
o campus, dove ci si autentica da una pagina web (qui un **Cisco ISE guest portal**)
e ogni dispositivo conta: dietro al Pi puoi collegare tutto quello che vuoi, e il
portale vede un dispositivo solo.

```
WiFi con captive portal  )))  wlan0 [Raspberry Pi, NAT] eth0 ---- switch ---- PC, console, ...
                                                       10.42.0.1      DHCP 10.42.0.x
```

## Cosa fa

- **Ponte WiFi → Ethernet con NAT, DHCP e DNS**, tutto con NetworkManager in
  modalità `shared`: niente hostapd, regole iptables a mano o dnsmasq separato.
- **Login automatico sul captive portal** (`portale-login`): ogni 2 minuti, e ogni
  volta che il WiFi si riconnette, controlla di essere online e, se non lo è, rifà
  il login come farebbe un browser.
- **Schermino di stato** su un display SPI da 3,5" (480x320, ILI9486): internet,
  segnale WiFi, IP, velocità di download e upload, traffico totale, dispositivi
  sullo switch, temperatura, RAM, SD, uptime, sottotensione. È uno script bash che
  scrive sulla console: niente da installare.
- **Resistenza ai blackout**: watchdog hardware, log in RAM, aggiornamenti automatici
  spenti e, alla fine, SD in sola lettura (overlay in RAM).
- **Installazione senza mani**: si prepara la SD dal PC e al primo avvio il Pi si
  configura da solo, poi si riavvia.

## Hardware

- Raspberry Pi 3 (provato su Raspberry Pi OS Lite Trixie 64 bit, 2026-10-06).
  Il 3B ha il WiFi solo a 2,4 GHz, il 3B+ anche a 5 GHz.
- Una microSD **buona** (SanDisk, Samsung...): con una scheda scadente i dati si
  rovinano da soli dopo la scrittura, e il Pi lampeggia 7 volte (kernel non trovato).
- Facoltativo: display generico "3.5inch RPi Display" 480x320, ILI9486 + touch
  XPT2046 (clone MPI3501 / Waveshare 3.5" A). Il touch non viene usato.

## Il captive portal

`portale-login` è scritto per il **Cisco ISE guest portal** ("Central Web Auth").
Il flusso, ricostruito guardando le pagine:

1. la richiesta HTTP di prova (`generate_204`) viene intercettata: risposta 200 con
   `Location` e meta refresh verso `https://<portale>:8443/portal/gateway?...`;
2. pagina di login (`PortalSetup.action`): un modulo `LoginSubmit.action` con i
   campi `token`, `portal`, `user.username`, `user.password`;
3. zero o più pagine con un solo pulsante "Continue" (`Continue.action?from=...`):
   - `MAX_DEVICES`: l'account ha già il massimo dei dispositivi e il portale
     **cancella quello registrato da più tempo** per fare posto al Pi (lo script
     lo scrive nel log);
   - `POST_ACCESS_BANNER`: il messaggio di benvenuto;
4. pagina "Success", poi una POST AJAX a `DoCoA.action` (riautorizzazione,
   *Change of Authorization*). **È il passo che fa partire davvero internet**:
   senza, il portale dice "Success" ma non si naviga.

Due dettagli che fanno perdere tempo:
- il portale risponde **404 a curl**: serve un user-agent da browser;
- l'hostname del portale non va scritto da nessuna parte, perché lo script lo
  ricava dal redirect.

Dopo il primo login il Pi resta **registrato**: se il WiFi cade e torna, anche dopo
un blackout, la rete lo riconosce dal MAC ed è subito online. Lo script serve
quando la registrazione scade.

Con un portale diverso (Fortinet, pfSense, UniFi...) l'unica cosa da riscrivere
è `portale-login`: il resto funziona uguale. Per vedere il flusso del tuo portale:
`curl -s -D - http://connectivitycheck.gstatic.com/generate_204`.

## File

| File | Cosa fa |
|---|---|
| `setup.sh` | Installa e configura tutto: connessioni NetworkManager, login, schermo, watchdog, log in RAM |
| `ponte.conf.example` | Configurazione: SSID, credenziali del portale, MAC da clonare, indirizzo LAN |
| `portale-login` | Login automatico sul captive portal Cisco ISE |
| `ponte-schermo` | Pagina di stato sullo schermino (tty1) |
| `primo-avvio/user-data.example` | cloud-init: utente, chiave SSH, fuso orario; lancia `setup.sh` al primo avvio |
| `primo-avvio/network-config` | cloud-init non deve configurare nessuna interfaccia |
| `strumenti/prepara-img.py` | Mette la configurazione dentro l'immagine `.img`, prima di scriverla |
| `strumenti/scrivi-sd.ps1` | Scrive l'immagine sulla SD da Windows e la verifica con SHA256 |

## Installazione

### 1. Configurazione

```bash
cp ponte.conf.example ponte.conf                       # SSID e credenziali del portale
cp primo-avvio/user-data.example primo-avvio/user-data # hash della password e chiave SSH
openssl passwd -6 'la-tua-password'                    # -> campo passwd di user-data
```

Per lo schermino serve l'overlay di goodtft, che non è incluso qui. Va messo
accanto a `setup.sh`:

```bash
curl -L -o tft35a.dtbo https://github.com/goodtft/LCD-show/raw/master/usr/tft35a-overlay.dtb
```

Senza questo file `setup.sh` salta lo schermo, e il resto funziona lo stesso.

### 2a. SD pronta dal PC (consigliato)

1. Scarica Raspberry Pi OS Lite 64 bit e decomprimila (`.img`).
2. Prepara una cartella con dentro `user-data`, `network-config` e una sottocartella
   `ponte/` con `setup.sh`, `portale-login`, `ponte-schermo`, `ponte.conf` e
   `tft35a.dtbo`.
3. Mettila dentro l'immagine e scrivila sulla SD:

   ```bash
   pip install pyfatfs "setuptools<80"
   python strumenti/prepara-img.py raspios-lite.img ponte.img cartella/
   ```

   Poi, da un PowerShell amministratore (oppure con Raspberry Pi Imager, usando
   l'immagine personalizzata):

   ```powershell
   Get-Disk     # trova il numero della SD, e controllalo due volte
   .\strumenti\scrivi-sd.ps1 -Img ponte.img -Disk N -Log scrivi.log
   ```

4. Estrai la SD, reinseriscila e controlla che i file siano ancora lì e integri.

Metti i file dentro l'immagine invece di copiarli sulla SD già scritta: così Windows
non tocca mai la partizione montata. Al primo avvio cloud-init sposta `ponte/` in
`/root/ponte` (le credenziali escono dalla partizione FAT, che chiunque abbia la
SD può leggere), lancia `setup.sh` e riavvia. Il log resta in `/var/log/ponte-setup.log`.

### 2b. Su un Raspberry Pi OS già installato

```bash
scp ponte.conf setup.sh portale-login ponte-schermo tft35a.dtbo pi@raspberrypi.local:~/ponte/
ssh pi@raspberrypi.local 'sudo bash ~/ponte/setup.sh && sudo poweroff'
```

### 3. Accensione

> **Il primo avvio va fatto già sul posto, o col cavo di rete staccato.** Da quel
> momento il Pi fa da server DHCP su eth0: collegato al router di casa, distribuirebbe
> indirizzi sulla tua rete.

Collega eth0 allo switch e accendi. Al primo avvio servono 2-3 minuti, riavvio
compreso. Poi i dispositivi sullo switch ricevono un indirizzo 10.42.0.x.

### 4. SD in sola lettura (quando tutto funziona)

```bash
sudo raspi-config nonint do_overlayfs 0 && sudo reboot   # attiva
sudo raspi-config nonint do_overlayfs 1 && sudo reboot   # disattiva, per modificare qualcosa
```

Con l'overlay attivo ogni modifica si perde al riavvio: prima di cambiare qualcosa,
disattivalo e riavvia.

## Comandi utili

Via SSH a `10.42.0.1`, da un PC collegato allo switch:

```bash
nmcli con show --active                 # ponte-wifi e ponte-lan attive?
journalctl -t portale-login             # esito dei login
sudo /usr/local/sbin/portale-login      # forza un tentativo adesso
ls /run/portale-login/                  # pagine del portale dell'ultimo tentativo (p0..p5.html)
sudo cat /dev/fb0 > schermo.raw         # "foto" dello schermino (RGB565, 480x320)
```

## Alternative al login automatico

- **A mano**: da un PC sullo switch apri `http://neverssl.com`: il portale autentica
  il Pi, quindi tutta la LAN.
- **MAC clonato**: in `MAC_CLONATO` metti il MAC di un dispositivo già registrato.
  Sul telefono va preso il MAC *privato* che usa per quella rete, non quello
  hardware. Quel dispositivo poi non deve più collegarsi alla rete, perché due MAC
  uguali si buttano fuori a vicenda.

## Licenza

MIT. L'overlay `tft35a.dtbo` è di [goodtft/LCD-show](https://github.com/goodtft/LCD-show)
e non è incluso.
