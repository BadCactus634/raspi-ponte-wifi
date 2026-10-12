"""Crea ponte.img: l'immagine Raspberry Pi OS con user-data, network-config e ponte/ gia' nella bootfs.

Uso: python prepara-img.py <raspios-lite.img> <ponte.img> <cartella>
dove <cartella> contiene user-data, network-config e una sottocartella ponte/ con
setup.sh, portale-login, ponte-schermo, ponte.conf e (facoltativo) tft35a.dtbo.
Serve pyfatfs (pip install pyfatfs "setuptools<80").
"""
import hashlib
import os
import shutil
import struct
import sys

from pyfatfs.PyFatFS import PyFatFS

src, dst, sd_dir = sys.argv[1], sys.argv[2], sys.argv[3]
shutil.copyfile(src, dst)
with open(dst, 'rb') as f:
    mbr = f.read(512)
lba, nsec = struct.unpack_from('<II', mbr, 446 + 8)
off, size = lba * 512, nsec * 512

part = dst + '.bootfs'
with open(dst, 'rb') as f, open(part, 'wb') as o:
    f.seek(off)
    o.write(f.read(size))

fat = PyFatFS(part, read_only=False)
for nome in ('user-data', 'network-config'):
    # pyfatfs non sa sovrascrivere un file esistente: si cancella e si riscrive
    if fat.exists('/' + nome):
        fat.remove('/' + nome)
    with open(os.path.join(sd_dir, nome), 'rb') as f:
        fat.writebytes('/' + nome, f.read())
if not fat.exists('/ponte'):
    fat.makedir('/ponte')
for nome in sorted(os.listdir(os.path.join(sd_dir, 'ponte'))):
    with open(os.path.join(sd_dir, 'ponte', nome), 'rb') as f:
        fat.writebytes('/ponte/' + nome, f.read())
fat.close()

# Rilettura: i file dentro la FAT devono essere identici agli originali
fat = PyFatFS(part, read_only=True)
for rel in ['user-data', 'network-config'] + ['ponte/' + n for n in os.listdir(os.path.join(sd_dir, 'ponte'))]:
    with open(os.path.join(sd_dir, rel), 'rb') as f:
        assert fat.readbytes('/' + rel) == f.read(), rel
assert fat.readbytes('/kernel8.img')[:4] != b'\xff\xff\xff\xff'
print('cmdline:', fat.readbytes('/cmdline.txt').decode().strip())
fat.close()

with open(part, 'rb') as p, open(dst, 'r+b') as o:
    o.seek(off)
    o.write(p.read())
os.remove(part)
h = hashlib.sha256()
with open(dst, 'rb') as f:
    for blocco in iter(lambda: f.read(4 << 20), b''):
        h.update(blocco)
print('OK', dst, os.path.getsize(dst), h.hexdigest())
