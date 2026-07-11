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
use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int, c_uint, c_void};
use std::sync::OnceLock;

use parley::{
    FontContext, FontFamily, FontStyle, FontWeight, InlineBox, InlineBoxKind, Language, Layout,
    LayoutContext, LineHeight, PositionedLayoutItem, StyleProperty,
};
use skrifa::{string::StringId, FontRef, MetadataProvider};

use swi_fli::*;

/// Color flows through Parley as the glyph brush. A Prolog `color` term handle
/// is a `term_t` (i.e. `usize`), which satisfies Parley's `Brush` bound
/// (`Clone + PartialEq + Default + Debug`), so Parley splits glyph runs at
/// color boundaries and each run carries its color term verbatim. The default
/// brush `0` means "no color". Color is a paint-only style, so it does not
/// affect shaping or the measured size.
type Brush = term_t;

/// Layout units per logical pixel (mirrors `px_units/2`).
const UNITS_PER_PX: f64 = 64.0;

thread_local! {
    /// Font and layout contexts are expensive to build (the font context
    /// enumerates the host's fonts via fontconfig), so keep them alive for the
    /// life of the thread. A `thread_local` keeps this sound if SWI-Prolog
    /// drives measurement from multiple threads.
    static CTX: RefCell<(FontContext, LayoutContext<Brush>)> =
        RefCell::new((FontContext::new(), LayoutContext::new()));

    /// Resolved family names keyed by (font blob id, face index), so each
    /// face's name table is read at most once.
    static FAMILIES: RefCell<HashMap<(u64, u32), String>> = RefCell::new(HashMap::new());
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
    color: atom_t,
    leading: atom_t,
    none: atom_t,
    normal: atom_t,
    italic: atom_t,
    truth: atom_t,
    falsity: atom_t,
    metrics: functor_t,
    line: functor_t,
    glyph_run: functor_t,
    glyph: functor_t,
    box_item: functor_t,
    font: functor_t,
    synth: functor_t,
    oblique: functor_t,
}

static ATOMS: OnceLock<Atoms> = OnceLock::new();

fn atoms() -> Atoms {
    *ATOMS.get_or_init(|| {
        // Safe: called from a registered foreign predicate, so the Prolog
        // engine is initialised.
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
    /// The run's `color` attribute term, passed through to the glyph run
    /// verbatim as its Parley brush. Valid for the whole `measure_text` call.
    color: Option<term_t>,
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
                color: attr(inherited, at.color),
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

// --- Layout --- //

/// Builds and line-breaks the Parley layout for a request. Shared by the size
/// read-back and the glyph walk.
fn build_layout(
    font_cx: &mut FontContext,
    layout_cx: &mut LayoutContext<Brush>,
    request: &Request,
) -> Layout<Brush> {
    let mut builder = layout_cx.ranged_builder(font_cx, &request.text, 1.0, true);

    if let Some(leading) = request.leading {
        builder.push_default(StyleProperty::LineHeight(LineHeight::FontSizeRelative(leading)));
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
        if let Some(color) = span.color {
            builder.push(StyleProperty::Brush(color), span.range.clone());
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

    let mut layout = builder.build(&request.text);
    layout.break_all_lines(request.max_advance);
    layout
}

/// The resolved family name of `font`, read from its name table (via skrifa) at
/// most once per (blob id, face index).
fn family_name(font: &parley::FontData) -> String {
    let key = (font.data.id(), font.index);
    FAMILIES.with_borrow_mut(|cache| {
        cache
            .entry(key)
            .or_insert_with(|| {
                FontRef::from_index(font.data.data(), font.index)
                    .ok()
                    .and_then(|f| {
                        f.localized_strings(StringId::FAMILY_NAME)
                            .english_or_first()
                    })
                    .map(|s| s.to_string())
                    .unwrap_or_default()
            })
            .clone()
    })
}

// --- Term builders --- //

unsafe fn put_float(v: f64) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        PL_put_float(t, v);
        t
    }
}

/// A layout-unit float term from a Parley pixel value.
unsafe fn units(px: f32) -> term_t {
    unsafe { put_float(px as f64 * UNITS_PER_PX) }
}

unsafe fn put_int(v: i64) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        PL_put_int64(t, v);
        t
    }
}

unsafe fn put_atom(a: atom_t) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        PL_put_atom(t, a);
        t
    }
}

unsafe fn put_string(s: &str) -> term_t {
    unsafe {
        let t = PL_new_term_ref();
        let flags = (PL_STRING | REP_UTF8) as c_int;
        PL_put_chars(t, flags, s.len(), s.as_ptr() as *const c_char);
        t
    }
}

/// Builds a proper list from element terms.
unsafe fn list_of(elems: &[term_t]) -> term_t {
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

/// `normal | italic | oblique(Deg|none)`.
unsafe fn put_style(style: FontStyle, at: &Atoms) -> term_t {
    unsafe {
        match style {
            FontStyle::Normal => put_atom(at.normal),
            FontStyle::Italic => put_atom(at.italic),
            FontStyle::Oblique(deg) => {
                let arg = match deg {
                    Some(d) => put_float(d as f64),
                    None => put_atom(at.none),
                };
                let t = PL_new_term_ref();
                PL_cons_functor(t, at.oblique, arg);
                t
            }
        }
    }
}

// --- Glyph walk --- //

/// Walks the laid-out lines into the `Lines` term of the ABI (see module docs).
unsafe fn glyph_lines(layout: &Layout<Brush>, at: &Atoms) -> term_t {
    unsafe {
        let mut line_terms = Vec::new();
        for line in layout.lines() {
            let m = line.metrics();
            let mut items = Vec::new();

            // A single Parley run may be split into several glyph runs (by
            // color); they arrive consecutively and share one visual
            // glyph -> cluster-text-range map, indexed by `cursor`.
            let mut run_ranges: Vec<std::ops::Range<usize>> = Vec::new();
            let mut cursor = 0usize;
            let mut cur_run: Option<std::ops::Range<usize>> = None;

            for item in line.items() {
                match item {
                    PositionedLayoutItem::GlyphRun(gr) => {
                        let run = gr.run();
                        let rr = run.text_range();
                        if cur_run.as_ref() != Some(&rr) {
                            run_ranges = run
                                .visual_clusters()
                                .flat_map(|c| {
                                    let tr = c.text_range();
                                    c.glyphs().map(move |_| tr.clone())
                                })
                                .collect();
                            cursor = 0;
                            cur_run = Some(rr);
                        }

                        let attrs = run.font_attrs();
                        let desc = PL_new_term_ref();
                        PL_cons_functor(
                            desc,
                            at.font,
                            put_string(&family_name(run.font())),
                            put_float(attrs.weight.value() as f64),
                            put_style(attrs.style, at),
                        );

                        let color = {
                            let b = gr.style().brush;
                            if b == 0 { put_atom(at.none) } else { b }
                        };

                        let s = run.synthesis();
                        let synth = PL_new_term_ref();
                        PL_cons_functor(
                            synth,
                            at.synth,
                            put_atom(if s.embolden() { at.truth } else { at.falsity }),
                            match s.skew() {
                                Some(deg) => put_float(deg as f64),
                                None => put_atom(at.none),
                            },
                        );

                        let positioned: Vec<_> = gr.positioned_glyphs().collect();
                        let mut glyph_terms = Vec::with_capacity(positioned.len());
                        for (i, g) in positioned.iter().enumerate() {
                            let range = run_ranges.get(cursor + i).cloned().unwrap_or(0..0);
                            let t = PL_new_term_ref();
                            PL_cons_functor(
                                t,
                                at.glyph,
                                put_int(g.id as i64),
                                units(g.x),
                                units(g.y),
                                units(g.advance),
                                put_int(range.start as i64),
                                put_int(range.end as i64),
                            );
                            glyph_terms.push(t);
                        }
                        cursor += positioned.len();

                        let gr_term = PL_new_term_ref();
                        PL_cons_functor(
                            gr_term,
                            at.glyph_run,
                            desc,
                            units(run.font_size()),
                            color,
                            synth,
                            list_of(&glyph_terms),
                        );
                        items.push(gr_term);
                    }
                    PositionedLayoutItem::InlineBox(b) => {
                        cur_run = None;
                        cursor = 0;
                        let t = PL_new_term_ref();
                        PL_cons_functor(
                            t,
                            at.box_item,
                            put_int(b.id as i64),
                            units(b.x),
                            units(b.y),
                            units(b.width),
                            units(b.height),
                        );
                        items.push(t);
                    }
                }
            }

            let line_term = PL_new_term_ref();
            PL_cons_functor(
                line_term,
                at.line,
                units(m.baseline),
                units(m.ascent),
                units(m.descent),
                list_of(&items),
            );
            line_terms.push(line_term);
        }
        list_of(&line_terms)
    }
}

// --- Foreign predicate --- //

/// `measure_text(+Runs, +Options, +MaxW, -Metrics)`: unifies `Metrics` with
/// `metrics(W, H, Lines)` — size in layout units plus the per-glyph layout (see
/// module docs) — or throws `type_error(max_width, MaxW)`.
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
        let at = atoms();

        let out = CTX.with_borrow_mut(|(font_cx, layout_cx)| {
            let layout = build_layout(font_cx, layout_cx, &parsed);
            let w = layout.width() as f64 * UNITS_PER_PX;
            let h = layout.height() as f64 * UNITS_PER_PX;
            let lines = glyph_lines(&layout, &at);
            let out = PL_new_term_ref();
            PL_cons_functor(out, at.metrics, put_float(w), put_float(h), lines);
            out
        });

        PL_unify(metrics, out) as foreign_t
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
