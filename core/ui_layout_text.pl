:- module(ui_layout_text, [ measure_text/4 ]).

%  Wraps the `layout_text` native library, which registers
%  `measure_text(+Runs, +Options, +MaxW, -Metrics)`: the text measurer ui_layout
%  calls to size and shape inline content. The library builds a Parley layout
%  from the runs and returns `metrics(W, H, Lines)` — the box size plus the
%  per-glyph layout for painting — all in layout units (1/64 px, floats):
%
%    Lines  = [ line(Baseline, Ascent, Descent, Items), ... ]
%    Item   = glyph_run(font(Family, Weight, Style), Size, Color, synth(Bold, Skew), Glyphs)
%           | box(BoxId, X, Y, W, H)
%    Glyphs = [ glyph(Id, X, Y, Advance, Start, End), ... ]
%
%  Id is a glyph id (not a codepoint); X/Y are absolute within the inline's box
%  (baseline applied); Start-End is the glyph's cluster's byte range into the
%  run-concatenated text. Color is the run's `color` attribute value verbatim,
%  or the atom `none`. It throws type_error(max_width, MaxW) if MaxW is neither
%  a number nor `inf`.

:- prolog_load_context(directory, Dir),
atomic_list_concat([Dir, '/../target/debug'], Debug),
atomic_list_concat([Dir, '/../target/release'], Release),
asserta(user:file_search_path(foreign, Debug)),
asserta(user:file_search_path(foreign, Release)).

:- use_foreign_library(foreign(liblayout_text)).
