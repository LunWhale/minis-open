#!/usr/bin/env python3
"""[T-ios-unit-test-infra] Proof that a test run did not touch the real Minis data.

  data_guard.py snapshot OUT.json         record the state before / after a run
  data_guard.py diff BEFORE.json AFTER.json START END
                                          compare, audit containermanagerd's log for
                                          [START, END], exit 1 on any finding

What is recorded:
  * the App Group container group.com.openminis.app - every file: size, mtime, sha256;
  * each real app container (MINIS_REAL_CONTAINERS, default the one on this Mac):
    the directory, its metadata plist and Data/ (stat). Its contents are hashed
    too when this process may read them; macOS privacy protection (TCC) usually
    blocks listing another app's Data/, which is recorded as such - the
    containermanagerd audit below is the independent check for that case;
  * the top level of ~/Library/Containers (new containers appear there);
  * ~/Library/Preferences/com.openminis.app*.plist and group.com.openminis.app*.plist.

The containermanagerd audit fails on any line in the window that names the real
app (com.openminis.app, its extensions) or a real container UUID, and on any
App Group request that was APPROVED for the test host.
"""
import glob, hashlib, json, os, re, subprocess, sys, time

HOME = os.path.expanduser('~')
GROUP = os.path.join(HOME, 'Library', 'Group Containers', 'group.com.openminis.app')
CONTAINERS = os.path.join(HOME, 'Library', 'Containers')
REAL = [c for c in os.environ.get('MINIS_REAL_CONTAINERS', '07EF1093-F27E-4130-9741-9766B14510AA').split(',') if c]
HOST_ID = 'com.openminis.MinisTestHost'


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


def stat_entry(path):
    try:
        st = os.lstat(path)
        return {'size': st.st_size, 'mtime_ns': st.st_mtime_ns, 'mode': st.st_mode, 'ino': st.st_ino}
    except OSError as e:
        return {'error': e.strerror}


def tree(root):
    out = {}
    for d, dirs, files in os.walk(root):
        out[os.path.relpath(d, root) + '/'] = stat_entry(d)
        for f in files:
            p = os.path.join(d, f)
            e = stat_entry(p)
            if 'error' not in e and os.path.isfile(p) and not os.path.islink(p):
                try:
                    e['sha256'] = sha256(p)
                except OSError as err:
                    e['sha256'] = 'unreadable: ' + err.strerror
            out[os.path.relpath(p, root)] = e
    return out


def deep_tree_with_timeout(root, seconds=8):
    """List + hash another app's container in a child process: a TCC block can hang."""
    code = 'import sys, json; sys.path.insert(0, %r); import data_guard as g; print(json.dumps(g.tree(%r)))' % (
        os.path.dirname(os.path.abspath(__file__)), root)
    try:
        r = subprocess.run([sys.executable, '-c', code], capture_output=True, text=True, timeout=seconds)
        data = json.loads(r.stdout) if r.returncode == 0 and r.stdout.strip() else None
        # A TCC denial shows up as an empty walk of Data/ rather than as an error.
        if data and len(data) > 1:
            return {'status': 'read', 'files': data}
        return {'status': 'blocked (no entries readable - macOS privacy protection)'}
    except subprocess.TimeoutExpired:
        return {'status': 'blocked (listing timed out - macOS privacy protection)'}


def snapshot(out):
    snap = {'taken_at': time.strftime('%Y-%m-%d %H:%M:%S'), 'group': tree(GROUP) if os.path.isdir(GROUP) else 'absent',
            'real_containers': {}, 'containers_top': {}, 'prefs': {}}
    for c in REAL:
        base = os.path.join(CONTAINERS, c)
        snap['real_containers'][c] = {
            'dir': stat_entry(base),
            'metadata': stat_entry(os.path.join(base, '.com.apple.containermanagerd.metadata.plist')),
            'Data': stat_entry(os.path.join(base, 'Data')),
            'deep': deep_tree_with_timeout(os.path.join(base, 'Data')),
        }
    for name in sorted(os.listdir(CONTAINERS)):
        snap['containers_top'][name] = stat_entry(os.path.join(CONTAINERS, name))
    for p in sorted(glob.glob(os.path.join(HOME, 'Library', 'Preferences', 'com.openminis.app*.plist')) +
                    glob.glob(os.path.join(HOME, 'Library', 'Preferences', 'group.com.openminis.app*.plist'))):
        e = stat_entry(p)
        e['sha256'] = sha256(p)
        snap['prefs'][os.path.basename(p)] = e
    json.dump(snap, open(out, 'w'), indent=1, sort_keys=True)
    g = snap['group']
    print(f'snapshot {out}: group files={sum(1 for k in g if not k.endswith("/")) if isinstance(g, dict) else g}, '
          f'real containers={ {c: v["deep"]["status"] for c, v in snap["real_containers"].items()} }, '
          f'containers={len(snap["containers_top"])}, prefs={len(snap["prefs"])}')


def compare(a, b):
    if a == b:
        return []
    if not isinstance(a, dict) or not isinstance(b, dict):
        return [('changed', '', a, b)]
    out = []
    for k in sorted(set(a) | set(b)):
        if k not in a:
            out.append(('added', k, None, b[k]))
        elif k not in b:
            out.append(('removed', k, a[k], None))
        elif a[k] != b[k]:
            out.append(('changed', k, a[k], b[k]))
    return out


def audit_log(start, end):
    pred = ('process == "containermanagerd" AND (eventMessage CONTAINS[c] "openminis"'
            + ''.join(' OR eventMessage CONTAINS "%s"' % c for c in REAL) + ')')
    r = subprocess.run(['log', 'show', '--style', 'compact', '--start', start, '--end', end, '--predicate', pred],
                       capture_output=True, text=True, timeout=600)
    lines = [l for l in r.stdout.splitlines() if 'containermanagerd' in l]
    bad, host = [], []
    for l in lines:
        names_real = re.search(r'\[com\.openminis\.app[\].]', l) or any(c in l for c in REAL)
        approved_for_host = HOST_ID in l and 'group.com.openminis.app' in l and 'APPROVED' in l
        if names_real or approved_for_host:
            bad.append(l)
        else:
            host.append(l)
    return lines, bad, host


def diff(before_p, after_p, start, end):
    a, b = json.load(open(before_p)), json.load(open(after_p))
    findings = []
    print(f'== data guard: {a["taken_at"]} -> {b["taken_at"]}')
    g = compare(a['group'], b['group'])
    print(f'App Group container group.com.openminis.app: {len(b["group"]) if isinstance(b["group"], dict) else b["group"]} '
          f'entries, {len(g)} differences')
    for kind, k, x, y in g:
        findings.append(f'group {kind}: {k}')
    for c in REAL:
        ra, rb = a['real_containers'][c], b['real_containers'][c]
        d = compare({k: v for k, v in ra.items() if k != 'deep'}, {k: v for k, v in rb.items() if k != 'deep'})
        deep = rb['deep']['status']
        dd = compare(ra['deep'].get('files', {}), rb['deep'].get('files', {})) if deep == 'read' else []
        print(f'real container {c}: dir/metadata/Data stat differences={len(d)}; contents: {deep}'
              + (f', {len(dd)} differences' if deep == 'read' else ''))
        findings += [f'real container {c} {kind}: {k}' for kind, k, x, y in d + dd]
    top = compare(a['containers_top'], b['containers_top'])
    new = [k for kind, k, x, y in top if kind == 'added']
    changed_real = [k for kind, k, x, y in top if kind != 'added' and k in REAL]
    print(f'~/Library/Containers: {len(new)} new ({", ".join(new) or "none"}), real container entry changed: {bool(changed_real)}')
    findings += [f'real container entry changed in ~/Library/Containers: {k}' for k in changed_real]
    p = compare(a['prefs'], b['prefs'])
    print(f'preferences com.openminis.app*/group.com.openminis.app*: {len(b["prefs"])} files, {len(p)} differences')
    findings += [f'prefs {kind}: {k}' for kind, k, x, y in p]
    lines, bad, host = audit_log(start, end)
    print(f'containermanagerd log {start} .. {end}: {len(lines)} lines naming openminis, '
          f'{len(host)} about the test host only, {len(bad)} about the real app / its containers')
    for l in host[:12]:
        print('   host: ' + l[:220])
    findings += ['containermanagerd: ' + l[:240] for l in bad]
    if findings:
        print('DATA GUARD FAILED:')
        for f in findings:
            print('  ' + f)
        return 1
    print('DATA GUARD PASSED: no difference in the real app data, nothing in the system log about the real app.')
    return 0


if __name__ == '__main__':
    if sys.argv[1] == 'snapshot':
        snapshot(sys.argv[2])
    elif sys.argv[1] == 'diff':
        sys.exit(diff(*sys.argv[2:6]))
    else:
        sys.exit(__doc__)
