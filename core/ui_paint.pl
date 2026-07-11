:- module(ui_paint, [ paint_apply/1, paint_render/3 ]).

:- use_module(library(apply)).
:- use_module(ui_native).

%  The stateless bridge between layout output and the native render scene. The
%  scene is state that lives in native code (keyed by state path); ui_paint just
%  forwards each paint change (from ui_layout:layout_changes/3) to a scene
%  predicate. It keeps no state of its own.

%! paint_apply(+Changes) is det.
%
%  Applies a paint-change stream to the native scene.

paint_apply(Changes) :-
    maplist(paint_change_, Changes).

paint_change_(paint_put(Path, X, Y, W, H, Draw)) :-
    scene_put(Path, X, Y, W, H, Draw).
paint_change_(paint_move(Path, X, Y)) :-
    scene_move(Path, X, Y).
paint_change_(paint_drop(Path)) :-
    scene_drop(Path).

%! paint_render(+Width, +Height, -Pixels) is semidet.
%
%  Renders the current scene to a Width x Height (pixel) image; Pixels is a
%  string of RGBA bytes. Fails if no GPU adapter is available.

paint_render(Width, Height, Pixels) :-
    scene_render_headless(Width, Height, Pixels).
