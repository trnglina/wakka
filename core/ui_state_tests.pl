:- module(ui_state_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(ui_state).

main :-
    run_tests.

build(DSL, Tree) :- node_apply_changes([insert_child([], DSL)], none, Tree).

:- begin_tests(construction).

test('empty_node is none') :-
    empty_node(Node),
    Node == none.

test('empty change list is identity on none') :-
    node_apply_changes([], none, Next),
    Next == none.

test('empty change list is identity on a built tree') :-
    build(div([span([], [])]), Tree),
    node_apply_changes([], Tree, Next),
    Next == Tree.

test('builds a text root') :-
    build("hi", Tree),
    Tree == node{text: "hi", inherited: attrs{}}.

test('builds a nested element root') :-
    build(div([span([], [])]), Tree),
    Tree == node{ tag: div, attributes: attrs{}, inherited: attrs{},
                  children: [ node{ tag: span, attributes: attrs{},
                                    children: [], inherited: attrs{} } ] }.

test('insert_child at [] replaces the existing root') :-
    build(div([span([], [])]), Old),
    node_apply_changes([insert_child([], "new")], Old, New),
    New == node{text: "new", inherited: attrs{}}.

:- end_tests(construction).

:- begin_tests(set_attribute).

test('sets a non-inheritable attribute; children untouched') :-
    build(div([], [span([], [])]), Tree),
    node_apply_changes([set_attribute([], key, [x])], Tree, Next),
    Next == node{ tag: div, attributes: attrs{key: [x]}, inherited: attrs{},
                  children: [ node{ tag: span, attributes: attrs{},
                                    children: [], inherited: attrs{} } ] }.

test('sets an inheritable attribute and re-resolves the subtree') :-
    build(div([], [span([], [])]), Tree),
    node_apply_changes([set_attribute([], color, [blue])], Tree, Next),
    Next == node{ tag: div, attributes: attrs{color: [blue]},
                  inherited: attrs{color: [blue]},
                  children: [ node{ tag: span, attributes: attrs{},
                                    children: [], inherited: attrs{color: [blue]} } ] }.

test('setting color on a nested node re-resolves only that subtree') :-
    build(div([color(red)], [span([], ["a"]), span([], ["b"])]), Tree),
    node_apply_changes([set_attribute([0], color, [green])], Tree, Next),
    Next == node{ tag: div, attributes: attrs{color: [red]},
                  inherited: attrs{color: [red]},
                  children:
                  [ node{ tag: span, attributes: attrs{color: [green]},
                          inherited: attrs{color: [green]},
                          children: [ node{text: "a", inherited: attrs{color: [green]}} ] },
                    node{ tag: span, attributes: attrs{},
                          inherited: attrs{color: [red]},
                          children: [ node{text: "b", inherited: attrs{color: [red]}} ] } ] }.

test('setting an existing key overwrites its value') :-
    build(div([color(red)], []), Tree),
    node_apply_changes([set_attribute([], color, [green])], Tree, Next),
    Next == node{ tag: div, attributes: attrs{color: [green]},
                  children: [], inherited: attrs{color: [green]} }.

:- end_tests(set_attribute).

:- begin_tests(remove_attribute).

test('removes a present non-inheritable attribute') :-
    build(div([key(foo), color(red)], []), Tree),
    node_apply_changes([remove_attribute([], key)], Tree, Next),
    Next == node{ tag: div, attributes: attrs{color: [red]},
                  children: [], inherited: attrs{color: [red]} }.

test('removing an overriding color falls back to the ancestor color') :-
    build(div([color(red)], [div([color(blue)], ["t"])]), Tree),
    node_apply_changes([remove_attribute([0], color)], Tree, Next),
    Next == node{ tag: div, attributes: attrs{color: [red]},
                  inherited: attrs{color: [red]},
                  children:
                  [ node{ tag: div, attributes: attrs{},
                          inherited: attrs{color: [red]},
                          children: [ node{text: "t", inherited: attrs{color: [red]}} ] } ] }.

test('removing an absent key is a no-op') :-
    build(div([color(red)], []), Tree),
    node_apply_changes([remove_attribute([], key)], Tree, Next),
    Next == Tree.

:- end_tests(remove_attribute).

:- begin_tests(insert_child).

test('appends a child at the end, inheriting the parent color') :-
    build(div([color(red)], ["a"]), Tree),
    node_apply_changes([insert_child([1], "b")], Tree, Next),
    Next == node{ tag: div, attributes: attrs{color: [red]},
                  inherited: attrs{color: [red]},
                  children: [ node{text: "a", inherited: attrs{color: [red]}},
                              node{text: "b", inherited: attrs{color: [red]}} ] }.

test('inserts an element child in the middle, shifting following siblings') :-
    build(div([span([key(a)], []), span([key(b)], [])]), Tree),
    node_apply_changes([insert_child([1], span([key(mid)], []))], Tree, Next),
    Next == node{ tag: div, attributes: attrs{}, inherited: attrs{},
                  children:
                  [ node{tag: span, attributes: attrs{key: [a]}, children: [], inherited: attrs{}},
                    node{tag: span, attributes: attrs{key: [mid]}, children: [], inherited: attrs{}},
                    node{tag: span, attributes: attrs{key: [b]}, children: [], inherited: attrs{}} ] }.

:- end_tests(insert_child).

:- begin_tests(detach_attach).

test('detaching at [] yields none') :-
    build(div([span([], [])]), Tree),
    node_apply_changes([detach_child([], k)], Tree, Next),
    Next == none.

test('detaching a child removes it and shifts remaining siblings') :-
    build(div([span([key(a)], []), span([key(b)], [])]), Tree),
    node_apply_changes([detach_child([0], k)], Tree, Next),
    Next == node{ tag: div, attributes: attrs{}, inherited: attrs{},
                  children: [ node{tag: span, attributes: attrs{key: [b]},
                                   children: [], inherited: attrs{}} ] }.

test('detach then attach moves a child within one change batch') :-
    build(div([span([key(a)], []), span([key(b)], [])]), Tree),
    node_apply_changes([detach_child([0], k), attach_child([1], k)], Tree, Next),
    Next == node{ tag: div, attributes: attrs{}, inherited: attrs{},
                  children: [ node{tag: span, attributes: attrs{key: [b]}, children: [], inherited: attrs{}},
                              node{tag: span, attributes: attrs{key: [a]}, children: [], inherited: attrs{}} ] }.

test('detach then re-attach at the same index round-trips') :-
    build(div([span([key(a)], []), span([key(b)], [])]), Tree),
    node_apply_changes([detach_child([0], k), attach_child([0], k)], Tree, Next),
    Next == Tree.

test('moving a subtree into a colored parent re-inherits the color') :-
    build(div([span([], ["x"]), div([color(green)], [])]), Tree),
    node_apply_changes([detach_child([0], k), attach_child([0, 0], k)], Tree, Next),
    Next == node{ tag: div, attributes: attrs{}, inherited: attrs{},
                  children:
                  [ node{ tag: div, attributes: attrs{color: [green]},
                          inherited: attrs{color: [green]},
                          children:
                          [ node{ tag: span, attributes: attrs{},
                                  inherited: attrs{color: [green]},
                                  children: [ node{text: "x", inherited: attrs{color: [green]}} ] } ] } ] }.

:- end_tests(detach_attach).

:- begin_tests(inheritance).

test('color propagates down a deep descendant chain') :-
    build(div([color(red)], [div([], [div([], ["deep"])])]), Tree),
    Tree == node{ tag: div, attributes: attrs{color: [red]},
                  inherited: attrs{color: [red]},
                  children:
                  [ node{ tag: div, attributes: attrs{},
                          inherited: attrs{color: [red]},
                          children:
                          [ node{ tag: div, attributes: attrs{},
                                  inherited: attrs{color: [red]},
                                  children: [ node{text: "deep", inherited: attrs{color: [red]}} ] } ] } ] }.

test('a child override only affects its own subtree, not siblings') :-
    build(div([color(red)], [div([color(blue)], ["b"]), span([], ["r"])]), Tree),
    Tree == node{ tag: div, attributes: attrs{color: [red]},
                  inherited: attrs{color: [red]},
                  children:
                  [ node{ tag: div, attributes: attrs{color: [blue]},
                          inherited: attrs{color: [blue]},
                          children: [ node{text: "b", inherited: attrs{color: [blue]}} ] },
                    node{ tag: span, attributes: attrs{},
                          inherited: attrs{color: [red]},
                          children: [ node{text: "r", inherited: attrs{color: [red]}} ] } ] }.

test('non-inheritable attributes never appear in inherited') :-
    build(div([key(x), color(red)], [span([], ["t"])]), Tree),
    Tree == node{ tag: div,
                  attributes: attrs{color: [red], key: [x]},
                  inherited: attrs{color: [red]},
                  children:
                  [ node{ tag: span, attributes: attrs{},
                          inherited: attrs{color: [red]},
                          children: [ node{text: "t", inherited: attrs{color: [red]}} ] } ] }.

test('duplicate DSL attribute keys resolve last-wins') :-
    build(div([color(red), color(blue)], []), Tree),
    Tree == node{ tag: div, attributes: attrs{color: [blue]},
                  children: [], inherited: attrs{color: [blue]} }.

test('a text root inherits nothing') :-
    build("hi", Tree),
    Tree == node{text: "hi", inherited: attrs{}}.

:- end_tests(inheritance).

:- begin_tests(errors).

test('out-of-range path index fails', [fail]) :-
    build(div([span([], [])]), Tree),
    node_apply_changes([set_attribute([5], color, [red])], Tree, _).

test('set_attribute on an empty tree fails', [fail]) :-
    node_apply_changes([set_attribute([], color, [red])], none, _).

test('set_attribute at a path into an empty tree fails', [fail]) :-
    node_apply_changes([set_attribute([0], color, [red])], none, _).

test('remove_attribute on an empty tree fails', [fail]) :-
    node_apply_changes([remove_attribute([], key)], none, _).

test('detaching the root of an empty tree fails', [fail]) :-
    node_apply_changes([detach_child([], k)], none, _).

test('detach_child at a path into an empty tree fails', [fail]) :-
    node_apply_changes([detach_child([0], k)], none, _).

test('insert_child at a path into an empty tree fails', [fail]) :-
    node_apply_changes([insert_child([0], "x")], none, _).

test('a batch reusing a stash key for two detaches fails', [fail]) :-
    build(div([span([key(a)], []), span([key(b)], [])]), Tree),
    node_apply_changes([detach_child([0], k), detach_child([0], k)], Tree, _).

test('attach without a prior detach for that key fails', [fail]) :-
    build(div([span([], [])]), Tree),
    node_apply_changes([attach_child([0], missing)], Tree, _).

test('descending into a text node fails', [fail]) :-
    build("txt", Tree),
    node_apply_changes([set_attribute([0], color, [red])], Tree, _).

:- end_tests(errors).
