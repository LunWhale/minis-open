# AOJIT images

`aot_<name>.S` files here are AOT images for the iSH ARM64 JIT: the
translations of one guest module, recorded ahead of time and linked into the
app (`deps/build_aot.sh` → `deps/libs/libish_aot.a`, force-loaded by the Minis
target). The app turns them on with **Rootfs Management → AOJIT** (off by
default); `libish` is built AOT-only (`-Djit=true -Djit_emit=false`), so
nothing is translated at run time and no executable memory is mapped.

The `.S` files are gitignored — together they are ~1 GB of assembly. Put them
back here before running `deps/build_ish.sh` (or `deps/build_aot.sh` alone);
without them the app still builds, with an empty `libish_aot.a`.

## Images

ish: `deps/ish` at `75da01ca` (ish-arm64 feat/aot-family-match `df9484e6` merged with
the local fakefs commit `7cbfc56c`; JIT_CODE_VERSION 8), abi `1f3bb5a0`. An image loads only into an ish with
the same abi (`cat /proc/ish/jit`); any other ish lists it as `rejected` -
**images and deps/ish must move together**: new-format images on an older
ish (or the reverse) all show `rejected` and the app runs without AOT.

**Re-recorded for abi `1f3bb5a0` (2026-10-05).** The JIT change in ish
`88f7680b` (one range check per TLB lookup, cycles counted on backward edges
and rets) bumped JIT_CODE_VERSION 7 -> 8, which rejects every abi `97963b7f`
image, so all 25 were recorded again by ish-arm64 into
`benchmark/aojit/images/1f3bb5a0/minis/`.
The bundled-rootfs modules (musl r8, busybox r8, zlib r2, libcrypto/libssl
3.3.2-r4) were recorded on a rootfs with exactly these build-ids; the `apk add`
ones on what a fresh `apk add` installs that day. Only python3 and its 10
lib-dynload modules changed version (3.12.14 -> 3.12.15, new build-ids); every
other build-id is the same as before. Hit rates on the AOJIT suite are 85-100%
except libjpeg (55.7%: Pillow's thumbnail decode path is not in
`pil_train.sh`) and, in ish-arm64's copies, libssl under node's https (31%;
python TLS is 99.9%). libcrypto, libssl and pcre2 were then recorded again
here, the way they were first made (see "recorded here" below), because
ish-arm64's copies had been recorded without py3-requests: `agent_cold.sh`
(certificate-verifying HTTPS through `requests`) prints FAIL and goes on, so
the handshake and verification paths were missing - libssl 900 translations,
16-17% on real HTTPS. Recorded here: libcrypto 19316 / libssl 7327 / pcre2
5138 translations; on the virtual iPhone libssl 99% (python https) / 96%
(node https), libcrypto 94-98%, pcre2 99%. ish-arm64 measured abi `1f3bb5a0` against `97963b7f`
on the same images at 4-18% faster. github-cli (`gh`, 456 MB `.S`) was
recorded too but is not carried here.

**Compact table format (abi `97963b7f`, 2026-09-27).** Same native code as
the abi `daf8fcc7` images byte for byte (the `__ish_aot` sections of all 25
objects compare equal); only the tables changed: `aot_trans`, `aot_seg` and
the per-unit gadget table hold 32-bit self-relative offsets instead of
64-bit absolute pointers (`aot_trans` 72 -> 48 bytes), and keys drop the
words that are always 0 in an image (per unit 9 -> 6). The linker resolves
the offsets, so dyld has almost nothing to rebase at launch. Produced by
ish-arm64's `tools/jit_aot/compact.py` from the daf8fcc7 set; build-ids,
families and file names are unchanged.

**grep/find re-recording (2026-09-28).** busybox and musl were re-recorded by
ish-arm64 `479714eb` (feat/aot-family-match) with `guest/busybox/grep_train.sh`
and `find_train.sh` added to the training set: busybox 6224 -> 6559
translations, musl 3858 -> 4807. Same build-ids, abi and symbols as before, so
it is a drop-in swap; ish-arm64 measured grep 134.3 s -> 99.7 s (AOT hit
86.9% -> 99.6%) and find 6.7 s -> 5.8 s (93.3% -> 99.7%). Source files:
ish-arm64 `benchmark/aojit/images/97963b7f/minis-grepfind/S/` (gitignored
there too); the assembled objects match its `minis-grepfind/ios/*.o` byte for
byte.

**One image per module, family matching for other versions.** An image runs
fully on the build it was recorded from (matched by **build-id**). It also
serves other versions of its module: the file name matches the image's
**family** pattern (fnmatch, written by gen.py: `libz.so.1.3.1` ->
`libz.so.1*`), blocks whose code did not change are found by content and run
from the image, the rest is emulated (ish-arm64 measured 51-93% of the exact
image's gain on other versions, 0-3.6% cost on the exact one). So each module
carries ONE image, not one per version; the build picked is the one most users
have: the bundled rootfs for core packages, what `apk add` installs today for
the rest.

| Image | Guest module | Recorded from (Alpine 3.21) | Family | build-id | Source |
|---|---|---|---|---|---|
| `aot_musl_1.2.5-r8.S` | `/lib/ld-musl-aarch64.so.1` | `musl-1.2.5-r8` (bundled rootfs) | `ld-musl-aarch64.so.1*` | `384940f9110e809da953d6fbabcb31d297c217b5` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_busybox_1.37.0-r8.S` | `/bin/busybox` | `busybox-1.37.0-r8` (bundled rootfs) | `busybox` | `2f8b429ec88eacccb94c8bb23ec060ab4a028ee8` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_zlib_1.3.1-r2.S` | `/usr/lib/libz.so.1.3.1` | `zlib-1.3.1-r2` (bundled rootfs) | `libz.so.1*` | `0b23d104a896ab2e7e3a8144b70175fb3ce8cbd9` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_libcrypto_3.3.2-r4.S` | `/usr/lib/libcrypto.so.3` | `libcrypto3-3.3.2-r4` (bundled rootfs) | `libcrypto.so.3*` | `1dcac613c1f6b724c56844356ad82a8c97ff401a` | recorded here (2026-10-05), `tls_train.sh` on rootfs A + py3-requests |
| `aot_libssl_3.3.2-r4.S` | `/usr/lib/libssl.so.3` | `libssl3-3.3.2-r4` (bundled rootfs) | `libssl.so.3*` | `d0b98a4924a7a7dcc3f3f31dc5645db6ffd4fd9c` | recorded here (2026-10-05), `tls_train.sh` on rootfs A + py3-requests |
| `aot_python3_3.12.15-r0.S` | `/usr/lib/libpython3.12.so.1.0` | `python3-3.12.15-r0` (`apk add`) | `libpython3.12.so.1*` | `d644d658076939b92edde6d007ef8bf491fec5a3` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_nodejs_22.23.2-r0.S` | `/usr/bin/node` | `nodejs-22.23.2-r0` (`apk add`) | `node` | `c324f04a6d01b07f6858cc8ef1da4d6d3656daa3` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_sqlite_3.48.0-r4.S` | `/usr/lib/libsqlite3.so.0.8.6` | `sqlite-libs-3.48.0-r4` (with python3) | `libsqlite3.so.0*` | `0cd2f33152f67d2b77c8468184bbe0cef1d7e7f2` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_pillow_11.0.0-r0.S` | `/usr/lib/python3.12/site-packages/PIL/_imaging.cpython-312-aarch64-linux-musl.so` | `py3-pillow-11.0.0-r0` (`apk add`) | same file name | `4c527f1dd53c539fadb6e761f32fe1c97453f94e` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_libwebp_1.4.0-r0.S` | `/usr/lib/libwebp.so.7.1.9` | `libwebp-1.4.0-r0` (`apk add`) | `libwebp.so.7*` | `8ef75205b20db80a13c5a7cc73c4010bf5ee4d6f` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_libjpeg_3.0.4-r0.S` | `/usr/lib/libjpeg.so.8.3.2` | `libjpeg-turbo-3.0.4-r0` (`apk add`) | `libjpeg.so.8*` | `18c1b17b04d907c6774bf76263b9fa42e9408db8` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_numpy_2.1.3-r0.S` | `/usr/lib/python3.12/site-packages/numpy/_core/_multiarray_umath.cpython-312-aarch64-linux-musl.so` | `py3-numpy-2.1.3-r0` (`apk add`) | same file name | `04b4971c8e52a43f5c0608f64d7b13207b8c1c3e` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_pcre2_10.43-r0.S` | `/usr/lib/libpcre2-8.so.0.12.0` | `pcre2-10.43-r0` (with git / grep) | `libpcre2-8.so.0*` | `2a7cfd13f571d133069bf15c8e869ba13d2a4c5f` | recorded here (2026-10-05), `pcre_train2.sh` on rootfs A + git + ripgrep |
| `aot_ssh_9.9_p2-r0.S` | `/usr/bin/ssh` | `openssh-client-default-9.9_p2-r0` (`apk add`) | `ssh` | `df1649582b7a74dc596ffcb440391796995dd202` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_scp_9.9_p2-r0.S` | `/usr/bin/scp` | `openssh-client-common-9.9_p2-r0` (`apk add`) | `scp` | `cbc5234e3d96db92e8acd726e6743ec76b66e03d` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_json_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/_json.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `a1d82af66c4470aa6cac49ca772927a2995ed297` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_hashlib_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/_hashlib.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `97a005a1b066e6bd4158eb271132e1b38c1be8cb` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_blake2_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/_blake2.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `f4f542cf566ffe62953373b6e54602f614df6951` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_struct_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/_struct.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `6cfef1a2458b6dcc2f396ec8f2b9d9ebb771bba1` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_datetime_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/_datetime.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `e361da74dd7d72b332863d47c2dfe3f52026d916` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_binascii_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/binascii.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `dd90d3e7366c8149d54e58c13669f05e76e48e60` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_math_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/math.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `67f6d6a06bb8f7453d482c52f6ef4bc6fb720937` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_zlib_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/zlib.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `fad09a48ab85c708fbd9bc458f4b1ac1ed129055` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_socket_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/_socket.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `d3f34d4d8f288f9f9324bf303dc3b25c8969b533` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |
| `aot_py_select_3.12.15-r0.S` | `/usr/lib/python3.12/lib-dynload/select.cpython-312-aarch64-linux-musl.so` | `python3-3.12.15-r0` (`apk add`) | same file name | `109bd4dae0f995d654c1e0b4346eba111c6aa8c1` | ish-arm64 `1f3bb5a0/minis/` (2026-10-05) |

**Provenance (2026-09-26).**
- "ish-arm64 set": `benchmark/aojit/images/daf8fcc7/`
  (same ish commit, `latest/` and `old/`, see its `COOKBOOK.md` and
  `benchmark/aojit/images.json` for the workloads). Symbols renamed here to
  `<package>_<version>_r<rel>`. Every build-id was checked against the
  official Alpine 3.21 package (or the bundled rootfs), the family pattern
  and abi read from each header.
- "recorded here": the ish-arm64 set has only OpenSSL 3.3.7-r1 and no PCRE2,
  so libcrypto / libssl 3.3.2-r4 (what the bundled rootfs and `apk add`
  users have) and pcre2 10.43-r0 were recorded with a CLI ish from the same
  commit (`-Djit=true`, `ISH_JIT_PIC=1`, abi `daf8fcc7`) and the new gen.py,
  using ish-arm64's workloads (`tls_train.sh` on rootfs A + py3-requests, one
  library per run because it binds fixed loopback ports; `pcre_train2.sh` with
  its sample git repo on rootfs A + git + ripgrep).
- node (2026-10-01): re-recorded by ish-arm64 at `4e0332e3` (abi `97963b7f`
  unchanged) in ish's default node mode, from
  `benchmark/aojit/images/97963b7f/minis-node/`.
  The node image must match the mode node runs in: the kernel's default mode
  (V8 compilers off, the interpreter AOT-translated); with the
  `ISH_NODE_MODE=jitless` fallback its hit rate roughly halves.
- Batch 2 (2026-09-27), from the same ish-arm64 set (`latest/`, recorded at
  `a5ba2e85`, abi unchanged): ssh, scp and 10 Python lib-dynload modules,
  chosen from nine shell usage reports (ssh/scp and `python3 -c` are the
  most frequent commands). Every build-id was checked here against the file
  `apk add` installs on Alpine 3.21 (openssh 9.9_p2-r0, python3 3.12.14-r0);
  the renamed copies differ from ish-arm64's `.S` only in the module symbol.
  ish-arm64's `latest/` crypto/ssl images are OpenSSL 3.3.7 and it has no
  PCRE2, so ours (3.3.2-r4, pcre2) stay: 25 images.
- Recorded but not carried (measured on an iPhone 11, AOT on with vs without
  the image): ripgrep 14.1.1 (`rg`) gained 3-6% wall time for 22 MB of
  binary (58% of batch 2's size) - rg spends its time in file system calls
  no image can speed up; Python `_ssl` gained 1% (the handshake runs in
  libcrypto, which has its own image).
- Not carried any more (family matching serves them): musl r11, busybox
  r14, zlib 1.3.2, OpenSSL 3.3.7, python 3.12.12. The abi `807b8b99` images
  of the previous ish are obsolete.
- Notes kept from earlier rounds: WebP / JPEG gain less (NEON, not translated
  yet); PCRE2 only helps `git grep -P`, GNU `grep -P`, `rg -P` (ripgrep's
  default engine and jq, which links oniguruma, do not use it); shared
  libraries are reached through a soname link, which fakefs stores as a small
  file holding its target, so the app's probe follows it by hand.

**Maintenance.** Package upgrades no longer switch an image off: a new build
falls back to family matching (partial gain). An image goes fully stale only
when the file name leaves its family (a soname bump, e.g. `libssl.so.4`) or
the ish abi changes; then it is `rejected` or shows "No image". Re-record when
the build most users have changes (a new bundled rootfs, a new Alpine release)
to get full speed back, most often for OpenSSL, which gets frequent security
updates.

The app's AOJIT screen lists the same table (`AOJITImage.catalog` in
`src/ios/Views/Rootfs/AOJITSettingsView.swift`); keep the two in sync when an
image changes. `MinisTests/Standalone/AOJITTests.swift` checks them against each
other and against the headers of the images present here.

## Recording list

How each image above is recorded. `Module` is what `ISH_JIT_RECORD_MOD`
matches (a substring of the module's file); the workload is the guest script
that one recording run executes.

- **`record.sh`** rows come from ish-arm64's AOJIT suite in `deps/ish`
  (`benchmark/aojit/`, see its README; the entry names are the keys of its
  `images.json`): `install.sh <ish> <rootfs>` copies the workloads to
  `/tmp/aojit` and makes their inputs, then
  `tools/jit_aot/record.sh <ish> <rootfs> /tmp/aojit/<workload> deps/aot/<image> <module>`
  records one image. Name the output after the Image column: the symbol
  `_ish_aot_module_<name>` is taken from the file name.
- **`record_local.sh`** rows are recorded by `tools/record_local.sh` on the
  app's own rootfs (`deps/resources/alpine-rootfs.zip`): it builds the
  recorder from `deps/ish`, installs what the workloads need
  (`python3 py3-requests git ripgrep`), makes the TLS certificates on the
  host and stops on any gate (abi, OpenSSL version, FAIL in a dry run, too
  few translations).

The recorder is a CLI ish built from the same `deps/ish` commit as the app
(`-Djit=true`, run with `ISH_JIT_PIC=1`), and the rootfs must hold the module
with the build-id in the table above - the bundled rootfs for core packages,
a fresh `apk add` for the rest (`images.json` lists the packages). With
another build of the module the image still works through family matching,
at partial speed.

| Image | Recorded with | Module | Workload |
|---|---|---|---|
| `aot_musl_1.2.5-r8.S` | `record.sh` (`musl`) | `ld-musl` | `deps/ish/benchmark/aojit/guest/shell/musl_train.sh` |
| `aot_busybox_1.37.0-r8.S` | `record.sh` (`busybox`) | `/bin/busybox` | `deps/ish/benchmark/aojit/guest/busybox/busybox_train.sh` |
| `aot_zlib_1.3.1-r2.S` | `record.sh` (`zlib`) | `libz.so` | `deps/ish/benchmark/aojit/guest/zlib/zlib_train.sh` |
| `aot_libcrypto_3.3.2-r4.S` | `tools/record_local.sh libcrypto` | `libcrypto.so` | `deps/ish/benchmark/aojit/guest/net/tls_train.sh` |
| `aot_libssl_3.3.2-r4.S` | `tools/record_local.sh libssl` | `libssl.so` | `deps/ish/benchmark/aojit/guest/net/tls_train.sh` |
| `aot_python3_3.12.15-r0.S` | `record.sh` (`python`) | `libpython3.12` | `deps/ish/benchmark/aojit/guest/py/python_train.sh` |
| `aot_nodejs_22.23.2-r0.S` | `record.sh` (`node`) | `/usr/bin/node` | `deps/ish/benchmark/aojit/guest/node/node_train.sh` |
| `aot_sqlite_3.48.0-r4.S` | `record.sh` (`sqlite`) | `libsqlite3.so` | `deps/ish/benchmark/aojit/guest/net/sqlite_train.sh` |
| `aot_pillow_11.0.0-r0.S` | `record.sh` (`imaging`) | `PIL/_imaging.cpython` | `deps/ish/benchmark/aojit/guest/pil/pil_train.sh` |
| `aot_libwebp_1.4.0-r0.S` | `record.sh` (`webp`) | `libwebp.so` | `deps/ish/benchmark/aojit/guest/pil/pil_train.sh` |
| `aot_libjpeg_3.0.4-r0.S` | `record.sh` (`jpeg`) | `libjpeg.so` | `deps/ish/benchmark/aojit/guest/pil/pil_train.sh` |
| `aot_numpy_2.1.3-r0.S` | `record.sh` (`numpy`) | `_multiarray_umath` | `deps/ish/benchmark/aojit/guest/doc/numpy_train.sh` |
| `aot_pcre2_10.43-r0.S` | `tools/record_local.sh pcre2` | `libpcre2-8.so` | `workloads/pcre_train.sh` |
| `aot_ssh_9.9_p2-r0.S` | `record.sh` (`ssh`) | `/usr/bin/ssh` | `deps/ish/benchmark/aojit/guest/ssh/ssh_train.sh` |
| `aot_scp_9.9_p2-r0.S` | `record.sh` (`scp`) | `/usr/bin/scp` | `deps/ish/benchmark/aojit/guest/ssh/ssh_train.sh` |
| `aot_py_json_3.12.15-r0.S` | `record.sh` (`pyjson`) | `lib-dynload/_json.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_hashlib_3.12.15-r0.S` | `record.sh` (`pyhashlib`) | `lib-dynload/_hashlib.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_blake2_3.12.15-r0.S` | `record.sh` (`pyblake2`) | `lib-dynload/_blake2.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_struct_3.12.15-r0.S` | `record.sh` (`pystruct`) | `lib-dynload/_struct.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_datetime_3.12.15-r0.S` | `record.sh` (`pydatetime`) | `lib-dynload/_datetime.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_binascii_3.12.15-r0.S` | `record.sh` (`pybinascii`) | `lib-dynload/binascii.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_math_3.12.15-r0.S` | `record.sh` (`pymath`) | `lib-dynload/math.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_zlib_3.12.15-r0.S` | `record.sh` (`pyzlib`) | `lib-dynload/zlib.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_socket_3.12.15-r0.S` | `record.sh` (`pysocket`) | `lib-dynload/_socket.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |
| `aot_py_select_3.12.15-r0.S` | `record.sh` (`pyselect`) | `lib-dynload/select.cpython-312` | `deps/ish/benchmark/aojit/guest/pyext/pyext_train.sh` |

## Re-recording (after an ish or package upgrade)

```sh
# 1. a CLI ish with the emitting JIT, from the same deps/ish commit as libish
meson setup /tmp/ish-rec -Dguest_arch=arm64 -Dengine=asbestos -Dkernel=ish -Djit=true -Db_ndebug=true --buildtype=release
ninja -C /tmp/ish-rec            # run twice if main.c misses the generated offsets
ISH_JIT_PIC=1 /tmp/ish-rec/ish -f <rootfs> /bin/sh -c 'grep abi /proc/ish/jit'   # must print the app's abi
# 2. the rootfs the app ships (fakefs format). It has no resolv.conf: add one
#    before any apk command.
unzip -q deps/resources/alpine-rootfs.zip -d /tmp/rec-A
/tmp/ish-rec/ish -f /tmp/rec-A/alpine-rootfs /bin/sh -c \
    'echo nameserver 223.5.5.5 > /etc/resolv.conf; apk update; apk add python3 py3-pillow'
# 3. record one module per run (ISH_JIT_PIC=1 is what gives the app's abi),
#    then generate the image (gen.py writes the family pattern and the
#    content table itself)
ISH_JIT_PIC=1 ISH_JIT_RECORD=/tmp/rec ISH_JIT_RECORD_MOD=libz.so \
    /tmp/ish-rec/ish -f /tmp/rec-A/alpine-rootfs /usr/bin/python3 -c "$(cat deps/aot/workloads/pillow.py)" 2
python3 deps/ish/tools/jit_aot/gen.py /tmp/rec /tmp/ish-rec/ish /tmp/rec-A/alpine-rootfs/data \
    deps/aot/aot_zlib_1.3.1-r2.S --name zlib_1_3_1_r2
```

`ISH_JIT_RECORD_MOD` is a substring of the module's real file: use one nothing
else contains (`libz.so`, not `libz`, which also matches libzstd). The other
workloads are in `deps/ish/benchmark/aojit/guest/` (see `images.json`).

**Naming.** `aot_<package>_<version>-r<rel>.S`, symbol
`_ish_aot_module_<package>_<version>_r<rel>` (dots as `_`). Then update the
table above and `AOJITImage.catalog` (build-id, package, family), and run
`deps/build_aot.sh`.
