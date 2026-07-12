:- module(ui_native_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(ui_native).

main :-
    run_tests.

:- begin_tests(ui_native).

test('version/1 returns an atom') :-
    version(V),
    atom(V).

:- end_tests(ui_native).
