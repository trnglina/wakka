:- module(ui_native, [ measure_text/4,
                       scene_put/7, scene_move/3, scene_drop/1, scene_render_headless/3 ]).

%  The single loader for the `native` shared library — the one FLI boundary for
%  the core. `native` consumes the pure worker crates (layout_text, and later
%  paint) and registers every foreign predicate the core calls. Loading it does
%  not start any GPU/windowing (those initialise lazily), so text measurement
%  works without a display.
%
%  Registered predicates:
%    measure_text(+Runs, +Options, +MaxW, -metrics(W, H, Lines))
%      Sizes and shapes inline content via Parley and returns the box size plus
%      the per-glyph layout, all in layout units (1/64 px, floats):
%
%        Lines  = [ line(Baseline, Ascent, Descent, Items), ... ]
%        Item   = glyph_run(font(FontId, Index, Family), Size, Color,
%                           synth(Bold, Skew), Glyphs)
%               | box(BoxId, X, Y, W, H)
%        Glyphs = [ glyph(Id, X, Y, Advance, Start, End), ... ]
%
%      Id is a glyph id (not a codepoint); X/Y are absolute within the inline's
%      box; Start-End is the glyph's cluster's byte range into the
%      run-concatenated text; Color is the run's `color` attribute value
%      verbatim, or the atom `none`. FontId/Index identify the exact face the run
%      was shaped against — the paint side renders these glyph ids against that
%      registered face rather than re-resolving from Family (which is carried for
%      inspection only). Throws type_error(max_width, MaxW) when MaxW is neither a
%      number nor `inf`.
%
%    scene_put(+Path, +X, +Y, +W, +H, +Draw, +Style)
%    scene_move(+Path, +X, +Y)
%    scene_drop(+Path)
%      Mutate the retained native render scene, keyed by state Path. Geometry is
%      in layout units; Draw is `glyphs(Lines)` (as returned by measure_text) or
%      the atom `none`. Style is `style(Backdrop, Opacity)` where Backdrop is a
%      color term (as `color`) or `none`, and Opacity is a number in 0..1 or
%      `none` (fully opaque); it fills the node box behind its content and fades
%      the node and its subtree.
%
%    scene_render_headless(+Width, +Height, -Pixels)
%      Render the current scene to an offscreen Width x Height (pixel) texture
%      and unify Pixels with its RGBA bytes (a string). Lazily initialises the
%      GPU; fails if no adapter is available.

%  Resolve the cargo build output relative to this file (core/ -> ../target/*).
:- prolog_load_context(directory, Dir),
   atomic_list_concat([Dir, '/../target/debug'], Debug),
   atomic_list_concat([Dir, '/../target/release'], Release),
   asserta(user:file_search_path(foreign, Debug)),
   asserta(user:file_search_path(foreign, Release)).

%  The cdylib is `libnative.so`; SWI does not add a `lib` prefix when resolving
%  `foreign/1`, so it loads under its on-disk base name.
:- use_foreign_library(foreign(libnative)).
