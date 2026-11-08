# Tuck M3 — Design Spec

> Milestone 3 of the Tuck build system (see `DESIGN.md` §4.3 and §11;
> `2026-06-01-tuck-m2-design.md` for the analysis phase this builds on).
> Date: 2026-11-08

## 1. Scope

M3 delivers the **execution phase**, single-threaded, with a **pure-Tcl directory
sandbox** per action:

- Artifacts get deterministic on-disk paths (`ctx path`), computed during analysis.
- Analysis validates that every action input/output is a registered artifact.
- An execution driver walks the action graph for the requested outputs, runs each
  stale action in its own sandbox directory, and moves declared outputs into the
  output tree.
- A staleness check based on a small action database (command + input `mtime`/size).
- A `tuck build <label>` CLI command.

**Explicitly out of scope for M3:** dynamic actions/thunks (M4), content hashing
(M5), parallelism (M6), and **kernel-level isolation** — no namespaces, `unshare`,
`bwrap`, seccomp or cgroups (see §9).

## 2. Why a pure-Tcl sandbox first

Tuck is core-Tcl only, and Tcl cannot make the system calls that real isolation needs
(`unshare(2)`, `mount(2)`, `pivot_root(2)`, seccomp, Landlock). Only cgroups are
driven through a filesystem (`/sys/fs/cgroup`), and that controls resources, not
visibility. The options for kernel isolation are shelling out to `unshare(1)`,
shipping a small C helper we `exec` (Bazel's `linux-sandbox` model), or using `bwrap`.
None of them is needed to catch the most common hermeticity bug.

A **directory sandbox** — a fresh directory per action, containing only that action's
declared inputs, with a cleared environment and that directory as the working
directory — catches **undeclared inputs reached by relative path**, and
**undeclared or missing outputs**. It is portable (Linux, macOS, BSD), needs no
privileges, and adds no dependency.

It deliberately does **not** stop an action from reading absolute paths
(`/usr/include`, `$HOME`), using the network, or writing through a symlinked input.
Those are what a kernel backend adds later (§9).

## 3. Artifact paths

Every artifact has an **exec path**: a path relative to the **exec root**. Outside a
sandbox the exec root is the repo root; inside a sandbox it is the sandbox directory.
The same command line is therefore valid in both places.

| Artifact | Exec path |
|---|---|
| `source:<p>` | `<p>` (repo-relative, unchanged) |
| `declared:<label>:<rel>` for `//<pkg>:<name>` | `tuck-out/<pkg>/__<name>__/<rel>` |
| … in the root package (`//:<name>`) | `tuck-out/__<name>__/<rel>` |

The `__<name>__` segment keeps a target's outputs apart from sub-packages and from
other targets in the same package, so two targets may both declare `build/main.o`.

`tuck-out/` lives at the repo root. The `//...` package scanner skips it, as it
already skips `.tuck/`.

### 3.1 `ctx path <artifact-id>`

A new `ctx` subcommand returns an artifact's exec path. It is a pure string function
(no I/O), so it is safe in the rules interpreter and keeps `cmd` free of any
substitution language. Rule authors build commands from it:

```tcl
set obj [ctx declare_output build/greet.o -private]
ctx action inputs [list $src] outputs [list $obj] \
    cmd [list cc -c [ctx path $src] -o [ctx path $obj]]
```

`cmd` remains stored verbatim; there is still no `$OUT`/`$SRCS` substitution.

### 3.2 Private outputs

Execution needs intermediates (object files) to be real artifacts, but a dependent
should not see them through `ctx dep_outputs`. `ctx declare_output` gains an optional
flag:

- `ctx declare_output <rel>` — as today: registered and published in
  `target_outputs`.
- `ctx declare_output <rel> -private` — registered, but not published.

## 4. Analysis-time validation (changes to M2)

`ctx action` now rejects malformed graphs early, with `tuck:`-prefixed errors:

- Every id in `inputs` and `outputs` must be a registered artifact
  (`tuck: ctx action: unknown artifact '<x>'`). This rules out the plain-path
  intermediates the current `example/TUCK` uses.
- Every id in `outputs` must be a declared artifact owned by this target
  (`tuck: ctx action: <id> is not an output of <label>`).
- An artifact may be produced by at most one action
  (`tuck: <id> is produced by both <a> and <b>`).

`ctx declare_output` rejects absolute paths, `..` segments and empty paths
(`tuck: ctx declare_output: invalid path '<rel>'`).

## 5. Execution driver

`::tuck::phase::execute {artifact_ids}` (DESIGN §8), in a new `lib/execute.tcl`:

1. Build a producer index: artifact id → action id.
2. Compute the needed actions: walk back from the requested artifacts through
   producers. A declared input with no producer is an error
   (`tuck: no action produces <id>`). A source input whose file does not exist is an
   error (`tuck: missing source file <path>`).
3. Order the needed actions leaves-first (post-order DFS over input → producer edges,
   detecting cycles: `tuck: action cycle: <a> -> <b> -> …`).
4. For each action in order: if it is up to date (§7) print `skip <id>`; otherwise
   run it in a sandbox (§6), print `run <id>`, and record it in the action database.
5. The first failing action stops the build.

`tuck build <label>` runs `analyse` on the label, then `execute` on that target's
published outputs (`target_outputs`), and prints the exec paths of those outputs on
success.

## 6. The directory sandbox

New file `lib/sandbox.tcl`, namespace `::tuck::sandbox`. All of it runs in the root
interpreter, which has `file`, `exec` and `cd`; the child interpreters are unchanged.

For one action:

1. **Create** `tuck-out/sandbox/<n>/` (`<n>` a per-run counter), removing any
   leftover directory of that name first.
2. **Stage inputs.** For each input, create its exec path's parent directories in
   the sandbox and add a symbolic link to the real file (source in the repo, declared
   artifact under `tuck-out/`). Nothing else from the repo appears.
3. **Environment.** For the duration of the `exec`, `::env` is replaced by:
   - `PATH` — inherited from the host (tools are not yet hermetic; see §9);
   - `HOME` and `TMPDIR` — `<sandbox>/.home` and `<sandbox>/.tmp`, created empty;
   - `LANG=C`, `LC_ALL=C`, `TZ=UTC`, `SOURCE_DATE_EPOCH=0`;
   - the action's own `env` dict, applied last.

   The previous environment is restored afterwards, even on error.
4. **Run.** `cd` into the sandbox, `exec {*}$cmd` with stdout and stderr captured
   together, then `cd` back (restored on error). Single-threaded execution makes the
   process-wide `cd` and `::env` changes safe; M6 will need a different mechanism.
5. **Check.** On a non-zero exit, error with the action id, the exit status and the
   captured output (`tuck: action <id> failed (exit <n>)` followed by the output).
   On success, every declared output must exist in the sandbox
   (`tuck: action <id> did not produce <exec-path>`).
6. **Collect.** Move each output into place under the exec root with
   `file rename -force` (same filesystem: both are under `tuck-out/`).
7. **Clean up** the sandbox directory. With `TUCK_KEEP_SANDBOX=1` set, failed
   sandboxes are kept for debugging and their path is printed.

## 7. Staleness

An action database at `tuck-out/.db` holds a Tcl dict:
action id → `{key <cmd+env> inputs {<exec-path> {<mtime> <size>} …}}`.
It is loaded at the start of `execute` and rewritten after each successful action.

An action is **stale** if any of:

- one of its outputs is missing under the exec root;
- it has no database entry, or the recorded `cmd`/`env` differs from the current one;
- any input's current `mtime` or size differs from the recorded value.

Comparing against recorded values, rather than "input newer than output", also
catches reverted files and changed commands. Because a rebuilt upstream output gets a
new `mtime`, staleness propagates to dependents naturally. M5 replaces the
`{mtime size}` pair with a content hash; the database shape stays the same.

## 8. Modules and CLI

New files:

```
lib/sandbox.tcl   # ::tuck::sandbox — create/stage/run/collect/cleanup for one action
lib/execute.tcl   # ::tuck::phase::execute — producer index, ordering, staleness, db
```

Modified files:

- `lib/action.tcl`: `exec_path` helper; producer-uniqueness bookkeeping.
- `lib/ctx.tcl`: `ctx path`; `declare_output … -private`; validation in `ctx action`.
- `tuck.tcl`: source the new files; add `build` to the dispatch; skip `tuck-out` in
  `_find_builds`.
- `example/TUCK` and `example/app/BUILD`: rewritten for execution (§10).

## 9. Later: kernel-level backends

The sandbox is one step behind a narrow interface — *given an action and its staged
directory, run it and report the exit status and output* — so stronger backends can
be swapped in later:

- `unshare` — wrap the command in `unshare(1)` (util-linux) with a user and mount
  namespace, bind-mounting the staged inputs read-only and the toolchain directories,
  plus `--net` for no network.
- a small standalone C helper, if the `unshare` mount script becomes too fragile.
- `bwrap`, opportunistically, where installed.
- cgroup v2 limits, written directly to `/sys/fs/cgroup` from Tcl.

Some distributions restrict unprivileged user namespaces, so any kernel backend must
fall back to the directory sandbox.

## 10. Worked example: what the sandbox catches

The current `example/` does not build under this design, which is the point:

- Intermediate objects are plain paths (`build/greet.o`), not artifacts. They become
  `-private` declared outputs.
- `//app:hello` compiles `main.c` with `-Ilib/greet`, but `greet.h` is not one of its
  inputs. In the sandbox the header does not exist, so the compile fails. This is the
  undeclared-input bug the sandbox exists to catch.

The fix in the example: `cc_library` publishes its headers (a `cp` action declaring
`include/<hdr>` outputs) alongside the archive; `cc_binary` adds `.h` outputs of its
deps to its compile inputs and derives `-I` from their exec paths, and links the
`.a` outputs. The `-Ilib/greet` copt goes away. Passing typed information between
rules properly (providers) is a later milestone; filtering `dep_outputs` by
extension is enough for M3.

## 11. Testing (TDD with `tcltest`)

- **action.test / ctx.test** — `exec_path` for root and non-root packages;
  `ctx path`; `-private` outputs are registered but absent from `dep_outputs`;
  `ctx action` rejects unknown artifacts, foreign outputs and double producers;
  `declare_output` rejects bad paths.
- **sandbox.test** — only declared inputs are visible (an action that `cat`s an
  undeclared repo file fails); the environment is cleared (an action that prints a
  host variable sees nothing) and the caller's `::env` and working directory are
  restored afterwards, including on failure; a missing declared output is an error;
  outputs land at their exec paths; the sandbox directory is removed.
- **execute.test** — leaves-first ordering across targets; second run skips
  everything; touching a source re-runs that action and its dependents only;
  changing a `cmd` re-runs; missing source and missing producer errors.
- **integration.test / example.test** — `tuck build` on a `genrule` fixture using
  only POSIX tools (`cat`, `cp`, `sh`); the C example builds and runs when `cc` is
  available (skipped otherwise via a `tcltest` constraint).

## 12. Definition of done

- `tuck build <label>` builds a fixture repo end to end, and a second run does no work.
- Each action runs in its own sandbox directory with only its declared inputs and a
  cleared environment.
- The reworked `example/` builds `tuck-out/app/__hello__/build/hello`.
- All error cases produce clear `tuck:`-prefixed messages.
- All `tcltest` suites green.

## 13. Open questions

- Symlinked inputs are fast but let an action write through to the source file.
  Copying is safer and slower. M3 uses symlinks; revisit if it bites.
- `PATH` is inherited from the host, so toolchains are not hermetic. Declaring
  toolchains as artifacts is a separate design question.
