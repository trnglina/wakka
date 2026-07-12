use std::ffi::CString;
use std::panic::{UnwindSafe, catch_unwind};

use swi_fli::{
    PL_cons_functor, PL_new_functor, PL_new_term_ref, PL_put_atom_chars, PL_raise_exception,
    PL_unify_atom_chars, foreign_t, term_t,
};

const PL_FALSE: foreign_t = 0;
const PL_TRUE: foreign_t = 1;

/// Runs `f`, converting a Rust panic into a catchable Prolog exception.
pub fn guard(f: impl FnOnce() -> foreign_t + UnwindSafe) -> foreign_t {
    match catch_unwind(f) {
        Ok(rc) => rc,
        Err(payload) => {
            let msg = panic_message(&payload);
            raise_foreign_error(&msg);
            PL_FALSE
        }
    }
}

fn panic_message(payload: &Box<dyn std::any::Any + Send>) -> String {
    if let Some(s) = payload.downcast_ref::<&str>() {
        s.to_string()
    } else if let Some(s) = payload.downcast_ref::<String>() {
        s.clone()
    } else {
        "native panic (no message)".to_string()
    }
}

/// Raises `error(foreign_error(Msg), _)`.
fn raise_foreign_error(msg: &str) {
    unsafe {
        let Some(msg_atom) = new_atom_term(msg) else {
            return;
        };

        let foreign_error_functor = PL_new_functor(atom_from_chars("foreign_error"), 1);
        let inner = PL_new_term_ref();
        if !PL_cons_functor(inner, foreign_error_functor, msg_atom) {
            return;
        }

        let error_functor = PL_new_functor(atom_from_chars("error"), 2);
        let context = PL_new_term_ref(); // unbound var, i.e. `_`
        let exception = PL_new_term_ref();
        if !PL_cons_functor(exception, error_functor, inner, context) {
            return;
        }

        PL_raise_exception(exception);
    }
}

unsafe fn atom_from_chars(s: &str) -> swi_fli::atom_t {
    let c = CString::new(s).expect("no interior NUL");
    unsafe { swi_fli::PL_new_atom(c.as_ptr()) }
}

unsafe fn new_atom_term(s: &str) -> Option<term_t> {
    let t = unsafe { PL_new_term_ref() };
    if unify_atom(t, s) { Some(t) } else { None }
}

/// Unifies `term` with the Prolog atom `s`.
pub fn unify_atom(term: term_t, s: &str) -> bool {
    let Ok(c) = CString::new(s) else {
        return false;
    };
    unsafe { PL_unify_atom_chars(term, c.as_ptr()) }
}

/// Puts the Prolog atom `s` into a fresh output term.
#[allow(dead_code)]
pub fn put_atom(term: term_t, s: &str) -> bool {
    let Ok(c) = CString::new(s) else {
        return false;
    };
    unsafe { PL_put_atom_chars(term, c.as_ptr()) }
}

pub const TRUE: foreign_t = PL_TRUE;
pub const FALSE: foreign_t = PL_FALSE;
