:- module(ui_changes_bench, []).
:- initialization(main, main).

:- use_module(library(ansi_term)).
:- use_module(library(lists)).
:- use_module(library(statistics)).
:- use_module(ui_changes).

main :-
    nl,
    deep_scenario, nl,
    wide_keyed_scenario, nl.

% --- Scenarios --- %

deep_scenario :-
    ansi_format([fg(white), bg(blue)], ' Deep Tree ', []), nl,
    print_header(depth),
    forall(member(Depth, [500, 1000, 2000, 5000]),
           ( deep_tree(Depth, "a", Prev),
             deep_tree(Depth, "b", Next),
             measure(Prev, Next, MinWallMs, Inferences),
             print_row(Depth, MinWallMs, Inferences) )).

wide_keyed_scenario :-
    ansi_format([fg(white), bg(blue)], ' Wide Tree with Keys ', []), nl,
    print_header(children),
    forall(member(Count, [500, 1000, 2000, 5000]),
           ( wide_keyed_prev(Count, Prev),
             wide_keyed_next(Count, Next),
             measure(Prev, Next, MinWallMs, Inferences),
             print_row(Count, MinWallMs, Inferences) )).

% --- Harness --- %

%! measure(+Prev, +Next, -MinWallMs, -Inferences) is det.

measure(Prev, Next, MinWallMs, Inferences) :-
    Repeats = 5,
    findall(Wall,
            ( between(1, Repeats, _),
              call_time(diff_ok(Prev, Next), Dict),
              Wall = Dict.wall ),
            Walls),
    min_list(Walls, MinWallSec),
    MinWallMs is MinWallSec * 1000,
    call_time(diff_ok(Prev, Next), InfDict),
    Inferences = InfDict.inferences.

%! diff_ok(+Prev, +Next) is det.

diff_ok(Prev, Next) :-
    element_changes(Prev, Next, Changes),
    ( is_list(Changes) -> true ; throw(error(bad_changes(Changes), diff_ok/2)) ).

print_header(SizeLabel) :-
    ansi_format([italic], " ~w~t~12| ~w~t~26| ~w ~n", [SizeLabel, 'wall (ms)', inferences]).

print_row(Size, WallMs, Inferences) :-
    format(" ~d~t~12| ~2f~t~26| ~D ~n", [Size, WallMs, Inferences]).

% --- Tree generators --- %

%! deep_tree(+Depth, +Leaf, -Tree) is det.

deep_tree(0, Leaf, Leaf) :- !.
deep_tree(N, Leaf, div([Inner])) :-
    N > 0,
    N1 is N - 1,
    deep_tree(N1, Leaf, Inner).

%! wide_keyed_prev(+Count, -Tree) is det.

wide_keyed_prev(Count, div(Children)) :-
    Last is Count - 1,
    numlist(0, Last, Is),
    maplist(keyed_child, Is, Children).

%! wide_keyed_next(+Count, -Tree) is det.

wide_keyed_next(Count, div(Children)) :-
    Last is Count - 1,
    numlist(0, Last, Is),
    reverse(Is, Reversed),
    maplist(keyed_child, Reversed, Children).

keyed_child(I, span([key(Key)], [])) :-
    atom_concat(k, I, Key).
