:- module(ui_layout, [ layout_tree/2, relayout_tree/4, px_units/2 ]).

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(ui_attributes).
:- use_module(ui_layout_text).

%  All layout arithmetic is exact integer math in layout units, 1/64 of a
%  logical pixel (see px_units/2). Attribute lengths (main_size, cross_size,
%  margin, padding) and the root viewport are given in logical pixels and
%  converted where read; constraints, the measurement protocol, and the
%  resulting layout geometry are all in units. Flex factors are unitless
%  integers.

%! layout_tree(+Root, -Layout) is det.

layout_tree(Root, Layout) :-
    relayout_tree([], Root, none, Layout).

%! relayout_tree(+Changes, +Root, +PrevLayout, -Layout) is det.

relayout_tree(Changes, Root, PrevLayout, Layout) :-
    get_dict(viewport_width, Root, W0),
    get_dict(viewport_height, Root, H0),
    px_units(W0, W),
    px_units(H0, H),
    get_dict(node, Root, Node),
    (  Node == none
    -> Layout = none
    ;  changes_dirty(Changes, Dirty),
       node_layout(Dirty, [], Node, constraints(W, W, H, H), PrevLayout, Layout)
    ).

%! px_units(+Px, -Units) is det.

px_units(Px, Units) :-
    Units is round(Px * 64).

% --- Dirty Tracking --- %

%! changes_dirty(+Changes, -Dirty) is det.

changes_dirty(Changes, dirty(Shallow, Deep)) :-
    foldl(change_dirty_, Changes, []-[], S-D),
    sort(S, Shallow),
    sort(D, Deep).

change_dirty_(set_attribute(Path, Key, _), Acc0, Acc) :- attribute_dirty_(Path, Key, Acc0, Acc).
change_dirty_(remove_attribute(Path, Key), Acc0, Acc) :- attribute_dirty_(Path, Key, Acc0, Acc).
change_dirty_(insert_child(Path, _), Acc0, Acc) :- tree_dirty_(Path, Acc0, Acc).
change_dirty_(detach_child(Path, _), Acc0, Acc) :- tree_dirty_(Path, Acc0, Acc).
change_dirty_(attach_child(Path, _), Acc0, Acc) :- tree_dirty_(Path, Acc0, Acc).

attribute_dirty_(Path, Key, S-D, Acc) :-
    (  \+ attribute_flag(Key, layout)
    -> Acc = S-D
    ;  attribute_flag(Key, inherit)
    -> Acc = S-[Path|D]
    ;  Acc = [Path|S]-D
    ).

tree_dirty_([], S-D, S-[[]|D]) :- !.
tree_dirty_(Path, S-D, S-[Parent|D]) :-
    once(append(Parent, [_], Path)).

%! subtree_clean(+Path, +Dirty) is semidet.

subtree_clean(Path, dirty(Shallow, Deep)) :-
    \+ ( member(P, Shallow), path_prefix_(Path, P) ),
    \+ ( member(P, Deep), ( path_prefix_(Path, P) ; path_prefix_(P, Path) ) ).

path_prefix_([], _).
path_prefix_([Idx|Prefix], [Idx|Path]) :- path_prefix_(Prefix, Path).

% --- Node Layout --- %

%! node_layout(+Dirty, +Path, +Node, +Constraints, +Prev, -Layout) is det.

node_layout(Dirty, Path, Node, Constraints, Prev, Layout) :-
    (  is_dict(Prev),
       get_dict(constraints, Prev, PrevConstraints),
       PrevConstraints == Constraints,
       subtree_clean(Path, Dirty)
    -> Layout = Prev
    ;  get_dict(text, Node, _)
    -> inline_options_(attrs{}, Options),
       inline_layout(Dirty, Path, Node, Options, Constraints, none, Layout)
    ;  block_layout(Dirty, Path, Node, Constraints, Prev, Layout)
    ).

%! block_layout(+Dirty, +Path, +Node, +Constraints, +Prev, -Layout) is det.

block_layout(Dirty, Path, Node, Constraints, Prev, Layout) :-
    Constraints = constraints(MinW, MaxW, MinH, MaxH),
    get_dict(attributes, Node, Attrs),
    get_dict(children, Node, Children),
    attr_default_(Attrs, direction, Dir),
    attr_default_(Attrs, main_axis, MainAlign),
    attr_default_(Attrs, cross_axis, CrossAlign),
    inline_options_(Attrs, Options),
    box_sides_(Attrs, padding, PT, PR, PB, PL),
    PadW is PL + PR,
    PadH is PT + PB,
    axis_(Dir, MinW, MinH, MinMain, MinCross),
    axis_(Dir, MaxW, MaxH, MaxMain, MaxCross),
    axis_(Dir, PadW, PadH, PadMain, PadCross),
    bounded_sub_(MaxCross, PadCross, ContentCrossMax),
    flow_items_(Children, 0, Items),
    Ctx = ctx(Dirty, Path, Prev, Dir, CrossAlign, ContentCrossMax, Options),
    measure_rigid_items_(Items, Ctx, RigidSum, TotalFlex, Measured0),
    (  TotalFlex > 0
    -> main_extent_(MaxMain, PadMain, Path, MainRoom),
       Remaining is max(0, MainRoom - RigidSum),
       measure_flex_items_(Measured0, Ctx, Remaining, TotalFlex, Measured)
    ;  Measured = Measured0
    ),
    extents_sum_(Measured, SumExtents),
    (  TotalFlex > 0
    -> SelfMain is MainRoom + PadMain
    ;  SelfMain is min(max(SumExtents + PadMain, MinMain), MaxMain)
    ),
    max_cross_extent_(Measured, MaxChildCross),
    SelfCross is min(max(MaxChildCross + PadCross, MinCross), MaxCross),
    length(Measured, NItems),
    ContentMain is SelfMain - PadMain,
    Free is max(0, ContentMain - SumExtents),
    axis_(Dir, PL, PT, PadMainLead, PadCrossLead),
    CrossRoom is SelfCross - PadCross,
    PCtx = place(MainAlign, Free, NItems, PadMainLead, PadCrossLead, CrossRoom, CrossAlign, Dir),
    place_items_(Measured, 0, 0, PCtx, Placed),
    axis_(Dir, Width, Height, SelfMain, SelfCross),
    Layout0 = layout{width: Width, height: Height, children: Placed,
                     constraints: Constraints, path: Path},
    Overflow is SumExtents - ContentMain,
    (  Overflow > 0
    -> put_dict(overflow, Layout0, Overflow, Layout)
    ;  Layout = Layout0
    ).

%! main_extent_(+MaxMain, +PadMain, +Path, -MainRoom) is det.

main_extent_(MaxMain, PadMain, Path, MainRoom) :-
    (  MaxMain == inf
    -> throw(error(layout_error(unbounded_flex, Path), _))
    ;  MainRoom is max(0, MaxMain - PadMain)
    ).

% --- Flow Items --- %

%! flow_items_(+Children, +Idx, -Items) is det.

flow_items_([], _, []).
flow_items_([Child|Rest], Idx, [Item|Items]) :-
    (  node_inline_(Child)
    -> Item = inline(Idx, Child)
    ;  Item = block(Idx, Child)
    ),
    Idx1 is Idx + 1,
    flow_items_(Rest, Idx1, Items).

node_inline_(Node) :-
    (  get_dict(text, Node, _)
    -> true
    ;  get_dict(attributes, Node, Attrs),
       get_dict(display, Attrs, [inline])
    ).

% --- Item Measurement --- %

%! measure_rigid_items_(+Items, +Ctx, -RigidSum, -TotalFlex, -Measured) is det.

measure_rigid_items_([], _, 0, 0, []).
measure_rigid_items_([Item|Items], Ctx, RigidSum, TotalFlex, [M|Ms]) :-
    item_flex_(Item, Flex),
    (  Flex > 0
    -> M = pending_flex(Item, Flex),
       measure_rigid_items_(Items, Ctx, RigidSum, TotalFlex0, Ms),
       TotalFlex is TotalFlex0 + Flex
    ;  measure_item_(Item, Ctx, unbounded, M),
       measured_extent_(M, Extent),
       measure_rigid_items_(Items, Ctx, RigidSum0, TotalFlex, Ms),
       RigidSum is RigidSum0 + Extent
    ).

%! measure_flex_items_(+Measured0, +Ctx, +Remaining, +TotalFlex, -Measured) is det.
%
%  Each flex item's share is the difference of successive cumulative
%  quotients Remaining * CumFlex // TotalFlex, so the shares partition
%  Remaining exactly: no unit is lost or duplicated by per-item rounding,
%  and no share is off by more than one unit from its ideal.

measure_flex_items_(Measured0, Ctx, Remaining, TotalFlex, Measured) :-
    measure_flex_items_(Measured0, Ctx, Remaining, TotalFlex, 0, 0, Measured).

measure_flex_items_([], _, _, _, _, _, []).
measure_flex_items_([pending_flex(Item, Flex)|Ms0], Ctx, Remaining, TotalFlex, CumFlex0, Alloc,
                    [M|Ms]) :- !,
    CumFlex is CumFlex0 + Flex,
    Boundary is Remaining * CumFlex // TotalFlex,
    Share is Boundary - Alloc,
    item_fit_(Item, Fit),
    MainSpec =.. [Fit, Share],
    measure_item_(Item, Ctx, MainSpec, M),
    measure_flex_items_(Ms0, Ctx, Remaining, TotalFlex, CumFlex, Boundary, Ms).
measure_flex_items_([M|Ms0], Ctx, Remaining, TotalFlex, CumFlex, Alloc, [M|Ms]) :-
    measure_flex_items_(Ms0, Ctx, Remaining, TotalFlex, CumFlex, Alloc, Ms).

item_flex_(block(_, Node), Flex) :-
    get_dict(attributes, Node, Attrs),
    attr_default_(Attrs, flex, Flex).
item_flex_(inline(_, Node), Flex) :-
    (  get_dict(attributes, Node, Attrs)
    -> attr_default_(Attrs, flex, Flex)
    ;  Flex = 0
    ).

item_fit_(block(_, Node), Fit) :-
    get_dict(attributes, Node, Attrs),
    attr_default_(Attrs, fit, Fit).
item_fit_(inline(_, Node), Fit) :-
    (  get_dict(attributes, Node, Attrs)
    -> attr_default_(Attrs, fit, Fit)
    ;  Fit = tight
    ).

%! measure_item_(+Item, +Ctx, +MainSpec, -Measured) is det.
%
%  Measured = measured(Lead, Trail, CrossLead, CrossTrail, MainSize, CrossSize, Layout)
%  where Lead/Trail/CrossLead/CrossTrail are the item's margins mapped onto the
%  container's axes. MainSpec is unbounded for a rigid item, or tight(Share)
%  or loose(Share) for a flex item: a tight item is forced to exactly its
%  share, a loose item may take at most its share.

measure_item_(block(Idx, Child), Ctx, MainSpec,
              measured(Lead, Trail, CrossLead, CrossTrail, MainSize, CrossSize, ChildLayout)) :-
    Ctx = ctx(Dirty, Path, Prev, Dir, CrossAlign, ContentCrossMax, _),
    get_dict(attributes, Child, Attrs),
    box_sides_(Attrs, margin, MT, MR, MB, ML),
    axis_(Dir, ML, MT, Lead, CrossLead),
    axis_(Dir, MR, MB, Trail, CrossTrail),
    CrossMargins is CrossLead + CrossTrail,
    bounded_sub_(ContentCrossMax, CrossMargins, CrossLimit),
    cross_bounds_(CrossAlign, CrossLimit, CMinCross0, CMaxCross0),
    main_spec_bounds_(MainSpec, Lead, Trail, CMinMain0, CMaxMain0),
    item_size_(Attrs, main_size, CMinMain0, CMaxMain0, CMinMain, CMaxMain),
    item_size_(Attrs, cross_size, CMinCross0, CMaxCross0, CMinCross, CMaxCross),
    axis_(Dir, CMinW, CMinH, CMinMain, CMinCross),
    axis_(Dir, CMaxW, CMaxH, CMaxMain, CMaxCross),
    append(Path, [Idx], ChildPath),
    prev_item_layout_(Prev, Idx, PrevChild),
    node_layout(Dirty, ChildPath, Child,
                constraints(CMinW, CMaxW, CMinH, CMaxH), PrevChild, ChildLayout),
    get_dict(width, ChildLayout, ChildW),
    get_dict(height, ChildLayout, ChildH),
    axis_(Dir, ChildW, ChildH, MainSize, CrossSize).
measure_item_(inline(Idx, Node), Ctx, MainSpec,
              measured(0, 0, 0, 0, MainSize, CrossSize, InlineLayout)) :-
    Ctx = ctx(Dirty, Path, Prev, Dir, CrossAlign, ContentCrossMax, Options),
    main_spec_bounds_(MainSpec, 0, 0, MinMain, MaxMain),
    cross_bounds_(CrossAlign, ContentCrossMax, MinCross, MaxCross),
    axis_(Dir, MinW, MinH, MinMain, MinCross),
    axis_(Dir, MaxW, MaxH, MaxMain, MaxCross),
    append(Path, [Idx], ChildPath),
    prev_item_layout_(Prev, Idx, PrevChild),
    inline_layout(Dirty, ChildPath, Node, Options,
                  constraints(MinW, MaxW, MinH, MaxH), PrevChild, InlineLayout),
    get_dict(width, InlineLayout, InlineW),
    get_dict(height, InlineLayout, InlineH),
    axis_(Dir, InlineW, InlineH, MainSize, CrossSize).

%! cross_bounds_(+CrossAlign, +CrossLimit, -Min, -Max) is det.

cross_bounds_(stretch, CrossLimit, CrossLimit, CrossLimit) :-
    CrossLimit \== inf, !.
cross_bounds_(_, CrossLimit, 0, CrossLimit).

%! main_spec_bounds_(+MainSpec, +Lead, +Trail, -Min, -Max) is det.

main_spec_bounds_(unbounded, _, _, 0, inf).
main_spec_bounds_(loose(Share), Lead, Trail, 0, Max) :-
    Max is max(0, Share - Lead - Trail).
main_spec_bounds_(tight(Share), Lead, Trail, Size, Size) :-
    Size is max(0, Share - Lead - Trail).

prev_item_layout_(Prev, Idx, PrevChild) :-
    (  is_dict(Prev),
       get_dict(children, Prev, PrevChildren),
       nth0(Idx, PrevChildren, child(_, _, PrevChild0))
    -> PrevChild = PrevChild0
    ;  PrevChild = none
    ).

measured_extent_(measured(Lead, Trail, _, _, MainSize, _, _), Extent) :-
    Extent is Lead + MainSize + Trail.

extents_sum_([], 0).
extents_sum_([M|Ms], Sum) :-
    measured_extent_(M, Extent),
    extents_sum_(Ms, Sum0),
    Sum is Sum0 + Extent.

max_cross_extent_([], 0).
max_cross_extent_([measured(_, _, CrossLead, CrossTrail, _, CrossSize, _)|Ms], Max) :-
    max_cross_extent_(Ms, Max0),
    Max is max(Max0, CrossLead + CrossSize + CrossTrail).

% --- Item Placement --- %

%! place_items_(+Measured, +Idx, +ExtentsBefore, +PCtx, -Children) is det.

place_items_([], _, _, _, []).
place_items_([measured(Lead, Trail, CrossLead, CrossTrail, MainSize, CrossSize, ChildLayout)|Ms],
             Idx, Extents0, PCtx, [child(X, Y, ChildLayout)|Cs]) :-
    PCtx = place(MainAlign, Free, NItems, PadMainLead, PadCrossLead, CrossRoom, CrossAlign, Dir),
    space_cum_(MainAlign, Free, Idx, NItems, Space),
    MainPos is PadMainLead + Extents0 + Space + Lead,
    CrossExtent is CrossLead + CrossSize + CrossTrail,
    cross_offset_(CrossAlign, CrossRoom, CrossExtent, CrossLead, CrossOffset),
    CrossPos is PadCrossLead + CrossOffset,
    axis_(Dir, X, Y, MainPos, CrossPos),
    Extents1 is Extents0 + Lead + MainSize + Trail,
    Idx1 is Idx + 1,
    place_items_(Ms, Idx1, Extents1, PCtx, Cs).

%! space_cum_(+MainAlign, +Free, +Idx, +NItems, -Space) is det.

space_cum_(start, _, _, _, 0).
space_cum_(end, Free, _, _, Free).
space_cum_(center, Free, _, _, Space) :-
    Space is Free // 2.
space_cum_(space_between, Free, Idx, NItems, Space) :-
    (  NItems > 1
    -> Space is Free * Idx // (NItems - 1)
    ;  Space = 0
    ).
space_cum_(space_around, Free, Idx, NItems, Space) :-
    Space is Free * (2 * Idx + 1) // (2 * NItems).
space_cum_(space_evenly, Free, Idx, NItems, Space) :-
    Space is Free * (Idx + 1) // (NItems + 1).

cross_offset_(start, _, _, CrossLead, CrossLead).
cross_offset_(stretch, _, _, CrossLead, CrossLead).
cross_offset_(center, Room, Extent, CrossLead, Offset) :-
    Offset is CrossLead + (Room - Extent) // 2.
cross_offset_(end, Room, Extent, CrossLead, Offset) :-
    Offset is CrossLead + Room - Extent.

% --- Inline Layout --- %

%! inline_layout(+Dirty, +Path, +Node, +Options, +Constraints, +Prev, -Layout) is det.
%
%  Lays out one inline node (a text node or a display(inline) element at
%  Path) by measuring its content through ui_layout_text:
%
%    measure_text(Runs, Options, MaxW, metrics(W, H, Glyphs))
%    Runs    ::= [ run(Text, InheritedAttrs)  % text node
%                | box(RelPath, W, H)         % explicitly sized inline element,
%                | ... ]                      %   RelPath relative to Path
%    Options  = inline_options{leading: _}
%    MaxW     = units | inf
%
%  The runs and the returned metrics speak layout units. W/H are ceiled to
%  whole units (so measured content never overflows its box) and clamped into
%  Constraints, so a tight main axis (a tight flex share) forces the inline's
%  box regardless of its content. Glyphs is the per-glyph layout (lines, glyph
%  runs, positioned glyphs; see ui_layout_text), stored verbatim under the
%  layout's glyphs key for a later paint pass.

inline_layout(Dirty, Path, Node, Options, Constraints, Prev, Layout) :-
    (  is_dict(Prev),
       get_dict(constraints, Prev, Constraints0),
       Constraints0 == Constraints,
       get_dict(options, Prev, Options0),
       Options0 == Options,
       subtree_clean(Path, Dirty)
    -> Layout = Prev
    ;  Constraints = constraints(MinW, MaxW, MinH, MaxH),
       inline_node_runs_(Node, [], Runs, []),
       measure_text(Runs, Options, MaxW, metrics(W0, H0, Glyphs)),
       Wc is ceiling(W0),
       Hc is ceiling(H0),
       clamp_(Wc, MinW, MaxW, W),
       clamp_(Hc, MinH, MaxH, H),
       Layout = layout{width: W, height: H, glyphs: Glyphs, constraints: Constraints,
                       options: Options, path: Path}
    ).

%! inline_node_runs_(+Node, +RevPath, -Runs, ?Tail) is det.
%
%  Flattens an inline node into measurement runs; RevPath is the node's
%  reversed path relative to the inline being laid out ([] denotes that
%  node itself). Unsized inline elements contribute their children's runs.

inline_node_runs_(Node, _, [run(Text, Inherited)|Runs], Runs) :-
    get_dict(text, Node, Text), !,
    get_dict(inherited, Node, Inherited).
inline_node_runs_(Node, RevPath, Runs0, Runs) :-
    get_dict(attributes, Node, Attrs),
    (  \+ get_dict(display, Attrs, [inline])
    -> reverse(RevPath, RelPath),
       Runs0 = [box(RelPath, 0, 0)|Runs]
    ;  get_dict(main_size, Attrs, [Main]),
       get_dict(cross_size, Attrs, [Cross])
    -> reverse(RevPath, RelPath),
       px_units(Main, MainU),
       px_units(Cross, CrossU),
       Runs0 = [box(RelPath, MainU, CrossU)|Runs]
    ;  get_dict(children, Node, Children),
       inline_children_runs_(Children, 0, RevPath, Runs0, Runs)
    ).

inline_children_runs_([], _, _, Runs, Runs).
inline_children_runs_([Node|Nodes], Idx, RevBase, Runs0, Runs) :-
    inline_node_runs_(Node, [Idx|RevBase], Runs0, Runs1),
    Idx1 is Idx + 1,
    inline_children_runs_(Nodes, Idx1, RevBase, Runs1, Runs).

% --- Attribute Readers --- %

layout_default(display, block).
layout_default(direction, column).
layout_default(main_axis, start).
layout_default(cross_axis, center).
layout_default(flex, 0).
layout_default(fit, tight).
layout_default(alignment, start).
layout_default(leading, none).

attr_default_(Attrs, Key, Value) :-
    (  get_dict(Key, Attrs, [Value0])
    -> Value = Value0
    ;  layout_default(Key, Value)
    ).

inline_options_(Attrs, inline_options{leading: Leading}) :-
    attr_default_(Attrs, leading, Leading).

%! clamped_size_(+Attrs, +Key, +Min, +Max, -Explicit) is det.

clamped_size_(Attrs, Key, Min, Max, Explicit) :-
    (  get_dict(Key, Attrs, [N]),
       number(N)
    -> px_units(N, U),
       Clamped is min(max(U, Min), Max),
       Explicit = size(Clamped)
    ;  Explicit = none
    ).

%! item_size_(+Attrs, +Key, +Min0, +Max0, -Min, -Max) is det.

item_size_(Attrs, Key, Min0, Max0, Min, Max) :-
    (  clamped_size_(Attrs, Key, Min0, Max0, size(N))
    -> Min = N, Max = N
    ;  Min = Min0, Max = Max0
    ).

%! clamp_(+Value, +Min, +Max, -Clamped) is det.

clamp_(V, Min, inf, Out) :- !,
    Out is max(V, Min).
clamp_(V, Min, Max, Out) :-
    Out is min(max(V, Min), Max).

%! bounded_sub_(+Limit, +Amount, -Rest) is det.

bounded_sub_(inf, _, inf) :- !.
bounded_sub_(Limit, Amount, Rest) :-
    Rest is max(0, Limit - Amount).

%! box_sides_(+Attrs, +Key, -Top, -Right, -Bottom, -Left) is det.

box_sides_(Attrs, Key, Top, Right, Bottom, Left) :-
    (  get_dict(Key, Attrs, Value)
    -> sides_(Value, T0, R0, B0, L0),
       px_units(T0, Top),
       px_units(R0, Right),
       px_units(B0, Bottom),
       px_units(L0, Left)
    ;  Top = 0, Right = 0, Bottom = 0, Left = 0
    ).

sides_([All], All, All, All, All) :- !.
sides_([Vertical, Horizontal], Vertical, Horizontal, Vertical, Horizontal) :- !.
sides_([Top, Right, Bottom, Left], Top, Right, Bottom, Left).

%! axis_(+Dir, ?W, ?H, ?Main, ?Cross) is det.

axis_(row, W, H, W, H).
axis_(column, W, H, H, W).
