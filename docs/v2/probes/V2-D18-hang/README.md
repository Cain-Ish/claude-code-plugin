# N5: the macOS self-test hang

The registration, the arms and how the result is read are in [06](../../06-first-slice.md), section 4, "4a: the
diagnosis probe". D18 holds the observation.

- `probe.mjs <calls per arm> <out dir>`: seven arms that call the `bash` hook, or a child that only reads its input,
  in turn, each call limited to 15 seconds. It writes `results.json` and `timeouts.txt`.
- `watch.mjs <out dir>`: runs beside the probe or the self-test on macOS. It captures `ps`, `lsof` and `sample` of any
  hook still alive after 5 seconds.
- Both run in `.github/workflows/v2-n5.yml`.
