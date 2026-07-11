:- module(ui_layout_tests, []).
:- initialization(main, main).

:- use_module(library(plunit)).
:- use_module(ui_changes).
:- use_module(ui_layout).
:- use_module(ui_native).
:- use_module(ui_state).

%  ui_layout measures inline content by calling ui_native (measure_text/4)
%  directly, so the whole suite drives the real Parley measurer across the
%  foreign boundary and requires the native library: run `cargo build -p native`
%  first.
%  Because metrics depend on the host's fonts, tests over text assert structural
%  or relational properties rather than exact pixels; tests whose geometry is
%  fixed by the engine (flex shares, stretch, axis_alignment of fixed-size boxes)
%  still assert exact values.

main :-
    run_tests.

build(El, Node) :-
    node_apply_changes([insert_child([], El)], none, Node).

root(W, H, Node, root{viewport_width: W, viewport_height: H, node: Node}).

lay(El, W-H, Layout) :-
    build(El, Node),
    root(W, H, Node, Root),
    layout_tree(Root, Layout).

%  Layout geometry is in layout units; u/2 converts expected logical pixels.

u(Px, Units) :-
    px_units(Px, Units).

%  Drives the native measurer with default inline options. MaxW is a unit count
%  or the atom inf; W and H come back in layout units.

measure(Runs, MaxW, W, H) :-
    measure_text(Runs, inline_options{leading: none}, MaxW, metrics(W, H, _)).

%  Drives the native measurer and returns the per-glyph Lines payload.

measure_lines(Runs, MaxW, Lines) :-
    measure_text(Runs, inline_options{leading: none}, MaxW, metrics(_, _, Lines)).

node_runs(El, Idx, Runs) :-
    build(El, Node),
    get_dict(children, Node, Children),
    nth0(Idx, Children, Child),
    ui_layout:inline_node_runs_(Child, [], Runs, []).

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
    layout_tree(Root, L),
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

test('loose slack becomes free space for main_axis axis_alignment') :-
    lay(div([direction(row), main_axis(end)],
            [div([flex(1), fit(loose), main_size(20), cross_size(10)], [])]),
        100-50, L),
    u(80, X),
    get_dict(children, L, [child(X, _, _)]).

test('a loose flex inline wraps within its share') :-
    build(div([direction(row)],
              [div([main_size(30), cross_size(10)], []),
               span([display(inline), flex(1), fit(loose)], ["hello world!!!"])]), Node),
    root(100, 100, Node, Root),
    layout_tree(Root, L),
    u(30, X1),
    get_dict(children, L, [child(0, _, _), child(X1, _, T)]),
    u(70, Share),
    get_dict(width, T, W),
    W > 0, W =< Share.

test('a tight flex inline is forced to its share') :-
    build(div([direction(row)], [span([display(inline), flex(1)], ["hi"])]), Node),
    root(100, 50, Node, Root),
    layout_tree(Root, L),
    get_dict(children, L, [child(0, _, T)]),
    u(100, W), get_dict(width, T, W).

test('a rigid inline in a row is measured unbounded, so long text overflows') :-
    lay(div([direction(row)], ["the quick brown fox jumps over the lazy dog"]), 50-50, L),
    get_dict(children, L, [child(_, _, T)]),
    u(50, Viewport),
    get_dict(width, T, W),
    W > Viewport.

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

:- begin_tests(axis_alignment).

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
    layout_tree(Root, L),
    get_dict(children, L, [child(0, 0, T)]),
    get_dict(width, T, W), W > 0,
    u(50, H), get_dict(height, T, H).

:- end_tests(axis_alignment).

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

:- begin_tests(inline_text).

test('a text node is measured to a positive box at its padded offset') :-
    lay(div([font_size(12), padding(10), cross_axis(start)], ["hello"]), 100-100, L),
    get_dict(children, L, [child(X, Y, P)]),
    u(10, Pad), X == Pad, Y == Pad,
    get_dict(path, P, [0]),
    \+ get_dict(pending, P, _),
    get_dict(width, P, W), W > 0,
    get_dict(height, P, H), H > 0.

test('inline leading from the owning block grows the text box') :-
    lay(div([font_size(16)], ["hi"]), 100-100, L0),
    get_dict(children, L0, [child(_, _, P0)]),
    get_dict(height, P0, H0),
    lay(div([font_size(16), leading(64)], ["hi"]), 100-100, L1),
    get_dict(children, L1, [child(_, _, P1)]),
    get_dict(height, P1, H1),
    H1 > H0.

test('measured text flows into shrink-wrap sizing') :-
    build(div([cross_axis(start)], [div([], ["hi"])]), Node),
    root(200, 200, Node, Root),
    layout_tree(Root, L),
    get_dict(children, L, [child(0, 0, Inner)]),
    get_dict(children, Inner, [child(0, 0, P)]),
    \+ get_dict(pending, P, _),
    get_dict(width, Inner, IW), get_dict(width, P, IW), IW > 0,
    get_dict(height, Inner, IH), get_dict(height, P, IH), IH > 0.

:- end_tests(inline_text).

:- begin_tests(inline_runs).

test('each inline child is its own measured flow item') :-
    lay(div([], ["a",
                 span([display(inline)], ["b"]),
                 img([display(inline), main_size(5), cross_size(5)], []),
                 div([main_size(10), cross_size(10)], []),
                 "c"]),
        100-100, L),
    get_dict(children, L, [child(_, _, P1), child(_, _, P2), child(_, _, P3),
                           child(_, _, Block), child(_, _, P4)]),
    get_dict(path, P1, [0]),
    get_dict(path, P2, [1]),
    get_dict(path, P3, [2]),
    u(10, WBlock), get_dict(width, Block, WBlock),
    get_dict(path, P4, [4]),
    forall(member(P, [P1, P2, P3, P4]), \+ get_dict(pending, P, _)).

test('a text node flattens to a single run carrying its inherited attributes') :-
    node_runs(div([font_size(12)], ["hello"]), 0, Runs),
    Runs == [run("hello", attrs{font_size: [12]})].

test('an inline element flattens its descendants into one run list') :-
    node_runs(div([], [span([display(inline)], ["a", span([display(inline)], ["b"])])]),
              0, Runs),
    Runs = [run("a", _), run("b", _)].

test('an explicitly sized inline element flattens to a box') :-
    node_runs(div([], [img([display(inline), main_size(5), cross_size(5)], [])]), 0, Runs),
    u(5, Five),
    Runs = [box([], Five, Five)].

test('a block nested in inline content becomes a zero-sized box') :-
    node_runs(div([], [span([display(inline)], ["x", div([], [])])]), 0, Runs),
    Runs = [run("x", _), box([1], 0, 0)].

:- end_tests(inline_runs).

:- begin_tests(relayout_reuse).

test('an identical relayout reuses the whole tree') :-
    build(div([], [div([main_size(10), cross_size(10)], [])]), Node),
    root(100, 100, Node, Root),
    layout_tree(Root, L0),
    relayout_tree([], Root, L0, L1),
    same_term(L0, L1).

test('a purely presentational attribute change reuses the whole tree') :-
    build(div([], [div([main_size(10), cross_size(10)], [])]), Node0),
    Changes = [set_attribute([0], opacity, [0.5])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node0, Root0),
    layout_tree(Root0, L0),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    same_term(L0, L1).

test('a color change recolors the text in place without re-shaping') :-
    build(div([font_size(16), color(blue)], ["hi"]), Node0),
    root(100, 100, Node0, Root0),
    layout_tree(Root0, L0),
    get_dict(children, L0, [child(_, _, P0)]),
    get_dict(width, P0, W), get_dict(height, P0, H),
    get_dict(glyphs, P0, G0),
    once((member(line(_, _, _, Its0), G0), member(glyph_run(_, _, C0, _, Glyphs0), Its0))),
    C0 == blue,
    Changes = [set_attribute([], color, [red])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    get_dict(children, L1, [child(_, _, P1)]),
    \+ same_term(P0, P1),
    get_dict(width, P1, W), get_dict(height, P1, H),
    get_dict(glyphs, P1, G1),
    once((member(line(_, _, _, Its1), G1), member(glyph_run(_, _, C1, _, Glyphs1), Its1))),
    C1 == red,
    Glyphs1 == Glyphs0.

test('a viewport change reuses unaffected children') :-
    build(div([], [div([main_size(10), cross_size(10)], [])]), Node),
    root(100, 100, Node, Root0),
    layout_tree(Root0, L0),
    root(100, 200, Node, Root1),
    relayout_tree([], Root1, L0, L1),
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
    layout_tree(Root0, L0),
    Changes = [set_attribute([0], main_size, [60])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    u(40, X40), u(60, X60),
    get_dict(children, L0, [child(0, 0, A0), child(X40, 0, B0)]),
    get_dict(children, L1, [child(0, 0, A1), child(X60, 0, B1)]),
    \+ same_term(A0, A1),
    get_dict(width, A1, X60),
    same_term(B0, B1).

test('an inherited layout attribute change re-measures the text') :-
    build(div([font_size(12)], ["hi"]), Node0),
    root(100, 100, Node0, Root0),
    layout_tree(Root0, L0),
    get_dict(children, L0, [child(_, _, P0)]),
    get_dict(height, P0, H0),
    Changes = [set_attribute([], font_size, [20])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    get_dict(children, L1, [child(_, _, P1)]),
    \+ same_term(P0, P1),
    get_dict(height, P1, H1),
    H1 > H0.

test('an inserted child recomputes the container positions') :-
    build(div([cross_axis(start)], [div([main_size(10), cross_size(10)], [])]), Node0),
    root(100, 100, Node0, Root0),
    layout_tree(Root0, L0),
    Changes = [insert_child([0], div([main_size(20), cross_size(10)], []))],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
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
    layout_tree(Root0, L0),
    element_changes(Prev, Next, Changes),
    node_apply_changes(Changes, Node0, Node1),
    root(200, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    layout_tree(Root1, LFresh),
    L1 == LFresh.

:- end_tests(integration).

%  --- Native text measurement (Parley) --- %
%
%  These groups exercise the foreign boundary directly. Metrics depend on the
%  host's fonts, so the assertions are structural (positive/finite boxes) or
%  relational (monotonic in font size, wrapping, etc.) rather than exact pixels.

:- begin_tests(text_content).

test('non-empty text measures to a positive box') :-
    measure([run("hello world", attrs{font_size: [16]})], inf, W, H),
    number(W), number(H),
    W > 0, H > 0.

test('empty content measures to a finite, non-negative box') :-
    measure([], inf, W, H),
    number(W), number(H),
    W >= 0, H >= 0.

test('more text is wider when unbounded') :-
    measure([run("short", attrs{font_size: [16]})], inf, Narrow, _),
    measure([run("short short short", attrs{font_size: [16]})], inf, Wide, _),
    Wide > Narrow.

test('splitting a run across boundaries does not change the measurement') :-
    A = attrs{font_size: [16]},
    measure([run("hello world", A)], inf, W1, H1),
    measure([run("hello ", A), run("world", A)], inf, W2, H2),
    W1 =:= W2, H1 =:= H2.

test('unicode text measures to a positive box') :-
    measure([run("héllo wörld 日本語", attrs{font_size: [16]})], inf, W, H),
    W > 0, H > 0.

:- end_tests(text_content).

:- begin_tests(text_attributes).

test('font size increases both dimensions') :-
    measure([run("size", attrs{font_size: [10]})], inf, W1, H1),
    measure([run("size", attrs{font_size: [40]})], inf, W2, H2),
    W2 > W1, H2 > H1.

test('every font weight form is accepted') :-
    forall(member(Wt, [normal, bold, 700]),
           ( measure([run("weight", attrs{font_size: [16], font_weight: [Wt]})], inf, W, H),
             W > 0, H > 0 )).

test('every slant is accepted') :-
    forall(member(S, [normal, italic, oblique]),
           ( measure([run("slant", attrs{font_size: [16], slant: [S]})], inf, W, H),
             W > 0, H > 0 )).

test('a named font family is accepted, whether or not it resolves') :-
    forall(member(F, ['DejaVu Sans', 'NoSuchFontXYZ']),
           ( measure([run("family", attrs{font_size: [16], font_family: [F]})], inf, W, H),
             W > 0, H > 0 )).

test('a language tag is accepted') :-
    forall(member(L, [en, de, fr]),
           ( measure([run("lang", attrs{font_size: [16], lang: [L]})], inf, W, H),
             W > 0, H > 0 )).

test('an irrelevant color attribute is ignored') :-
    measure([run("color", attrs{font_size: [16], color: [red]})], inf, W, H),
    W > 0, H > 0.

test('all inherited attributes together are accepted') :-
    measure([run("mixed", attrs{font_size: [20], font_family: ['DejaVu Sans'],
                                font_weight: [bold], slant: [italic], lang: [en],
                                color: [blue]})],
            inf, W, H),
    W > 0, H > 0.

test('a run with no attributes uses defaults') :-
    measure([run("plain", attrs{})], inf, W, H),
    W > 0, H > 0.

:- end_tests(text_attributes).

:- begin_tests(text_boxes).

test('an inline box contributes at least its own size') :-
    u(20, B),
    measure([box([], B, B)], inf, W, H),
    W >= B, H >= B.

test('a zero-sized box measures to a finite box') :-
    measure([box([], 0, 0)], inf, W, H),
    number(W), number(H),
    W >= 0, H >= 0.

test('a box widens the box beyond adjacent text alone') :-
    A = attrs{font_size: [16]},
    measure([run("hi", A)], inf, WText, _),
    u(30, B),
    measure([run("hi", A), box([], B, B)], inf, WBoth, _),
    WBoth > WText, WBoth >= B.

:- end_tests(text_boxes).

:- begin_tests(text_options).

test('a large absolute leading grows the line box') :-
    Runs = [run("leading", attrs{font_size: [16]})],
    measure_text(Runs, inline_options{leading: none}, inf, metrics(_, H0, _)),
    measure_text(Runs, inline_options{leading: 2}, inf, metrics(_, H1, _)),
    H1 > H0.

:- end_tests(text_options).

:- begin_tests(text_maxw).

test('a max width above the natural width does not wrap') :-
    Runs = [run("nowrap", attrs{font_size: [16]})],
    measure(Runs, inf, W, H),
    u(1000, Wide),
    measure(Runs, Wide, W2, H2),
    W =:= W2, H =:= H2.

test('a narrow max width wraps text to a taller box') :-
    Runs = [run("the quick brown fox jumps over the lazy dog", attrs{font_size: [16]})],
    measure(Runs, inf, _, Unwrapped),
    u(60, Narrow),
    measure(Runs, Narrow, _, Wrapped),
    Wrapped > Unwrapped.

:- end_tests(text_maxw).

:- begin_tests(text_errors).

test('an unparseable max width throws a type error',
     [throws(error(type_error(max_width, bogus), _))]) :-
    measure([run("x", attrs{font_size: [16]})], bogus, _, _).

test('a variable max width throws an instantiation error',
     [throws(error(instantiation_error, _))]) :-
    measure([run("x", attrs{font_size: [16]})], _, _, _).

:- end_tests(text_errors).

:- begin_tests(text_integration).

test('text in a block is measured and carries its state path') :-
    build(div([font_size(16)], ["hello"]), Node),
    root(200, 200, Node, Root),
    layout_tree(Root, L),
    get_dict(children, L, [child(_, _, P)]),
    get_dict(path, P, [0]),
    get_dict(width, P, W), W > 0,
    get_dict(height, P, H), H > 0.

test('a styled text node is measured end to end') :-
    build(div([font_size(20), font_weight(bold), slant(italic), lang(en)], ["Styled"]), Node),
    root(200, 200, Node, Root),
    layout_tree(Root, L),
    get_dict(children, L, [child(_, _, P)]),
    \+ get_dict(pending, P, _),
    get_dict(width, P, W), W > 0,
    get_dict(height, P, H), H > 0.

test('an explicitly sized inline element is measured to its box') :-
    build(div([], [img([display(inline), main_size(5), cross_size(5)], [])]), Node),
    root(100, 100, Node, Root),
    layout_tree(Root, L),
    get_dict(children, L, [child(_, _, P)]),
    \+ get_dict(pending, P, _),
    u(5, Five),
    get_dict(width, P, W), W >= Five,
    get_dict(height, P, H), H >= Five.

:- end_tests(text_integration).

:- begin_tests(glyph_layout).

first_glyph_run(Lines, GlyphRun) :-
    member(line(_, _, _, Items), Lines),
    member(GlyphRun, Items),
    GlyphRun = glyph_run(_, _, _, _, _),
    !.

test('text produces glyph runs with a font descriptor and positioned glyphs') :-
    measure_lines([run("hello", attrs{font_size: [16]})], inf, Lines),
    Lines = [line(Baseline, Ascent, Descent, _)|_],
    maplist(number, [Baseline, Ascent, Descent]),
    first_glyph_run(Lines,
        glyph_run(font(Family, Weight, Style), Size, _, synth(Bold, _), Glyphs)),
    string(Family), string_length(Family, FN), FN > 0,
    number(Weight), number(Size),
    once((Style == normal ; Style == italic ; Style = oblique(_))),
    memberchk(Bold, [true, false]),
    Glyphs = [_|_],
    forall(member(glyph(Id, X, Y, Adv, S, E), Glyphs),
           ( maplist(number, [Id, X, Y, Adv]), integer(S), integer(E), S =< E )).

test('a run color is carried through to its glyph run') :-
    measure_lines([run("x", attrs{font_size: [16], color: [red]})], inf, Lines),
    first_glyph_run(Lines, glyph_run(_, _, Color, _, _)),
    Color == red.

test('a run without color yields none') :-
    measure_lines([run("x", attrs{font_size: [16]})], inf, Lines),
    first_glyph_run(Lines, glyph_run(_, _, Color, _, _)),
    Color == none.

test('glyph clusters cover the source text') :-
    measure_lines([run("hi", attrs{font_size: [16]})], inf, Lines),
    first_glyph_run(Lines, glyph_run(_, _, _, _, Glyphs)),
    findall(S, member(glyph(_, _, _, _, S, _), Glyphs), Starts),
    findall(E, member(glyph(_, _, _, _, _, E), Glyphs), Ends),
    min_list(Starts, 0),
    max_list(Ends, 2).

test('an inline box appears as a positioned box item') :-
    u(20, B),
    measure_lines([run("a", attrs{font_size: [16]}), box([], B, B)], inf, Lines),
    member(line(_, _, _, Items), Lines),
    member(box(_, X, Y, W, H), Items),
    maplist(number, [X, Y, W, H]),
    W >= B.

test('glyphs flow into the stored layout node') :-
    build(div([font_size(16)], ["hi"]), Node),
    root(100, 100, Node, Root),
    layout_tree(Root, L),
    get_dict(children, L, [child(_, _, P)]),
    get_dict(glyphs, P, Lines),
    first_glyph_run(Lines, glyph_run(_, _, _, _, [_|_])).

:- end_tests(glyph_layout).

:- begin_tests(layout_changes).

test('an initial paint puts every node') :-
    lay(div([cross_axis(start)], [div([main_size(10), cross_size(10)], [])]), 100-100, L),
    layout_changes(none, L, Cs),
    memberchk(paint_put([], _, _, _, _, _), Cs),
    memberchk(paint_put([0], _, _, _, _, _), Cs),
    \+ memberchk(paint_move(_, _, _), Cs),
    \+ memberchk(paint_drop(_), Cs).

test('an identical relayout yields no changes') :-
    build(div([], [div([main_size(10), cross_size(10)], [])]), Node),
    root(100, 100, Node, Root),
    layout_tree(Root, L0),
    relayout_tree([], Root, L0, L1),
    layout_changes(L0, L1, Cs),
    Cs == [].

test('a moved but otherwise unchanged child yields a paint_move') :-
    build(div([direction(row), cross_axis(start)],
              [div([main_size(40), cross_size(10)], []),
               div([main_size(30), cross_size(10)], [])]),
          Node0),
    root(100, 100, Node0, Root0),
    layout_tree(Root0, L0),
    Changes = [set_attribute([0], main_size, [60])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    layout_changes(L0, L1, Cs),
    memberchk(paint_put([0], _, _, _, _, _), Cs),
    u(60, X60),
    memberchk(paint_move([1], X60, _), Cs),
    \+ memberchk(paint_put([1], _, _, _, _, _), Cs).

test('a removed child yields a paint_drop') :-
    build(div([cross_axis(start)],
              [div([main_size(10), cross_size(10)], []),
               div([main_size(10), cross_size(10)], [])]),
          Node0),
    root(100, 100, Node0, Root0),
    layout_tree(Root0, L0),
    Changes = [detach_child([1], gone)],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    layout_changes(L0, L1, Cs),
    memberchk(paint_drop([1]), Cs),
    \+ memberchk(paint_drop([0]), Cs).

test('a color change repaints only the recolored inline') :-
    build(div([cross_axis(start)],
              [div([font_size(16), color(blue)], ["hi"]),
               div([main_size(10), cross_size(10)], [])]),
          Node0),
    root(100, 100, Node0, Root0),
    layout_tree(Root0, L0),
    Changes = [set_attribute([0], color, [red])],
    node_apply_changes(Changes, Node0, Node1),
    root(100, 100, Node1, Root1),
    relayout_tree(Changes, Root1, L0, L1),
    layout_changes(L0, L1, Cs),
    memberchk(paint_put([0, 0], _, _, _, _, glyphs(_)), Cs),
    \+ ( member(paint_put(P, _, _, _, _, _), Cs), P \== [0, 0] ),
    \+ memberchk(paint_move(_, _, _), Cs),
    \+ memberchk(paint_drop(_), Cs).

:- end_tests(layout_changes).
