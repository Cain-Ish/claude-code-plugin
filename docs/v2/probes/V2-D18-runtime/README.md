# V2-D18 runtime probe

The hook contract measured on Windows against P2's full map (14,119 entries in 189 Markdown map files). The check,
the three attempts and the lock are in [`DECISIONS.md`](../../DECISIONS.md) under V2-D18.

- `lib.mjs`: the hook library, self-contained. It holds the cache, the keyed lookup and the guards every delivery
  carries: D16's re-find and D14's label on uncommitted entries.
- `hooks.mjs`: one script per event, run as `node hooks.mjs <session-start|on-read|on-write|deliver30>` (exec
  form). `deliver30` exists for the bench only.
- `bench.mjs`: the bench. Each mode writes counts only to `results/`:
  - `build`: renders the map into a worktree of the scratch clone and asserts that the library's copies equal their
    originals;
  - `load`: the hooks against the empty-Node floor in paired blocks, at 1 and 8 concurrent;
  - `checks`: labels, boundary, nested converter and missing runtime (`--local` runs the first two only);
  - `nonode`: the session-start wrapper with `node` off `PATH`.

| Attempt | Load | Checks | Result |
|---|---|---|---|
| 1 | [load-a1.json](results/load-a1.json) | not run | fail: an empty Node process already exceeds the absolute bar |
| 2 | [load-a2.json](results/load-a2.json) | [checks-a2.json](results/checks-a2.json) | fail: session start had 13 errors and 139 ms added |
| 3 | [load-a3.json](results/load-a3.json) | [checks-a3.json](results/checks-a3.json), [nonode-a3.json](results/nonode-a3.json) | pass |

To run it, the private test-bed config (`research/raw/d20-stage2.json`, gitignored) and the scratch clone of P2 are
needed:

    node bench.mjs build  <config> <bench-dir>
    node bench.mjs load   <config> <bench-dir> 200
    node bench.mjs checks <config> <bench-dir> [--local]
    node bench.mjs nonode <config> -
