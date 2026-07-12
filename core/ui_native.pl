:- module(ui_native, [ version/1 ]).

:- use_module(library(filesex)).

native_lib_parts(Base, Ext) :-
    (   current_prolog_flag(windows, true)
    ->  Base = native, Ext = dll
    ;   current_prolog_flag(apple, true)
    ->  Base = libnative, Ext = dylib
    ;   Base = libnative, Ext = so
    ).

native_target_base(Base) :-
    (   getenv('CARGO_TARGET_DIR', Base0)
    ->  true
    ;   prolog_load_context(directory, Here),
        directory_file_path(Here, '../target', Base0)
    ),
    absolute_file_name(Base0, Base,
                       [file_type(directory), file_errors(fail)]).

native_lib_dir(Dir) :-
    native_target_base(Base),
    native_lib_parts(LibBase, Ext),
    file_name_extension(LibBase, Ext, File),
    member(Profile, [debug, release]),
    directory_file_path(Base, Profile, Dir),
    directory_file_path(Dir, File, Path),
    exists_file(Path),
    !.

:- (   native_lib_dir(Dir)
   ->  asserta(user:file_search_path(foreign, Dir)),
       native_lib_parts(LibBase, _),
       use_foreign_library(foreign(LibBase), [install(install_native)])
   ;   print_message(error, format("native library not available", []))
   ).
