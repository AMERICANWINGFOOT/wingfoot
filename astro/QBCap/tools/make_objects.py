# Build QBCap_objects.txt from the SynScan app's sky object database (skyobj.sqlite).
# usage: python3 make_objects.py skyobj.sqlite QBCap_objects.txt
import sqlite3, sys, math, unicodedata
EPOCH = 2026.8          # proper motion of named stars carried to about now
def asc(s):
    s = unicodedata.normalize('NFKD', s or '').encode('ascii', 'ignore').decode()
    return s.replace('|', '/').strip()
c = sqlite3.connect('file:' + sys.argv[1] + '?mode=ro', uri=True)
const = {i: n for i, a, n in c.execute('select constId, constAbbr, constName_en from tblConstellation')}
names = {i: asc(n) for i, n in c.execute('select idStel, name_en from tblDsoName')}
dso = c.execute('select idStel,idNgc,idIc,idM,idC,j2kRaRad,j2kDecRad,vmag,constId from tblDso').fetchall()
out = []
def add(name, desc, typ, ra_rad, dec_rad, mag):
    out.append('%s|%s|%s|%.6f|%.5f|%.1f' % (name, desc, typ, math.degrees(ra_rad) / 15.0, math.degrees(dec_rad), mag))
def dso_desc(r, skip):
    idStel, ngc, ic, m, cc, ra, de, mag, ci = r
    al = []
    if m and skip != 'M': al.append('M%d' % m)
    if cc and skip != 'C': al.append('C%d' % cc)
    if ngc and skip != 'N': al.append('NGC %d' % ngc)
    if ic and skip != 'I': al.append('IC %d' % ic)
    d = names.get(idStel, '')
    if al: d = (d + ' (' + ', '.join(al) + ')').strip()
    return (d + ', ' + const.get(ci, '')).strip(', ')
def mag(v): return 0.0 if v is None or v >= 90 else v
for r in sorted([r for r in dso if r[3]], key=lambda r: r[3]):
    add('M%d' % r[3], dso_desc(r, 'M'), 'messier', r[5], r[6], mag(r[7]))
for r in sorted([r for r in dso if r[4]], key=lambda r: r[4]):
    add('C%d' % r[4], dso_desc(r, 'C'), 'caldwell', r[5], r[6], mag(r[7]))
stars = c.execute('select name_en,constId,saoJ2kRaRad,saoJ2kDecRad,saoVMag,saoJ2kRaApm,saoJ2kDecApm from tblNamedStar').fetchall()
for n, ci, ra, de, vm, pra, pde in sorted(stars, key=lambda s: s[4]):
    dt = EPOCH - 2000.0
    ra2 = ra + math.radians((pra or 0) * dt * 15.0 / 3600.0)      # s/yr of time
    de2 = de + math.radians((pde or 0) * dt / 3600.0)             # arcsec/yr
    add(asc(n), const.get(ci, ''), 'star', ra2, de2, vm)
for n, ra, de, vm, sep, ci in sorted(c.execute('select name_en,j2kRaRad,j2kDecRad,vmag,sepArcsec,constId from tblDoubleStar'), key=lambda s: asc(s[0]).lower()):
    add(asc(n), '%s  sep %g"' % (const.get(ci, ''), sep), 'double', ra, de, vm)
for r in sorted([r for r in dso if r[1]], key=lambda r: r[1]):
    add('NGC %d' % r[1], dso_desc(r, 'N'), 'ngc', r[5], r[6], mag(r[7]))
for r in sorted([r for r in dso if r[2]], key=lambda r: r[2]):
    add('IC %d' % r[2], dso_desc(r, 'I'), 'ic', r[5], r[6], mag(r[7]))
seen = {}
for i, l in enumerate(out):
    f0 = l.split('|'); seen.setdefault((f0[0], f0[2]), []).append(i)
for (n, _lst), idx in seen.items():
    if len(idx) > 1:
        for k, i in enumerate(idx):
            f = out[i].split('|'); f[0] = '%s %s' % (n, 'abcdefghij'[k]); out[i] = '|'.join(f)
open(sys.argv[2], 'w').write('# QBCap GoTo objects (from the SynScan sky object database)\n# name|description|list|RA hours J2000|Dec deg J2000|mag\n' + '\n'.join(out) + '\n')
print(len(out), 'objects')
