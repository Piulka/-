#!/usr/bin/env python3
"""Stable local development signing. Code-sign trust is a separate, explicit user-approved setup."""
import os,pathlib,secrets,subprocess,sys,tempfile,shlex
root=pathlib.Path.home()/'Library/Application Support/Drivee QA Desk/Signing'
root.mkdir(parents=True,exist_ok=True);root.chmod(0o700)
keychain=root/'development.keychain-db';secret=root/'keychain-password';certificate=root/'development.crt'
def run(args):
 result=subprocess.run(args,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 if result.returncode:raise RuntimeError(result.stderr.decode(errors="replace").strip())
 return result.stdout
if not (root/'ready').exists():
 if keychain.exists():run(['/usr/bin/security','delete-keychain',str(keychain)])
 password=secrets.token_urlsafe(40)
 fd=os.open(secret,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
 with os.fdopen(fd,'w') as f:f.write(password)
 with tempfile.TemporaryDirectory(dir=root) as temporary:
  temp=pathlib.Path(temporary);key=temp/'key.pem';p12=temp/'identity.p12';conf=temp/'certificate.conf'
  conf.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Drivee QA Local Development\n[ext]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\n')
  run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','3650','-config',str(conf),'-keyout',str(key),'-out',str(certificate)])
  run(['/usr/bin/openssl','pkcs12','-export','-inkey',str(key),'-in',str(certificate),'-out',str(p12),'-passout','pass:'+password])
  run(['/usr/bin/security','create-keychain','-p',password,str(keychain)])
  run(['/usr/bin/security','unlock-keychain','-p',password,str(keychain)])
  run(['/usr/bin/security','import',str(p12),'-k',str(keychain),'-P',password,'-T','/usr/bin/codesign'])
  run(['/usr/bin/security','set-key-partition-list','-S','apple-tool:,apple:','-s','-k',password,str(keychain)])
 (root/'ready').touch(mode=0o600)
password=secret.read_text()
run(['/usr/bin/security','unlock-keychain','-p',password,str(keychain)])
sha=run(['/usr/bin/openssl','x509','-in',str(certificate),'-noout','-fingerprint','-sha1']).decode().strip().split('=')[-1].replace(':','')
requirement='designated => identifier "local.drivee.qadesk" and certificate leaf = H"'+sha+'"'
search=shlex.split(run(['/usr/bin/security','list-keychains','-d','user']).decode())
try:
 run(['/usr/bin/security','list-keychains','-d','user','-s']+search+[str(keychain)])
 run(['/usr/bin/codesign','--force','--sign',sha,'--keychain',str(keychain),'--timestamp=none','--identifier','local.drivee.qadesk','--requirements','='+requirement,sys.argv[1]])
except RuntimeError as error:
 sys.stderr.write(str(error)+'\n');sys.exit(1)
finally:
 run(['/usr/bin/security','list-keychains','-d','user','-s']+search)
print('Приложение подписано постоянным локальным сертификатом.')
