# Contributing

This is a fork of [OpenMinis](https://github.com/OpenMinis/OpenMinis). It is
a normal GitHub repository: issues and pull requests are both welcome.

## Opening a PR

1. Fork this repository (or use a branch if you have push access).
2. Make your change, add a test where it makes sense.
3. Open a PR against `main`. Keep it focused — one concern per PR.

The build is unusual (it compiles iSH, FFmpeg, LAME and an Alpine rootfs from
source), so if your change touches the sandbox or the native toolchain, read
[BUILDING.md](BUILDING.md) first and note in the PR what you actually ran.

## Filing an issue

- **Bug**: platform and version (Settings → About), what you expected, what
  happened instead, steps to reproduce, and the model/provider if relevant.
- **Feature**: describe the workflow you want, not the implementation. The
  extension system (`.minisx` bundles) may already cover it without touching
  the app — check `docs/extensions.md` first.

## Provenance note

This fork was almost entirely built by **deepseek-v4-flash** (a third-party
model accessed through a relay/proxy) driving the **pi-agent** coding harness.
If you contribute, your changes will sit alongside that history — see
[CHANGELOG.md](CHANGELOG.md) for the record.

## License

GPLv3. Fork it, modify it, run your own build — see
[BUILDING.md](BUILDING.md). If you distribute a build, you must publish its
source under GPLv3.
