:- module(ui_attributes, [ attribute_flag/2, normalize_attributes/2 ]).

:- use_module(library(lists)).
:- use_module(ui_element).

% --- Attributes Definition --- %

% Functional attributes
attribute(key, 1, []).
attribute(lang, 1, [inherit, layout]).

% Text rendering attributes
attribute(color, 1, [inherit]).
attribute(font_family, 1, [inherit, layout]).
attribute(font_size, 1, [inherit, layout]).
attribute(font_weight, 1, [inherit, layout]).
attribute(slant, 1, [inherit, layout]).

% Text layout attributes
attribute(alignment, 1, [layout]).
attribute(leading, 1, [layout]).

% Layout attributes
attribute(display, 1, [layout]).
attribute(main_size, 1, [layout]).
attribute(cross_size, 1, [layout]).
attribute(flex, 1, [layout]).
attribute(fit, 1, [layout]).
attribute(direction, 1, [layout]).
attribute(main_axis, 1, [layout]).
attribute(cross_axis, 1, [layout]).
attribute(margin, 1, [layout]).
attribute(margin, 2, [layout]).
attribute(margin, 4, [layout]).
attribute(padding, 1, [layout]).
attribute(padding, 2, [layout]).
attribute(padding, 4, [layout]).
attribute(overflow, 1, [layout]).

% Presentational attributes
attribute(decoration, 1, []).
attribute(backdrop, 1, []).
attribute(opacity, 1, []).

% --- Attributes API --- %

attribute_flag(Key, Flag) :-
    attribute(Key, _, Flags),
    memberchk(Flag, Flags).

normalize_attributes(Attrs, Pairs) :-
    collect_pairs_(Attrs, Collected),
    reverse(Collected, Reversed),
    sort(1, @<, Reversed, Pairs).

collect_pairs_([], []).
collect_pairs_([Attr|Attrs], Pairs) :-
    attribute_parts(Attr, Key, Value),
    length(Value, Arity),
    ( attribute(Key, Arity, _) -> Pairs = [Key-Value|Rest] ; Pairs = Rest ),
    collect_pairs_(Attrs, Rest).
