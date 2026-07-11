//! `measure_text/4`: bridges Prolog terms to `layout_text::measure`.
//!
//! ```prolog
//! measure_text(+Runs, +Options, +MaxW, -metrics(W, H, Lines))
//! ```
//!
//! Speaks layout units at the boundary (px * 64); `layout_text` speaks pixels.
//! Throws `type_error(max_width, MaxW)` when `MaxW` is neither a number nor the
//! atom `inf`. Each run's `color` term is interned to an opaque id that
//! `layout_text` carries through and that we map back to the term on output.

use std::os::raw::c_char;

use layout_text::{Item, Line, LineItem, Measured, Options, Run, Slant};
use swi_fli::*;

use crate::fli::*;

struct Parsed {
    items: Vec<Item>,
    options: Options,
    max_advance: Option<f32>,
    /// Interned `color` terms; a run's color id is its index here + 1 (0 = none).
    colors: Vec<term_t>,
}

/// `measure_text(+Runs, +Options, +MaxW, -Metrics)`.
pub unsafe extern "C" fn measure_text(
    runs: term_t,
    options: term_t,
    max_w: term_t,
    metrics: term_t,
) -> foreign_t {
    unsafe {
        let Some(parsed) = parse(runs, options, max_w) else {
            return PL_type_error(b"max_width\0".as_ptr() as *const c_char, max_w) as foreign_t;
        };
        let measured = layout_text::measure(&parsed.items, &parsed.options, parsed.max_advance);
        let out = build_metrics(&measured, &parsed.colors);
        PL_unify(metrics, out) as foreign_t
    }
}

unsafe fn parse(runs: term_t, options: term_t, max_w: term_t) -> Option<Parsed> {
    unsafe {
        let at = atoms();

        // MaxW: the atom `inf` is unbounded, otherwise a count of units.
        let max_advance = if term_text(max_w).as_deref() == Some("inf") {
            None
        } else {
            Some((term_number(max_w)? / UNITS_PER_PX) as f32)
        };

        let leading = dict_key(options, at.leading)
            .and_then(|v| term_number(v))
            .map(|px| px as f32);

        let mut items = Vec::new();
        let mut colors = Vec::new();
        for_each_list(runs, |el| parse_item(el, &at, &mut items, &mut colors));

        Some(Parsed {
            items,
            options: Options { leading },
            max_advance,
            colors,
        })
    }
}

unsafe fn parse_item(el: term_t, at: &Atoms, items: &mut Vec<Item>, colors: &mut Vec<term_t>) {
    unsafe {
        let mut name: atom_t = 0;
        let mut arity: std::os::raw::c_int = 0;
        if !PL_get_name_arity(el, &mut name, &mut arity) {
            return;
        }

        if name == at.run && arity == 2 {
            let Some(text) = term_text(arg(1, el)) else {
                return;
            };
            let inh = arg(2, el);
            let color = match attr(inh, at.color) {
                Some(ct) => {
                    colors.push(ct);
                    colors.len() as u64
                }
                None => 0,
            };
            items.push(Item::Run(Run {
                text,
                font_size: attr(inh, at.font_size).and_then(|v| term_number(v).map(|n| n as f32)),
                family: attr(inh, at.font_family).and_then(|v| term_text(v)),
                weight: attr(inh, at.font_weight).and_then(|v| read_weight(v)),
                slant: attr(inh, at.slant).and_then(|v| read_slant(v)),
                lang: attr(inh, at.lang).and_then(|v| term_text(v)),
                color,
            }));
        } else if name == at.boxed && arity == 3 {
            // box(RelPath, W, H); W and H arrive in layout units.
            let (Some(w), Some(h)) = (term_number(arg(2, el)), term_number(arg(3, el))) else {
                return;
            };
            items.push(Item::Box {
                width: (w / UNITS_PER_PX) as f32,
                height: (h / UNITS_PER_PX) as f32,
            });
        }
    }
}

/// A `font_weight` value (`normal`, `bold`, or a number) as a CSS weight.
unsafe fn read_weight(t: term_t) -> Option<f32> {
    unsafe {
        if let Some(n) = term_number(t) {
            return Some(n as f32);
        }
        match term_text(t)?.as_str() {
            "normal" => Some(400.0),
            "bold" => Some(700.0),
            _ => None,
        }
    }
}

/// A `slant` value (`normal`, `italic`, `oblique`).
unsafe fn read_slant(t: term_t) -> Option<Slant> {
    unsafe {
        match term_text(t)?.as_str() {
            "normal" => Some(Slant::Normal),
            "italic" => Some(Slant::Italic),
            "oblique" => Some(Slant::Oblique(None)),
            _ => None,
        }
    }
}

// --- Output --- //

unsafe fn build_metrics(m: &Measured, colors: &[term_t]) -> term_t {
    unsafe {
        let at = atoms();
        let lines: Vec<term_t> = m.lines.iter().map(|l| build_line(l, colors, &at)).collect();
        let out = PL_new_term_ref();
        PL_cons_functor(out, at.metrics, units(m.width), units(m.height), list_of(&lines));
        out
    }
}

unsafe fn build_line(l: &Line, colors: &[term_t], at: &Atoms) -> term_t {
    unsafe {
        let items: Vec<term_t> = l.items.iter().map(|it| build_item(it, colors, at)).collect();
        let t = PL_new_term_ref();
        PL_cons_functor(
            t,
            at.line,
            units(l.baseline),
            units(l.ascent),
            units(l.descent),
            list_of(&items),
        );
        t
    }
}

unsafe fn build_item(it: &LineItem, colors: &[term_t], at: &Atoms) -> term_t {
    unsafe {
        match it {
            LineItem::GlyphRun(gr) => {
                let desc = PL_new_term_ref();
                PL_cons_functor(
                    desc,
                    at.font,
                    put_string(&gr.family),
                    put_float(gr.weight as f64),
                    put_slant(gr.slant, at),
                );
                let color = if gr.color == 0 {
                    put_atom(at.none)
                } else {
                    colors[(gr.color - 1) as usize]
                };
                let synth = PL_new_term_ref();
                PL_cons_functor(
                    synth,
                    at.synth,
                    put_atom(if gr.synth.bold { at.truth } else { at.falsity }),
                    match gr.synth.skew {
                        Some(deg) => put_float(deg as f64),
                        None => put_atom(at.none),
                    },
                );
                let glyphs: Vec<term_t> = gr
                    .glyphs
                    .iter()
                    .map(|g| {
                        let t = PL_new_term_ref();
                        PL_cons_functor(
                            t,
                            at.glyph,
                            put_int(g.id as i64),
                            units(g.x),
                            units(g.y),
                            units(g.advance),
                            put_int(g.start as i64),
                            put_int(g.end as i64),
                        );
                        t
                    })
                    .collect();
                let t = PL_new_term_ref();
                PL_cons_functor(t, at.glyph_run, desc, units(gr.size), color, synth, list_of(&glyphs));
                t
            }
            LineItem::Box {
                id,
                x,
                y,
                width,
                height,
            } => {
                let t = PL_new_term_ref();
                PL_cons_functor(
                    t,
                    at.box_item,
                    put_int(*id as i64),
                    units(*x),
                    units(*y),
                    units(*width),
                    units(*height),
                );
                t
            }
        }
    }
}

unsafe fn put_slant(s: Slant, at: &Atoms) -> term_t {
    unsafe {
        match s {
            Slant::Normal => put_atom(at.normal),
            Slant::Italic => put_atom(at.italic),
            Slant::Oblique(deg) => {
                let a = match deg {
                    Some(d) => put_float(d as f64),
                    None => put_atom(at.none),
                };
                let t = PL_new_term_ref();
                PL_cons_functor(t, at.oblique, a);
                t
            }
        }
    }
}
