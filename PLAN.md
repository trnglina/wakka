# Native Interop Plan

This document plans the native layer that sits beneath the pure-Prolog UI core
(`ui_element`, `ui_attributes`, `ui_changes`, `ui_state`, `ui_layout`). It
covers _what_ to build, _in what order_, and — most importantly — _what the
Prolog-facing API looks like at each step_. It is a plan, not an implementation:
nothing here should be built all at once.

## Where we are

The Prolog core is a pure, deterministic pipeline over ground terms:

```
element tree ──ui_changes──▶ change list ──ui_state──▶ canonical node tree
                                                              │
                                              ui_layout (relayout_tree)
                                                              ▼
                                                        layout tree
```

- **Node tree** (`ui_state`): `node{tag, attributes, children, inherited}` for
  boxes, `node{text, inherited}` for text. Inheritance is pre-resolved.
- **Layout tree** (`ui_layout`): `layout{width, height, children:[child(X,Y,L)],
constraints, path, overflow?}`. All geometry is integer **layout units =
  1/64 logical pixel** (`px_units/2`).
- **Measurement boundary already exists.** `layout_tree/3` and
  `relayout_tree/5` take a `:MeasureContent` goal and call it as
  `MeasureContent(measure_inline(Runs, Options, MaxW), metrics(W, H))`. The
  default `defer_measurement/2` fails, producing placeholders that carry a
  `pending: Request` for a later pass. **This is the seam the native text layer
  plugs into** — it is the single most important pre-existing design affordance.

The native side is a single Rust `cdylib`, `native`, which today only generates
raw bindgen bindings to `SWI-Prolog.h`. Nothing is registered as a foreign
predicate yet; the crate is not even configured to build as a loadable module.

Target native stack: **parley** (text layout), **vello** (2D scene), **wgpu**
(GPU), **winit** (windowing).

## Guiding architectural decisions

These shape the whole API. They are recommendations with rationale; the first
three are the ones worth challenging before we commit.

### 1. Prolog drives; native is a library (not the reverse)

The core is a pure functional pipeline and _owns the application state_. So
Prolog owns the outer loop and calls _into_ native for the three things native
is good at — measuring text, drawing, and talking to the OS:

```prolog
app_loop(Win, PrevEl, PrevNode, PrevLayout) :-
    poll_events(Win, Events),                       % pump winit, drain queue
    update_model(Events, PrevEl, NextEl),           % pure app logic
    element_changes(PrevEl, NextEl, Changes),
    node_apply_changes(Changes, PrevNode, NextNode),
    window_viewport(Win, W, H),
    relayout_tree(measure_native(Win), Changes,
                  root{viewport_width:W, viewport_height:H, node:NextNode},
                  PrevLayout, Layout),
    paint_tree(NextNode, Layout, DisplayList),      % pure: ui_paint
    render(Win, DisplayList),
    app_loop(Win, NextEl, NextNode, Layout).
```

This requires winit's **`pump_app_events`** (non-blocking pump) rather than the
control-inverting `EventLoop::run`. It keeps the winit event loop on the main
thread (a hard macOS requirement) while letting Prolog's `main/0` be that main
thread. The alternative — native owns the loop and calls Prolog back per event —
fights the pure-core design and is dropped.

### 2. The paint boundary is a flat display list generated in Prolog

Native should _not_ walk `node{}`/`layout{}` dicts. Instead a new pure Prolog
module `ui_paint` walks `(node, layout)` and emits a **flat, ordered display
list** of primitive draw ops (ground terms). Native executes it into a vello
`Scene`. Rationale:

- Presentation semantics (`decoration`, `backdrop`, `opacity`, `color`) are
  _policy_ and belong with the rest of the core in Prolog, where they are
  testable without a GPU.
- It keeps the native boundary marshalling narrow and stable: native reads one flat list of
  simple terms instead of traversing recursive dicts (dicts are painful to read
  through the native boundary).
- It decouples paint cadence from layout cadence and makes post-layout
  transforms (scroll, opacity layers) just a display-list transformation.

Text is the one thing Prolog cannot serialize cheaply, so text ops carry an
**opaque integer handle** into a native cache of parley layouts (see #3).

The alternative (native tree-walk of the dicts) is faster to _not_ design but
pushes presentation policy into Rust and widens the native library surface; rejected.

### 3. Text layout is measured once and cached by handle

parley produces a full glyph layout during measurement; we must not recompute it
at paint time. `measure_native/2` builds the parley `Layout`, stores it in a
per-window slab keyed by an integer handle, and returns `metrics(W,H)` **plus**
the handle (surfaced to Prolog via the inline `layout{}`'s `text: Handle` field
so both the painter and interaction can reference it). The cache is invalidated
per relayout using the same dirty information `ui_layout` already computes.

**Handles are ephemeral per-frame query tokens.** Everything character-level
(cluster geometry, byte↔position maps, selection) stays behind the handle and is
queried lazily — never returned in `metrics/2`, which would ship a large table
across the native boundary on every measurement for data mostly never touched. Durable
interaction state (caret, selection endpoints) is expressed in **tree-semantic**
terms — `(RelPath, Offset)` — not in handles, so it survives relayout; a path is
re-resolved to the current handle via the layout tree's `text:` field at query
or paint time. Getting handle lifetime and invalidation right is a real risk and
gets its own attention in Phase 1.

### 4. Hit testing is a Prolog/native collaboration

The layout tree (with per-child `child(X,Y,L)` offsets) is already in Prolog, so
**coarse** hit testing — point → node path — is a pure Prolog walk (`ui_hit`);
native only delivers raw pointer coordinates. But **character-level** hit testing
(which character, for caret and selection) needs per-glyph geometry that only
parley has. Neither side can do it alone: document order and "which text flow a
point belongs to" are tree properties Prolog owns; within-a-node position is
parley's. So the two collaborate — and `ui_hit`'s contract is **nearest
selectable text position**, not merely the _containing_ node, because a drag
focus routinely misses all glyphs (gaps, padding, below the last line). Prolog
picks the nearest selectable text node from the tree, clamps the point into its
box, and routes to that node's handle; parley clamps within the flow. See the
text-position API and Phase 4.

### 5. Units and DPI

The display list stays in **layout units (1/64 logical px)** — the same units as
the layout tree — so Prolog never does lossy float conversion. The renderer
applies a single root transform `scale = scale_factor / 64.0` to map units →
physical pixels. Scale factor changes are just a new root transform, no relayout
(layout is in logical space).

### 6. Focus is a framework-owned canonical register; native requests, never owns

Focus is **owned entirely by Prolog canonical state** — a _focus register_ that
sits beside the node tree, not an element attribute. This makes focus one of a
family of **interaction registers** (with text selection from decision #3, and
scroll offsets — see "Scrolling"): state that is canonical and Prolog-owned but _not_
app-declared — the framework maintains it by reducing input events over the tree,
and it is keyed to node identity (so it survives reconciliation and reordering,
where a raw index path would not). Registers drive **repaint, not relayout**
(a focus ring is a paint-time overlay read from the register), so focus changes
are cheap.

Three consequences pin down the semantics:

- **No application-exposed way to adjust focus.** There is no `focused` attribute
  and no app-facing focus command. Focus moves only via interaction the framework
  interprets — pointer-down on a focusable node, Tab/Shift-Tab tab-order
  traversal (`ui_focus` computes the focusable set and order from the tree) — or
  via a native _request_ (below). _Focusability_ (tab-eligibility) is a separate,
  static question from _adjusting focus_; see the open decision.

- **Native requests, the framework decides.** Native is a _source of focus-change
  requests_ — most importantly from platform accessibility tools (VoiceOver
  moving focus) — never an owner. It emits `focus_requested(WidgetId, Reason)`;
  the framework's focus manager validates and applies it to the register. When
  the register changes, the framework informs native via `set_native_focus/3` so
  the widget can activate (caret/IME) and so the platform a11y layer is notified.

- **Widgets own internal focus, not global focus.** A complex control may manage
  focus _within its own subtree_ (fields of a date picker) autonomously and
  opaquely to Prolog. It has no say over which widget is globally focused. When
  its internal focus would leave its boundary (Tab past its last field), it does
  not move global focus itself — it emits `focus_escape(WidgetId, forward|back)`,
  and the framework moves the global register to the next focusable sibling.

## Native widgets

Some elements (a `text_input`, later a rich editor) are implemented almost
entirely in native code but expose a simple `value` / on-change API to Prolog.
They are a **deliberate, bounded exception** to "Prolog owns all state" and to
"handles are ephemeral" — a _second category_ of native object, and worth
calling out as such so the exception stays contained.

**A persistent, key-identified instance.** Unlike a per-frame text handle, a
widget holds state that must live across frames (caret, selection, IME
composition, undo, intra-field scroll). Its identity is the element's `key`; its
lifetime is bound to the node's presence in the tree, which the existing keying
and stash/attach reconciliation already track (insert → create, detach-to-stash →
keep alive hidden, attach → re-show, `key(_,drop)` → destroy).

**State splits along one principled line:**

- _Model state — Prolog-owned, controlled._ The `value` (plus declared props:
  `placeholder`, `disabled`, …). Source of truth, flows through the normal loop.
- _View/interaction state — native-owned._ Selection, caret + blink, IME preedit,
  scroll-to-caret, undo/redo. Native mutates it **autonomously, at input latency,
  with no Prolog round-trip and no relayout.** This autonomy is the entire point
  of a native widget (and IME/undo can't cross the native boundary per keystroke).

Rule: **model changes are transactional through the event/relayout loop; view
changes are local and cheap.**

**The controlled loop, driven by the existing diff.** No closures live in the
tree (that would break `element_changes`'s `ground/1` requirement); `on_change`
_is_ the keyed event stream. Native reports edits as `change(Key, NewValue)`
events; the app stores `NewValue` (or transforms/rejects it) as the node's
`value`. Then `element_changes` diffs `PrevElement.value` (= what native emitted
last frame) against `NextElement.value`:

- **Equal** (the normal echo) → no `set_attribute` → native untouched → caret does
  not jump.
- **Differs** (Prolog transformed/rejected) → a `value` `set_attribute` fires →
  native reconciles its buffer. The safety rule at the boundary: native replaces
  its buffer only when the incoming `value` differs from the buffer's current
  text, re-mapping the caret.

So the diff computes "does native need to reconcile?" for free. There is **zero
input latency** despite the round-trip: native renders from its own buffer every
frame, so the model round-trip only affects what Prolog _derives_ from `value`
(e.g. validation styling), a frame later.

**Rendering and focus.** The widget is a black box that paints itself:
`ui_paint` emits `widget(WidgetId, X, Y, W, H)` and native draws its editor
(text + selection + caret) into that rect during `render`. Global focus is _not_
the widget's to set (decision #6): the framework's focus register decides which
widget is focused and tells native via `set_native_focus/3`. Only while a widget
holds global focus does it consume keyboard/`text_input`/IME and surface
`change`/`submit`; otherwise those events flow to app-level key handling. The
widget may manage its _internal_ focus freely, and asks to hand global focus back
with `focus_escape/2` (Tab past its edge) or to acquire it with
`focus_requested/2` (e.g. an accessibility action).

**Purity is preserved.** The impure bridging — create/stash/destroy instances,
push `value`, route focus — lives in the host driver loop, which keeps a registry
of native-backed tags and reads lifecycle off the change list. `ui_changes` /
`ui_state` / `ui_layout` see `text_input` as an ordinary element with a `value`
attribute (`attribute(value, 1, [])`) and no children.

**Controlled by default; uncontrolled opt-in.** Controlled marshals the whole
`value` on every `change` — fine for a field, wasteful for a large code editor or
a password Prolog shouldn't hold. Uncontrolled mode lets native own `value`
entirely (`value` is initial-only; read via `widget_value/2`; `change` events
optional). Delta events are possible but complicate the value diff, so they stay
out of the default.

### Limitation: no content-determined sizing

The autonomy that justifies a native widget carries a natural cost: **a native
widget cannot size to its own content.** Layout runs only when Prolog relayouts,
and a widget's box is fixed by `measure_widget` _at that relayout_. But the whole
point of the widget is that its content mutates **natively, between relayouts,
without participating in layout** — so those mutations cannot feed back into its
size. Concretely:

- The widget must be **externally sized** — by `main_size`/`cross_size`, flex, or
  parent constraints — and **scroll/clip its content internally** to fit.
- Sizing to the _controlled_ `value` is technically possible (it round-trips and
  dirties layout), but that re-couples every keystroke to a full relayout — i.e.
  it forfeits exactly the autonomy the widget existed to provide.
- Content that never reaches the model — an **IME preedit** string, or the buffer
  in **uncontrolled** mode — can _never_ drive size, because layout never sees it.
  So an autogrowing field that grows to fit an in-progress composition is not
  expressible; this is a hard boundary, not a tuning question.

Prefer giving native widgets a definite box. If genuine content-driven autogrow
is required, that argues for a _Prolog-owned_ element measured by the normal text
path, not a native widget.

## Scrolling

Scrolling is an **intersection point** — it touches layout, the interaction
registers, paint, and hit testing at once — so it is specified here explicitly
rather than left implicit in Phase 5. Two things it deliberately is _not_: there
is **no app-facing way to set or read scroll position** (like focus, scroll
offset is a framework-owned register, not an attribute — decision #6), and there
is **no virtualization** (the whole content subtree is always laid out). The
design keeps each subsystem's role narrow.

**Layout (done).** A scroll container is declared with the `overflow` attribute
(`[layout]` flag), whose value is a **list of scroll axes** in the engine's
flow-relative vocabulary — `overflow([main])` scrolls along the flow (a row
horizontally, a column vertically). The container keeps its box at its
externally-determined size and lets content exceed it on the scroll axis, where
**flex-grow is inert** (the content defines the extent, not the container). It
self-describes on `layout{}`: the existing `overflow` scalar doubles as the
main-axis max scroll offset, and a `scroll: Axes` key marks the container.
Children stay placed in **content coordinates**, so **scrolling never relayouts**
— it is repaint-only, like focus. This is the contract the register/paint/hit
steps below build on.

**Scroll offset — the third interaction register (future).** Offset lives in a
**scroll register** beside the node tree, keyed by **node identity**, maintained
by a reducer over `pointer_scroll` events and **clamped to `[0, overflow]`** from
the layout (the `overflow` scalar is the max offset). It is not an attribute, not in the element tree, and
has no app-facing setter — so "no way for Prolog to manipulate scroll state" falls
out of the register model (decision #6), the same shape as focus and selection.

**Paint — a pure display-list transform (Phase 5).** For each scroll
container, `ui_paint` reads the register and wraps the subtree:
`clip_push(viewport)` + `transform_push(−Ox, −Oy)` … children … `transform_pop` +
`clip_pop`. Children are in content coordinates, so the transform slides them and
the clip masks to the viewport. No new ops, no relayout.

**Hit testing + routing (future).** `ui_hit` applies the **same**
offset-subtract-and-clip when descending a scroll container (a point outside the
viewport misses clipped children). `pointer_scroll` routes to the **innermost**
scroll container under the pointer, with **scroll-chaining** to an ancestor once
the inner one clamps. The register re-anchors to node identity after tree changes
and clears when its container is removed (`focus_reconcile`-style).

**Not the same as native-widget scroll.** A native widget scrolling its content
internally (see "Native widgets") is _native-owned view state_, mutated at input
latency and invisible to layout. Framework scroll containers are _Prolog-owned
registers + display-list transforms_. Same word, different mechanism.

**Extending to a second axis (`cross`) — future.** Only `main` is honored, and
the `overflow` list form keeps a second axis _unrepresentable_ rather than
degraded, so adding `cross` is a purely additive change to the accepted set
(clip-without-scroll, an empty list, likewise). The two axes are asymmetric in the
engine — the main axis _stacks_ (`SumExtents`, overflow falls out at
ui_layout.pl:145) while the cross axis _maxes_ against a **bounded** constraint
(`ContentCrossMax`) that prevents cross overflow rather than tracking it — so
cross scroll needs a new path that relaxes the cross constraint. Everything
downstream (register, paint, hit) is already 2D — a `(Ox, Oy)` offset — so the
whole cost sits in layout plus one real consequence: **relaxing the cross
constraint disables text wrapping** (wrapping is driven by the bounded cross width
parley breaks against), correct for a horizontally-scrolling code view but a
surprising coupling — so it is deferred until a genuine 2D surface needs it. Note
unified 2D surfaces (code editors, spreadsheets) are largely native widgets that
scroll internally anyway; nesting a cross-scroll container inside a main-scroll one
gives _independent_ offsets, not one unified pane.

**`native` gains nothing** — scrolling is entirely Prolog-side (layout
constraint + register + paint transform), which is why the native library surface below
carries no scroll calls.

## Decoration

`decoration` is the general edge-anchored primitive-painting attribute — the one
mechanism for borders, rules, underlines, strikethroughs, and highlights (there is
no separate `border`/`underline` attribute; `decoration` subsumes them). Its value
is a **list of decorations**, painted in list order (later on top within a layer).
Each decoration is _semantically a single rect_ but **renders as one or more
rects** across line and bidi fragments (see Fragmentation).

### Model

A decoration is a rect whose **four edges are each `at(Ref, Offset)`** — an anchor
plus a signed offset in layout units (1/64px). There are **no widths and no
defaults**: all four edges are always given, and a "thickness" is simply two edges
sharing an anchor at different offsets (an underline = `cross_start: at(baseline,
0), cross_end: at(baseline, 64)`).

```
deco{
  layer:       below | above,                       % vs the element's own content
  main_start:  at(MainRef,  OffUnits),
  main_end:    at(MainRef,  OffUnits),
  cross_start: at(CrossRef, OffUnits),
  cross_end:   at(CrossRef, OffUnits),
  fill:        rgba(R,G,B,A),                        % optional
  stroke:      stroke(rgba(R,G,B,A), WeightUnits),   % optional (≥1 of fill/stroke)
  radius:      RadiusUnits                           % optional (absent = square)
}

MainRef  ∈ main_start | main_end | text_start | text_end
CrossRef ∈ cross_start | cross_end
         | baseline | ascent | descent | cap_height | x_height | line_top | line_bottom
```

- `main_start`/`main_end`/`cross_start`/`cross_end` reference the element's
  **border-box** edges; the content box needs no anchors of its own — it is already
  reachable through the typographic anchors.
- `text_*` and the cross font-metric anchors reference the element's **own text**
  and are **inline-only**.
- Anchors are **flow-relative and direction-aware**: `start`/`end` and positive
  offset follow content direction, so in RTL the main axis flips (matching the
  text). For inline text anchors, main = inline/advance axis, cross = block/line
  axis, regardless of any container `direction`.
- **Inverted rects are accepted** (`main_start` resolving past `main_end`, mixing a
  box anchor on one edge with a text anchor on the other): resolve and emit as-is.

### Fragmentation (why one rect becomes many)

Fragmentation is a property of **inline layout**, not of which anchor is used:

- **Block element:** a single rect, resolved purely in Prolog from the layout's
  border box (`layout{width,height}` + padding). Text anchors are meaningless here
  and are **silently dropped**; because there are no defaults, a decoration naming
  any text anchor on a block is dropped in full (its edge cannot otherwise be
  filled).
- **Inline element:** the element's text — and its own box — is spread over line
  fragments and bidi visual runs, so **every** edge (box or text) resolves **per
  fragment**, emitting one rect per fragment, exactly like `text_selection_rects`.
  This needs per-fragment geometry only parley has, so it crosses the native boundary. Thus
  `decoration` is pure paint for blocks but **handle-dependent for inlines** —
  depending on Phase 1's handle plus the metrics query below, not just Phase 3.

### Lowering to the display list

Per resolved rect, `ui_paint` emits into the decoration's `below`/`above` slot:

- `fill` → `fill_rect`, or with `radius` → `rounded_rect`
- `stroke` → `stroke_rect` (weight centered on the edge; inside/outside stroke
  alignment deferred)
- `fill` + `stroke` → both, fill under stroke
- `stroke` + `radius` needs a rounded stroke op the vocab lacks — add
  `rounded_stroke_rect(X,Y,W,H,Radius,Weight,Color)` when this lands.

`below` decorations paint before the element's content/children, `above` after.
Only these two positions exist; **global z-index is deferred**. Interaction with
scrolling: box-anchored block decorations paint _outside_ the scroll transform
(they belong to the viewport); inline text-anchored rects are in content space and
scroll with the content.

## Prolog-facing API (target surface)

Grouped by the module that will own each predicate. Signatures are the contract
each phase builds toward.

### `native` (foreign predicates, registered from Rust)

```prolog
%! version(-Version:atom) is det.          % smoke test that load works

%! create_window(+Options:dict, -Window) is det.
%   Options ~ window{title, width, height}. Window is an opaque integer/blob id.
%! destroy_window(+Window) is det.
%! window_viewport(+Window, -WidthPx, -HeightPx) is det.   % logical px
%! window_scale(+Window, -ScaleFactor) is det.

%! poll_events(+Window, -Events:list) is det.       % non-blocking pump + drain
%   Events are ground terms (see event vocabulary below).

%! measure_native(+Window, +Request, -Metrics) is semidet.
%   Request  = measure_inline(Runs, Options, MaxW)   (as ui_layout emits)
%   Metrics  = metrics(WidthUnits, HeightUnits)
%   Side effect: caches the parley layout + per-run source map under a handle,
%   surfaced to Prolog as the inline layout{}'s `text: Handle` field.

%! render(+Window, +DisplayList:list) is det.       % build vello scene + present

% Character-level text queries — operate on a live handle, resolve byte offsets
% back to node-local code-point offsets via the source map (see decision below).
%! text_position_at(+Handle, +XUnits, +YUnits, -RelPath, -Offset, -Affinity) is semidet.
%   point → text position (parley clamps within the flow). Click, drag-select, IME.
%! text_caret_rect(+Handle, +RelPath, +Offset, +Affinity, -X, -Y, -H) is semidet.
%   position → caret geometry. Caret rendering, scroll-into-view.
%! text_selection_rects(+Handle, +RelPath0,+Off0, +RelPath1,+Off1, -Rects) is det.
%   sub-range within one handle → highlight rects. Selection painting.
%! text_boundary(+Handle, +RelPath, +Offset, +Kind, +Dir, -RelPath2, -Offset2) is semidet.
%   Kind ∈ grapheme|word|line. Arrow-key nav, double/triple-click select.
%! text_line_metrics(+Handle, +RelPath, -Fragments) is det.
%   Per visual line-fragment (bidi-split) of the node's text, in content units:
%   the fragment's border box + advance start/end (main axis) and the cross
%   font-metric lines (baseline, ascent, descent, cap_height, x_height, line_top,
%   line_bottom). Native reports geometry only; ui_paint composes each decoration
%   rect (box vs text value per edge + offset). Backs inline `decoration` (see
%   "Decoration"); matches decision #4's geometry/policy split.

% Native widgets (persistent, key-identified instances — see "Native widgets").
%! measure_widget(+WidgetId, +Constraints, -Metrics) is det.
%   Intrinsic size of the widget's *current, last-relayout* content within
%   Constraints. Note the sizing limitation below: content mutated natively
%   between relayouts is not reflected here until the model round-trips.
%! set_native_focus(+Window, +NativeId, +Bool) is det.
%   Framework-internal (NOT app-facing): the focus manager tells a native widget
%   it gained/lost *global* focus; native notifies the platform a11y layer.
%! widget_value(+WidgetId, -Value) is det.          % read (mainly uncontrolled mode)
% Instance lifecycle (create/stash/destroy) is bridged by the host driver from
% the change list, not called by the pure core.
% NB: scrolling adds nothing here — it is entirely Prolog-side (see "Scrolling").
```

### `ui_paint` (new pure Prolog module)

```prolog
%! paint_tree(+Node, +Layout, +Registers, -DisplayList:list) is det.
%   Walks node+layout, emits ordered primitive draw ops (see op vocabulary).
%   Registers carries the interaction registers (focus, selection) so paint can
%   overlay a focus ring / selection without a relayout (decisions #3, #6).
```

### `ui_hit` (new pure Prolog module)

```prolog
%! hit_test(+Layout, +XUnits, +YUnits, -Path:list) is semidet.
%   Deepest node path whose box contains the point. Coarse routing.
%! nearest_text(+Layout, +XUnits, +YUnits, -Path, -LocalX, -LocalY) is semidet.
%   Nearest selectable text node in document order, with the point clamped into
%   its box — the routing step for character-level hit testing (see decision #4).
%   Prolog then calls text_position_at/6 on that node's handle.
```

### `ui_focus` (new pure Prolog module — the focus manager)

```prolog
%! focusable_order(+Node, -Targets:list) is det.
%   Focusable node identities in tab order (document order + focus scopes).
%! focus_step(+Node, +Focus, +Dir, -Focus2) is semidet.   % Dir ∈ forward|back
%! focus_at(+Node, +Path, -Focus) is semidet.              % pointer-down → focus
%! focus_reconcile(+Node, +Changes, +Focus0, -Focus) is det.
%   Re-anchors the register to node identity after a tree change; clears it if the
%   focused node was removed. Never invents an app-visible focus attribute.
```

### Event vocabulary (native → Prolog, ground terms)

```
resized(WidthPx, HeightPx)      scale_changed(Factor)     close_requested
pointer_moved(XUnits, YUnits)   pointer_button(Button, up|down)
pointer_scroll(DxUnits, DyUnits)
key(Key, up|down, Mods)         text_input(String)
redraw_requested                focused(true|false)

% From native widgets, tagged by the element's key (this *is* on_change):
change(WidgetId, Value)         submit(WidgetId)
% Focus *requests* only — native never announces global focus (decision #6):
focus_requested(WidgetId, Reason)   focus_escape(WidgetId, forward|back)
```

### Display-list op vocabulary (Prolog → native, ground terms; units = 1/64 px)

```
fill_rect(X, Y, W, H, Color)            stroke_rect(X, Y, W, H, Width, Color)
rounded_rect(X, Y, W, H, Radius, Color) clip_push(X, Y, W, H)   clip_pop
rounded_stroke_rect(X, Y, W, H, Radius, Width, Color)   % rounded + stroked decoration
text(Handle, X, Y, Color)               layer_push(Opacity)     layer_pop
transform_push(Dx, Dy)                  transform_pop
widget(WidgetId, X, Y, W, H)            % black box: native draws its own editor
```

`Color` = `rgba(R,G,B,A)` with 0..255 integer channels. The set starts minimal
(Phases 3) and grows.

## Implementation phases

Ordered by dependency and by how much real capability each unlocks. Each phase
is independently testable and lands as its own commit(s).

### Phase 0 — Loadable module (done)

`native` (`native/src/`) is a working `cdylib` exposing `version/1` (plus a
`panic_test/0` regression test) through the Prolog module `ui_native`
(`core/ui_native.pl`) — living in `core/` with the rest of the Prolog codebase,
not under `native/`, since the native library is never meant to stand alone.
It loads the compiled library via an explicit per-OS path +
`load_foreign_library(Path, [install(install_native)])` — the explicit
`install(Function)` option bypasses SWI's default entry-point-name derivation
from the _resolved_ filename, which Cargo's `lib` prefix on Unix would
otherwise break. Every foreign entry point runs through a `catch_unwind` guard
(`native/src/term.rs`) that turns a panic into a catchable
`error(foreign_error(Msg), _)` instead of aborting the process (required since
Rust 1.71, where an uncaught panic across an `extern "C"` boundary aborts).
`swi_fli/build.rs` discovers SWI-Prolog via `swipl --dump-runtime-variables`
(portable across Linux/macOS/Windows, unlike a `pkg-config` `.pc` file, which
isn't reliably present outside Linux/Nix packaging) and links directly against
`libswipl` uniformly on all three platforms, avoiding per-OS linker
special-casing (macOS's `-undefined dynamic_lookup`, Windows' import library).

**Not yet verified:** the Windows path — `PLLIB`/`PLLIBSWIPL`'s shape from a
real Windows SWI install, and whether Windows' linker accepts the resulting
link config — since no Windows machine was available to test against.

### Phase 1 — Text measurement with parley (headless)

**Goal:** replace `defer_measurement` with a real measurer. Unlocks correct
layout for all real text — the highest-value integration and it needs **no
window or GPU**, so it is fully unit-testable.

**Native work (deps: `parley`):**

- Global `FontContext` + per-call `LayoutContext`. System fonts via parley's
  bundled fontique; a `register_font/1` predicate can come later.
- Build a parley `Layout` from `Runs`: map each `run(Text, Inherited)`'s
  inherited attrs (`font_family`, `font_size`, `font_weight`, `slant`, `lang`)
  to parley style spans; insert `box(RelPath,W,H)` runs as parley **inline
  boxes**. Apply `Options` (`alignment`, `leading`). Constrain to `MaxW`
  (`inf` → unbounded), break lines, take `ceil` metrics, convert px → units.
- Store the built `Layout` in a handle-keyed cache; surface the handle as the
  inline `layout{}`'s `text:` field so paint (Phase 3) and interaction (Phase 4)
  can reach it.
- **Build a per-run source map** alongside the layout. An inline flattens
  _multiple_ descendant text nodes into one concatenated stream that parley
  indexes by UTF-8 byte; the source map records, per run, its `RelPath`, its byte
  span in the flattened stream, and a byte↔code-point table for that span. Every
  position crossing back to Prolog is resolved through it into
  `(RelPath, code-point Offset)`. Without this, parley's byte offsets are
  meaningless to the tree-addressed core.
- Define the cache-invalidation contract against `ui_layout`'s dirty tracking;
  handles are valid for the current layout tree and not evicted while present in
  it.

**Prolog API delivered:** `measure_native(+Win, +Request, -Metrics)`. In this
phase `Win` may be a headless font/measure context handle rather than a real
window, so tests need no display.

**Milestone:** point `ui_layout_tests` at `measure_native` (behind a flag) and
confirm layouts match hand-computed expectations for wrapped text, mixed
runs, and inline boxes.

**Risks:** unit rounding vs. `ceiling` in `inline_layout`; handle cache identity
and invalidation; font fallback determinism across machines (tests must not
depend on a specific installed font's metrics — use a bundled test font).

### Phase 2 — Windowing + event loop with winit

**Goal:** a real window whose viewport/scale feed the `root{}`, and a pump that
turns OS events into Prolog terms. Still no drawing (clear-to-color only).

**Native work (deps: `winit`):**

- Single global `EventLoop`, created on the main thread; windows in an id-keyed
  registry. Driven by `pump_app_events` from `poll_events/2` (non-blocking).
- `create_window/2`, `destroy_window/1`, `window_viewport/3`, `window_scale/2`.
- Event translation to the event vocabulary above; buffer between pumps and
  drain on `poll_events`. Convert pointer coords logical px → units.

**Prolog API delivered:** `create_window/2`, `destroy_window/1`,
`window_viewport/3`, `window_scale/2`, `poll_events/2`.

**Milestone:** a Prolog `main/0` that opens a window, loops on `poll_events`,
prints events, and quits on `close_requested`.

**Risks:** main-thread ownership on macOS; interaction with the SWI toplevel
(run the demo via `swipl script`, not the interactive REPL, or document the
constraint); event coalescing (pointer move floods).

### Phase 3 — GPU surface + painting with wgpu + vello

**Goal:** draw the display list to the window. First pixels on screen.

**Native work (deps: `wgpu`, `vello`):**

- Per-window wgpu `Instance`/`Adapter`/`Device`/`Queue`/`Surface`, resized on
  `resized`; a vello `Renderer`.
- `render/2`: fold the display list into a vello `Scene`, applying the root
  `scale_factor/64` transform, then render to the surface texture and present.
- Implement the initial op set: `fill_rect`, `rounded_rect`, `stroke_rect`,
  `clip_push`/`clip_pop`, `text(Handle,...)` (draw the cached parley layout's
  glyphs), `layer_push`/`layer_pop`, `transform_push`/`transform_pop`.

**Prolog work:** new `ui_paint` module — `paint_tree(Node, Layout,
DisplayList)`. Map `decoration`/`backdrop` → rects, `color` → text color,
`opacity` → `layer_*`, `overflow` → `clip_*`.

**Prolog API delivered:** `render/2`; `ui_paint:paint_tree/3`.

**Milestone:** end-to-end — the `app_loop` sketch above renders a static styled
tree with wrapped text, and updates on resize.

**Risks:** parley→vello glyph handoff (font/glyph id plumbing); surface
reconfiguration on resize/scale; frame pacing vs. `redraw_requested`.

### Phase 4 — Hit testing, text selection + event routing

**Goal:** route pointer/keyboard events to nodes and characters so app logic can
respond, including caret and text selection.

**Coarse routing (Prolog only):** `ui_hit:hit_test/4` walks the layout tree
against a point (respecting `child(X,Y,L)` offsets and clip/overflow). App-level
plumbing maps `pointer_*`/`key`/`text_input` events + hit paths into the model
update step.

**Character-level (Prolog/native collaboration, decision #4):**

- `ui_hit:nearest_text/6` finds the nearest selectable text node in document
  order and clamps the point into its box; Prolog then calls the node's handle
  via `text_position_at/6` to get `(RelPath, Offset, Affinity)`. This "nearest,
  not containing" contract is what lets a drag focus that misses all glyphs still
  resolve to a text position.
- **Selection state is stored as `(RelPath, Offset, Affinity)` endpoints, never
  as handles** — it survives relayout; the path re-resolves to the current
  handle for querying/painting.
- **Rendering composes per-node sub-ranges.** Prolog orders anchor/focus in
  document order, walks the text nodes between them, and assigns each its covered
  sub-range (anchor node `[anchorOffset..len]`, interior nodes `[0..len]`, focus
  node `[0..focusOffset]`), calling `text_selection_rects/6` per handle and
  concatenating rects into the display list. parley never needs a cross-layout
  selection; Prolog never needs glyph geometry.
- Caret rendering and arrow/word navigation use `text_caret_rect/7` and
  `text_boundary/7`.

**Focus manager (Prolog, framework — decision #6):** a `ui_focus` reducer owns
the focus register beside the node tree. Pointer-down on a focusable node and
Tab/Shift-Tab move it; `focus_reconcile/4` re-anchors it to node identity after
every tree change. Focus changes trigger **repaint only** — `paint_tree/4` reads
the register to overlay a focus ring — never relayout. No app-facing focus knob
exists. Native accessibility/widget focus _requests_ (`focus_requested/2`,
`focus_escape/2`) are inputs the manager validates; applied focus is pushed to
the relevant widget via `set_native_focus/3`, which also notifies the platform
a11y layer.

**Milestone:** clicking a node reports its path; dragging selects text across
paragraph boundaries with correct highlight rects and a rendered caret; Tab moves
a visible focus ring through focusable nodes with no relayout.

### Phase 5 — Post-layout transforms & compositing refinements

**Goal:** effects that must _not_ trigger relayout — scrolling (the scroll
register → `clip`/`transform` display-list wrap; see "Scrolling"), animated
transforms, opacity/blur layers, nested clipping. All expressed as display-list
transforms in `ui_paint` plus any new vello ops (`blur`, richer `layer` blend
modes). Font registration (`register_font/1`) and image/backdrop assets also land
here.

### Phase 6 — Native widgets

**Goal:** the first native-backed element — a `text_input` — under the controlled
`value` / on-change contract (see "Native widgets"). Depends on text layout
(Phase 1), rendering (Phase 3), and event routing (Phase 4).

**Native work:** a persistent editor instance (parley's editing module) keyed by
widget id; `measure_widget/3`, `set_native_focus/3`, `widget_value/2`; expansion
of the `widget(...)` display-list op into a self-drawn editor; consume
keyboard/`text_input`/IME only while holding global focus, emit `change`/
`submit`, and raise `focus_requested/2` / `focus_escape/2` rather than moving
global focus itself; the buffer-reconciliation rule (replace only on divergence,
re-map caret).

**Host/Prolog work:** register `text_input` as a native-backed tag; bridge
instance lifecycle from the change list; add `attribute(value, 1, [])`; route
`change` events into the model so the controlled loop closes; wire the widget's
focus requests/escapes through the `ui_focus` manager and push applied focus back
with `set_native_focus/3`.

**Milestone:** a controlled `text_input` whose `value` lives in the Prolog model,
echoes without caret jump, and can be transformed (e.g. forced uppercase) from
Prolog. The field is **externally sized** and scrolls internally — content-driven
autogrow is intentionally out of scope (see the limitation above).

**Risks:** buffer reconciliation / caret re-mapping; IME correctness; focus and
event-routing precedence between widgets and app-level key handling.

## Open decisions to confirm before coding

1. **Display list vs. native dict walk** (decision #2). Recommendation: display
   list. This is the highest-leverage call and hardest to reverse later.
2. **Text-handle lifetime**: cache keyed by node path (needs invalidation wired
   to dirty tracking) vs. by content hash (self-invalidating, simpler, costs a
   hash + dedup). Lean toward content hash first.
3. **Threading**: single-threaded Prolog-drives model for now. Revisit only if
   we want a live REPL alongside a running window.
4. **Text index space** (recommendation adopted above): positions cross the native boundary
   as **node-local code-point offsets** — parley's UTF-8 byte offsets converted
   via the source map — so Prolog never sees byte indexing and offsets compose
   with its own string ops. Grapheme movement is served by `text_boundary/7`
   rather than by making clusters the index unit.
5. **Native widget control mode**: controlled by default (single source of truth,
   whole-`value` marshalling per change); uncontrolled opt-in for large/sensitive
   fields. Accept the resulting limitation — native widgets are externally sized
   and cannot size to their own content (see "Native widgets").
6. **How focusability is declared** (decision #6 settles _ownership_, not this).
   The current focus is a canonical register with _no app-facing focus attribute_;
   but the framework still needs to know which nodes are tab-eligible. Options:
   derive from role/tag (native widgets + known interactive elements) vs. a static
   `focusable`/`role` marker (eligibility only — distinct from adjusting focus).
   Lean toward deriving from role, with an accessibility `role` attribute feeding
   both focusability and the a11y tree. Confirm before `ui_focus` lands.

```

```
