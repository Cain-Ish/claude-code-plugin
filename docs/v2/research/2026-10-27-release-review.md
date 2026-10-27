# Release review of 2.0.0-alpha.0 (2026-10-27)

**What ran,** by the user's go (2026-10-27):
- the devils-advocate workflow (`.claude/workflows/devils-advocate.js`): 5 lenses, then a refute-first verifier for
  each finding. 47 agents ran. 42 findings were raised; 22 survived refutation and 20 were dismissed;
- Gemini 4 Argon, through the Antigravity CLI (rule 10): a 10 KB brief of public text, holding the README verbatim
  and a summary of the records. It took 4 minutes. Its verdict: "nothing blocks".

Both reviewed the release candidate at commit `4c5527b` (plugin `61964f9bbb40`). Rule 8 sets the disposition: each
surviving finding either fires a named reopen trigger, or is fixed or recorded as an accepted risk. Nothing re-argues a
lock without a trigger.

## The workflow's 22 survivors, as 14 issues

Severity is the verifier's. Four survivors are medium (#1, #2 and #5, #3 and its duplicates, #4); the rest are low.

| # | Issue (survivors) | What fires | Disposition |
| --- | --- | --- | --- |
| I1 | A session started in a repo subdirectory takes that directory as the root. The index covers the subtree only, and a read of the root's map file gets no label. With a project-scope install, the plugin does not load from a subdirectory at all: a live probe on CLI 2.1.311 found that root project settings do not apply there (1) | D18's "an uncommitted entry arrives unlabelled"; D14's "an injected entry is ever delivered without the unreviewed label" | **Fix:** the hooks take the git toplevel (the nearest folder holding `.git`) as the root. The README says project and local installs load only when Claude starts at the repo root |
| I2 | The session-start text has no guard for Claude Code's 10,000-character cap on hook output. An index past about 8,880 B (roughly 300 one-document directories) collapses to a file path and a 2,000-character preview, which drops most of the index and D23's line (2, 5) | D22's size trigger: an index past P2's that was never measured | **Fix:** the index is cut at a directory to fit, with a line that says so, and onboarding warns. A live probe checks both the cliff and the cut. The README states it as a known issue |
| I3 | The install route follows the moving branch `#v2`; nothing checks that what installs hashes to what was measured; and the version `2.0.0-alpha.0` contradicts V2-D05, which starts v2 at `2.0.0-alpha.1` (3, 6, 8, 18) | D05 as written | **Fix:** version `2.0.0-alpha.1`. A self-test assertion pins the product hash, so a product change fails CI until the record moves with it. The README installs from the tag `#v2.0.0-alpha.1` |
| I4 | One unreadable cited source (a locked or permission-denied file) makes `labels()` throw. The read hook exits 1 with no output, so every entry of that map file reaches Claude unlabelled. Reproduced on Windows (4) | D18's and D14's unlabelled triggers | **Fix:** a source that cannot be read gets its own label, and any error in the read hook gives a file-level fail-closed label |
| I5 | The README leaves out Git Bash, which the shell-form session-start hook needs on Windows (7, 10, 22) | none | **Fix:** README requirements |
| I6 | The README promises that every read is labelled, but reads by subagents, Grep and Bash are not (04, D12 build step 0) (9, 22) | none | **Fix:** README wording |
| I7 | D18's re-lock says the one-session bar holds "on every machine CI runs", but only the Windows runner ran the bench (11) | none | **Fix:** the load lane runs on all three systems, gated at one session |
| I8 | A quote with no stretch of three or more words counts as found, so once committed it never gets a label (12) | none: this is D16's defined match | **Accepted** as D16's behaviour. The README says that quotes of three or more words are checked |
| I9 | If the forced decision's marker cannot be written (TEMP missing or read-only), session start throws before it emits, and the whole delivery is lost (13) | none | **Fix:** the marker write is caught, so only the forced decision is lost |
| I10 | The reference machine's runs and the calibration runs were not saved under `probes/`, so the README's ranges trace to nothing committed (14, 15, 20) | none | **Fix:** the run records are committed |
| I11 | On Windows and macOS, a tracked map file renamed on disk only in letter case is listed twice. The old git call listed it once (16) | none: a second difference from D16's change, not disclosed | **Fix:** the tracked-file check ignores letter case on win32 and darwin |
| I12 | "No model, no network, hooks spawn only git" has no machine check in the shipped tests (17, 21) | none | **Fix:** a self-test lint over the product scripts' imports and spawns |
| I13 | A UTF-8 byte-order mark at the start of a map file hides its first entry from the labels. Windows PowerShell 5.1's `Out-File` and `Set-Content` write one (19; the verifier refuted the other malformed cases) | D14's unlabelled trigger | **Fix:** a leading byte-order mark is stripped before parsing |
| I14 | 04's budget section still states the superseded bar (22) | none | **Fix:** 04 |

## Gemini's points

| Point | Disposition |
| --- | --- |
| The README reads as if hooks enforce reading and capture. Reading the documents, capturing and naming are instructions the hooks deliver, not locks. The gap when an automatic compaction happens inside a turn is not mentioned | **Fix:** README wording, and the gap as a known issue (it is D22's standing trigger) |
| The latency figures subtract an empty Node start, but the plugin itself spawns that Node process | **Fix:** the README gives wall-clock p95 beside the added figures |
| "Above in 17, below in 9" hides 31 ties | **Fix:** 17 above, 31 level, 9 below (seven of those by one run of ten, two by two runs). Checked against the verdict and baseline files |
| A2 and the added shapes ran on the previous hash, and the shapes are 5 runs, not 10 | **Fix:** README wording |
| "The index lists the files git tracks" leaves out the untracked map files, and now the gitignored ones too | **Fix:** README wording |
| The marketplace name clash between a local developer install and a GitHub install is not stated | **Fix:** a known issue, for contributors |
| "Nothing else" leaves out the settings file that install writes, and the markers left behind by sessions that never get a prompt | **Fix:** README wording |
| Live testing ran on Windows only, and the evals ran on one CLI version | **Fix:** README wording |
| Check a gitignored map file's labels, and a repo with no commit | **Done:** self-test cases in `503e678` |
| Run one live session on macOS or Linux | **Accepted as a limit:** no such machine is available here, and the README says so |
| Check `/clear`, resume, compaction and local scope live | **Already covered:** D12's build step 0 (clear and resume, 3 of 3 each), 2b's smoke (across `/compact`), and the user's own check (resume, two automatic compactions, a local-scope install) |
| Check sources that are deleted, renamed or outside the repo | **Covered** by the self-test's `gone` and `outside` cases. Unreadable sources are I4 |

## What this changes

- I1, I4 and I13 fire D18's trigger and D14's. I2 fires D22's size trigger. The fixes change the plugin, so the
  release candidate moves to `2.0.0-alpha.1` with a new hash. That is 06's 2g attempt 3, registered before any code.
- The workflow was not rerun by default on the fixed hash: the user opted in once, and rule 8 reviews once. The fixes
  got their own checks, plus Gemini on the diff and the final README, and a second run was offered. The user chose it.
  It is recorded below, under "The workflow again".

## Gemini 4 Argon, second round: the fixes' diff and the final README (2026-10-27)

A 22 KB brief: the fixes' diff from `4c5527b` to `a84a31665af3` (the `plugin/` product files), and the README as it
will ship. Verdict: "nothing blocks". It confirmed that none of the six fixes can change the output in a normal case:
a session started at the root, readable files, no byte-order mark, a writable TEMP, and an index under the cap.

| Point | Disposition |
| --- | --- |
| The cut line says "the index is past the 10,000-character limit" when it is the session-start text that passes it, and the index is cut once it reaches about 8,880 characters. Onboarding's warning says the same, and the cut line reads "1 more directories" | **Accepted for the next version.** These texts appear only past the cap, and no eval run reaches them. Changing them now would move the hash and restart A1 for wording alone |
| Letter case is ignored by operating system, not by the file system: a case-sensitive macOS volume or a case-insensitive Linux mount behaves wrongly. Directory keys inside `.project-map/` are not folded | **Accepted:** stated as a known issue in the README. Reading `core.ignorecase` would cost a git spawn on every session start |
| The README merges two equivalence steps, and the 20,400 random quotes and the gitignored case belong to the first | **Fixed:** the README names both steps |
| Quotes shorter than three words that cite a repo file get no label once committed, and the README leaves that implicit | **Fixed:** stated (I8's D16 behaviour) |
| The local-scope line leaves the subdirectory limit implicit | **Fixed** |
| The cap wording in the known issues | **Fixed:** the plugin cuts the session-start text at the documented 10,000, and the measured cliff is stated |

## The workflow again, on `a84a31665af3` (2026-10-27, the user's call)

The user asked for a second workflow run before publishing. 35 agents ran. 30 findings were raised; 15 survived and
15 were dismissed. The survivors come down to 6 issues.

| # | Issue (survivors) | What fires | Disposition |
| --- | --- | --- | --- |
| J1 | The guard's cut is quadratic: its loop rebuilds the whole text for every directory it drops. Session start takes about 0.8 s at 8,000 document directories and about 1.2 s at 10,000; the old code was linear there. Each `CMakeLists.txt` counts as a document (1, 5, 12) | D18's "a hook's added p95 exceeds 100 ms at 1 session", on repos far past P2's shape | **Fix:** one forward pass. The output is unchanged, since the text grows with every directory added |
| J2 | Past the cap, a `.project-map/` with no commit yet is listed last, so it is the first line cut. A repo adopting the plugin would then not see its captured decisions in the index (2, 13) | none: an order the guard made load-bearing | **Fix:** when the index is cut, the map's line goes first |
| J3 | The read hook's labels have no cap guard. A map file of about 150 entries or more puts the labels past 10,000 characters, and the newest uncommitted entry's label is the last line (3, 4, 10). **Live** (CLI 2.1.311, 301 entries, 17,431 characters): the text was saved to a file and Claude got a preview; it found entry 301's label only by reading that file, because the prompt asked for it | D18's re-lock trigger: an uncommitted entry reaches Claude unlabelled through the main session's Read | **Fix:** past the cap, the labels are cut at a line, and the last line says to treat every entry after the last one shown as unreviewed and unverified |
| J4 | A UTF-16 map file gets no labels. Windows PowerShell 5.1's `Out-File` and `>` write UTF-16LE: the hook reads UTF-8, finds no entries, and prints nothing, while Claude's Read shows the decoded entries. Reproduced (6, 9) | D18's and D14's unlabelled triggers | **Fix:** a file with a UTF-16 byte-order mark is decoded as UTF-16, for the map file, its HEAD version and cited sources |
| J5 | The README's wall clock for session start leaves out the bash start that the shell-form hook pays (7). Measured here: about 22 ms more at 1 session (p95 85.1 against 63.3 ms) | none | **Fix:** the README states it |
| J6 | The "spawns only git" lint can be bypassed: `execFileSync` and `fork` from the allowed module, double-quoted or side-effect imports, `new Function` (8, 11, 14, 15) | none: a tripwire weaker than its claim | **Fix:** the lint covers every child_process function, both quote styles, side-effect imports and `Function`. It is described as a tripwire, not a proof |

- J3 and J4 fire D18's trigger. Their fixes, and J1's and J2's, change the plugin, so they make a new epoch, registered
  in 06 as 2g attempt 4.
- Since the hash moves anyway, the past-cap wording accepted in Gemini's second round is fixed in the same epoch: the
  cut line and onboarding's warning name the session-start text, and the count's plural is right.
