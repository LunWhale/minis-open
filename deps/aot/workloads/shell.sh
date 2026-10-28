#!/bin/sh
# Workload for recording the musl + busybox AOT images: the shell paths an
# agent's commands actually take (pipelines, loops, find/grep, archives).
set +e
mkdir -p /tmp/wl && cd /tmp/wl
i=0; while [ $i -lt 20000 ]; do i=$((i+1)); done; echo "loop $i"
for n in $(seq 1 200); do echo "line $n alpha beta gamma $((n*7))"; done > data.txt
cat data.txt | grep -v beta | wc -l; grep -c gamma data.txt
awk '{s+=$6} END {print s}' data.txt; sed 's/alpha/ALPHA/g' data.txt | tail -3
cut -d' ' -f2,6 data.txt | sort -k2 -n | uniq | head -5; tr 'a-z' 'A-Z' < data.txt | head -2
sort -r data.txt | head -2; wc -c data.txt; md5sum data.txt; sha256sum data.txt; sha1sum data.txt
ls -la /usr/lib | head; ls -R /etc > /dev/null; du -sh /usr 2>/dev/null
find /usr -name "*.so*" | head -20; find / -xdev -type f -name "*.py" 2>/dev/null | head -50 | wc -l
grep -r "import" /usr/lib/python3.12/json 2>/dev/null | wc -l; grep -rl "require" /usr/lib/node_modules 2>/dev/null | head -5
cp data.txt d2.txt; mv d2.txt d3.txt; rm d3.txt; mkdir -p a/b/c; touch a/b/c/f; rm -rf a
tar czf wl.tgz data.txt; tar tzf wl.tgz; gzip -c data.txt | gunzip | wc -l; rm -f wl.tgz
printf '%s %d\n' foo 42; expr 3 + 4; test -f data.txt && echo ok; date +%s > /dev/null
echo '{"a":[1,2,3]}' | head -c 100; basename /a/b/c.txt; dirname /a/b/c.txt; env | head -3 > /dev/null
ps 2>/dev/null | head -3; id; uname -a; which sh; xargs echo < data.txt | head -c 80; echo
for n in $(seq 1 30); do sh -c 'echo $$ > /dev/null'; done
for n in $(seq 1 10); do echo '{"a":[1]}' | python3 -c "import json,sys; print(json.load(sys.stdin))"; done
python3 -c "import os,re,json,subprocess; print(len(os.listdir('/usr/lib')))"
for n in $(seq 1 5); do node -e "console.log(1)"; done
node -e "const fs=require('fs'); console.log(fs.readdirSync('/usr/lib').length)"
cd / && rm -rf /tmp/wl
