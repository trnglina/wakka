:- module(ui_state_bench, []).
:- initialization(main, main).

:- use_module(library(ansi_term)).
:- use_module(library(lists)).
:- use_module(library(statistics)).
:- use_module(ui_state).
:- use_module(ui_changes).

main :-
    nl,
    deep_ingest_scenario, nl,
    wide_ingest_scenario, nl,
    deep_apply_scenario, nl,
    deep_inherit_apply_scenario, nl,
    wide_reorder_apply_scenario, nl.

% --- Ingest scenarios --- %

deep_ingest_scenario :-
    ansi_format([fg(white), bg(blue)], ' Ingest Deep Tree ', []), nl,
    print_header(depth),
    forall(member(Depth, [500, 1000, 2000, 5000]),
           ( deep_dsl(Depth, "leaf", Dsl),
             measure([insert_child([], Dsl)], none, MinWallMs, Inferences),
             print_row(Depth, MinWallMs, Inferences) )).

wide_ingest_scenario :-
    ansi_format([fg(white), bg(blue)], ' Ingest Wide Tree ', []), nl,
    print_header(children),
    forall(member(Count, [500, 1000, 2000, 5000]),
           ( wide_keyed_dsl(Count, Dsl),
             measure([insert_child([], Dsl)], none, MinWallMs, Inferences),
             print_row(Count, MinWallMs, Inferences) )).

% --- Apply scenarios --- %

deep_apply_scenario :-
    ansi_format([fg(white), bg(blue)], ' Apply Deep set_attribute (non-inheritable) ', []), nl,
    print_header(depth),
    forall(member(Depth, [500, 1000, 2000, 5000]),
           ( deep_dsl(Depth, "leaf", Dsl),
             build(Dsl, Tree),
             deep_path(Depth, Path),
             measure([set_attribute(Path, key, [x])], Tree, MinWallMs, Inferences),
             print_row(Depth, MinWallMs, Inferences) )).

deep_inherit_apply_scenario :-
    ansi_format([fg(white), bg(blue)], ' Apply Deep set_attribute (inheritable) ', []), nl,
    print_header(depth),
    forall(member(Depth, [500, 1000, 2000, 5000]),
           ( deep_dsl(Depth, "leaf", Dsl),
             build(Dsl, Tree),
             measure([set_attribute([], color, [blue])], Tree, MinWallMs, Inferences),
             print_row(Depth, MinWallMs, Inferences) )).

wide_reorder_apply_scenario :-
    ansi_format([fg(white), bg(blue)], ' Apply Wide Reorder (detach/attach) ', []), nl,
    print_header(children),
    forall(member(Count, [500, 1000, 2000, 5000]),
           ( wide_keyed_dsl(Count, PrevDsl),
             wide_keyed_dsl_reversed(Count, NextDsl),
             build(PrevDsl, Tree),
             element_changes(PrevDsl, NextDsl, Changes),
             measure(Changes, Tree, MinWallMs, Inferences),
             print_row(Count, MinWallMs, Inferences) )).

% --- Harness --- %

%! measure(+Changes, +PrevNode, -MinWallMs, -Inferences) is det.

measure(Changes, PrevNode, MinWallMs, Inferences) :-
    Repeats = 5,
    findall(Wall,
            ( between(1, Repeats, _),
              call_time(apply_ok(Changes, PrevNode), Dict),
              Wall = Dict.wall ),
            Walls),
    min_list(Walls, MinWallSec),
    MinWallMs is MinWallSec * 1000,
    call_time(apply_ok(Changes, PrevNode), InfDict),
    Inferences = InfDict.inferences.

%! apply_ok(+Changes, +PrevNode) is det.

apply_ok(Changes, PrevNode) :-
    node_apply_changes(Changes, PrevNode, NextNode),
    ( NextNode == none ; is_dict(NextNode) ), !.
apply_ok(Changes, _) :-
    throw(error(bad_apply(Changes), apply_ok/2)).

print_header(SizeLabel) :-
    ansi_format([italic], " ~w~t~12| ~w~t~26| ~w ~n", [SizeLabel, 'wall (ms)', inferences]).

print_row(Size, WallMs, Inferences) :-
    format(" ~d~t~12| ~2f~t~26| ~D ~n", [Size, WallMs, Inferences]).

% --- Tree / change generators --- %

%! build(+DSL, -Tree) is det.

build(DSL, Tree) :- node_apply_changes([insert_child([], DSL)], none, Tree).

%! deep_dsl(+Depth, +Leaf, -DSL) is det.

deep_dsl(0, Leaf, Leaf) :- !.
deep_dsl(N, Leaf, div([Inner])) :-
    N > 0,
    N1 is N - 1,
    deep_dsl(N1, Leaf, Inner).

%! deep_path(+Depth, -Path) is det.
%
% Root-first index list targeting the innermost div (not the leaf text
% node, which has no `attributes` key).

deep_path(Depth, Path) :-
    Steps is Depth - 1,
    length(Path, Steps),
    maplist(=(0), Path).

%! wide_keyed_dsl(+Count, -DSL) is det.

wide_keyed_dsl(Count, div(Children)) :-
    Last is Count - 1,
    numlist(0, Last, Is),
    maplist(keyed_child, Is, Children).

%! wide_keyed_dsl_reversed(+Count, -DSL) is det.

wide_keyed_dsl_reversed(Count, div(Children)) :-
    Last is Count - 1,
    numlist(0, Last, Is),
    reverse(Is, Reversed),
    maplist(keyed_child, Reversed, Children).

keyed_child(I, span([key(Key)], [])) :-
    atom_concat(k, I, Key).
