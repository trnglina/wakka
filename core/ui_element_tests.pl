:- module(ui_element_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(ui_element).

main :-
    run_tests.

:- begin_tests(attribute_parts).

test('parses an atomic value') :-
    attribute_parts(id(a), Key, Value),
    Key == id, Value == [a].

test('parses a numeric value') :-
    attribute_parts(main_size(42), Key, Value),
    Key == main_size, Value == [42].

test('parses a list value') :-
    attribute_parts(class([a, b]), Key, Value),
    Key == class, Value == [[a, b]].

test('parses an empty list value') :-
    attribute_parts(class([]), Key, Value),
    Key == class, Value == [[]].

test('parses a nested list value') :-
    attribute_parts(data([a, [1, b]]), Key, Value),
    Key == data, Value == [[a, [1, b]]].

test('parses a bare atom') :-
    attribute_parts(foo, Key, Value),
    Key == foo, Value == [].

test('parses a compound argument') :-
    attribute_parts(id(f(x)), Key, Value),
    Key == id, Value == [f(x)].

test('parses an arbitrary-arity term') :-
    attribute_parts(style(a, b), Key, Value),
    Key == style, Value == [a, b].

test('parses a multi-argument term with a nested compound') :-
    attribute_parts(on(click, f(x)), Key, Value),
    Key == on, Value == [click, f(x)].

test('constructs from key and value') :-
    attribute_parts(Attr, id, [a]),
    Attr == id(a).

test('constructs a bare atom from an empty value') :-
    attribute_parts(Attr, disabled, []),
    Attr == disabled.

test('constructs a multi-argument term') :-
    attribute_parts(Attr, style, [a, b]),
    Attr == style(a, b).

test('constructs with a nested compound argument') :-
    attribute_parts(Attr, id, [f(x)]),
    Attr == id(f(x)).

test('refuses to construct from a non-list value', [fail]) :-
    attribute_parts(_, id, f(x)).

test('refuses to construct with a non-atom key', [fail]) :-
    attribute_parts(_, 42, [a]).

test('waits for the key before constructing') :-
    attribute_parts(Attr, Key, [v]),
    var(Attr),
    Key = id,
    Attr == id(v).

test('constructs with the value supplied later') :-
    attribute_parts(Attr, id, Value),
    var(Attr),
    Value = [a],
    Attr == id(a).

test('rejects a non-list value supplied later', [fail]) :-
    attribute_parts(_, id, Value),
    Value = f(x).

test('parses a term whose value is still a variable') :-
    attribute_parts(id(V), Key, Value),
    Key == id,
    Value == [V].

:- end_tests(attribute_parts).

:- begin_tests(element_parts).

test('parses with attributes and children') :-
    element_parts(div([id(a)], [span([])]), Tag, Attrs, Children),
    Tag = div,
    Attrs = [id(a)],
    Children = [span([])].

test('parses with empty attribute list and children') :-
    element_parts(div([], [span([])]), Tag, Attrs, Children),
    Tag = div,
    Attrs = [],
    Children = [span([])].

test('parses with children') :-
    element_parts(div([span([])]), Tag, Attrs, Children),
    Tag = div,
    Attrs = [],
    Children = [span([])].

test('parses with empty attributes and empty children') :-
    element_parts(div([], []), Tag, Attrs, Children),
    Tag = div,
    Attrs = [],
    Children = [].

test('parses with attributes and empty children') :-
    element_parts(div([id(a)], []), Tag, Attrs, Children),
    Tag = div,
    Attrs = [id(a)],
    Children = [].

test('parses single-argument form with empty children') :-
    element_parts(div([]), Tag, Attrs, Children),
    Tag = div,
    Attrs = [],
    Children = [].

test('parses without validating the attribute list contents') :-
    element_parts(div([a, b], [x]), Tag, Attrs, Children),
    Tag == div,
    Attrs == [a, b],
    Children == [x].

test('parses with an improper attribute list') :-
    element_parts(div([a|b], [x]), Tag, Attrs, Children),
    Tag == div,
    Attrs == [a|b],
    Children == [x].

test('parses even when the children position is not a list') :-
    element_parts(div([x], y), Tag, Attrs, Children),
    Tag == div,
    Attrs == [x],
    Children == y.

test('rejects non-list attributes', [fail]) :-
    element_parts(f(foo, bar), _, _, _).

test('rejects a bare atom', [fail]) :-
    element_parts(foo, _, _, _).

test('rejects an over-arity term', [fail]) :-
    element_parts(f(a, b, c), _, _, _).

test('rejects a list term as a node', [fail]) :-
    element_parts([a, b], _, _, _).

test('rejects a compound value in the attribute position', [fail]) :-
    element_parts(f(foo(x), [c]), _, _, _).

test('constructs with attributes and children') :-
    element_parts(Node, div, [id(a)], [x]),
    Node == div([id(a)], [x]).

test('constructs with children') :-
    element_parts(Node, div, [], [x]),
    Node == div([x]).

test('constructs with empty attributes and empty children') :-
    element_parts(Node, div, [], []),
    Node == div([]).

test('constructs with attributes and empty children') :-
    element_parts(Node, div, [id(a)], []),
    Node == div([id(a)], []).

test('waits for the tag before constructing') :-
    element_parts(Node, Tag, [], [x]),
    var(Node),
    Tag = div,
    Node == div([x]).

test('waits for the tag before constructing with attributes') :-
    element_parts(Node, Tag, [id(a)], [x]),
    var(Node),
    Tag = div,
    Node == div([id(a)], [x]).

test('rejects a non-atom tag supplied later', [fail]) :-
    element_parts(_, Tag, [], [x]),
    Tag = 42.

test('rejects a compound tag supplied later', [fail]) :-
    element_parts(_, Tag, [], [x]),
    Tag = f(x).

test('constructs with children supplied later') :-
    element_parts(Node, div, [], Children),
    Node == div(Children),
    Children = [y],
    Node == div([y]).

test('constructs even when children is supplied as a non-list') :-
    element_parts(Node, div, [], Children),
    Children = foo,
    Node == div(foo).

test('constructs with an unbound attribute list, defaulting to no attributes') :-
    element_parts(Node, div, Attrs, []),
    Node == div([]),
    Attrs == [].

:- end_tests(element_parts).
