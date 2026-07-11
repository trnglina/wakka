:- module(ui_layout, [ layout_tree/2, relayout_tree/4, layout_changes/3, px_units/2 ]).

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(ui_attributes).
:- use_module(ui_native).

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
%
%  Dirty = dirty(Shallow, Deep, Paint). Shallow/Deep drive layout reuse (a
%  Deep path invalidates itself, its ancestors and its descendants; a Shallow
%  path only itself and its ancestors). Paint is a separate, deep-style set for
%  presentational attributes that change a node's rendered content but not its
%  geometry (currently `color`): a Paint path is recolored in place, reusing all
%  measured geometry.

changes_dirty(Changes, dirty(Shallow, Deep, Paint)) :-
    foldl(change_dirty_, Changes, []-[]-[], S-D-P),
    sort(S, Shallow),
    sort(D, Deep),
    sort(P, Paint).

change_dirty_(set_attribute(Path, Key, _), Acc0, Acc) :- attribute_dirty_(Path, Key, Acc0, Acc).
change_dirty_(remove_attribute(Path, Key), Acc0, Acc) :- attribute_dirty_(Path, Key, Acc0, Acc).
change_dirty_(insert_child(Path, _), Acc0, Acc) :- tree_dirty_(Path, Acc0, Acc).
change_dirty_(detach_child(Path, _), Acc0, Acc) :- tree_dirty_(Path, Acc0, Acc).
change_dirty_(attach_child(Path, _), Acc0, Acc) :- tree_dirty_(Path, Acc0, Acc).

attribute_dirty_(Path, Key, S-D-P, Acc) :-
    (  attribute_flag(Key, layout)
    -> (  attribute_flag(Key, inherit)
       -> Acc = S-[Path|D]-P
       ;  Acc = [Path|S]-D-P  )
    ;  attribute_flag(Key, paint)
    -> Acc = S-D-[Path|P]
    ;  Acc = S-D-P
    ).

tree_dirty_([], S-D-P, S-[[]|D]-P) :- !.
tree_dirty_(Path, S-D-P, S-[Parent|D]-P) :-
    once(append(Parent, [_], Path)).

%! subtree_layout_clean(+Path, +Dirty) is semidet.

subtree_layout_clean(Path, dirty(Shallow, Deep, _)) :-
    \+ ( member(P, Shallow), path_prefix_(Path, P) ),
    \+ ( member(P, Deep), ( path_prefix_(Path, P) ; path_prefix_(P, Path) ) ).

%! subtree_paint_clean(+Path, +Dirty) is semidet.
%
%  A subtree needs no recolor when no Paint path lies on it or under it (a Paint
%  path above Path means Path is inside a recolored subtree; below means Path is
%  an ancestor that must be descended to reach it).

subtree_paint_clean(Path, dirty(_, _, Paint)) :-
    \+ ( member(P, Paint), ( path_prefix_(Path, P) ; path_prefix_(P, Path) ) ).

path_prefix_([], _).
path_prefix_([Idx|Prefix], [Idx|Path]) :- path_prefix_(Prefix, Path).

% --- Node Layout --- %

%! node_layout(+Dirty, +Path, +Node, +Constraints, +Prev, -Layout) is det.

node_layout(Dirty, Path, Node, Constraints, Prev, Layout) :-
    (  is_dict(Prev),
       get_dict(constraints, Prev, PrevConstraints),
       PrevConstraints == Constraints,
       subtree_layout_clean(Path, Dirty)
    -> (  subtree_paint_clean(Path, Dirty)
       -> Layout = Prev
       ;  recolor_node_(Dirty, Node, Prev, Layout)  )
    ;  get_dict(text, Node, _)
    -> inline_options_(attrs{}, Options),
       inline_layout(Dirty, Path, Node, Options, Constraints, none, Layout)
    ;  block_layout(Dirty, Path, Node, Constraints, Prev, Layout)
    ).

% --- Recolor --- %
%
%  A paint-only change (see changes_dirty/2) rewrites the glyph-run colors of the
%  affected inlines while reusing every measured geometry: no text is re-shaped
%  and no box is re-placed. The traversal walks the previous layout tree next to
%  the current state node (paired positionally by flow index, which is sound
%  because any structural change is layout-dirty, never merely paint-dirty).

%! recolor_node_(+Dirty, +Node, +Prev, -Layout) is det.

recolor_node_(Dirty, Node, Prev, Layout) :-
    (  get_dict(glyphs, Prev, _)
    -> recolor_inline_(Node, Prev, Layout)
    ;  get_dict(children, Prev, PrevChildren)
    -> get_dict(children, Node, NodeChildren),
       recolor_child_list_(Dirty, NodeChildren, 0, PrevChildren, NewChildren),
       put_dict(children, Prev, NewChildren, Layout)
    ;  Layout = Prev
    ).

recolor_child_list_(_, _, _, [], []).
recolor_child_list_(Dirty, NodeChildren, Idx, [child(X, Y, PrevChild)|Ps],
                    [child(X, Y, NewChild)|Ns]) :-
    nth0(Idx, NodeChildren, ChildNode),
    get_dict(path, PrevChild, ChildPath),
    (  subtree_paint_clean(ChildPath, Dirty)
    -> NewChild = PrevChild
    ;  recolor_node_(Dirty, ChildNode, PrevChild, NewChild)
    ),
    Idx1 is Idx + 1,
    recolor_child_list_(Dirty, NodeChildren, Idx1, Ps, Ns).

%! recolor_inline_(+Node, +Prev, -Layout) is det.
%
%  Re-derives the inline's source runs (cheap: no shaping) to read the current
%  inherited colors, then substitutes each glyph run's color by mapping the run's
%  byte offset (from its glyphs) onto the source runs. Returns Prev unchanged
%  when no color actually differs, so an unaffected inline emits no paint change.

recolor_inline_(Node, Prev, Layout) :-
    inline_node_runs_(Node, [], Runs, []),
    run_color_ranges_(Runs, 0, Ranges),
    get_dict(glyphs, Prev, Lines0),
    recolor_lines_(Lines0, Ranges, Lines),
    (  Lines == Lines0
    -> Layout = Prev
    ;  put_dict(glyphs, Prev, Lines, Layout)
    ).

%! run_color_ranges_(+Runs, +Offset, -Ranges) is det.
%
%  Ranges = [range(Start, End, Color), ...] over the run-concatenated text (byte
%  offsets, matching the measurer). Boxes contribute no text, so they do not
%  advance the offset; a run with no color attribute yields the atom `none`.

run_color_ranges_([], _, []).
run_color_ranges_([run(Text, Inherited)|Rest], Off, [range(Off, End, Color)|Ranges]) :- !,
    string_bytes(Text, Bytes, utf8),
    length(Bytes, Len),
    End is Off + Len,
    (  get_dict(color, Inherited, [Color0])
    -> Color = Color0
    ;  Color = none
    ),
    run_color_ranges_(Rest, End, Ranges).
run_color_ranges_([box(_, _, _)|Rest], Off, Ranges) :-
    run_color_ranges_(Rest, Off, Ranges).

%! recolor_lines_(+Lines, +Ranges, -Recolored) is det.

recolor_lines_([], _, []).
recolor_lines_([line(B, A, D, Items0)|Ls0], Ranges, [line(B, A, D, Items)|Ls]) :-
    recolor_items_(Items0, Ranges, Items),
    recolor_lines_(Ls0, Ranges, Ls).

recolor_items_([], _, []).
recolor_items_([glyph_run(Font, Size, _, Synth, Glyphs)|Is0], Ranges,
               [glyph_run(Font, Size, Color, Synth, Glyphs)|Is]) :- !,
    run_glyphs_color_(Glyphs, Ranges, Color),
    recolor_items_(Is0, Ranges, Is).
recolor_items_([Item|Is0], Ranges, [Item|Is]) :-
    recolor_items_(Is0, Ranges, Is).

%! run_glyphs_color_(+Glyphs, +Ranges, -Color) is det.
%
%  A glyph run lies wholly within one source run; its first glyph's start byte
%  selects the run (and thus the color). Falls back to `none` when the run has no
%  glyphs or no range matches.

run_glyphs_color_([glyph(_, _, _, _, Start, _)|_], Ranges, Color) :- !,
    (  member(range(RS, RE, C), Ranges), Start >= RS, Start < RE
    -> Color = C
    ;  Color = none
    ).
run_glyphs_color_(_, _, none).

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
%  Path) by measuring its content through ui_native:
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
%  runs, positioned glyphs; see ui_native), stored verbatim under the
%  layout's glyphs key for a later paint pass.

inline_layout(Dirty, Path, Node, Options, Constraints, Prev, Layout) :-
    (  is_dict(Prev),
       get_dict(constraints, Prev, Constraints0),
       Constraints0 == Constraints,
       get_dict(options, Prev, Options0),
       Options0 == Options,
       subtree_layout_clean(Path, Dirty)
    -> (  subtree_paint_clean(Path, Dirty)
       -> Layout = Prev
       ;  recolor_inline_(Node, Prev, Layout)  )
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

% --- Paint Changes --- %

%! layout_changes(+PrevLayout, +NextLayout, -Changes) is det.
%
%  Reconciles two layout trees (each a layout node or `none`) into the minimal
%  paint-change stream that turns the scene painted for PrevLayout into the one
%  for NextLayout. It is O(changes): relayout_tree/4 shares unchanged subtrees,
%  so same_term/2 skips them in constant time. Nodes are keyed by their state
%  path; a node's position lives in its parent's child(X, Y, Layout) entry, so
%  moves are detected at the parent and content changes by recursion.
%
%    Change ::= paint_put(Path, X, Y, W, H, Draw)   % (re)create: transform + size + content
%             | paint_move(Path, X, Y)              % position-only (subtree unchanged)
%             | paint_drop(Path)                     % remove node + subtree
%    Draw   ::= glyphs(Lines) | none
%
%  The initial paint is layout_changes(none, Layout, Changes).

layout_changes(Prev, Next, Changes) :-
    phrase(node_changes_(0, 0, Prev, 0, 0, Next), Changes).

%! node_changes_(+PX, +PY, +Prev, +NX, +NY, +Next)// is det.
%
%  (PX, PY, Prev) is the node's previous position and layout, (NX, NY, Next) its
%  next; positions are supplied by the parent.

node_changes_(PX, PY, Prev, NX, NY, Next) -->
    (  { same_term(Prev, Next) }
    -> (  { PX == NX, PY == NY }
       -> []
       ;  { get_dict(path, Next, Path) },
          [ paint_move(Path, NX, NY) ]  )
    ;  { Next == none }
    -> { get_dict(path, Prev, Path) },
       [ paint_drop(Path) ]
    ;  { Prev == none }
    -> put_subtree_(NX, NY, Next)
    ;  node_put_(PX, PY, Prev, NX, NY, Next),
       children_changes_(Prev, Next)
    ).

%! node_put_(+PX, +PY, +Prev, +NX, +NY, +Next)// is det.
%
%  Emits paint_put only when the node's own transform or content changed; a
%  difference confined to its children is handled by recursion.

node_put_(PX, PY, Prev, NX, NY, Next) -->
    { node_paint_(Prev, PW, PH, PDraw),
      node_paint_(Next, NW, NH, NDraw) },
    (  { PX == NX, PY == NY, PW == NW, PH == NH, PDraw == NDraw }
    -> []
    ;  { get_dict(path, Next, Path) },
       [ paint_put(Path, NX, NY, NW, NH, NDraw) ]
    ).

%! put_subtree_(+X, +Y, +Layout)// is det.
%
%  Emits paint_put for a wholly new node and, recursively, its children.

put_subtree_(X, Y, Layout) -->
    { node_paint_(Layout, W, H, Draw),
      get_dict(path, Layout, Path) },
    [ paint_put(Path, X, Y, W, H, Draw) ],
    put_children_(Layout).

put_children_(Layout) -->
    { get_dict(children, Layout, Children) }, !,
    put_child_list_(Children).
put_children_(_) --> [].

put_child_list_([]) --> [].
put_child_list_([child(X, Y, L)|Cs]) -->
    put_subtree_(X, Y, L),
    put_child_list_(Cs).

%! node_paint_(+Layout, -W, -H, -Draw) is det.

node_paint_(Layout, W, H, Draw) :-
    get_dict(width, Layout, W),
    get_dict(height, Layout, H),
    (  get_dict(glyphs, Layout, Glyphs)
    -> Draw = glyphs(Glyphs)
    ;  Draw = none
    ).

%! children_changes_(+Prev, +Next)// is det.

children_changes_(Prev, Next) -->
    { layout_children_(Prev, PrevChildren),
      layout_children_(Next, NextChildren) },
    child_pairs_(PrevChildren, NextChildren).

layout_children_(Layout, Children) :-
    ( get_dict(children, Layout, Children) -> true ; Children = [] ).

%! child_pairs_(+PrevChildren, +NextChildren)// is det.
%
%  Children are matched positionally; a shorter/longer list yields drops/puts.

child_pairs_([], []) --> [].
child_pairs_([child(PX, PY, PL)|Ps], [child(NX, NY, NL)|Ns]) --> !,
    node_changes_(PX, PY, PL, NX, NY, NL),
    child_pairs_(Ps, Ns).
child_pairs_([], [child(NX, NY, NL)|Ns]) --> !,
    put_subtree_(NX, NY, NL),
    child_pairs_([], Ns).
child_pairs_([child(_, _, PL)|Ps], []) -->
    { get_dict(path, PL, Path) },
    [ paint_drop(Path) ],
    child_pairs_(Ps, []).
