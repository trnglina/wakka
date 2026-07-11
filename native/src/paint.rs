//! Scene predicates: bridge `ui_paint`'s changes to a retained `paint::Scene`
//! and render it headless via wgpu.
//!
//! ```prolog
//! scene_put(+Path, +X, +Y, +W, +H, +Draw)   % Draw = glyphs(Lines) | none
//! scene_move(+Path, +X, +Y)
//! scene_drop(+Path)
//! scene_render_headless(+Width, +Height, -Pixels)   % Width/Height in pixels; Pixels = RGBA byte string
//! ```
//!
//! Geometry crosses the boundary in layout units (px * 64); `Width`/`Height`
//! for the render are plain pixel counts. The scene is CPU-only and always
//! available; only rendering lazily initialises the GPU.

use std::cell::RefCell;
use std::os::raw::c_char;

use swi_fli::*;

use crate::fli::*;

thread_local! {
    static SCENE: RefCell<paint::Scene> = RefCell::new(paint::Scene::new());
    // The GPU state is leaked (a `&'static mut`) so its wgpu resources are never
    // dropped: tearing down a wgpu device from a thread-local destructor as the
    // process (and the dlopened library) shut down panics. One leaked device
    // per thread is fine for a long-lived singleton.
    static GPU: RefCell<Option<&'static mut Gpu>> = const { RefCell::new(None) };
}

struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    renderer: paint::Renderer,
}

// --- Predicates --- //

pub unsafe extern "C" fn scene_put(
    path: term_t,
    x: term_t,
    y: term_t,
    w: term_t,
    h: term_t,
    draw: term_t,
) -> foreign_t {
    unsafe {
        let p = parse_path(path);
        let d = parse_draw(draw);
        SCENE.with_borrow_mut(|s| s.put(p, px(x), px(y), px(w), px(h), d));
        1
    }
}

pub unsafe extern "C" fn scene_move(path: term_t, x: term_t, y: term_t) -> foreign_t {
    unsafe {
        let p = parse_path(path);
        SCENE.with_borrow_mut(|s| s.place(&p, px(x), px(y)));
        1
    }
}

pub unsafe extern "C" fn scene_drop(path: term_t) -> foreign_t {
    unsafe {
        let p = parse_path(path);
        SCENE.with_borrow_mut(|s| s.remove(&p));
        1
    }
}

pub unsafe extern "C" fn scene_render_headless(
    w: term_t,
    h: term_t,
    pixels: term_t,
) -> foreign_t {
    unsafe {
        let width = term_number(w).unwrap_or(0.0) as u32;
        let height = term_number(h).unwrap_or(0.0) as u32;
        if width == 0 || height == 0 {
            return 0;
        }
        let bytes = GPU.with_borrow_mut(|slot| {
            if slot.is_none() {
                *slot = init_gpu().map(|gpu| &mut *Box::leak(Box::new(gpu)));
            }
            let gpu = slot.as_deref_mut()?;
            SCENE.with_borrow(|scene| render_to_bytes(gpu, scene, width, height))
        });
        match bytes {
            Some(b) => {
                PL_unify_string_nchars(pixels, b.len(), b.as_ptr() as *const c_char) as foreign_t
            }
            None => 0,
        }
    }
}

// --- GPU --- //

fn init_gpu() -> Option<Gpu> {
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        ..Default::default()
    }))
    .ok()?;
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("wakka-headless"),
        required_features: wgpu::Features::empty(),
        required_limits: adapter.limits(),
        experimental_features: Default::default(),
        memory_hints: Default::default(),
        trace: wgpu::Trace::Off,
    }))
    .ok()?;
    let renderer = paint::Renderer::new(&device).ok()?;
    Some(Gpu {
        device,
        queue,
        renderer,
    })
}

fn render_to_bytes(gpu: &mut Gpu, scene: &paint::Scene, width: u32, height: u32) -> Option<Vec<u8>> {
    let size = wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };
    let texture = gpu.device.create_texture(&wgpu::TextureDescriptor {
        label: Some("wakka-target"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::STORAGE_BINDING | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let view = texture.create_view(&wgpu::TextureViewDescriptor::default());

    gpu.renderer
        .render(scene, &gpu.device, &gpu.queue, &view, width, height, [255, 255, 255, 255])
        .ok()?;

    // Copy the texture into a mappable buffer with 256-byte-aligned rows.
    let unpadded = width * 4;
    let padded = unpadded.div_ceil(256) * 256;
    let buffer = gpu.device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("wakka-readback"),
        size: (padded * height) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut encoder = gpu
        .device
        .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
    encoder.copy_texture_to_buffer(
        wgpu::TexelCopyTextureInfo {
            texture: &texture,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        wgpu::TexelCopyBufferInfo {
            buffer: &buffer,
            layout: wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(padded),
                rows_per_image: Some(height),
            },
        },
        size,
    );
    gpu.queue.submit([encoder.finish()]);

    let slice = buffer.slice(..);
    slice.map_async(wgpu::MapMode::Read, |_| {});
    gpu.device.poll(wgpu::PollType::wait_indefinitely()).ok()?;

    let data = slice.get_mapped_range();
    let mut out = Vec::with_capacity((unpadded * height) as usize);
    for row in 0..height {
        let start = (row * padded) as usize;
        out.extend_from_slice(&data[start..start + unpadded as usize]);
    }
    drop(data);
    buffer.unmap();
    Some(out)
}

// --- Term parsing --- //

/// Layout units -> pixels.
unsafe fn px(t: term_t) -> f32 {
    unsafe { (term_number(t).unwrap_or(0.0) / UNITS_PER_PX) as f32 }
}

unsafe fn parse_path(t: term_t) -> Vec<i64> {
    unsafe {
        list_terms(t)
            .into_iter()
            .filter_map(|e| {
                let mut i = 0i64;
                if PL_get_int64(e, &mut i) { Some(i) } else { None }
            })
            .collect()
    }
}

unsafe fn parse_draw(t: term_t) -> paint::Draw {
    unsafe {
        let at = atoms();
        let mut f: functor_t = 0;
        if PL_get_functor(t, &mut f) && f == at.glyphs {
            paint::Draw::Glyphs(parse_glyph_runs(arg(1, t), &at))
        } else {
            paint::Draw::None
        }
    }
}

unsafe fn parse_glyph_runs(lines: term_t, at: &Atoms) -> Vec<paint::GlyphRun> {
    unsafe {
        let mut runs = Vec::new();
        for line in list_terms(lines) {
            let mut lf: functor_t = 0;
            if !(PL_get_functor(line, &mut lf) && lf == at.line) {
                continue;
            }
            for item in list_terms(arg(4, line)) {
                let mut itf: functor_t = 0;
                if PL_get_functor(item, &mut itf) && itf == at.glyph_run {
                    if let Some(run) = parse_glyph_run(item, at) {
                        runs.push(run);
                    }
                }
            }
        }
        runs
    }
}

unsafe fn parse_glyph_run(t: term_t, at: &Atoms) -> Option<paint::GlyphRun> {
    unsafe {
        // glyph_run(font(BlobId, Index, Family), Size, Color, synth(Bold, Skew), Glyphs)
        let font_term = arg(1, t);
        let blob_id = term_i64(arg(1, font_term))? as u64;
        let index = term_i64(arg(2, font_term))? as u32;
        // Recover the exact face the run was shaped against; skip if it is not
        // registered (it always is when the run came from measure_text).
        let font = crate::font::lookup_font(blob_id, index)?;
        let size = px(arg(2, t));
        let color = parse_color(arg(3, t), at);
        let (bold, skew) = parse_synth(arg(4, t));
        let glyphs = list_terms(arg(5, t))
            .into_iter()
            .filter_map(|g| parse_glyph(g))
            .collect();
        Some(paint::GlyphRun {
            font,
            size,
            color,
            bold,
            skew,
            glyphs,
        })
    }
}

unsafe fn parse_glyph(t: term_t) -> Option<paint::GlyphPos> {
    unsafe {
        // glyph(Id, X, Y, Advance, Start, End)
        Some(paint::GlyphPos {
            id: term_number(arg(1, t))? as u32,
            x: px(arg(2, t)),
            y: px(arg(3, t)),
        })
    }
}

/// Reads `synth(Bold, Skew)`: Bold is the atom `true`/`false`, Skew a skew angle
/// in degrees or the atom `none`.
unsafe fn parse_synth(t: term_t) -> (bool, Option<f32>) {
    unsafe {
        let bold = term_text(arg(1, t)).as_deref() == Some("true");
        let skew = term_number(arg(2, t)).map(|d| d as f32);
        (bold, skew)
    }
}

unsafe fn parse_color(t: term_t, at: &Atoms) -> [u8; 4] {
    unsafe {
        if let Some(name) = term_text(t) {
            return named_color(&name);
        }
        let mut f: functor_t = 0;
        if PL_get_functor(t, &mut f) {
            if f == at.rgb {
                return [comp(arg(1, t)), comp(arg(2, t)), comp(arg(3, t)), 255];
            }
            if f == at.rgba {
                return [comp(arg(1, t)), comp(arg(2, t)), comp(arg(3, t)), comp(arg(4, t))];
            }
        }
        [0, 0, 0, 255]
    }
}

unsafe fn comp(t: term_t) -> u8 {
    unsafe { term_number(t).unwrap_or(0.0).clamp(0.0, 255.0) as u8 }
}

fn named_color(name: &str) -> [u8; 4] {
    match name {
        "white" => [255, 255, 255, 255],
        "red" => [255, 0, 0, 255],
        "green" => [0, 128, 0, 255],
        "blue" => [0, 0, 255, 255],
        "yellow" => [255, 255, 0, 255],
        "gray" | "grey" => [128, 128, 128, 255],
        // `none`, `black`, and anything unknown paint as opaque black.
        _ => [0, 0, 0, 255],
    }
}
