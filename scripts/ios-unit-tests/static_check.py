#!/usr/bin/env python3
"""[T-ios-unit-test-infra] Static guard: tests must not reach real app data.

Scans every .swift file under src/ios/MinisTests/ (XCTest files AND Standalone
scripts, including code they embed in strings and compile later) for APIs that
resolve to real storage. Comment lines are skipped; everything else counts,
because a Standalone script may emit source text that it compiles and runs.

Each remaining hit must be in static-check-allowlist.tsv with a category and a
reason. Entries are keyed by file + a hash of the stripped line, so they follow
the line when code moves and stop matching when the line changes. Exit 1 lists
every unexplained hit as path:line.

  --list   print every hit (allowed or not) with its key, for maintaining the list
"""
import hashlib, os, re, sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
TESTS = os.path.join(ROOT, 'src', 'ios', 'MinisTests')
ALLOW = os.path.join(os.path.dirname(__file__), 'static-check-allowlist.tsv')

PATTERNS = [
    ('ChatStore.shared', re.compile(r'ChatStore\.shared\b')),
    ('UserDefaults.standard', re.compile(r'UserDefaults\.standard\b|NSUserDefaults\.standardUserDefaults\b')),
    ('documentDirectory', re.compile(r'FileManager\.default\.urls\(\s*for:\s*\.documentDirectory')),
    ('Group Containers', re.compile(r'Group Containers')),
    ('containerURL(forSecurityApplicationGroupIdentifier', re.compile(r'containerURL\(\s*forSecurityApplicationGroupIdentifier')),
    # Beyond the required five: the keychain and iCloud are shared with the real app too.
    ('SecItem', re.compile(r'\bSecItem(Add|Update|Delete|CopyMatching)\b')),
    ('CloudKit container', re.compile(r'\bCKContainer\s*\(|CKContainer\.default\(')),
]

def key(rel, line):
    return rel + '\t' + hashlib.sha1(line.strip().encode()).hexdigest()[:16]

def hits():
    out = []
    for d, _, fs in os.walk(TESTS):
        for f in sorted(fs):
            if not f.endswith('.swift'):
                continue
            path = os.path.join(d, f)
            rel = os.path.relpath(path, ROOT)
            in_block = False
            for n, line in enumerate(open(path, encoding='utf-8', errors='replace'), 1):
                t = line.strip()
                if in_block:
                    if '*/' in t:
                        in_block = False
                    continue
                if t.startswith('/*') and '*/' not in t:
                    in_block = True
                    continue
                if t.startswith('//') or t.startswith('*'):
                    continue
                for name, rx in PATTERNS:
                    if rx.search(line):
                        out.append((rel, n, name, line.rstrip('\n')))
    return out

def allowlist():
    allowed = {}
    if not os.path.exists(ALLOW):
        return allowed
    for ln in open(ALLOW, encoding='utf-8'):
        if not ln.strip() or ln.startswith('#'):
            continue
        parts = ln.rstrip('\n').split('\t')
        if len(parts) < 4 or not parts[3].strip():
            sys.exit(f'allowlist entry without a reason: {ln!r}')
        allowed[parts[0] + '\t' + parts[1]] = (parts[2], parts[3])
    return allowed

def main():
    allowed = allowlist()
    hs = hits()
    if '--list' in sys.argv:
        for rel, n, name, line in hs:
            k = key(rel, line)
            print(f'{k}\t{allowed.get(k, ("-", ""))[0]}\t{rel}:{n}\t[{name}]\t{line.strip()[:120]}')
        return 0
    bad = [(rel, n, name, line) for rel, n, name, line in hs if key(rel, line) not in allowed]
    used = {key(rel, line) for rel, n, name, line in hs}
    stale = [k for k in allowed if k not in used]
    print(f'static check: {len(hs)} hits, {len(hs) - len(bad)} allowlisted, {len(bad)} unexplained, {len(stale)} stale allowlist entries')
    for rel, n, name, line in bad:
        print(f'  FORBIDDEN {rel}:{n} [{name}] {line.strip()[:140]}')
    for k in stale:
        print(f'  stale allowlist entry (line changed or removed): {k}')
    return 1 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
