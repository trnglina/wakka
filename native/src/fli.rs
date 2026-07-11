//! Shared SWI-Prolog FLI helpers: cached atoms/functors, term readers and term
//! builders, plus the layout-unit convention. Used by every predicate wrapper.

use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint};
use std::sync::OnceLock;

use swi_fli::*;

/// Layout units per logical pixel (mirrors `px_units/2`). The FLI boundary
/// speaks units; the worker crates speak pixels.
pub const UNITS_PER_PX: f64 = 64.0;

/// Atoms and functors reused on every call. SWI atoms are process-global and
/// interned, so caching avoids churning their reference counts.
#[derive(Clone, Copy)]
pub struct Atoms {
    pub run: atom_t,
    pub boxed: atom_t,
    pub font_size: atom_t,
    pub font_family: atom_t,
    pub font_weight: atom_t,
    pub slant: atom_t,
    pub lang: atom_t,
    pub color: atom_t,
    pub leading: atom_t,
    pub none: atom_t,
    pub normal: atom_t,
    pub italic: atom_t,
    pub truth: atom_t,
    pub falsity: atom_t,
    pub metrics: functor_t,
    pub line: functor_t,
    pub glyph_run: functor_t,
    pub glyph: functor_t,
    pub box_item: functor_t,
    pub font: functor_t,
    pub synth: functor_t,
    pub oblique: functor_t,
    pub glyphs: functor_t,
    pub rgb: functor_t,
    pub rgba: functor_t,
}

static ATOMS: OnceLock<Atoms> = OnceLock::new();

pub fn atoms() -> Atoms {
    *ATOMS.get_or_init(|| {
        // Safe: called from a registered foreign predicate, so the engine is up.
        unsafe {
            let a = |s: &[u8]| PL_new_atom(s.as_ptr() as *const c_char);
            let f = |s: &[u8], n| PL_new_functor(a(s), n);
            Atoms {
                run: a(b"run\0"),
                boxed: a(b"box\0"),
                font_size: a(b"font_size\0"),
                font_family: a(b"font_family\0"),
                font_weight: a(b"font_weight\0"),
                slant: a(b"slant\0"),
                lang: a(b"lang\0"),
                color: a(b"color\0"),
                leading: a(b"leading\0"),
                none: a(b"none\0"),
                normal: a(b"normal\0"),
                italic: a(b"italic\0"),
                truth: a(b"true\0"),
                falsity: a(b"false\0"),
                metrics: f(b"metrics\0", 3),
                line: f(b"line\0", 4),
                glyph_run: f(b"glyph_run\0", 5),
                glyph: f(b"glyph\0", 6),
                box_item: f(b"box\0", 5),
                font: f(b"font\0", 3),
                synth: f(b"synth\0", 2),
                oblique: f(b"oblique\0", 1),
                glyphs: f(b"glyphs\0", 1),
                rgb: f(b"rgb\0", 3),
                rgba: f(b"rgba\0", 4),
            }
        }
    })
}

// --- Readers --- //

/// Reads an atom or string term as a UTF-8 `String`. `None` for numbers,
/// compounds and variables.
pub unsafe fn term_text(t: term_t) -> Option<String> {
    unsafe {
        let mut ptr: *mut c_char = std::ptr::null_mut();
        let flags = (CVT_ATOM | CVT_STRING | BUF_DISCARDABLE | REP_UTF8) as c_uint;
        if PL_get_chars(t, &mut ptr, flags) && !ptr.is_null() {
            Some(CStr::from_ptr(ptr).to_string_lossy().into_owned())
        } else {
            None
        }
    }
}

/// Reads a numeric term (integer or float) as `f64`.
pub unsafe fn term_number(t: term_t) -> Option<f64> {
    unsafe {
        let mut f = 0.0f64;
        if PL_get_float(t, &mut f) {
            return Some(f);
        }
        let mut i = 0i64;
        if PL_get_int64(t, &mut i) {
            return Some(i as f64);
        }
        None
    }
}

/// `PL_get_arg` for a 1-based argument, into a fresh term reference.
pub unsafe fn arg(index: c_int, t: term_t) -> term_t {
    unsafe {
        let a = PL_new_term_ref();
        PL_get_arg(index, t, a);
        a
    }
}

/// Looks up `key` in dict `t`, returning the value term.
pub unsafe fn dict_key(t: term_t, key: atom_t) -> Option<term_t> {
    unsafe {
        let v = PL_new_term_ref();
        if PL_get_dict_key(key, t, v) { Some(v) } else { None }
    }
}

/// Reads the head of a proper list, into a fresh term reference.
pub unsafe fn list_head(t: term_t) -> Option<term_t> {
    unsafe {
        let head = PL_new_term_ref();
        let tail = PL_new_term_ref();
        if PL_get_list(t, head, tail) { Some(head) } else { None }
    }
}

/// Reads an arity-1 attribute value `[V]` from an `attrs{}` dict.
pub unsafe fn attr(dict: term_t, key: atom_t) -> Option<term_t> {
    unsafe { list_head(dict_key(dict, key)?) }
}

/// Walks a proper list, calling `f` on each element term.
pub unsafe fn for_each_list(mut list: term_t, mut f: impl FnMut(term_t)) {
    unsafe {
        loop {
            let head = PL_new_term_ref();
            let tail = PL_new_term_ref();
            if !PL_get_list(list, head, tail) {
                break;
            }
            f(head);
            list = tail;
        }
    }
}

/// Collects the elements of a proper list into a `Vec` of term references.
pub unsafe fn list_terms(list: term_t) -> Vec<term_t> {
    unsafe {
        let mut v = Vec::new();
        for_each_list(list, |e| v.push(e));
        v
    }
}

// --- Builders --- //

pub unsafe fn put_float(v: f64) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        PL_put_float(t, v);
        t
    }
}

/// A layout-unit float term from a pixel value.
pub unsafe fn units(px: f32) -> term_t {
    unsafe { put_float(px as f64 * UNITS_PER_PX) }
}

pub unsafe fn put_int(v: i64) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        PL_put_int64(t, v);
        t
    }
}

pub unsafe fn put_atom(a: atom_t) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        PL_put_atom(t, a);
        t
    }
}

pub unsafe fn put_string(s: &str) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        let flags = (PL_STRING | REP_UTF8) as c_int;
        PL_put_chars(t, flags, s.len(), s.as_ptr() as *const c_char);
        t
    }
}

/// Builds a proper list from element terms.
pub unsafe fn list_of(elems: &[term_t]) -> term_t {
    unsafe {
        let lst = PL_new_term_ref();
        PL_put_nil(lst);
        let mut acc = lst;
        for &e in elems.iter().rev() {
            let cell = PL_new_term_ref();
            PL_cons_list(cell, e, acc);
            acc = cell;
        }
        acc
    }
}
