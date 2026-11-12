# SPDX-License-Identifier: MIT
"""Join original upstream executable code to ordinary Nix loader packaging."""
import hashlib,json,struct,sys,zipfile
from pathlib import Path
archive,binary,report=map(Path,sys.argv[1:])
with zipfile.ZipFile(archive)as z:
 assert z.namelist()==["deno"]
 original=z.read("deno")
installed=binary.read_bytes()
def sections(raw):
 assert raw[:6]==b"\x7fELF\x02\x01"and struct.unpack_from("<H",raw,18)[0]==62
 offset=struct.unpack_from("<Q",raw,40)[0];size,count,names=struct.unpack_from("<HHH",raw,58)
 def entry(i):return struct.unpack_from("<IIQQQQIIQQ",raw,offset+i*size)
 table=entry(names);strings=raw[table[4]:table[4]+table[5]];out={}
 for i in range(count):
  row=entry(i);name=strings[row[0]:].split(b"\0",1)[0].decode();out[name]=raw[row[4]:row[4]+row[5]]
 return out
left,right=sections(original),sections(installed)
for name in [".text",".rodata"]:assert left[name]==right[name],name
sha=lambda raw:hashlib.sha256(raw).hexdigest()
report.write_text(json.dumps(dict(archive=str(archive),archiveSha256=sha(archive.read_bytes()),originalBinarySha256=sha(original),installedBinarySha256=sha(installed),unchangedSections={name:sha(left[name])for name in [".text",".rodata"]},scope="Only ELF loader/RPATH packaging; no version/source/code/rodata workaround"),indent=2)+"\n")
