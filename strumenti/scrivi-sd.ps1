# Scrive un'immagine .img su una microSD in raw, scrivendo per ultimo il primo blocco
# (cosi' Windows non monta le partizioni a meta' scrittura), poi la rilegge e confronta lo SHA256.
# Va lanciato da amministratore. Il numero del disco si trova con Get-Disk: controllalo due volte.
# Uso: powershell -File scrivi-sd.ps1 -Img ponte.img -Disk 1 -Log scrivi-sd.log
param([string]$Img, [int]$Disk, [string]$Log)
$ErrorActionPreference = 'Stop'
Start-Transcript -Path $Log -Force | Out-Null
try {
    $d = Get-Disk -Number $Disk
    "Disco: $($d.Number) $($d.FriendlyName) $($d.BusType) $([math]::Round($d.Size/1GB,1)) GB"
    if ($d.IsSystem -or $d.IsBoot -or $d.BusType -in 'NVMe', 'SATA', 'RAID' -or $d.Size -gt 128GB) {
        throw "Il disco $Disk non sembra la microSD: mi fermo"
    }
    $imgLen = (Get-Item $Img).Length
    if ($imgLen -gt $d.Size) { throw "Immagine piu' grande della SD" }

    "Cancello la SD"
    Clear-Disk -Number $Disk -RemoveData -RemoveOEM -Confirm:$false

    [long]$chunk = 4MB
    $in = [IO.File]::OpenRead($Img)
    $out = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite, 4096, [IO.FileOptions]::WriteThrough)
    $buf = New-Object byte[] $chunk

    # Il primo blocco (con la tabella delle partizioni) si scrive per ultimo:
    # cosi' Windows non vede e non monta le partizioni mentre stiamo ancora scrivendo
    $primo = New-Object byte[] $chunk
    $nPrimo = $in.Read($primo, 0, $chunk)
    $out.Seek($chunk, 'Begin') | Out-Null
    $scritti = $nPrimo; $ultimo = 0
    while (($n = $in.Read($buf, 0, $chunk)) -gt 0) {
        if ($n % 512) { $pad = 512 - ($n % 512); [Array]::Clear($buf, $n, $pad); $n += $pad }
        $out.Write($buf, 0, $n)
        $scritti += $n
        $pct = [int](100 * $scritti / $imgLen)
        if ($pct -ge $ultimo + 10) { "Scritto $pct%"; $ultimo = $pct }
    }
    $out.Seek(0, 'Begin') | Out-Null
    $out.Write($primo, 0, $nPrimo)
    $out.Flush()
    $out.Close(); $in.Close()

    "Verifica: rileggo la SD"
    [long]$imgLen = $imgLen
    $sha = [Security.Cryptography.SHA256]::Create()
    $rd = New-Object IO.FileStream("\\.\PhysicalDrive$Disk", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    [long]$resto = $imgLen
    while ($resto -gt 0) {
        [long]$voglio = [math]::Min($chunk, [long]([math]::Ceiling($resto / 512.0) * 512))
        $n = $rd.Read($buf, 0, [int]$voglio)
        if ($n -le 0) { throw "Lettura della SD interrotta" }
        [int]$usa = [math]::Min([long]$n, $resto)
        $sha.TransformBlock($buf, 0, $usa, $null, 0) | Out-Null
        $resto -= $usa
    }
    $sha.TransformFinalBlock($buf, 0, 0) | Out-Null
    $rd.Close()
    $hSd = ($sha.Hash | ForEach-Object { $_.ToString('x2') }) -join ''
    $hImg = (Get-FileHash $Img -Algorithm SHA256).Hash.ToLower()
    "SHA256 immagine: $hImg"
    "SHA256 SD:       $hSd"
    if ($hSd -ne $hImg) { throw "La SD non corrisponde all'immagine" }
    Update-HostStorageCache
    "ESITO: OK"
} catch {
    "ESITO: ERRORE $_"
} finally {
    Stop-Transcript | Out-Null
}
