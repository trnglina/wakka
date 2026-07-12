mod interop;

use std::ffi::CString;
use std::os::raw::c_void;

use swi_fli::{PL_register_foreign_in_module, foreign_t, term_t};

use interop::{FALSE, TRUE, guard, unify_atom};

unsafe extern "C" fn pl_version(a0: term_t) -> foreign_t {
    guard(|| {
        if unify_atom(a0, env!("CARGO_PKG_VERSION")) {
            TRUE
        } else {
            FALSE
        }
    })
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn install_native() {
    let module = CString::new("ui_native").unwrap();
    unsafe {
        register(&module, "version", 1, pl_version as *mut c_void);
    }
}

unsafe fn register(module: &CString, name: &str, arity: i32, func: *mut c_void) {
    let name = CString::new(name).unwrap();
    unsafe {
        PL_register_foreign_in_module(module.as_ptr(), name.as_ptr(), arity, func, 0);
    }
}
