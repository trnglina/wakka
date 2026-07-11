:- module(ui_changes, [ element_changes/3 ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(ui_element).
:- use_module(ui_attributes).

%! element_changes(+Prev, +Next, -Changes) is semidet.

element_changes(P, N, Changes) :-
    ground(P), ground(N),
    phrase(element_changes(P, N, []), Changes).

%! element_changes(+Prev, +Next, +Path)// is det.

element_changes(P, N, _) --> { string(P), P == N }, !.
element_changes(P, N, Path) -->
    { element_parts(P, Tag, PAttrs, PChildren), element_parts(N, Tag, NAttrs, NChildren) }, !,
    attributes_changes(PAttrs, NAttrs, Path),
    children_changes(PChildren, NChildren, Path).
element_changes(_, N, Path) -->
    detach_child(Path, key(Path, drop)),
    insert_child(Path, N).

%! attributes_changes(+PrevAttrs, +NextAttrs, +Path)// is det.

attributes_changes(PAttrs, NAttrs, _) -->
    { PAttrs == NAttrs }, !,
    { normalize_attributes(PAttrs, _) }. % validity guard, via the schema
attributes_changes(PAttrs, NAttrs, Path) -->
    { normalize_attributes(PAttrs, PrevPairs), ord_list_to_assoc(PrevPairs, PrevAssoc),
      normalize_attributes(NAttrs, NextPairs), ord_list_to_assoc(NextPairs, NextAssoc) },
    removed_attributes_(PrevPairs, NextAssoc, Path),
    set_attributes_(NextPairs, PrevAssoc, Path).

%! removed_attributes_(+PrevPairs, +NextAssoc, +Path)// is det.

removed_attributes_([], _, _) --> !.
removed_attributes_([Key-_|Pairs], NextAssoc, Path) -->
    ( { get_assoc(Key, NextAssoc, _) }
    ; remove_attribute(Path, Key) ), !,
    removed_attributes_(Pairs, NextAssoc, Path).

%! set_attributes_(+NextPairs, +PrevAssoc, +Path)// is det.

set_attributes_([], _, _) --> !.
set_attributes_([Key-Value|Pairs], PrevAssoc, Path) -->
    ( { get_assoc(Key, PrevAssoc, Value) }   % ground unify == equality
    ; set_attribute(Path, Key, Value) ), !,
    set_attributes_(Pairs, PrevAssoc, Path).

%! children_changes(+PrevChildren, +NextChildren, +Path)// is det.

children_changes(Ps, Ns, Path) -->
    { keyed_assoc(Ps, PrevAssoc),
      keyed_assoc(Ns, NextAssoc),
      empty_assoc(SA) },
    children_changes_(Ps, Ns, Path, 0, 0, PrevAssoc, NextAssoc, SA).

%! children_changes_(+PrevChildren, +NextChildren, +BasePath, +PrevIdx, +NextIdx, +PrevAssoc, +NextAssoc, +StashAssoc)// is det.

children_changes_([], [], _, _, _, _, _, _) --> !.
children_changes_([P|Ps], [N|Ns], BasePath, PIdx1, NIdx1, PrevAssoc, NextAssoc, StashAssoc) -->
    { (  element_key(P, Key)
      -> element_key(N, Key)
      ;  \+ element_key(N, _), element_parts(P, Tag, _, _), element_parts(N, Tag, _, _)  ),
      PIdx2 is PIdx1 + 1, NIdx2 is NIdx1 + 1,
      Path = [NIdx1|BasePath] },
    element_changes(P, N, Path), !,
    children_changes_(Ps, Ns, BasePath, PIdx2, NIdx2, PrevAssoc, NextAssoc, StashAssoc).
children_changes_(Ps, [N|Ns], BasePath, PIdx, NIdx1, PrevAssoc, NextAssoc, StashAssoc) -->
    { element_key(N, NKey), get_assoc(NKey, StashAssoc, P-StashKey),
      Path = [NIdx1|BasePath], NIdx2 is NIdx1 + 1 },
    attach_child(Path, StashKey),
    element_changes(P, N, Path), !,
    children_changes_(Ps, Ns, BasePath, PIdx, NIdx2, PrevAssoc, NextAssoc, StashAssoc).
children_changes_([P|Ps], [N|Ns], BasePath, PIdx, NIdx1, PrevAssoc, NextAssoc, StashAssoc) -->
    { element_key(P, PKey), get_assoc(PKey, NextAssoc, _),
      element_key(N, NKey), \+ get_assoc(NKey, PrevAssoc, _),
      NIdx2 is NIdx1 + 1,
      Path = [NIdx1|BasePath] },
    insert_child(Path, N), !,
    children_changes_([P|Ps], Ns, BasePath, PIdx, NIdx2, PrevAssoc, NextAssoc, StashAssoc).
children_changes_([P|Ps], Ns, BasePath, PIdx1, NIdx, PrevAssoc, NextAssoc, StashAssoc1) -->
    { StashKey = key(BasePath, PIdx1),
      (  element_key(P, PKey)
      -> put_assoc(PKey, StashAssoc1, P-StashKey, StashAssoc2)
      ;  StashAssoc2 = StashAssoc1  ),
      PIdx2 is PIdx1 + 1,
      Path = [NIdx|BasePath] },
    detach_child(Path, StashKey), !,
    children_changes_(Ps, Ns, BasePath, PIdx2, NIdx, PrevAssoc, NextAssoc, StashAssoc2).
children_changes_(Ps, [N|Ns], BasePath, PIdx, NIdx1, PrevAssoc, NextAssoc, StashAssoc) -->
    { NIdx2 is NIdx1 + 1,
      Path = [NIdx1|BasePath] },
    insert_child(Path, N), !,
    children_changes_(Ps, Ns, BasePath, PIdx, NIdx2, PrevAssoc, NextAssoc, StashAssoc).

%! keyed_assoc(+Els, -Assoc) is det.

keyed_assoc(Els, Assoc) :-
    keyed_pairs_(Els, Pairs),
    sort(1, @<, Pairs, Sorted),
    ord_list_to_assoc(Sorted, Assoc).

keyed_pairs_([], []).
keyed_pairs_([E|Es], Pairs) :-
    (  element_key(E, Key)
    -> Pairs = [Key-[]|Rest]
    ;  Pairs = Rest  ),
    keyed_pairs_(Es, Rest).

%! remove_attribute(+Path, +Key)// is det.

remove_attribute(Path, Key) -->
    { reverse(Path, ForwardPath) },
    [ remove_attribute(ForwardPath, Key) ].

%! set_attribute(+Path, +Key, +Value)// is det.

set_attribute(Path, Key, Value) -->
    { reverse(Path, ForwardPath) },
    [ set_attribute(ForwardPath, Key, Value) ].

%! attach_child(+Path, +StashKey)// is det.

attach_child(Path, StashKey) -->
    { reverse(Path, ForwardPath) },
    [ attach_child(ForwardPath, StashKey) ].

%! detach_child(+Path, +StashKey)// is det.

detach_child(Path, StashKey) -->
    { reverse(Path, ForwardPath) },
    [ detach_child(ForwardPath, StashKey) ].

%! insert_child(+Path, +El)// is det.

insert_child(Path, El) -->
    { reverse(Path, ForwardPath) },
    [ insert_child(ForwardPath, El) ].
