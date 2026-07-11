//! Text layout over [Parley]: shaping, line breaking and the resulting
//! per-glyph geometry. This crate is Prolog-agnostic — the `native` crate owns
//! the SWI FLI boundary and drives this API.
//!
//! [`measure`] takes an ordered list of inline [`Item`]s (styled text runs and
//! sized inline boxes), lays them out into `MaxAdvance` pixels, and returns the
//! box size plus every positioned glyph. All values are in logical pixels;
//! callers convert to their own units at the boundary.
//!
//! Color is opaque: each run carries a `u64` color id (0 = none) that flows
//! through Parley as the glyph brush and comes back out on each glyph run, so
//! the caller can map ids to whatever color representation it likes without this
//! crate interpreting them.

use std::cell::RefCell;
use std::collections::HashMap;

use parley::{
    FontContext, FontFamily, FontStyle, FontWeight, InlineBox, InlineBoxKind, Language, Layout,
    LayoutContext, LineHeight, PositionedLayoutItem, StyleProperty,
};
use skrifa::{string::StringId, FontRef, MetadataProvider};

/// The exact shareable font resource a run was shaped against. Re-exported so
/// the caller can render with the identical face (matching glyph ids) instead of
/// re-resolving from a descriptor.
pub use parley::FontData;

/// Color id carried opaquely through layout. `0` means "no color".
pub type ColorId = u64;

/// Parley's glyph brush is the run's color id.
type Brush = ColorId;

// --- Input --- //

/// Font slant, for both requested run style and resolved glyph-run style.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Slant {
    Normal,
    Italic,
    /// `oblique` with an optional angle in degrees.
    Oblique(Option<f32>),
}

/// A styled run of text.
#[derive(Clone, Debug, Default)]
pub struct Run {
    pub text: String,
    /// Font size in logical pixels.
    pub font_size: Option<f32>,
    pub family: Option<String>,
    /// CSS numeric weight (e.g. `400.0`, `700.0`).
    pub weight: Option<f32>,
    pub slant: Option<Slant>,
    /// BCP-47 language tag (e.g. `en`, `ja`).
    pub lang: Option<String>,
    pub color: ColorId,
}

/// One inline item, in document order. Boxes are placed inline at the byte
/// offset where they appear between runs.
#[derive(Clone, Debug)]
pub enum Item {
    Run(Run),
    Box { width: f32, height: f32 },
}

/// Block-level inline layout options.
#[derive(Clone, Debug, Default)]
pub struct Options {
    /// Line leading as a multiple of the font size, if set.
    pub leading: Option<f32>,
}

// --- Output --- //

/// The measured size (logical px) and the full per-glyph layout.
#[derive(Clone, Debug)]
pub struct Measured {
    pub width: f32,
    pub height: f32,
    pub lines: Vec<Line>,
}

#[derive(Clone, Debug)]
pub struct Line {
    pub baseline: f32,
    pub ascent: f32,
    pub descent: f32,
    pub items: Vec<LineItem>,
}

#[derive(Clone, Debug)]
pub enum LineItem {
    GlyphRun(GlyphRun),
    Box {
        id: u64,
        x: f32,
        y: f32,
        width: f32,
        height: f32,
    },
}

/// Synthesis a face receives when it lacks the requested weight/slant.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Synth {
    pub bold: bool,
    /// Synthetic-oblique skew angle in degrees, if any.
    pub skew: Option<f32>,
}

/// A run of glyphs sharing one resolved face, size and color.
#[derive(Clone, Debug)]
pub struct GlyphRun {
    /// The exact face Parley shaped with; render against this so the glyph ids
    /// match. Carries the font blob and face index.
    pub font: FontData,
    /// Resolved family name of that face, for inspection/debugging only.
    pub family: String,
    pub size: f32,
    pub color: ColorId,
    pub synth: Synth,
    pub glyphs: Vec<Glyph>,
}

#[derive(Clone, Copy, Debug)]
pub struct Glyph {
    pub id: u32,
    pub x: f32,
    pub y: f32,
    pub advance: f32,
    /// Byte range of the glyph's cluster in the run-concatenated text.
    pub start: usize,
    pub end: usize,
}

thread_local! {
    /// Font and layout contexts are expensive to build (the font context
    /// enumerates the host's fonts via fontconfig), so keep them alive for the
    /// life of the thread.
    static CTX: RefCell<(FontContext, LayoutContext<Brush>)> =
        RefCell::new((FontContext::new(), LayoutContext::new()));

    /// Resolved family names keyed by (font blob id, face index).
    static FAMILIES: RefCell<HashMap<(u64, u32), String>> = RefCell::new(HashMap::new());
}

/// Lays out the items into `max_advance` pixels (unbounded if `None`) and
/// returns the box size plus every positioned glyph.
pub fn measure(items: &[Item], options: &Options, max_advance: Option<f32>) -> Measured {
    // Concatenate run text, recording each run's byte range and each box's
    // inline byte offset (preserving document order).
    let mut text = String::new();
    let mut runs: Vec<(std::ops::Range<usize>, &Run)> = Vec::new();
    let mut boxes: Vec<(usize, f32, f32)> = Vec::new();
    for item in items {
        match item {
            Item::Run(run) => {
                let start = text.len();
                text.push_str(&run.text);
                runs.push((start..text.len(), run));
            }
            Item::Box { width, height } => boxes.push((text.len(), *width, *height)),
        }
    }

    CTX.with_borrow_mut(|(font_cx, layout_cx)| {
        let mut builder = layout_cx.ranged_builder(font_cx, &text, 1.0, true);

        if let Some(leading) = options.leading {
            builder.push_default(StyleProperty::LineHeight(LineHeight::FontSizeRelative(leading)));
        }

        for (range, run) in &runs {
            if let Some(size) = run.font_size {
                builder.push(StyleProperty::FontSize(size), range.clone());
            }
            if let Some(family) = &run.family {
                builder.push(
                    StyleProperty::FontFamily(FontFamily::named(family)),
                    range.clone(),
                );
            }
            if let Some(weight) = run.weight {
                builder.push(StyleProperty::FontWeight(FontWeight::new(weight)), range.clone());
            }
            if let Some(slant) = run.slant {
                builder.push(StyleProperty::FontStyle(font_style(slant)), range.clone());
            }
            if let Some(lang) = &run.lang {
                if let Ok(locale) = Language::parse(lang) {
                    builder.push(StyleProperty::Locale(Some(locale)), range.clone());
                }
            }
            if run.color != 0 {
                builder.push(StyleProperty::Brush(run.color), range.clone());
            }
        }

        for (i, (index, width, height)) in boxes.iter().enumerate() {
            builder.push_inline_box(InlineBox {
                id: i as u64,
                kind: InlineBoxKind::InFlow,
                index: *index,
                width: *width,
                height: *height,
            });
        }

        let mut layout = builder.build(&text);
        layout.break_all_lines(max_advance);

        Measured {
            width: layout.width(),
            height: layout.height(),
            lines: walk_lines(&layout),
        }
    })
}

/// One text range per glyph in a run, in `positioned_glyphs` order
/// (`visual_clusters().flat_map(glyphs)`). A ligature glyph's range spans the
/// whole ligature: Parley emits the glyph on the `LigatureStart` cluster (whose
/// own range is just the first char) and zero glyphs on the following
/// `LigatureComponent` clusters, so their bytes are folded back into the start.
fn glyph_text_ranges(run: &parley::Run<Brush>) -> Vec<std::ops::Range<usize>> {
    // Pass 1, logical order: a `LigatureStart` is immediately followed by its
    // components, so components fold forward onto the last glyph-bearing cluster.
    // Keyed by start byte so the visual pass can look them up under RTL reorder.
    let mut extended: HashMap<usize, std::ops::Range<usize>> = HashMap::new();
    let mut key: Option<usize> = None;
    for c in run.clusters() {
        let tr = c.text_range();
        if c.is_ligature_continuation() {
            if let Some(e) = key.and_then(|k| extended.get_mut(&k)) {
                e.start = e.start.min(tr.start);
                e.end = e.end.max(tr.end);
            }
        } else {
            extended.insert(tr.start, tr.clone());
            key = Some(tr.start);
        }
    }

    // Pass 2, visual order: one entry per glyph, matching `positioned_glyphs`.
    let mut ranges = Vec::new();
    for c in run.visual_clusters() {
        let tr = c.text_range();
        let range = extended.get(&tr.start).cloned().unwrap_or(tr);
        for _ in c.glyphs() {
            ranges.push(range.clone());
        }
    }
    ranges
}

/// Walks the laid-out lines into owned [`Line`] data.
fn walk_lines(layout: &Layout<Brush>) -> Vec<Line> {
    let mut lines = Vec::new();
    for line in layout.lines() {
        let m = line.metrics();
        let mut items = Vec::new();

        // A single Parley run may be split into several glyph runs (by color);
        // they arrive consecutively and share one per-glyph text-range map (in
        // `positioned_glyphs` order), indexed by `cursor`.
        let mut run_ranges: Vec<std::ops::Range<usize>> = Vec::new();
        let mut cursor = 0usize;
        let mut cur_run: Option<std::ops::Range<usize>> = None;

        for item in line.items() {
            match item {
                PositionedLayoutItem::GlyphRun(gr) => {
                    let run = gr.run();
                    let rr = run.text_range();
                    if cur_run.as_ref() != Some(&rr) {
                        run_ranges = glyph_text_ranges(run);
                        cursor = 0;
                        cur_run = Some(rr);
                    }

                    let synth = run.synthesis();
                    let positioned: Vec<_> = gr.positioned_glyphs().collect();
                    let mut glyphs = Vec::with_capacity(positioned.len());
                    for (i, g) in positioned.iter().enumerate() {
                        let range = run_ranges.get(cursor + i).cloned().unwrap_or(0..0);
                        glyphs.push(Glyph {
                            id: g.id,
                            x: g.x,
                            y: g.y,
                            advance: g.advance,
                            start: range.start,
                            end: range.end,
                        });
                    }
                    cursor += positioned.len();

                    items.push(LineItem::GlyphRun(GlyphRun {
                        font: run.font().clone(),
                        family: family_name(run.font()),
                        size: run.font_size(),
                        color: gr.style().brush,
                        synth: Synth {
                            bold: synth.embolden(),
                            skew: synth.skew(),
                        },
                        glyphs,
                    }));
                }
                PositionedLayoutItem::InlineBox(b) => {
                    cur_run = None;
                    cursor = 0;
                    items.push(LineItem::Box {
                        id: b.id,
                        x: b.x,
                        y: b.y,
                        width: b.width,
                        height: b.height,
                    });
                }
            }
        }

        lines.push(Line {
            baseline: m.baseline,
            ascent: m.ascent,
            descent: m.descent,
            items,
        });
    }
    lines
}

fn font_style(slant: Slant) -> FontStyle {
    match slant {
        Slant::Normal => FontStyle::Normal,
        Slant::Italic => FontStyle::Italic,
        Slant::Oblique(deg) => FontStyle::Oblique(deg),
    }
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
                    .and_then(|f| f.localized_strings(StringId::FAMILY_NAME).english_or_first())
                    .map(|s| s.to_string())
                    .unwrap_or_default()
            })
            .clone()
    })
}
