:- module(ui_element, [ attribute_parts/3, element_parts/4, element_key/2 ]).

:- use_module(library(when)).

%! attribute_parts(?Attr, ?Key, ?Value) is semidet.

attribute_parts(Attr, Key, Value) :-
    nonvar(Attr), !,
    Attr =.. [Key|Value],
    atom(Key).
attribute_parts(Attr, Key, Value) :-
    when(( ground(Value), nonvar(Key) ),
         ( atom(Key), is_list(Value), Attr =.. [Key|Value] )).

%! element_parts(?El, ?Tag, ?Attrs, ?Children) is semidet.

element_parts(El, Tag, Attrs, Children) :-
    nonvar(El), !,
    compound(El),
    (  functor(El, Tag, 2),
       arg(1, El, First),
       ( First == [] -> true ; First = [_|_] )
    -> Attrs = First,
       arg(2, El, Children)
    ;  functor(El, Tag, 1),
       Attrs = [],
       arg(1, El, Children)  ).
element_parts(El, Tag, Attrs, Children) :-
    element_args(Attrs, Children, Args),
    freeze(Tag, ( atom(Tag), El =.. [Tag|Args] )).

%! element_args(?Attrs, ?Children, ?Args) is semidet.

element_args(Attrs, Children, Args) :-
    (  nonvar(Args)
    -> (  Args = [Attrs, Children], ( Attrs == [] ; Attrs = [_|_] )
       -> true
       ;  Args = [Children], Attrs = []  )
    ;  var(Attrs)
    -> (  Attrs = [], Args = [Children]
       -> true
       ;  Attrs = [_|_], Args = [Attrs, Children]  )
    ;  Attrs == []
    -> Args = [Children]
    ;  Attrs = [_|_],
       Args = [Attrs, Children]  ).

%! element_key(+El, ?Key) is semidet.

element_key(String, text-String) :- string(String), !.
element_key(El, Tag-KeyValue) :-
    compound(El),
    functor(El, Tag, 2),
    arg(1, El, Attrs),
    ( key_attr(Attrs, KeyValue) -> true ).

%! key_attr(+Attrs, ?KeyValue) is nondet.

key_attr([key(Value)|_], Value) :- atom(Value).
key_attr([_|Attrs], Value) :- key_attr(Attrs, Value).
