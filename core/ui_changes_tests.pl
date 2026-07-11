:- module(ui_changes_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(library(lists)).
:- use_module(ui_changes).

main :-
    run_tests.

%! changes_match(+Actual, +Expected) is semidet.
%  Attribute-change order is unspecified, so compare order-insensitively.
changes_match(Actual, Expected) :-
    msort(Actual, Sorted),
    msort(Expected, Sorted).

:- begin_tests(element_changes).

test('emits no changes for identical text nodes') :-
    element_changes("hello", "hello", Changes),
    Changes == [].

test('emits no changes for identical empty elements') :-
    element_changes(div([]), div([]), Changes),
    Changes == [].

test('emits no changes for identical unkeyed siblings') :-
    element_changes(div([span([]), span([])]), div([span([]), span([])]), Changes),
    Changes == [].

test('emits no changes for unchanged mixed text and element children') :-
    element_changes(div(["a", span([])]), div(["a", span([])]), Changes),
    Changes == [].

test('replaces the root when text content differs') :-
    element_changes("a", "b", Changes),
    Changes = [detach_child([], _), insert_child([], "b")].

test('replaces a text root with an element root') :-
    element_changes("a", div([]), Changes),
    Changes = [detach_child([], _), insert_child([], div([]))].

test('replaces an element root with a text root') :-
    element_changes(div([]), "a", Changes),
    Changes = [detach_child([], _), insert_child([], "a")].

test('replaces the root when the tag differs') :-
    element_changes(div([]), span([]), Changes),
    Changes = [detach_child([], _), insert_child([], span([]))].

test('replaces the root wholesale rather than diffing into its children') :-
    element_changes(div([span([])]), p([span([])]), Changes),
    Changes = [detach_child([], _), insert_child([], p([span([])]))].

test('replaces a nested text child when its content differs') :-
    element_changes(div(["a"]), div(["b"]), Changes),
    Changes = [detach_child([0], _), insert_child([0], "b")].

test('replaces a nested child when its tag differs') :-
    element_changes(div([span([])]), div([p([])]), Changes),
    Changes = [detach_child([0], _), insert_child([0], p([]))].

test('adds a new attribute') :-
    element_changes(div([]), div([color(a)], []), Changes),
    Changes == [set_attribute([], color, [a])].

test('discards a bare-atom attribute') :-
    element_changes(div([], []), div([disabled], []), Changes),
    Changes == [].

test('discards a wrong-arity attribute') :-
    element_changes(div([], []), div([color(a, b)], []), Changes),
    Changes == [].

test('discards an unknown attribute') :-
    element_changes(div([], []), div([id(a)], []), Changes),
    Changes == [].

test('removes an attribute no longer present') :-
    element_changes(div([color(a)], []), div([]), Changes),
    Changes == [remove_attribute([], color)].

test('changes an atomic attribute value') :-
    element_changes(div([color(a)], []), div([color(b)], []), Changes),
    Changes == [set_attribute([], color, [b])].

test('changes a list attribute value') :-
    element_changes(div([color([a, b])], []), div([color([a, c])], []), Changes),
    Changes == [set_attribute([], color, [[a, c]])].

test('emits no change for an unchanged list attribute value') :-
    element_changes(div([color([a, b])], []), div([color([a, b])], []), Changes),
    Changes == [].

test('emits no change for an unchanged attribute') :-
    element_changes(div([color(a)], []), div([color(a)], []), Changes),
    Changes == [].

test('emits removals and sets for a mixed attribute change') :-
    element_changes(
        div([color(a), lang(x), key(k)], []),
        div([lang(y), key(k)], []),
        Changes),
    changes_match(Changes, [remove_attribute([], color),
                            set_attribute([], lang, [y])]).

test('removes all attributes') :-
    element_changes(div([color(a), lang(x)], []), div([]), Changes),
    changes_match(Changes, [remove_attribute([], color), remove_attribute([], lang)]).

test('adds all attributes') :-
    element_changes(div([]), div([color(a), lang(x)], []), Changes),
    changes_match(Changes, [set_attribute([], color, [a]), set_attribute([], lang, [x])]).

test('inserts a child appended to an empty list') :-
    element_changes(div([]), div([span([])]), Changes),
    Changes == [insert_child([0], span([]))].

test('detaches the sole remaining child') :-
    element_changes(div([span([])]), div([]), Changes),
    Changes = [detach_child([0], _)].

test('inserts multiple children appended to a shorter list') :-
    element_changes(div([span([])]), div([span([]), p([]), a([])]), Changes),
    Changes == [insert_child([1], p([])), insert_child([2], a([]))].

test('detaches multiple trailing children') :-
    element_changes(div([span([]), p([]), a([])]), div([span([])]), Changes),
    Changes = [detach_child([1], _), detach_child([1], _)].

test('diffs unkeyed same-tag siblings positionally instead of reordering') :-
    element_changes(
        div([span([color(a)], []), span([color(b)], [])]),
        div([span([color(b)], []), span([color(a)], [])]),
        Changes),
    Changes == [set_attribute([0], color, [b]), set_attribute([1], color, [a])].

test('detaches and reinserts the tail when an unkeyed tag mismatches mid-list') :-
    element_changes(
        div([span([]), p([]), a([])]),
        div([span([]), h1([]), a([])]),
        Changes),
    Changes = [detach_child([1], _), detach_child([1], _),
               insert_child([1], h1([])), insert_child([2], a([]))].

test('swaps two keyed children via detach and attach') :-
    element_changes(
        div([span([key(a)], []), span([key(b)], [])]),
        div([span([key(b)], []), span([key(a)], [])]),
        Changes),
    Changes = [detach_child([0], K), attach_child([1], K)].

test('inserts a new keyed child at the start without disturbing the existing one') :-
    element_changes(
        div([span([key(a)], [])]),
        div([span([key(z)], []), span([key(a)], [])]),
        Changes),
    Changes == [insert_child([0], span([key(z)], []))].

test('inserts a new keyed child at the end') :-
    element_changes(
        div([span([key(a)], [])]),
        div([span([key(a)], []), span([key(z)], [])]),
        Changes),
    Changes == [insert_child([1], span([key(z)], []))].

test('shuffles three keyed children via paired detach/attach') :-
    element_changes(
        div([span([key(a)], []), span([key(b)], []), span([key(c)], [])]),
        div([span([key(c)], []), span([key(a)], []), span([key(b)], [])]),
        Changes),
    Changes = [detach_child([0], K0), detach_child([0], K1),
               attach_child([1], K0), attach_child([2], K1)].

test('does not match a shared key value across different tags') :-
    element_changes(
        div([span([key(a)], [])]),
        div([p([key(a)], [])]),
        Changes),
    Changes = [detach_child([0], _), insert_child([0], p([key(a)], []))].

test('replaces a child that gains a key attribute') :-
    element_changes(
        div([span([])]),
        div([span([key(a)], [])]),
        Changes),
    Changes = [detach_child([0], _), insert_child([0], span([key(a)], []))].

test('replaces a child that loses its key attribute') :-
    element_changes(
        div([span([key(a)], [])]),
        div([span([])]),
        Changes),
    Changes = [detach_child([0], _), insert_child([0], span([]))].

test('reorders mixed keyed and unkeyed siblings via detach and attach') :-
    element_changes(
        div([span([key(a)], []), p([])]),
        div([p([]), span([key(a)], [])]),
        Changes),
    Changes = [detach_child([0], K), attach_child([1], K)].

test('accumulates a two-level path in root-to-leaf order') :-
    element_changes(
        div([span([]), div([p([color(a)], [])])]),
        div([span([]), div([p([color(b)], [])])]),
        Changes),
    Changes == [set_attribute([1, 0], color, [b])].

test('accumulates a path through a keyed child') :-
    element_changes(
        div([span([key(a)], [p([color(x)], [])])]),
        div([span([key(a)], [p([color(y)], [])])]),
        Changes),
    Changes == [set_attribute([0, 0], color, [y])].

test('a nested removal does not reuse a pending move stash key') :-
    element_changes(
        div([span([key(mv)], []), div([key(bb)], [span([key(rm)], [])])]),
        div([div([key(bb)], []), span([key(mv)], [])]),
        Changes),
    Changes = [detach_child([0], MvKey), detach_child([0, 0], RmKey),
               attach_child([1], MvKey)],
    MvKey \== RmKey.

test('a nested replacement does not reuse a pending move stash key') :-
    element_changes(
        div([span([key(mv)], []), div([key(bb)], ["old"])]),
        div([div([key(bb)], ["new"]), span([key(mv)], [])]),
        Changes),
    Changes = [detach_child([0], MvKey), detach_child([0, 0], ReplKey),
               insert_child([0, 0], "new"), attach_child([1], MvKey)],
    MvKey \== ReplKey.

test('fails when the previous element is not ground', [fail]) :-
    element_changes(div([_], []), div([color(a)], []), _).

test('fails when the next element is not ground', [fail]) :-
    element_changes(div([]), _, _).

:- end_tests(element_changes).
