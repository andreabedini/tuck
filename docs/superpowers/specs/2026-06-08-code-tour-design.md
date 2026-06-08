# Code Tour — making Tuck readable to non-TCL developers

> Design spec. Date: 2026-06-08.

## Problem

Tuck's source is small (~657 lines) and clean, but it is written in TCL, which most
developers today have never used. The idioms that carry the most architectural weight
— child interpreters created with `interp create -safe`, command `alias`es as the only
escape hatch, namespaces, `dict` as the universal data structure, `upvar`, and
scripts-as-data (`eval`) — are exactly the ones a newcomer cannot read. The existing
docs (`README.md`, `DESIGN.md`, `CLAUDE.md`) describe *what* Tuck does and *why* the
design is shaped this way, but none of them teaches the reader enough TCL to follow the
actual code.

## Goal

A reader who does not know TCL should be able to open the codebase and understand both
the architecture and the individual files, learning just enough TCL along the way.

Non-goals (YAGNI):

- No general TCL tutorial beyond the features Tuck actually uses.
- No rewrite of `README.md`, `DESIGN.md`, or `CLAUDE.md`.
- No per-proc doc-comment pass; no comment churn on files that already read clearly.

## Deliverables

### 1. `docs/CODE-TOUR.md` (primary artifact)

A prose guide structured as a **narrative that follows one command through the
system** — `tclsh tuck.tcl analyze //tools/hello:hello` — because that single path
touches every source file in dependency order and makes the two-phase architecture
concrete. Sections:

1. **What Tuck is & the mental model.** Two phases / two graphs (loading → target
   graph; analysis → action graph), hermeticity enforced by the interpreter boundary,
   "TCL is the language, not a DSL." One short section; link to `DESIGN.md` for the
   full design rather than restating it.

2. **The TCL you need, scoped to Tuck.** Just-enough explanations, each with a
   one-line "you'll see this in `<file>`" pointer:
   - **Namespaces** — `::tuck::graph::…` qualified names; why `namespace eval` must
     create a namespace before a qualified variable can be set.
   - **Dicts** — the universal data structure here; targets, nodes, schemas, the
     action graph are all dicts.
   - **Procs and `upvar`** — pass-by-name for the accumulator in `topo_sort`.
   - **`eval` / scripts-as-data** — a `{ ... }` block is just a string until something
     evaluates it; this is what makes `targets { ... }` and `rules { ... }` work.
   - **Child interpreters, `-safe`, and `alias`** (the big one) — what a child interp
     is, why `interp create -safe` removes `open`/`exec`/`file`/`package` so the interp
     cannot touch the filesystem, and how an `alias` is the single narrow bridge back
     to the trusted root interp. This is the mechanism behind hermeticity.

3. **The walkthrough**, in execution order, one short section per file. Each section
   says what the file does, names the key idiom, and shows a short real excerpt:
   - `tuck.tcl` — entry point and CLI wiring; `main` sets up and dispatches.
   - `config.tcl` — find the repo root by walking up to `.tuck/`.
   - `loader.tcl` — the three interpreters (loader / target / rules) and per-file
     loading; the heart of hermeticity.
   - `label.tcl` — parsing and canonicalizing `//pkg:name`.
   - `rules.tcl` + `target.tcl` — the loading phase: registering rules with typed attr
     schemas, then validating targets against them and extracting deps.
   - `graph.tcl` — dangling-dep validation and post-order DFS topo-sort (leaves-first,
     with cycle detection).
   - `analyse.tcl` + `ctx.tcl` + `action.tcl` — the analysis phase: leaves-first impl
     invocation, the `ctx` command surface for rule impls, and the action-graph stores.

4. **The two tricky mechanisms**, called out explicitly with prose diagrams:
   - **The three-interpreter model** — what loader / target / rules each hold, which
     code runs in which interp, and how aliases connect them to the root.
   - **The inline-`impl` → compiled-proc → `ctx`-currying flow** — how an `impl { ... }`
     body is compiled into a zero-arg proc at rule registration, and how analysis
     curries the current target node into the `ctx` alias before invoking it. This is
     the cleverest and least-obvious part of the system.

### 2. Light inline comments

Add a one-line comment *only* where a single line is genuinely cryptic to a non-TCL
reader and an in-context pointer helps more than the guide alone. Each comment points
to the relevant CODE-TOUR section by name. Expected sites (final set decided while
writing):

- `graph.tcl` — the `upvar` line in `_visit`.
- `analyse.tcl` — the `alias ctx ::tuck::ctx::dispatch $node` currying line.
- `loader.tcl` — the `interp create -safe` lines and what `-safe` strips.

Do not add comments to files that already read clearly.

## Approach / structure rationale

Following one command top-to-bottom (rather than a file-by-file reference ordered
alphabetically) means concepts are introduced in the order the reader would encounter
them when tracing real behavior, and the two-phase architecture emerges naturally from
the narrative. The "TCL you need" section front-loads the vocabulary so the walkthrough
can reference it instead of re-explaining idioms at each site.

## Success criteria

- A reader unfamiliar with TCL can explain, after reading the guide: the two phases,
  why builds are hermetic, and what each source file is responsible for.
- Every TCL idiom used in `lib/` and `tuck.tcl` is explained at least once in the guide.
- Inline comments are minimal, one line each, and reference the guide.
- Existing docs are untouched except, optionally, a single pointer to the new guide.
