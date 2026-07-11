//! Native text measurement for `ui_layout`.
//!
//! Registers the SWI-Prolog foreign predicate that `ui_layout` calls to size
//! inline content:
//!
//! ```prolog
//! measure_text(+Runs, +Options, +MaxW, -Metrics)
//! ```
//!
//! `Runs` is a list of `run(Text, Attrs)` / `box(RelPath, W, H)`, `Options` is
//! an `inline_options{leading:_}` dict, `MaxW` is a unit count or the atom
//! `inf`, and `Metrics` is unified with `metrics(W, H)`. The predicate is
//! total: it throws `type_error(max_width, MaxW)` when `MaxW` is neither a
//! number nor `inf`. Its arguments and result speak layout units (1/64 logical
//! px, see `px_units/2`): `MaxW` and `box` sizes arrive in units, `font_size`
//! arrives in logical px, and Parley works in px — so we divide unit inputs by
//! 64 on the way in and multiply Parley's px output by 64 on the way out.

use std::cell::RefCell;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::sync::OnceLock;

use parley::{
    FontContext, FontFamily, FontStyle, FontWeight, InlineBox, InlineBoxKind, Language, Layout,
    LayoutContext, LineHeight, StyleProperty,
};

use swi_fli::*;

/// Measurement never paints, so the brush type is irrelevant; use the smallest
/// value that satisfies Parley's `Brush` bound (`Clone + PartialEq + Default +
/// Debug`).
type Brush = [u8; 0];

/// Layout units per logical pixel (mirrors `px_units/2`).
const UNITS_PER_PX: f64 = 64.0;

thread_local! {
    /// Font and layout contexts are expensive to build (the font context
    /// enumerates the host's fonts via fontconfig), so keep them alive for the
    /// life of the thread. A `thread_local` keeps this sound if SWI-Prolog
    /// drives measurement from multiple threads.
    static CTX: RefCell<(FontContext, LayoutContext<Brush>)> =
        RefCell::new((FontContext::new(), LayoutContext::new()));
}

// --- Cached atoms --- //

/// Atoms and functors reused on every call. SWI atoms are process-global and
/// interned, so caching them (rather than re-creating on each call) avoids
/// churning their reference counts.
#[derive(Clone, Copy)]
struct Atoms {
    run: atom_t,
    boxed: atom_t,
    font_size: atom_t,
    font_family: atom_t,
    font_weight: atom_t,
    slant: atom_t,
    lang: atom_t,
    leading: atom_t,
    metrics: functor_t,
}

static ATOMS: OnceLock<Atoms> = OnceLock::new();

fn atoms() -> Atoms {
    *ATOMS.get_or_init(|| {
        // Safe: called from a registered foreign predicate, so the Prolog
        // engine is initialised.
        unsafe {
            let a = |s: &[u8]| PL_new_atom(s.as_ptr() as *const c_char);
            Atoms {
                run: a(b"run\0"),
                boxed: a(b"box\0"),
                font_size: a(b"font_size\0"),
                font_family: a(b"font_family\0"),
                font_weight: a(b"font_weight\0"),
                slant: a(b"slant\0"),
                lang: a(b"lang\0"),
                leading: a(b"leading\0"),
                metrics: PL_new_functor(a(b"metrics\0"), 2),
            }
        }
    })
}

// --- Term readers --- //

/// Reads an atom or string term as a UTF-8 `String`. Fails (returns `None`) for
/// numbers, compounds and variables.
unsafe fn term_text(t: term_t) -> Option<String> {
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
unsafe fn term_number(t: term_t) -> Option<f64> {
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
unsafe fn arg(index: c_int, t: term_t) -> term_t {
    unsafe {
        let a = PL_new_term_ref();
        PL_get_arg(index, t, a);
        a
    }
}

/// Looks up `key` in dict `t`, returning the value term.
unsafe fn dict_key(t: term_t, key: atom_t) -> Option<term_t> {
    unsafe {
        let v = PL_new_term_ref();
        if PL_get_dict_key(key, t, v) {
            Some(v)
        } else {
            None
        }
    }
}

/// Reads the head of a proper list, into a fresh term reference.
unsafe fn list_head(t: term_t) -> Option<term_t> {
    unsafe {
        let head = PL_new_term_ref();
        let tail = PL_new_term_ref();
        if PL_get_list(t, head, tail) {
            Some(head)
        } else {
            None
        }
    }
}

/// Reads an arity-1 attribute value `[V]` from an `attrs{}` dict.
unsafe fn attr(dict: term_t, key: atom_t) -> Option<term_t> {
    unsafe { list_head(dict_key(dict, key)?) }
}

// --- Request parsing --- //

/// A styled span of the concatenated text, in byte offsets.
struct Span {
    range: std::ops::Range<usize>,
    font_size: Option<f32>,
    family: Option<String>,
    weight: Option<FontWeight>,
    style: Option<FontStyle>,
    locale: Option<Language>,
}

/// An inline element placed at a byte offset in the concatenated text.
struct Boxed {
    index: usize,
    width: f32,
    height: f32,
}

struct Request {
    text: String,
    spans: Vec<Span>,
    boxes: Vec<Boxed>,
    leading: Option<f32>,
    max_advance: Option<f32>,
}

/// Parses the request arguments. Returns `None` only when `MaxW` is neither a
/// number nor the atom `inf`, which `measure_text` reports as a `type_error`.
unsafe fn parse(runs: term_t, options: term_t, max_w: term_t) -> Option<Request> {
    unsafe {
        let at = atoms();

        // MaxW: the atom `inf` means unbounded, otherwise a count of units.
        let max_advance = if term_text(max_w).as_deref() == Some("inf") {
            None
        } else {
            Some((term_number(max_w)? / UNITS_PER_PX) as f32)
        };

        let leading = dict_key(options, at.leading)
            .and_then(|v| term_number(v))
            .map(|px| px as f32);

        let mut text = String::new();
        let mut spans = Vec::new();
        let mut boxes = Vec::new();

        // Walk the run list, extracting each element into owned Rust data.
        let mut list = runs;
        loop {
            let head = PL_new_term_ref();
            let tail = PL_new_term_ref();
            if !PL_get_list(list, head, tail) {
                break;
            }
            parse_run(head, &at, &mut text, &mut spans, &mut boxes);
            list = tail;
        }

        Some(Request {
            text,
            spans,
            boxes,
            leading,
            max_advance,
        })
    }
}

/// Parses one `run(Text, Attrs)` or `box(RelPath, W, H)` element.
unsafe fn parse_run(
    element: term_t,
    at: &Atoms,
    text: &mut String,
    spans: &mut Vec<Span>,
    boxes: &mut Vec<Boxed>,
) {
    unsafe {
        let mut name: atom_t = 0;
        let mut arity: c_int = 0;
        if !PL_get_name_arity(element, &mut name, &mut arity) {
            return;
        }

        if name == at.run && arity == 2 {
            let Some(content) = term_text(arg(1, element)) else {
                return;
            };
            let start = text.len();
            text.push_str(&content);
            let range = start..text.len();

            let inherited = arg(2, element);
            spans.push(Span {
                range,
                font_size: attr(inherited, at.font_size)
                    .and_then(|v| term_number(v).map(|n| n as f32)),
                family: attr(inherited, at.font_family).and_then(|v| term_text(v)),
                weight: attr(inherited, at.font_weight).and_then(|v| read_weight(v)),
                style: attr(inherited, at.slant).and_then(|v| read_style(v)),
                locale: attr(inherited, at.lang).and_then(|v| read_locale(v)),
            });
        } else if name == at.boxed && arity == 3 {
            // box(RelPath, W, H); W and H are already in layout units.
            let (Some(w), Some(h)) = (term_number(arg(2, element)), term_number(arg(3, element)))
            else {
                return;
            };
            boxes.push(Boxed {
                index: text.len(),
                width: (w / UNITS_PER_PX) as f32,
                height: (h / UNITS_PER_PX) as f32,
            });
        }
    }
}

/// Maps a `font_weight` value (`normal`, `bold`, or a numeric weight) to Parley.
unsafe fn read_weight(t: term_t) -> Option<FontWeight> {
    unsafe {
        if let Some(n) = term_number(t) {
            return Some(FontWeight::new(n as f32));
        }
        match term_text(t)?.as_str() {
            "normal" => Some(FontWeight::NORMAL),
            "bold" => Some(FontWeight::BOLD),
            _ => None,
        }
    }
}

/// Maps a `slant` value (`normal`, `italic`, `oblique`) to Parley.
unsafe fn read_style(t: term_t) -> Option<FontStyle> {
    unsafe {
        match term_text(t)?.as_str() {
            "normal" => Some(FontStyle::Normal),
            "italic" => Some(FontStyle::Italic),
            "oblique" => Some(FontStyle::Oblique(None)),
            _ => None,
        }
    }
}

/// Parses a `lang` value (a BCP-47 tag such as `en` or `ja`) into a locale.
unsafe fn read_locale(t: term_t) -> Option<Language> {
    unsafe { Language::parse(&term_text(t)?).ok() }
}

// --- Measurement --- //

/// Builds the Parley layout and returns its size in layout units.
fn measure(request: &Request) -> (f64, f64) {
    CTX.with_borrow_mut(|(font_cx, layout_cx)| {
        let mut builder = layout_cx.ranged_builder(font_cx, &request.text, 1.0, true);

        if let Some(leading) = request.leading {
            builder.push_default(StyleProperty::LineHeight(LineHeight::FontSizeRelative(
                leading,
            )));
        }

        for span in &request.spans {
            if let Some(size) = span.font_size {
                builder.push(StyleProperty::FontSize(size), span.range.clone());
            }
            if let Some(family) = &span.family {
                builder.push(
                    StyleProperty::FontFamily(FontFamily::named(family)),
                    span.range.clone(),
                );
            }
            if let Some(weight) = span.weight {
                builder.push(StyleProperty::FontWeight(weight), span.range.clone());
            }
            if let Some(style) = span.style {
                builder.push(StyleProperty::FontStyle(style), span.range.clone());
            }
            if let Some(locale) = span.locale {
                builder.push(StyleProperty::Locale(Some(locale)), span.range.clone());
            }
        }

        for (id, b) in request.boxes.iter().enumerate() {
            builder.push_inline_box(InlineBox {
                id: id as u64,
                kind: InlineBoxKind::InFlow,
                index: b.index,
                width: b.width,
                height: b.height,
            });
        }

        let mut layout: Layout<Brush> = builder.build(&request.text);
        layout.break_all_lines(request.max_advance);

        (
            layout.width() as f64 * UNITS_PER_PX,
            layout.height() as f64 * UNITS_PER_PX,
        )
    })
}

// --- Foreign predicate --- //

/// `measure_text(+Runs, +Options, +MaxW, -Metrics)`: unifies `Metrics` with
/// `metrics(W, H)`, or throws `type_error(max_width, MaxW)`.
unsafe extern "C" fn measure_text(
    runs: term_t,
    options: term_t,
    max_w: term_t,
    metrics: term_t,
) -> foreign_t {
    unsafe {
        let Some(parsed) = parse(runs, options, max_w) else {
            return PL_type_error(b"max_width\0".as_ptr() as *const c_char, max_w) as foreign_t;
        };

        let (w, h) = measure(&parsed);

        let wt = PL_new_term_ref();
        let ht = PL_new_term_ref();
        let out = PL_new_term_ref();
        if PL_put_float(wt, w)
            && PL_put_float(ht, h)
            && PL_cons_functor(out, atoms().metrics, wt, ht)
            && PL_unify(metrics, out)
        {
            true as foreign_t
        } else {
            false as foreign_t
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn install_liblayout_text() {
    unsafe {
        let f: unsafe extern "C" fn(term_t, term_t, term_t, term_t) -> foreign_t = measure_text;
        PL_register_foreign(
            b"measure_text\0".as_ptr() as *const c_char,
            4,
            f as *mut c_void,
            0,
        );
    }
}
