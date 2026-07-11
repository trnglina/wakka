:- module(ui_attributes_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(ui_attributes).

main :-
    run_tests.

:- begin_tests(normalize_attributes).

test('keeps known attributes while discarding unmatched ones') :-
    normalize_attributes([id(x), color(blue), color(a, b), lang(en)], Pairs),
    Pairs == [color-[blue], lang-[en]].

test('discards an unknown key') :-
    normalize_attributes([id(x)], Pairs),
    Pairs == [].

test('discards a wrong-arity form of a known key') :-
    normalize_attributes([color(a, b)], Pairs),
    Pairs == [].

test('discards a bare atom (arity zero)') :-
    normalize_attributes([color], Pairs),
    Pairs == [].

test('keeps the last value for a duplicated key') :-
    normalize_attributes([color(a), color(b)], Pairs),
    Pairs == [color-[b]].

test('keeps a list argument as a single value') :-
    normalize_attributes([color([a, b])], Pairs),
    Pairs == [color-[[a, b]]].

test('produces an empty list for no attributes') :-
    normalize_attributes([], Pairs),
    Pairs == [].

test('fails on a malformed non-atom key', [fail]) :-
    normalize_attributes([42], _).

:- end_tests(normalize_attributes).
