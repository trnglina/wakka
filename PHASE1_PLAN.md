# Phase 1 — Text measurement with parley (headless)

## Context

Phase 0 delivered the FLI marshalling core (`native/src/term.rs`): compound
destructuring, `dict_get`, list iteration, number readers, term builders, and the
`guard` panic boundary. Phase 1 is the highest-value integration on top of it:
replace the `defer_measurement/2` no-op with a real content measurer,
`measure_native/3`, backed by **parley 0.11** (latest; `ranged_builder` →
`push_default`/`push`/`push_inline_box` → `build`, then
`Layout::break_all_lines(Some(max))` + `align`, `width()`/`height()`, and
`lines()`→`GlyphRun`/`Cluster` with `text_range()` byte offsets). It needs **no
window or GPU**, so it is fully unit-testable.

Per PLAN.md decision #3 and the user's scoping calls, Phase 1 includes the **full
handle/cache machinery**: native measures once, caches the built parley `Layout`
(plus a per-run source map) under an integer handle, and the handle is **surfaced
into the layout tree** as the inline `layout{}`'s `text:` field so Phase 3 (paint)
and Phase 4 (interaction) can reach it. Tests use a **bundled OFL font** so
measured metrics are exact and machine-independent.

## The measurement boundary today (verified)

- `ui_layout.pl:425`: `call(MeasureContent, measure_inline(Runs,Options,MaxW),
metrics(W0,H0))`; the inline builds `layout{width,height,constraints,options,
path}` on success (`:430`), or a `pending: Request` placeholder on failure.
- Request shape (confirmed Phase 0): `Text` string; `Inherited`/`Options` are
  `attrs{}`/`inline_options{}` dicts with **single-element-list** values
  (`font_size:[12]`, `alignment:[start]`… actually options resolve to bare atoms
  via `inline_options_/2`, `:486`); `RelPath` int list; `W`/`H`/`MaxW` in **units**
  (1/64 px) or `MaxW = inf`. Metrics speak **units** (`:407`); Prolog `ceiling`s
  them (`:426`).
- Only `measure_fake` (`ui_layout_tests.pl:27`) and the one call site reference the
  `metrics/2` term; no test does whole-dict equality on an inline layout, and no
  core file imports the native lib — so the contract change is contained.

## Core change (`core/ui_layout.pl` + test stub)

Extend the measure reply to carry the handle and store it on measured inlines:

- Call site `:425` → `call(MeasureContent, Request, metrics(W0, H0, Handle))`.
- Success layout `:430` → add `text: Handle` to the `layout{}` dict. The `pending`
  placeholder branch stays handle-less (an unmeasured inline has no handle).
- `defer_measurement/2` and `measure_fake/2` stay **arity 2** (only the `Metrics`
  term’s shape changes); update `measure_fake` (`:27`) to yield
  `metrics(W, H, fake)` with a dummy atom handle. The four `measure_fake` tests
  read `width`/`height`/`pending` via `get_dict`, so the additive `text:` key does
  not disturb them.

## Native design (`native/` crate)

**Dependencies** (`native/Cargo.toml`): `parley = "0.11"` (re-exports `fontique`
for font registration). Content hashing uses `std::hash::DefaultHasher` (fixed
keys → deterministic, no new dep).

**Per-context state, thread-local** (single-threaded Prolog-drives model, decision
#3 open-decision #3 — a `thread_local! RefCell` sidesteps `Send`/`Sync` bounds on
parley types). A registry maps a context id → `MeasureCtx { font: FontContext,
layout: LayoutContext, cache: HashMap<u64, Cached> }`. For headless Phase 1 a
context is created explicitly; a real window will later double as a context id.

**`Cached`**: the built `parley::Layout<()>` + a **source map** — per run its
`RelPath` (`Vec<i64>`) and byte span in the concatenated stream. (The full
byte↔code-point table decision #4 needs is deferred to Phase 4 queries; the
rel-path + byte span, which we have for free at build time, is enough now.)

**New foreign predicates** (registered in `lib.rs`, all through `guard`, exported
from `core/ui_native.pl`), reusing the Phase-0 `term.rs` API end-to-end:

- `create_measure_context(-Ctx:int)` / `destroy_measure_context(+Ctx)` — headless
  ctx lifecycle; `Ctx` is an integer id.
- `register_font(+Ctx, +Path:atom)` — pulled forward from PLAN Phase 5, minimally,
  to load the bundled test font into the ctx's `FontContext.collection`
  (`fontique` register). Returns the registered family name is not needed; tests
  name the family directly.
- `measure_native(+Ctx, +Request, -Metrics)` — the measurer:
  1. `Term::compound("measure_inline", 3)` → `[Runs, Options, MaxW]`.
  2. `Runs.to_vec()`, each element `compound("run",2)` or `compound("box",3)`:
     - run: `text()`; read `Inherited` via `dict_get(k)?.to_vec()?.first()` for
       `font_size`(int px), `font_family`(string), `font_weight`(atom/int→f32),
       `slant`(atom→`FontStyle`), `lang`(int, → locale — optional, may defer).
     - box: `RelPath` via `to_vec`+`i64`; `W`/`H` `i64` units → px (`/64.0`).
  3. Concatenate run texts into one `String`, tracking byte ranges; build with
     `ranged_builder(scale=1.0)`, `push(StyleProperty, range)` per run,
     `push_inline_box(InlineBox{ id, index, width, height })` per box (id → box
     table → RelPath).
  4. `Options`: `dict_get("alignment")`→`Alignment`; `dict_get("leading")` →
     `none` (default) or int units → `LineHeight` px.
  5. `MaxW`: `atom()=="inf"` → `None`, else `i64` units → `Some(px)`;
     `break_all_lines(max_px)`, then `Layout::align(max_px, alignment, ..)`.
  6. Metrics: `width()`/`height()` px → units (`*64.0`, returned as floats so
     Prolog ceils). Handle = 64-bit content hash of the request signature; on a
     hit return the cached layout (verify stored signature to guard collisions),
     else insert `Cached`. Build reply `metrics(Wu, Hu, Handle)` via
     `Term::compound_from` + `Term::float`/`Term::int`.

**Handle identity — content hash** (recommended; PLAN open-decision #2 lean): the
handle is a hash of the run/options/maxw signature, so identical content
self-dedups (cache hit, same handle) and nothing needs explicit eviction wired to
dirty tracking — a re-measured identical inline gets the same handle, a changed one
gets a new hash. The cache is scoped to its context and cleared on
`destroy_measure_context`.

## Prolog-facing API

Export from `core/ui_native.pl`: `create_measure_context/1`,
`destroy_measure_context/1`, `register_font/2`, `measure_native/3`. Used as a
`MeasureContent` goal by partial application: `layout_tree(measure_native(Ctx),
Root, Layout)` calls `measure_native(Ctx, Request, Metrics)`.

## Test font

Add a small OFL-licensed font under `native/fixtures/` (e.g. DejaVu Sans or an
equivalently ubiquitous permissive face) plus its license file. Tests
`register_font` it and set `font_family` to that family so ASCII test text never
hits system fallback → deterministic metrics. Expected unit values are computed
once from this font and pinned.

## Files

- **Modify:** `core/ui_layout.pl` — reply `metrics/3`, store `text: Handle`.
- **Modify:** `core/ui_layout_tests.pl` — `measure_fake` → `metrics(W,H,fake)`.
- **Modify:** `native/Cargo.toml` — add `parley`.
- **New:** `native/src/measure.rs` — ctx registry, parley build, cache, source map.
- **Modify:** `native/src/lib.rs` — `mod measure;`, register the four predicates.
- **Modify:** `core/ui_native.pl` — export them.
- **New:** `native/fixtures/<font>.ttf` (+ `LICENSE`).
- **Modify:** `core/ui_native_tests.pl` — add cases that create a ctx, register
  the font, and measure with it.
- **On completion:** collapse PLAN.md Phase 1 prose per the
  update-PLAN-on-completion convention.

## Verification

1. `cargo build -p native` green with parley added.
2. `core/ui_layout_tests.pl` still passes under the updated `measure_fake`
   (`swipl -g run_tests -t halt core/ui_layout_tests.pl`).
3. New cases in `core/ui_native_tests.pl` (run under the flake's `swipl`):
   - single run: exact pinned `width`/`height` units for known text at a known
     `font_size`;
   - wrapping: a long run at a tight `MaxW` yields `height` for >1 line (pinned);
   - mixed runs: two adjacent runs measure as the sum of advances (pinned);
   - inline box: a `box(RelPath, W, H)` reserves at least `W`×`H`;
   - `font_size` scaling: larger size → proportionally taller line;
   - `inf` MaxW: single line, no wrap;
   - handle surfaced: `layout_tree(measure_native(Ctx), Root, L)` gives measured
     inlines a `text: Handle` integer, and identical content yields the **same**
     handle (cache hit);
   - panic/robustness: a malformed request fails cleanly (no crash across the FLI).

## Notes / non-goals

- `lang`→locale mapping and the full byte↔code-point source-map table are the only
  bits deferred within Phase 1 (Phase 4 needs the latter); everything else lands.
- `register_font/2` is pulled forward minimally for test determinism; the richer
  Phase-5 font story (fallback config, family enumeration) stays deferred.
- Core tests remain on `measure_fake` for exact-value layout assertions; real-font
  measurement lives in the dedicated native suite so the core tests never depend on
  the native build.
