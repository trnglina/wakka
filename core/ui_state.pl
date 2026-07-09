:- module(ui_state, [ empty_node/1, node_apply_changes/3 ]).

:- use_module(library(assoc)).
:- use_module(library(lists)).
:- use_module(ui_element).
:- use_module(ui_attributes).

%! empty_node(?Node) is det.

empty_node(none).

%! node_apply_changes(+Changes, +PrevNode, -NextNode) is semidet.

node_apply_changes(Changes, PrevNode, NextNode) :-
    empty_assoc(Stash),
    foldl(node_apply_change, Changes, PrevNode-Stash, NextNode-_).

%! node_apply_change(+Change, +PrevNode-PrevStash, -NextNode-NextStash) is semidet.

node_apply_change(set_attribute(Path, Key, Value), PrevNode-NextStash, NextNode-NextStash) :-
    update_node(Path, attrs{}, PrevNode, NextNode, node_set_attribute(Key, Value)).
node_apply_change(remove_attribute(Path, Key), PrevNode-NextStash, NextNode-NextStash) :-
    update_node(Path, attrs{}, PrevNode, NextNode, node_remove_attribute(Key)).
node_apply_change(insert_child([], El), _-NextStash, NextNode-NextStash) :- !,
    build_node(El, attrs{}, NextNode).
node_apply_change(insert_child(Path, El), PrevNode-NextStash, NextNode-NextStash) :-
    once(append(BasePath, [Idx], Path)),
    update_node(BasePath, attrs{}, PrevNode, NextNode, node_build_child(Idx, El)).
node_apply_change(detach_child([], Key), PrevNode-PrevStash, none-NextStash) :- !,
    is_dict(PrevNode),
    \+ get_assoc(Key, PrevStash, _),
    put_assoc(Key, PrevStash, PrevNode, NextStash).
node_apply_change(detach_child(Path, Key), PrevNode-PrevStash, NextNode-NextStash) :-
    \+ get_assoc(Key, PrevStash, _),
    once(append(BasePath, [Idx], Path)),
    update_node(BasePath, attrs{}, PrevNode, NextNode, node_detach_child(Idx, Removed)),
    put_assoc(Key, PrevStash, Removed, NextStash).
node_apply_change(attach_child(Path, Key), PrevNode-PrevStash, NextNode-NextStash) :-
    del_assoc(Key, PrevStash, Node, NextStash),
    once(append(BasePath, [Idx], Path)),
    update_node(BasePath, attrs{}, PrevNode, NextNode, node_insert_child(Idx, Node)).

%! node_resolve_inheritance_(+Node, +ParentInherited, -Resolved) is det.

node_resolve_inheritance_(Node, ParentInherited, Resolved) :-
    (  get_dict(children, Node, Children)
    -> get_dict(tag, Node, Tag),
       get_dict(attributes, Node, Attrs),
       get_inherited_dict(Attrs, ParentInherited, Inherited),
       (  get_dict(inherited, Node, Inherited)
       -> Resolved = Node
       ;  node_resolve_children(Children, Inherited, ResolvedChildren),
          Resolved = node{tag: Tag, attributes: Attrs, children: ResolvedChildren, inherited: Inherited}  )
    ;  (  get_dict(inherited, Node, ParentInherited)
       -> Resolved = Node
       ;  get_dict(text, Node, Text),
          Resolved = node{text: Text, inherited: ParentInherited}  )  ).

node_resolve_children([], _, []).
node_resolve_children([Node|Nodes], Inherited, [Resolved|Resolveds]) :-
    node_resolve_inheritance_(Node, Inherited, Resolved),
    node_resolve_children(Nodes, Inherited, Resolveds).

%! get_inherited_dict(+OwnAttrs, +ParentInherited, -Inherited) is det.

get_inherited_dict(OwnAttrs, ParentInherited, Inherited) :-
    (  OwnAttrs == attrs{}
    -> Inherited = ParentInherited
    ;  findall(Key-Value,
               ( attribute_flag(Key, inherit), get_dict(Key, OwnAttrs, Value) ),
               OwnPairs),
       (  OwnPairs == []
       -> Inherited = ParentInherited
       ;  put_dict(OwnPairs, ParentInherited, Inherited)  )  ).

% --- Node Operations --- %

%! build_node(+Element, +ParentInherited, -Node) is semidet.

build_node(String, ParentInherited, node{text: String, inherited: ParentInherited}) :-
    string(String), !.
build_node(El, ParentInherited,
           node{tag: Tag, attributes: Attrs, children: Children, inherited: Inherited}) :-
    element_parts(El, Tag, A, C),
    normalize_attributes(A, Pairs),
    dict_pairs(Attrs, attrs, Pairs),
    get_inherited_dict(Attrs, ParentInherited, Inherited),
    build_children(C, Inherited, Children).

build_children([], _, []).
build_children([El|Els], Inherited, [Node|Nodes]) :-
    build_node(El, Inherited, Node),
    build_children(Els, Inherited, Nodes).

%! update_node(+Path, +ParentInherited, +PrevNode, -NextNode, :Goal) is semidet.

update_node([], ParentInherited, PrevNode, NextNode, Goal) :-
    is_dict(PrevNode),
    call(Goal, ParentInherited, PrevNode, NextNode).
update_node([Idx|Idxs], _, PrevNode, NextNode, Goal) :-
    is_dict(PrevNode),
    get_dict(children, PrevNode, PrevChildren),
    get_dict(inherited, PrevNode, OwnInherited),
    get_dict(tag, PrevNode, Tag),
    get_dict(attributes, PrevNode, Attrs),
    nth0(Idx, PrevChildren, PrevChild, Rest),
    update_node(Idxs, OwnInherited, PrevChild, NextChild, Goal),
    nth0(Idx, NextChildren, NextChild, Rest),
    NextNode = node{tag: Tag, attributes: Attrs, children: NextChildren, inherited: OwnInherited}.

update_node_children(PrevNode, Children,
                     node{tag: Tag, attributes: Attrs, children: Children, inherited: Inh}) :-
    get_dict(tag, PrevNode, Tag),
    get_dict(attributes, PrevNode, Attrs),
    get_dict(inherited, PrevNode, Inh).

update_node_attributes(PrevNode, Attrs,
                       node{tag: Tag, attributes: Attrs, children: Children, inherited: Inh}) :-
    get_dict(tag, PrevNode, Tag),
    get_dict(children, PrevNode, Children),
    get_dict(inherited, PrevNode, Inh).

node_set_attribute(Key, Value, ParentInherited, PrevNode, NextNode) :-
    get_dict(attributes, PrevNode, PrevAttrs),
    put_dict(Key, PrevAttrs, Value, NextAttrs),
    update_node_attributes(PrevNode, NextAttrs, UpdatedNode),
    ( attribute_flag(Key, inherit)
    -> node_resolve_inheritance_(UpdatedNode, ParentInherited, NextNode)
    ;  NextNode = UpdatedNode ).

node_remove_attribute(Key, ParentInherited, PrevNode, NextNode) :-
    get_dict(attributes, PrevNode, PrevAttrs),
    ( del_dict(Key, PrevAttrs, _, NextAttrs) -> true ; NextAttrs = PrevAttrs ),
    update_node_attributes(PrevNode, NextAttrs, UpdatedNode),
    ( attribute_flag(Key, inherit)
    -> node_resolve_inheritance_(UpdatedNode, ParentInherited, NextNode)
    ;  NextNode = UpdatedNode ).

node_insert_child(Idx, Node, _, PrevNode, NextNode) :-
    get_dict(inherited, PrevNode, OwnInherited),
    node_resolve_inheritance_(Node, OwnInherited, ResolvedNode),
    get_dict(children, PrevNode, PrevChildren),
    nth0(Idx, NextChildren, ResolvedNode, PrevChildren),
    update_node_children(PrevNode, NextChildren, NextNode).

node_build_child(Idx, El, _, PrevNode, NextNode) :-
    get_dict(inherited, PrevNode, OwnInherited),
    build_node(El, OwnInherited, Node),
    get_dict(children, PrevNode, PrevChildren),
    nth0(Idx, NextChildren, Node, PrevChildren),
    update_node_children(PrevNode, NextChildren, NextNode).

node_detach_child(Idx, El, _, PrevNode, NextNode) :-
    get_dict(children, PrevNode, PrevChildren),
    nth0(Idx, PrevChildren, El, NextChildren),
    update_node_children(PrevNode, NextChildren, NextNode).
