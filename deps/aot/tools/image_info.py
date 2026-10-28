#!/usr/bin/env python3
"""[T-aojit-sync] Read the header of AOJIT images (aot_*.S): module path, family,
build-id, abi and symbol. The header sits at the end of the file.

  image_info.py deps/aot                      table of every image here
  image_info.py --json DIR_OR_FILES...        machine-readable
  image_info.py --map OLD_DIR NEW_DIR         old -> new build-id per module path
                                              (what the catalog / tests / README need)

The abi printed is the 32-bit word gen.py writes after the build-id (e.g.
1f3bb5a0 = 524006816); it must equal `grep abi /proc/ish/jit` of the ish the
app links, or every image is rejected.
"""
import json, os, re, sys

def info(path):
    size = os.path.getsize(path)
    with open(path, 'rb') as f:
        f.seek(max(0, size - 300000))
        t = f.read().decode('utf-8', 'replace')
    sym = re.search(r'\.globl (_ish_aot_module_\w+)\n\1:\n(.*?)\n\s+\.p2align', t, re.S)
    fam = re.search(r'Lfamily:\n\s+\.asciz "([^"]*)"', t)
    mod = re.search(r'Lpath:\n\s+\.asciz "([^"]*)"', t)
    out = {'file': os.path.basename(path), 'size': size, 'symbol': None, 'module': mod and mod.group(1),
           'family': fam and fam.group(1), 'build_id': None, 'abi': None, 'translations': None}
    if sym:
        out['symbol'] = sym.group(1)
        body = sym.group(2)
        m = re.search(r'\.long 20, \d+, \d+, (\d+)', body)
        if m: out['abi'] = '%08x' % int(m.group(1))
        m = re.search(r'\.long (\d+), \d+\n\s+\.quad Ltrans', body)
        if m: out['translations'] = int(m.group(1))
        m = re.search(r'\.long 20\n\s+\.byte ([\d, ]+)', body)
        if m: out['build_id'] = ''.join('%02x' % int(x) for x in m.group(1).split(','))
    return out

def collect(args):
    files = []
    for a in args:
        files += sorted(os.path.join(a, f) for f in os.listdir(a) if f.startswith('aot_') and f.endswith('.S')) if os.path.isdir(a) else [a]
    return [info(f) for f in files]

def main():
    a = sys.argv[1:]
    if not a or a[0] in ('-h', '--help'):
        sys.exit(__doc__)
    if a[0] == '--map':
        old = {i['module']: i for i in collect([a[1]])}
        for n in collect([a[2]]):
            o = old.get(n['module'])
            state = 'new' if not o else ('same' if o['build_id'] == n['build_id'] else 'CHANGED')
            print('\t'.join([state, n['module'] or '?', o['file'] if o else '-', n['file'],
                             o['build_id'] if o else '-', n['build_id'] or '-(no build-id)']))
        return
    if a[0] == '--json':
        print(json.dumps(collect(a[1:]), indent=1)); return
    for i in collect(a):
        print(f"{i['file']:38} abi {i['abi']}  {i['translations'] or '?':>7} tr  {i['build_id'] or '-(no build-id)':40}  {i['module']}")

if __name__ == '__main__':
    main()
