:- module(ui_layout_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(ui_changes).
:- use_module(ui_layout).
:- use_module(ui_state).

main :-
    run_tests.

build(El, Node) :-
    node_apply_changes([insert_child([], El)], none, Node).

root(W, H, Node, root{viewport_width: W, viewport_height: H, node: Node}).

lay(El, W-H, Layout) :-
    build(El, Node),
    root(W, H, Node, Root),
    layout_tree(measure_none, Root, Layout).

%  Layout geometry is in layout units; u/2 converts expected logical pixels.

u(Px, Units) :-
    px_units(Px, Units).

measure_fake(measure_inline(Runs, _, _), metrics(W, H)) :-
    u(14, H),
    runs_width(Runs, W).

runs_width([], 0).
runs_width([run(Text, _)|Runs], W) :- !,
    string_length(Text, N),
    runs_width(Runs, W0),
    u(7, CharW),
    W is W0 + N * CharW.
runs_width([box(_, BoxW, _)|Runs], W) :-
    runs_width(Runs, W0),
    W is W0 + BoxW.

:- begin_tests(root).

test('the root fills the viewport') :-
    lay(div([], []), 100-50, L),
    u(100, W), u(50, H),
    get_dict(width, L, W),
    get_dict(height, L, H),
    get_dict(path, L, []).

test('an explicit size on the root is inert') :-
    lay(div([main_size(1), cross_size(999)], []), 100-50, L),
    u(100, W), u(50, H),
    get_dict(width, L, W),
    get_dict(height, L, H).

test('an empty tree has no layout') :-
    root(100, 50, none, Root),
    layout_tree(measure_none, Root, L),
    L == none.

:- end_tests(root).

:- begin_tests(column_row_fixed).

test('a column stacks fixed children vertically') :-
    lay(div([], [div([main_size(30), cross_size(10)], []),
                 div([main_size(50), cross_size(10)], [])]),
        100-100, L),
    u(45, X), u(30, Y1),
    get_dict(children, L, [child(X, 0, A), child(X, Y1, B)]),
    u(30, HA), get_dict(height, A, HA),
    u(50, HB), get_dict(height, B, HB).

test('a row places fixed children along the x axis') :-
    lay(div([direction(row)], [div([main_size(30), cross_size(10)], []),
                               div([main_size(50), cross_size(10)], [])]),
        100-100, L),
    u(45, Y), u(30, X1),
    get_dict(children, L, [child(0, Y, _), child(X1, Y, _)]).

test('an unsized container shrink-wraps to its children') :-
    lay(div([], [div([], [div([main_size(30), cross_size(30)], []),
                          div([main_size(50), cross_size(20)], [])])]),
        200-200, L),
    get_dict(children, L, [child(_, 0, Inner)]),
    u(30, W), get_dict(width, Inner, W),
    u(80, H), get_dict(height, Inner, H).

test('child layouts carry their state paths') :-
    lay(div([], [div([], [div([main_size(10), cross_size(10)], [])])]), 100-100, L),
    get_dict(children, L, [child(_, _, Inner)]),
    get_dict(path, Inner, [0]),
    get_dict(children, Inner, [child(_, _, Leaf)]),
    get_dict(path, Leaf, [0, 0]).

:- end_tests(column_row_fixed).

:- begin_tests(flex).

test('flex children divide the remaining main extent') :-
    lay(div([direction(row)], [div([main_size(40), cross_size(10)], []),
                               div([flex(1), cross_size(10)], []),
                               div([flex(3), cross_size(10)], [])]),
        100-50, L),
    u(40, X1), u(55, X2),
    get_dict(children, L, [child(0, _, A), child(X1, _, B), child(X2, _, C)]),
    u(40, WA), get_dict(width, A, WA),
    u(15, WB), get_dict(width, B, WB),
    u(45, WC), get_dict(width, C, WC).

test('flex children fill the whole main extent') :-
    lay(div([direction(row)], [div([flex(1), cross_size(10)], []),
                               div([flex(1), cross_size(10)], [])]),
        100-50, L),
    u(50, X1),
    get_dict(children, L, [child(0, _, A), child(X1, _, B)]),
    u(50, W), get_dict(width, A, W),
    get_dict(width, B, W).

test('flex shares partition the extent exactly') :-
    lay(div([direction(row)], [div([flex(1), cross_size(10)], []),
                               div([flex(1), cross_size(10)], []),
                               div([flex(1), cross_size(10)], [])]),
        100-50, L),
    get_dict(children, L, Children),
    findall(W, (member(child(_, _, C), Children), get_dict(width, C, W)), Ws),
    maplist(integer, Ws),
    sum_list(Ws, Sum),
    u(100, Sum),
    \+ get_dict(overflow, L, _).

test('flex clamps to zero when nothing remains') :-
    lay(div([direction(row)], [div([main_size(120), cross_size(10)], []),
                               div([flex(1), cross_size(10)], [])]),
        100-50, L),
    get_dict(children, L, [_, child(_, _, B)]),
    get_dict(width, B, 0).

test('flex on an unbounded main axis throws',
     [throws(error(layout_error(unbounded_flex, [0]), _))]) :-
    lay(div([], [div([], [div([flex(1)], [])])]), 100-50, _).

:- end_tests(flex).

:- begin_tests(flex_fit).

test('a tight fit overrides an explicit main_size') :-
    lay(div([direction(row)], [div([flex(1), main_size(10), cross_size(10)], []),
                               div([flex(1), cross_size(10)], [])]),
        100-50, L),
    u(50, X1),
    get_dict(children, L, [child(0, _, A), child(X1, _, _)]),
    u(50, W), get_dict(width, A, W).

test('a loose fit honors an explicit main_size below the share') :-
    lay(div([direction(row)], [div([main_size(40), cross_size(10)], []),
                               div([flex(1), fit(loose), main_size(20), cross_size(10)], [])]),
        100-50, L),
    u(40, X1),
    get_dict(children, L, [_, child(X1, _, B)]),
    u(20, W), get_dict(width, B, W).

test('a loose fit caps content at the share') :-
    lay(div([direction(row)], [div([flex(1), fit(loose), direction(row)],
                                   [div([main_size(80), cross_size(10)], [])])]),
        50-50, L),
    get_dict(children, L, [child(0, _, B)]),
    u(50, W), get_dict(width, B, W).

test('loose slack becomes free space for main_axis alignment') :-
    lay(div([direction(row), main_axis(end)],
            [div([flex(1), fit(loose), main_size(20), cross_size(10)], [])]),
        100-50, L),
    u(80, X),
    get_dict(children, L, [child(X, _, _)]).

test('a loose flex inline wraps at its share') :-
    build(div([direction(row)],
              [div([main_size(30), cross_size(10)], []),
               span([display(inline), flex(1), fit(loose)], ["hello world!!!"])]), Node),
    root(100, 100, Node, Root),
    layout_tree(measure_fake, Root, L),
    u(30, X1),
    get_dict(children, L, [child(0, _, _), child(X1, _, T)]),
    u(70, W), get_dict(width, T, W).

test('a tight flex inline is forced to its share') :-
    build(div([direction(row)], [span([display(inline), flex(1)], ["hi"])]), Node),
    root(100, 50, Node, Root),
    layout_tree(measure_fake, Root, L),
    get_dict(children, L, [child(0, _, T)]),
    u(100, W), get_dict(width, T, W).

test('a pending tight flex inline still occupies its share') :-
    lay(div([direction(row)], [span([display(inline), flex(1)], ["hi"])]), 100-50, L),
    get_dict(children, L, [child(0, _, T)]),
    u(100, W), get_dict(width, T, W),
    get_dict(pending, T, measure_inline(_, _, W)).

test('a rigid inline in a row is measured with unbounded width') :-
    lay(div([direction(row)], ["hi"]), 100-50, L),
    get_dict(children, L, [child(_, _, T)]),
    get_dict(pending, T, measure_inline(_, _, inf)).

:- end_tests(flex_fit).

:- begin_tests(overflow).

test('main-axis overflow is reported on the container') :-
    lay(div([direction(row)], [div([main_size(120), cross_size(10)], [])]), 100-50, L),
    u(20, O),
    get_dict(overflow, L, O).

test('a fitting container carries no overflow key') :-
    lay(div([], [div([main_size(10), cross_size(10)], [])]), 100-100, L),
    \+ get_dict(overflow, L, _).

:- end_tests(overflow).

:- begin_tests(alignment).

align_xs(Align, PxXs) :-
    lay(div([direction(row), main_axis(Align)],
            [div([main_size(20), cross_size(10)], []), div([main_size(20), cross_size(10)], [])]),
        100-50, L),
    get_dict(children, L, Children),
    findall(X, member(child(X, _, _), Children), Xs),
    maplist(u, PxXs, Xs).

test('main_axis start packs children to the leading edge') :-
    align_xs(start, [0, 20]).

test('main_axis end packs children to the trailing edge') :-
    align_xs(end, [60, 80]).

test('main_axis center centers the children') :-
    align_xs(center, [30, 50]).

test('main_axis space_between spreads children to the edges') :-
    align_xs(space_between, [0, 80]).

test('main_axis space_around halves the outer gaps') :-
    align_xs(space_around, [15, 65]).

test('main_axis space_evenly equalizes all gaps') :-
    align_xs(space_evenly, [20, 60]).

test('space_between distributes indivisible free space exactly') :-
    lay(div([direction(row), main_axis(space_between)],
            [div([main_size(1), cross_size(1)], []),
             div([main_size(1), cross_size(1)], []),
             div([main_size(1), cross_size(1)], []),
             div([main_size(1), cross_size(1)], [])]),
        101-50, L),
    get_dict(children, L, Children),
    findall(X, member(child(X, _, _), Children), Xs),
    maplist(integer, Xs),
    last(Xs, XLast),
    u(100, XLast).

cross_y(Align, Y) :-
    lay(div([direction(row), cross_axis(Align)], [div([main_size(20), cross_size(10)], [])]),
        100-50, L),
    get_dict(children, L, [child(_, Y, _)]).

test('cross_axis start aligns to the leading edge') :-
    cross_y(start, 0).

test('cross_axis defaults to center') :-
    lay(div([direction(row)], [div([main_size(20), cross_size(10)], [])]), 100-50, L),
    u(20, Y),
    get_dict(children, L, [child(_, Y, _)]).

test('cross_axis end aligns to the trailing edge') :-
    u(40, Y),
    cross_y(end, Y).

test('cross_axis stretch forces children to fill the cross axis') :-
    lay(div([direction(row), cross_axis(stretch)], [div([main_size(20)], [])]), 100-50, L),
    get_dict(children, L, [child(_, 0, C)]),
    u(50, H), get_dict(height, C, H).

test('cross_axis stretch forces a measured inline to fill the cross axis') :-
    build(div([direction(row), cross_axis(stretch)], ["hi"]), Node),
    root(100, 50, Node, Root),
    layout_tree(measure_fake, Root, L),
    get_dict(children, L, [child(0, 0, T)]),
    u(14, W), get_dict(width, T, W),
    u(50, H), get_dict(height, T, H).

test('cross_axis stretch forces a pending inline to fill the cross axis') :-
    lay(div([direction(row), cross_axis(stretch)], ["hi"]), 100-50, L),
    get_dict(children, L, [child(0, 0, T)]),
    u(50, H), get_dict(height, T, H),
    get_dict(pending, T, _).

:- end_tests(alignment).

:- begin_tests(margin_padding).

test('padding offsets children and deflates the content box') :-
    lay(div([padding(10), cross_axis(start)], [div([main_size(20), cross_size(30)], [])]),
        100-100, L),
    u(10, P),
    get_dict(children, L, [child(P, P, _)]).

test('padding grows a shrink-wrapped container') :-
    lay(div([cross_axis(start)],
            [div([padding(10)], [div([main_size(20), cross_size(30)], [])])]),
        200-200, L),
    get_dict(children, L, [child(0, 0, Inner)]),
    u(50, W), get_dict(width, Inner, W),
    u(40, H), get_dict(height, Inner, H).

test('margin consumes main-axis space and offsets the child') :-
    lay(div([cross_axis(start)], [div([margin(5), main_size(10), cross_size(10)], []),
                                  div([main_size(10), cross_size(10)], [])]),
        100-100, L),
    u(5, M), u(20, Y1),
    get_dict(children, L, [child(M, M, _), child(0, Y1, _)]).

test('four-value margin follows top-right-bottom-left order') :-
    lay(div([cross_axis(start)], [div([margin(1, 2, 3, 4), main_size(10), cross_size(10)], [])]),
        100-100, L),
    u(4, X), u(1, Y),
    get_dict(children, L, [child(X, Y, _)]).

test('flex distribution accounts for margins') :-
    lay(div([direction(row)], [div([main_size(40), cross_size(10)], []),
                               div([flex(1), margin(0, 5, 0, 5), cross_size(10)], [])]),
        100-50, L),
    u(45, X1),
    get_dict(children, L, [_, child(X1, _, B)]),
    u(50, W), get_dict(width, B, W).

:- end_tests(margin_padding).

:- begin_tests(text_stub).

test('text yields a pending measurement request') :-
    lay(div([font_size(12), padding(10)], ["hello"]), 100-100, L),
    get_dict(children, L, [child(_, _, P)]),
    get_dict(width, P, 0),
    get_dict(height, P, 0),
    get_dict(path, P, [0]),
    get_dict(pending, P, measure_inline(Runs, Options, MaxW)),
    Runs == [run("hello", attrs{font_size: [12]})],
    Options == inline_options{alignment: start, leading: none},
    u(80, MaxW).

test('inline options come from the owning block element') :-
    lay(div([alignment(justify), leading(4)], ["hi"]), 100-100, L),
    get_dict(children, L, [child(_, _, P)]),
    get_dict(pending, P, measure_inline(_, inline_options{alignment: justify, leading: 4}, _)).

test('measured text flows into shrink-wrap sizing') :-
    build(div([cross_axis(start)], [div([], ["hi"])]), Node),
    root(200, 200, Node, Root),
    layout_tree(measure_fake, Root, L),
    get_dict(children, L, [child(0, 0, Inner)]),
    u(14, S),
    get_dict(width, Inner, S),
    get_dict(height, Inner, S),
    get_dict(children, Inner, [child(0, 0, P)]),
    get_dict(width, P, S),
    get_dict(height, P, S),
    \+ get_dict(pending, P, _).

:- end_tests(text_stub).

:- begin_tests(inline_runs).

test('each inline child is its own flow item') :-
    lay(div([], ["a",
                 span([display(inline)], ["b"]),
                 img([display(inline), main_size(5), cross_size(5)], []),
                 div([main_size(10), cross_size(10)], []),
                 "c"]),
        100-100, L),
    get_dict(children, L, [child(_, _, P1), child(_, _, P2), child(_, _, P3),
                           child(_, _, Block), child(_, _, P4)]),
    get_dict(path, P1, [0]),
    get_dict(pending, P1, measure_inline([run("a", _)], _, _)),
    get_dict(path, P2, [1]),
    get_dict(pending, P2, measure_inline([run("b", _)], _, _)),
    get_dict(path, P3, [2]),
    u(5, B5),
    get_dict(pending, P3, measure_inline([box([], B5, B5)], _, _)),
    u(10, WBlock), get_dict(width, Block, WBlock),
    get_dict(path, P4, [4]),
    get_dict(pending, P4, measure_inline([run("c", _)], _, _)).

test('an inline element flattens its descendants into one measurement') :-
    lay(div([], [span([display(inline)],
                      ["a", span([display(inline)], ["b"])])]),
        100-100, L),
    get_dict(children, L, [child(_, _, P)]),
    get_dict(path, P, [0]),
    get_dict(pending, P, measure_inline(Runs, _, _)),
    Runs = [run("a", _), run("b", _)].

test('a block nested in inline content becomes a zero-sized box') :-
    lay(div([], [span([display(inline)], ["x", div([], [])])]), 100-100, L),
    get_dict(children, L, [child(_, _, P)]),
    get_dict(path, P, [0]),
    get_dict(pending, P, measure_inline(Runs, _, _)),
    Runs = [run("x", _), box([1], 0, 0)].

:- end_tests(inline_runs).

:- begin_tests(relayout_reuse).

test('an identical relayout reuses the whole tree') :-
    build(div([], [div([main_size(10), cross_size(10)], [])]), Node),
    root(100, 100, Node, Root),
    layout_tree(measure_none, Root, L0),
    relayout_tree(measure_none, [], Root, L0, L1),
    same_term(L0, L1).

test('a non-layout attribute change reuses the whole tree') :-
    build(div([], [div([main_size(10), cross_size(10)], [])]), Node0),
    Changes = [set_attribute([0], color, [red])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node0, Root0),
    layout_tree(measure_none, Root0, L0),
    root(100, 100, Node1, Root1),
    relayout_tree(measure_none, Changes, Root1, L0, L1),
    same_term(L0, L1).

test('a viewport change reuses unaffected children') :-
    build(div([], [div([main_size(10), cross_size(10)], [])]), Node),
    root(100, 100, Node, Root0),
    layout_tree(measure_none, Root0, L0),
    root(100, 200, Node, Root1),
    relayout_tree(measure_none, [], Root1, L0, L1),
    \+ same_term(L0, L1),
    u(200, H), get_dict(height, L1, H),
    get_dict(children, L0, [child(_, _, C0)]),
    get_dict(children, L1, [child(_, _, C1)]),
    same_term(C0, C1).

test('a size change recomputes only the affected child') :-
    build(div([direction(row), cross_axis(start)],
              [div([main_size(40), cross_size(10)], []), div([main_size(30), cross_size(10)], [])]),
          Node0),
    root(100, 100, Node0, Root0),
    layout_tree(measure_none, Root0, L0),
    Changes = [set_attribute([0], main_size, [60])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(measure_none, Changes, Root1, L0, L1),
    u(40, X40), u(60, X60),
    get_dict(children, L0, [child(0, 0, A0), child(X40, 0, B0)]),
    get_dict(children, L1, [child(0, 0, A1), child(X60, 0, B1)]),
    \+ same_term(A0, A1),
    get_dict(width, A1, X60),
    same_term(B0, B1).

test('an inherited layout attribute change re-requests text measurement') :-
    build(div([font_size(12)], ["hi"]), Node0),
    root(100, 100, Node0, Root0),
    layout_tree(measure_none, Root0, L0),
    Changes = [set_attribute([], font_size, [20])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(measure_none, Changes, Root1, L0, L1),
    get_dict(children, L1, [child(_, _, P)]),
    get_dict(pending, P, measure_inline([run("hi", attrs{font_size: [20]})], _, _)).

test('an inserted child recomputes the container positions') :-
    build(div([cross_axis(start)], [div([main_size(10), cross_size(10)], [])]), Node0),
    root(100, 100, Node0, Root0),
    layout_tree(measure_none, Root0, L0),
    Changes = [insert_child([0], div([main_size(20), cross_size(10)], []))],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(measure_none, Changes, Root1, L0, L1),
    u(20, Y1),
    get_dict(children, L1, [child(0, 0, New), child(0, Y1, _)]),
    get_dict(height, New, Y1).

:- end_tests(relayout_reuse).

:- begin_tests(integration).

test('incremental relayout equals a fresh layout') :-
    Prev = div([direction(row)],
               [div([key(a), main_size(30), cross_size(10)], []),
                div([key(b), flex(1)], ["hello"])]),
    Next = div([direction(row), main_axis(space_between)],
               [div([key(b), flex(1)], ["hello"]),
                div([key(a), main_size(50), cross_size(10)], [])]),
    build(Prev, Node0),
    root(200, 100, Node0, Root0),
    layout_tree(measure_none, Root0, L0),
    element_changes(Prev, Next, Changes),
    node_apply_changes(Changes, Node0, Node1),
    root(200, 100, Node1, Root1),
    relayout_tree(measure_none, Changes, Root1, L0, L1),
    layout_tree(measure_none, Root1, LFresh),
    L1 == LFresh.

:- end_tests(integration).
