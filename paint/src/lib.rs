//! A retained render scene over [vello]. The scene is keyed by node path (the
//! lightweight state ref); hierarchy and z-order are implied by the path. This
//! crate is Prolog-agnostic — the `native` crate parses terms into the input
//! types below and holds the [`Scene`]/[`Renderer`] instances.
//!
//! Each glyph run carries the exact [`FontData`] it was shaped against, so the
//! renderer draws glyph ids against their own face — it never resolves fonts,
//! which keeps ids and faces in lockstep with the measurer.

use std::collections::BTreeMap;

use vello::kurbo::{Affine, Diagonal2};
use vello::peniko::{Color, Fill};
use vello::{AaConfig, AaSupport, FontEmbolden, RenderParams, RendererOptions};

/// The exact shareable font resource a glyph run was shaped against. Re-exported
/// so `native` can hand the measurer's face straight through.
pub use vello::peniko::FontData;

/// Synthetic-bold outline expansion, as a fraction of the font size (in pixels).
/// Only fattens outlines; glyph positions come from the shaped advances, so this
/// does not affect layout.
const SYNTH_BOLD_STRENGTH: f64 = 0.02;

/// A node's path: its state path, e.g. `[0, 1]`.
pub type Path = Vec<i64>;

/// One positioned glyph, in pixels relative to its node's origin.
#[derive(Clone, Copy, Debug)]
pub struct GlyphPos {
    pub id: u32,
    pub x: f32,
    pub y: f32,
}

/// A run of glyphs sharing one face, size and color.
#[derive(Clone, Debug)]
pub struct GlyphRun {
    /// The exact face the run was shaped against; its glyph ids are drawn as-is.
    pub font: FontData,
    /// Font size in pixels.
    pub size: f32,
    pub color: [u8; 4],
    /// Synthetic emboldening the shaper applied because the face lacked the
    /// requested weight; reproduced here so paint matches the measured advances.
    pub bold: bool,
    /// Synthetic-oblique skew angle in degrees, if the shaper slanted an upright
    /// face.
    pub skew: Option<f32>,
    pub glyphs: Vec<GlyphPos>,
}

/// A node's paintable content.
#[derive(Clone, Debug, Default)]
pub enum Draw {
    #[default]
    None,
    Glyphs(Vec<GlyphRun>),
}

#[derive(Clone, Debug)]
struct Node {
    /// Offset relative to the parent node, in pixels.
    x: f32,
    y: f32,
    #[allow(dead_code)]
    w: f32,
    #[allow(dead_code)]
    h: f32,
    draw: Draw,
}

/// The retained scene: a map from node path to its transform and content.
/// Ordered by path so iteration yields parents before children and paints in
/// document (z) order.
#[derive(Default)]
pub struct Scene {
    nodes: BTreeMap<Path, Node>,
}

impl Scene {
    pub fn new() -> Self {
        Self::default()
    }

    /// Creates or replaces the node at `path`.
    pub fn put(&mut self, path: Path, x: f32, y: f32, w: f32, h: f32, draw: Draw) {
        self.nodes.insert(path, Node { x, y, w, h, draw });
    }

    /// Updates only the transform of an existing node.
    pub fn place(&mut self, path: &[i64], x: f32, y: f32) {
        if let Some(node) = self.nodes.get_mut(path) {
            node.x = x;
            node.y = y;
        }
    }

    /// Removes the node at `path` and its whole subtree.
    pub fn remove(&mut self, path: &[i64]) {
        let doomed: Vec<Path> = self
            .nodes
            .range(path.to_vec()..)
            .take_while(|(p, _)| p.starts_with(path))
            .map(|(p, _)| p.clone())
            .collect();
        for p in doomed {
            self.nodes.remove(&p);
        }
    }

    /// Absolute pixel offset of `path` = sum of its own and every ancestor's
    /// relative offset.
    fn absolute(&self, path: &[i64]) -> (f32, f32) {
        let (mut x, mut y) = (0.0, 0.0);
        for i in 0..=path.len() {
            if let Some(node) = self.nodes.get(&path[..i]) {
                x += node.x;
                y += node.y;
            }
        }
        (x, y)
    }
}

/// Wraps a vello renderer; renders a [`Scene`] to a wgpu target texture.
pub struct Renderer {
    vello: vello::Renderer,
}

impl Renderer {
    pub fn new(device: &vello::wgpu::Device) -> Result<Self, vello::Error> {
        let vello = vello::Renderer::new(
            device,
            RendererOptions {
                use_cpu: false,
                antialiasing_support: AaSupport::area_only(),
                num_init_threads: None,
                pipeline_cache: None,
            },
        )?;
        Ok(Self { vello })
    }

    /// Composites the scene and renders it into `view` (an `Rgba8Unorm`
    /// `RENDER_ATTACHMENT` texture view of `width`x`height`).
    pub fn render(
        &mut self,
        scene: &Scene,
        device: &vello::wgpu::Device,
        queue: &vello::wgpu::Queue,
        view: &vello::wgpu::TextureView,
        width: u32,
        height: u32,
        base_color: [u8; 4],
    ) -> Result<(), vello::Error> {
        let mut vs = vello::Scene::new();
        for (path, node) in &scene.nodes {
            let Draw::Glyphs(runs) = &node.draw else {
                continue;
            };
            let (ax, ay) = scene.absolute(path);
            let transform = Affine::translate((ax as f64, ay as f64));
            for run in runs {
                let color =
                    Color::from_rgba8(run.color[0], run.color[1], run.color[2], run.color[3]);
                let mut builder = vs
                    .draw_glyphs(&run.font)
                    .font_size(run.size)
                    .brush(color)
                    .transform(transform);
                if run.bold {
                    let amount = run.size as f64 * SYNTH_BOLD_STRENGTH;
                    builder = builder.font_embolden(FontEmbolden::new(Diagonal2::new(amount, amount)));
                }
                if let Some(deg) = run.skew {
                    // Horizontal shear on the (y-down) glyph outline: ascenders
                    // (negative y) lean right, matching a forward italic slant.
                    let shear = (-(deg as f64).to_radians()).tan();
                    builder =
                        builder.glyph_transform(Some(Affine::new([1.0, 0.0, shear, 1.0, 0.0, 0.0])));
                }
                builder.draw(
                    Fill::NonZero,
                    run.glyphs.iter().map(|g| vello::Glyph {
                        id: g.id,
                        x: g.x,
                        y: g.y,
                    }),
                );
            }
        }

        self.vello.render_to_texture(
            device,
            queue,
            &vs,
            view,
            &RenderParams {
                base_color: Color::from_rgba8(
                    base_color[0],
                    base_color[1],
                    base_color[2],
                    base_color[3],
                ),
                width,
                height,
                antialiasing_method: AaConfig::Area,
            },
        )
    }
}
