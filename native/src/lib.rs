//! The single SWI-Prolog FLI boundary for the wakka native crates.
//!
//! `native` consumes the pure worker libraries (`layout_text`, and later
//! `paint`) and registers every foreign predicate the Prolog `core` calls. It
//! owns all `term_t` <-> Rust conversion; the workers stay Prolog-agnostic.

#![allow(clippy::missing_safety_doc)]

mod fli;
mod font;
mod paint;
mod text;

use std::os::raw::{c_char, c_int, c_void};

use swi_fli::*;

/// SWI install entry for `foreign(libnative)` (`shlib.pl` derives `install_` +
/// the spec base name, and does not add a `lib` prefix, so the cdylib
/// `libnative.so` is loaded as `foreign(libnative)`).
#[unsafe(no_mangle)]
pub extern "C" fn install_libnative() {
    unsafe {
        register("measure_text\0", 4, text::measure_text as *mut c_void);
        register("scene_put\0", 6, paint::scene_put as *mut c_void);
        register("scene_move\0", 3, paint::scene_move as *mut c_void);
        register("scene_drop\0", 1, paint::scene_drop as *mut c_void);
        register(
            "scene_render_headless\0",
            3,
            paint::scene_render_headless as *mut c_void,
        );
    }
}

unsafe fn register(name: &str, arity: c_int, func: *mut c_void) {
    unsafe {
        PL_register_foreign(name.as_ptr() as *const c_char, arity, func, 0);
    }
}
