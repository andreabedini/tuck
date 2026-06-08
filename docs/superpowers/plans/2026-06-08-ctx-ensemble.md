# ctx Ensemble Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the six dotted `ctx.<x> $ctx` rule-impl aliases with a single node-bound `ctx <subcmd>` command, removing the threaded `$ctx` argument.

**Architecture:** A single `ctx` alias in the rules interp forwards to `::tuck::ctx::dispatch`, with the current target node *curried into the alias* and rebound once per target during analysis. The existing accessor procs (`attr`, `label`, `package`, `declare_output`, `action`, `dep_outputs`) are unchanged — `dispatch` just forwards to them. Migration is strangler-fig: the new command is added alongside the old aliases (every intermediate commit stays green), fixtures are migrated, then the old surface is removed last.

**Tech Stack:** Tcl 9.0+, `tcltest`, Jujutsu (`jj`) for commits.

**Reference spec:** `docs/superpowers/specs/2026-06-08-ctx-ensemble-design.md`

**Test commands:**
- One suite: `tclsh tests/<module>.test`
- Full suite: `tclsh tests/all.tcl` (clean run ends `Total N Passed N Skipped 0 Failed 0`, exit 0)

---

## File Structure

| File | Responsibility | Change |
|------|----------------|--------|
| `lib/ctx.tcl` | `ctx` surface for impls | Add `dispatch` + `_unbound`; rewrite `install`; respell 3 error strings |
| `lib/rules.tcl` | rule registration / impl compile | Compile impl proc with no `ctx` param |
| `lib/analyse.tcl` | analysis driver | Rebind `ctx` alias per node; call impl with no arg |
| `tests/ctx.test` | unit tests for the surface | Add dispatch/unbound tests; respell error asserts |
| `tests/rules.test` | impl-compile tests | Zero-arg impl proc |
| `tests/analyse.test` | analysis end-to-end | Migrate genrule fixture to new surface |
| `tests/integration.test` | CLI end-to-end | Migrate genrule fixture to new surface |
| `CLAUDE.md`, `docs/superpowers/specs/2026-06-01-tuck-m2-design.md` | docs | Update impl/`ctx` surface description |

---

## Task 1: Add the `ctx` command alongside the old aliases

Adds `dispatch`, `_unbound`, the new `install` (which keeps the old dotted aliases AND adds `ctx`), and the per-node alias rebind in `analyse`. After this task both surfaces work. Error strings are NOT respelled yet (old asserts still pass).

**Files:**
- Modify: `lib/ctx.tcl:3-8` (install) and add two new procs
- Modify: `lib/analyse.tcl:21-29` (rebind alias in the loop)
- Test: `tests/ctx.test`

- [ ] **Step 1: Write the failing tests**

Append these three tests to `tests/ctx.test`, immediately before the final `cleanupTests` line:

```tcl
test dispatch-forwards {ctx dispatch forwards a subcommand to its accessor} -setup {setup_ctx} -body {
    ::tuck::ctx::dispatch [app_node] attr name
} -result {hello}

test dispatch-unknown {an unknown subcommand errors} -setup {setup_ctx} -body {
    catch {::tuck::ctx::dispatch [app_node] bogus} err
    string match "tuck: ctx: unknown subcommand 'bogus'" $err
} -result 1

test ctx-unbound {ctx errors before analysis binds a node} -setup {
    set i [interp create]
    ::tuck::ctx::install $i
} -body {
    catch {$i eval {ctx attr name}} err
    string match "tuck: ctx: no target bound*" $err
} -cleanup {
    interp delete $i
} -result 1
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `tclsh tests/ctx.test`
Expected: the three new tests FAIL (`invalid command name "::tuck::ctx::dispatch"` and the unbound test fails because `install` does not yet alias `ctx`).

- [ ] **Step 3: Add `dispatch` and `_unbound`, and rewrite `install` in `lib/ctx.tcl`**

Replace the current `install` proc (lines 3-8):

```tcl
# Alias the ctx.* surface into a (rules) interpreter.
proc ::tuck::ctx::install {interp} {
    foreach cmd {attr label package declare_output action dep_outputs} {
        $interp alias ctx.$cmd ::tuck::ctx::$cmd
    }
}
```

with this (keeps the old dotted aliases for now, adds `ctx` bound to `_unbound`, and adds the dispatcher + unbound stub):

```tcl
# Alias the ctx surface into a (rules) interpreter. The single `ctx` command is
# bound to an erroring stub until analysis curries a real node into it (see
# ::tuck::phase::analyse). The dotted ctx.* aliases are transitional and removed
# in a later task.
proc ::tuck::ctx::install {interp} {
    foreach cmd {attr label package declare_output action dep_outputs} {
        $interp alias ctx.$cmd ::tuck::ctx::$cmd
    }
    $interp alias ctx ::tuck::ctx::_unbound
}

# Bound to `ctx` until analysis curries a target node in; calling it means an
# impl used ctx outside an analysis invocation.
proc ::tuck::ctx::_unbound {args} {
    error "tuck: ctx: no target bound (used outside analysis)"
}

# Forward `ctx <subcmd> <args...>` to the matching accessor with the curried
# node as the first argument.
proc ::tuck::ctx::dispatch {node subcmd args} {
    switch -- $subcmd {
        attr - label - package - declare_output - action - dep_outputs {
            return [::tuck::ctx::$subcmd $node {*}$args]
        }
        default {
            error "tuck: ctx: unknown subcommand '$subcmd'"
        }
    }
}
```

- [ ] **Step 4: Rebind the `ctx` alias per node in `lib/analyse.tcl`**

In the `foreach label` loop, add the alias rebind just before the impl is evaluated. Replace lines 21-29:

```tcl
    foreach label [::tuck::graph::topo_sort $canon] {
        set node [dict get $::tuck::graph::targets $label]
        set rule [dict get $node rule]
        set impl [dict get $::tuck::graph::rules $rule impl]
        if {$impl eq ""} {
            error "tuck: rule $rule has no impl"
        }
        $::tuck::interp::rules eval [list $impl $node]
    }
```

with (adds the rebind line; impl is still called with `$node` for now — both surfaces work):

```tcl
    foreach label [::tuck::graph::topo_sort $canon] {
        set node [dict get $::tuck::graph::targets $label]
        set rule [dict get $node rule]
        set impl [dict get $::tuck::graph::rules $rule impl]
        if {$impl eq ""} {
            error "tuck: rule $rule has no impl"
        }
        $::tuck::interp::rules alias ctx ::tuck::ctx::dispatch $node
        $::tuck::interp::rules eval [list $impl $node]
    }
```

- [ ] **Step 5: Run the ctx suite to verify the new tests pass**

Run: `tclsh tests/ctx.test`
Expected: PASS, all tests including the three new ones.

- [ ] **Step 6: Run the full suite to confirm nothing regressed**

Run: `tclsh tests/all.tcl`
Expected: `Total N Passed N Skipped 0 Failed 0`, exit 0.

- [ ] **Step 7: Commit**

```bash
jj commit -m "feat: add node-bound ctx command alongside ctx.* aliases

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Migrate the `analyse.test` fixture to the new surface

The genrule impl in `analyse.test` still uses `ctx.X $ctx`. Switch it to `ctx X`. Expected analysis results are unchanged — this proves the new surface produces an identical action graph.

**Files:**
- Test: `tests/analyse.test:21-28` (the `impl { ... }` body)

- [ ] **Step 1: Edit the fixture impl body**

In `tests/analyse.test`, replace the `impl` block (lines 21-28):

```tcl
                impl {
                    set out [ctx.declare_output $ctx [ctx.attr $ctx out]]
                    set ins [ctx.attr $ctx srcs]
                    foreach d [ctx.attr $ctx deps] {
                        lappend ins {*}[ctx.dep_outputs $ctx $d]
                    }
                    ctx.action $ctx inputs $ins outputs [list $out] cmd [ctx.attr $ctx cmd]
                }
```

with:

```tcl
                impl {
                    set out [ctx declare_output [ctx attr out]]
                    set ins [ctx attr srcs]
                    foreach d [ctx attr deps] {
                        lappend ins {*}[ctx dep_outputs $d]
                    }
                    ctx action inputs $ins outputs [list $out] cmd [ctx attr cmd]
                }
```

- [ ] **Step 2: Run the analyse suite**

Run: `tclsh tests/analyse.test`
Expected: PASS — `analyse-builds-actions`, `analyse-dep-wiring`, `analyse-target-outputs` produce the same results as before (2 actions; wired inputs; recorded outputs).

- [ ] **Step 3: Commit**

```bash
jj commit -m "test: migrate analyse.test genrule fixture to ctx command

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Migrate the `integration.test` fixture to the new surface

Same fixture migration for the CLI end-to-end test. The asserted stdout is unchanged.

**Files:**
- Test: `tests/integration.test:20-27` (the `impl { ... }` body)

- [ ] **Step 1: Edit the fixture impl body**

In `tests/integration.test`, replace the `impl` block (lines 20-27):

```tcl
                impl {
                    set out [ctx.declare_output $ctx [ctx.attr $ctx out]]
                    set ins [ctx.attr $ctx srcs]
                    foreach d [ctx.attr $ctx deps] {
                        lappend ins {*}[ctx.dep_outputs $ctx $d]
                    }
                    ctx.action $ctx inputs $ins outputs [list $out] cmd [ctx.attr $ctx cmd]
                }
```

with:

```tcl
                impl {
                    set out [ctx declare_output [ctx attr out]]
                    set ins [ctx attr srcs]
                    foreach d [ctx attr deps] {
                        lappend ins {*}[ctx dep_outputs $d]
                    }
                    ctx action inputs $ins outputs [list $out] cmd [ctx attr cmd]
                }
```

- [ ] **Step 2: Run the integration suite**

Run: `tclsh tests/integration.test`
Expected: PASS — `analyze-dump` and `query-actions` print the same action dumps as before.

- [ ] **Step 3: Commit**

```bash
jj commit -m "test: migrate integration.test genrule fixture to ctx command

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Drop the `ctx` formal parameter from compiled impls

Now that both fixtures use the new surface, compile impls as zero-arg procs and call them with no argument. Impls can no longer reference `$ctx`.

**Files:**
- Modify: `lib/rules.tcl:66` (the `proc` compile line)
- Modify: `lib/analyse.tcl` (the impl eval line from Task 1)
- Test: `tests/rules.test:55-67` (the `inline-impl` test)

- [ ] **Step 1: Update the `inline-impl` test (failing first)**

In `tests/rules.test`, replace the `inline-impl` test (lines 55-67):

```tcl
test inline-impl {impl body is compiled into a callable proc in the rules interp} -setup {
    rules_setup
} -body {
    ::tuck::register_rule genrule {
        attrs {name {type string mandatory true}}
        impl { set ::result "ran with $ctx" }
    }
    set impl [dict get $::tuck::graph::rules genrule impl]
    $::tuck::interp::rules eval [list $impl CTX123]
    list $impl [$::tuck::interp::rules eval {set ::result}]
} -cleanup {
    interp delete $::tuck::interp::rules
} -result {__tuck_impl_genrule {ran with CTX123}}
```

with (zero-arg impl proc, called with no argument):

```tcl
test inline-impl {impl body is compiled into a zero-arg callable proc in the rules interp} -setup {
    rules_setup
} -body {
    ::tuck::register_rule genrule {
        attrs {name {type string mandatory true}}
        impl { set ::result "ran with no args" }
    }
    set impl [dict get $::tuck::graph::rules genrule impl]
    $::tuck::interp::rules eval [list $impl]
    list $impl [$::tuck::interp::rules eval {set ::result}]
} -cleanup {
    interp delete $::tuck::interp::rules
} -result {__tuck_impl_genrule {ran with no args}}
```

- [ ] **Step 2: Run rules suite to verify it fails**

Run: `tclsh tests/rules.test`
Expected: `inline-impl` FAILS — `register_rule` still compiles `proc ... {ctx} ...`, so calling `[list $impl]` (no arg) errors with `wrong # args`.

- [ ] **Step 3: Compile the impl proc with no parameter in `lib/rules.tcl`**

Replace line 66:

```tcl
        $::tuck::interp::rules eval [list proc $impl {ctx} [dict get $body impl]]
```

with:

```tcl
        $::tuck::interp::rules eval [list proc $impl {} [dict get $body impl]]
```

- [ ] **Step 4: Call the impl with no argument in `lib/analyse.tcl`**

Replace the impl eval line (added in Task 1):

```tcl
        $::tuck::interp::rules eval [list $impl $node]
```

with:

```tcl
        $::tuck::interp::rules eval [list $impl]
```

- [ ] **Step 5: Run rules + analyse + integration suites**

Run: `tclsh tests/rules.test && tclsh tests/analyse.test && tclsh tests/integration.test`
Expected: PASS for all three.

- [ ] **Step 6: Run the full suite**

Run: `tclsh tests/all.tcl`
Expected: `Total N Passed N Skipped 0 Failed 0`, exit 0.

- [ ] **Step 7: Commit**

```bash
jj commit -m "feat: compile rule impls as zero-arg procs (node via ctx command)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Remove the transitional `ctx.*` aliases and finalize error spelling

Drop the dotted aliases from `install` and respell the three accessor error messages from `ctx.<x>:` to `ctx <x>:`. Update the matching asserts in `tests/ctx.test`.

**Files:**
- Modify: `lib/ctx.tcl` (install, and 3 error strings)
- Test: `tests/ctx.test:43,64,75` (error-string asserts)

- [ ] **Step 1: Update the error-string asserts (failing first)**

In `tests/ctx.test`, make three edits:

Line 43, in `attr-unknown`:
```tcl
    string match "tuck: ctx.attr: no attribute 'bogus'" $err
```
→
```tcl
    string match "tuck: ctx attr: no attribute 'bogus'" $err
```

Line 64, in `dep-outputs-unanalysed`:
```tcl
    string match "tuck: ctx.dep_outputs: //nope:x has no analysed outputs" $err
```
→
```tcl
    string match "tuck: ctx dep_outputs: //nope:x has no analysed outputs" $err
```

Line 75, in `action-missing-arg`:
```tcl
    string match "tuck: ctx.action: missing cmd" $err
```
→
```tcl
    string match "tuck: ctx action: missing cmd" $err
```

- [ ] **Step 2: Run ctx suite to verify the three fail**

Run: `tclsh tests/ctx.test`
Expected: `attr-unknown`, `dep-outputs-unanalysed`, `action-missing-arg` FAIL (messages still say `ctx.attr:` etc.).

- [ ] **Step 3: Respell the error strings in `lib/ctx.tcl`**

Make four edits (line numbers from the current file):

Line 31:
```tcl
        error "tuck: ctx.attr: no attribute '$key'"
```
→
```tcl
        error "tuck: ctx attr: no attribute '$key'"
```

Line 75:
```tcl
        error "tuck: ctx.dep_outputs: $label has no analysed outputs"
```
→
```tcl
        error "tuck: ctx dep_outputs: $label has no analysed outputs"
```

Line 83:
```tcl
        error "tuck: ctx.action: arguments must be key/value pairs"
```
→
```tcl
        error "tuck: ctx action: arguments must be key/value pairs"
```

Line 91:
```tcl
            error "tuck: ctx.action: missing $req"
```
→
```tcl
            error "tuck: ctx action: missing $req"
```

- [ ] **Step 4: Remove the dotted aliases from `install`**

In `lib/ctx.tcl`, replace the `install` proc body so it only aliases the single `ctx` command:

```tcl
# Alias the ctx surface into a (rules) interpreter. The single `ctx` command is
# bound to an erroring stub until analysis curries a real node into it (see
# ::tuck::phase::analyse).
proc ::tuck::ctx::install {interp} {
    $interp alias ctx ::tuck::ctx::_unbound
}
```

- [ ] **Step 5: Run the ctx suite**

Run: `tclsh tests/ctx.test`
Expected: PASS — all asserts match the respelled messages.

- [ ] **Step 6: Run the full suite**

Run: `tclsh tests/all.tcl`
Expected: `Total N Passed N Skipped 0 Failed 0`, exit 0. (Confirms no fixture still relies on a `ctx.*` alias.)

- [ ] **Step 7: Commit**

```bash
jj commit -m "refactor: remove ctx.* aliases; finalize ctx command error messages

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Update the docs

Bring `CLAUDE.md` and the M2 design doc in line with the new surface.

**Files:**
- Modify: `CLAUDE.md` (the `lib/ctx.tcl` row, the impl-body invariant, and the analysis invariant)
- Modify: `docs/superpowers/specs/2026-06-01-tuck-m2-design.md`

- [ ] **Step 1: Update `CLAUDE.md`**

In the architecture table, the `lib/ctx.tcl` row currently reads:

```
| `lib/ctx.tcl`    | `::tuck::ctx` | the `ctx.*` surface for rule impls; `install` aliases it into the rules interp |
```

Change it to:

```
| `lib/ctx.tcl`    | `::tuck::ctx` | the `ctx <subcmd>` command for rule impls; `dispatch` forwards to accessors with the node curried by analysis; `install` aliases `ctx` into the rules interp |
```

In the "Rule `impl` is an inline body" bullet, replace its body so it describes the zero-arg compile and the `ctx` command. Replace:

> - **Rule `impl` is an inline body**, not a proc name: `impl { ...uses $ctx... }`.
>   `register_rule` compiles it into `__tuck_impl_<name> {ctx} <body>` in the rules
>   interp at registration time (so analysis always calls a real named proc). Note this
>   re-enters the rules interp from inside the `tuck::rule` alias — that is intentional
>   and works. A body of `{ helper $ctx }` recovers the named-proc style.

with:

> - **Rule `impl` is an inline body**, not a proc name: `impl { ...uses the `ctx` command... }`.
>   `register_rule` compiles it into `__tuck_impl_<name> {} <body>` (no parameters) in the
>   rules interp at registration time (so analysis always calls a real named proc). Note this
>   re-enters the rules interp from inside the `tuck::rule` alias — that is intentional
>   and works. The body uses `ctx attr`, `ctx declare_output`, `ctx action`, etc. — the
>   target node is curried into the `ctx` alias by analysis, not passed as an argument.
>   Helper procs defined in the `rules` block call `ctx ...` directly (the alias is global
>   to the rules interp during analysis); they take no `ctx` parameter.

In the analysis invariant bullet, replace:

> The `ctx` object passed to an impl *is* the target node.

with:

> Analysis curries the target node into the `ctx` alias (`$rules alias ctx ::tuck::ctx::dispatch $node`) once per target before invoking its impl; `ctx <subcmd>` forwards to the accessor with that node. A single live binding is safe because analysis is strictly sequential and impls never nest.

- [ ] **Step 2: Update the M2 design doc**

Open `docs/superpowers/specs/2026-06-01-tuck-m2-design.md`, find each occurrence of the dotted `ctx.` surface (e.g. `ctx.attr`, `ctx.declare_output`, `ctx.action`, `ctx.dep_outputs`, and any `__tuck_impl_<name> {ctx}` mention) and update it to the `ctx <subcmd>` command form with a zero-arg impl proc, matching the spec at `docs/superpowers/specs/2026-06-08-ctx-ensemble-design.md`. Add a one-line note pointing readers to that spec for the surface change.

- [ ] **Step 3: Verify no stale `ctx.` references remain in docs**

Run: `rg -n 'ctx\.(attr|label|package|declare_output|action|dep_outputs)' CLAUDE.md docs`
Expected: no matches.

- [ ] **Step 4: Run the full suite (sanity, docs-only change)**

Run: `tclsh tests/all.tcl`
Expected: `Total N Passed N Skipped 0 Failed 0`, exit 0.

- [ ] **Step 5: Commit**

```bash
jj commit -m "docs: describe ctx command surface (replaces ctx.* aliases)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review Notes

- **Spec coverage:** Surface (Tasks 2-4), binding mechanism / curry per node (Task 1 + Task 4), `install` unbound stub + `dispatch` (Task 1), zero-arg impl + helper note (Task 4 + Task 6), error handling incl. unknown-subcommand / unbound / respelled accessor errors (Task 1 + Task 5), all listed files touched, regression bar = identical action graph (Tasks 2-3 assert unchanged results). Out-of-scope items unchanged.
- **Green at every commit:** old and new surfaces coexist from Task 1 until the old surface is removed in Task 5; fixtures migrate (Tasks 2-3) before the `ctx` param is dropped (Task 4).
- **Type/name consistency:** `dispatch {node subcmd args}`, `_unbound {args}`, `install` aliases `ctx`; impl proc name remains `__tuck_impl_<name>` (so `register-rule` test result is unchanged); error prefix `tuck: ctx ...` used consistently.
