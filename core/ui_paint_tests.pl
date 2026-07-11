:- module(ui_paint_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(library(aggregate)).
:- use_module(library(lists)).
:- use_module(ui_layout).
:- use_module(ui_paint).
:- use_module(ui_state).

%  End-to-end paint tests: layout -> layout_changes -> ui_paint -> the native
%  vello scene -> a headless render, read back as pixels. They need a working
%  wgpu adapter (a GPU or a software Vulkan like lavapipe); the whole group is
%  skipped cleanly when none is available. Requires `cargo build -p native`.

main :-
    run_tests.

lay_root(El, W, H, L) :-
    node_apply_changes([insert_child([], El)], none, Node),
    layout_tree(root{viewport_width: W, viewport_height: H, node: Node}, L).

%  Paints El into a fresh scene and renders it W x H.
paint_layout(El, W, H, Pixels) :-
    lay_root(El, W, H, L),
    paint_apply([paint_drop([])]),          % clear any residual scene
    layout_changes(none, L, Changes),
    paint_apply(Changes),
    paint_render(W, H, Pixels).

has_adapter :-
    catch(paint_render(1, 1, _), _, fail).

:- begin_tests(paint_render, [condition(has_adapter)]).

test('a text layout renders to a full-size, non-blank image') :-
    paint_layout(div([font_size(20), color(red)], ["Hi"]), 64, 32, Pixels),
    string_length(Pixels, N),
    N =:= 64 * 32 * 4,
    string_codes(Pixels, Codes),
    aggregate_all(count, (member(C, Codes), C =\= 255), NonWhite),
    NonWhite > 0.

test('an empty scene renders blank at the requested size') :-
    paint_apply([paint_drop([])]),
    paint_render(8, 8, Pixels),
    string_length(Pixels, N),
    N =:= 8 * 8 * 4,
    string_codes(Pixels, Codes),
    forall(member(C, Codes), C =:= 255).

byte_sum(Pixels, Sum) :-
    string_codes(Pixels, Codes),
    sum_list(Codes, Sum).

test('a backdrop fills the node box') :-
    paint_layout(div([backdrop(red)], []), 16, 16, Pixels),
    string_length(Pixels, N),
    N =:= 16 * 16 * 4,
    string_codes(Pixels, Codes),
    aggregate_all(count, (member(C, Codes), C =\= 255), NonWhite),
    NonWhite > 0.

test('opacity fades a backdrop toward the white base') :-
    paint_layout(div([backdrop(red)], []), 16, 16, Opaque),
    paint_layout(div([backdrop(red), opacity(0.5)], []), 16, 16, Faded),
    byte_sum(Opaque, OpaqueSum),
    byte_sum(Faded, FadedSum),
    FadedSum > OpaqueSum.

test('re-rendering after a move keeps the text drawn') :-
    lay_root(div([font_size(20), color(blue)], ["Ok"]), 64, 32, L),
    paint_apply([paint_drop([])]),
    layout_changes(none, L, Changes),
    paint_apply(Changes),
    get_dict(children, L, [child(_, _, Inline)]),
    get_dict(path, Inline, Path),
    px_units(5, Five),
    paint_apply([paint_move(Path, Five, Five)]),
    paint_render(64, 32, Pixels),
    string_codes(Pixels, Codes),
    aggregate_all(count, (member(C, Codes), C =\= 255), NonWhite),
    NonWhite > 0.

:- end_tests(paint_render).
