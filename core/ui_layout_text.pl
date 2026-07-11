:- module(ui_layout_text, [ measure_text/4 ]).

%  Wraps the `layout_text` native library, which registers
%  `measure_text(+Runs, +Options, +MaxW, -Metrics)`: the text measurer ui_layout
%  calls to size inline content. The library builds a Parley layout from the
%  runs and returns `metrics(W, H)` in layout units.

:- prolog_load_context(directory, Dir),
atomic_list_concat([Dir, '/../target/debug'], Debug),
atomic_list_concat([Dir, '/../target/release'], Release),
asserta(user:file_search_path(foreign, Debug)),
asserta(user:file_search_path(foreign, Release)).

:- use_foreign_library(foreign(liblayout_text)).
