#!/bin/sh
# Workload for recording the PCRE2 AOT image: git grep -P, git log -P and
# rg -P with lookarounds, classes and backreferences, the regex paths agents
# reach through git and ripgrep (needs python3, git and ripgrep).
#
# The sample repository is built here from Python's standard library: one
# import commit, then five refactor rounds that each rewrite the comments of
# ten files, so `git log -P` has history to search.
R=/tmp/pcre-repo
rm -rf $R && mkdir -p $R && cd $R || { echo "FAIL pcre: no $R"; exit 1; }
src=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["stdlib"])')
( cd "$src" && find . -name '*.py' ! -path './site-packages/*' ! -path './test/*' ! -path '*/tests/*' ! -path '*/__pycache__/*' |
    tar cf - -T - ) | tar xf -
g() { git -c user.name=agent -c user.email=agent@example.invalid "$@"; }
g init -q && g add -A && g commit -qm 'import stdlib' || { echo "FAIL pcre: sample repo"; exit 1; }
for n in 1 2 3 4 5; do
    files=$(git ls-files '*.py' | awk -v n=$n 'NR % 53 == n * 7' | head -10)
    sed -i "s/^# /#$n /" $files
    g commit -qam "refactor round $n (fixes #20$n)"
done
echo "sample repo: $(git ls-files | wc -l) files, $(git rev-list --count HEAD) commits"

for p in 'def\s+\w+\(self(?=,|\))' '(?<=import )\w+' '\b(\w+)\s*=\s*\1\b' '(?i)error|warn(ing)?' 'raise\s+[A-Z]\w+Error\((?!\))' '^\s*#\d?\s+TODO' '"[^"\\]*(?:\\.[^"\\]*)*"' '\d{2,}\.\d+'; do
    git grep -P -c "$p" > /dev/null
    rg -P -c "$p" . > /dev/null
    rg -P -o -N "$p" email json > /dev/null
done
git log -P --grep='fix(es)?\s+#\d+' --oneline > /dev/null
git log -P --grep='^(add|refactor)\b.*(?<!s)$' --format=%s > /dev/null
git grep -P -n -i 'class\s+\w+(?:Error|Exception)\b' > /dev/null
rg -P -U 'def \w+\([^)]*\n[^)]*\)' -c . > /dev/null
cd / && rm -rf $R
echo pcre-train-ok
