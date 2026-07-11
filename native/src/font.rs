//! Thread-local font registry bridging measurement to painting.
//!
//! The measurer resolves each glyph run's face and hands it back as a
//! [`FontData`] (a shared font blob plus a face index). We register that face
//! here, keyed by its blob id and index, and embed the key in the `glyph_run`
//! term. At paint time the key recovers the exact same face, so the renderer
//! draws glyph ids against the face they were shaped with — there is no second,
//! independent font resolution to diverge from the measurer's.
//!
//! The registry is thread-local, like the scene and the measurer's contexts
//! (measurement and painting run on one thread). It never evicts: entries are
//! `Arc`-shared blobs bounded by the set of faces actually in use.

use std::cell::RefCell;
use std::collections::HashMap;

use paint::FontData;

thread_local! {
    static FONTS: RefCell<HashMap<(u64, u32), FontData>> = RefCell::new(HashMap::new());
}

/// Registers `font` and returns its (blob id, face index) key.
pub fn register_font(font: FontData) -> (u64, u32) {
    let key = (font.data.id(), font.index);
    FONTS.with_borrow_mut(|m| {
        m.entry(key).or_insert(font);
    });
    key
}

/// Recovers a previously registered face by its (blob id, face index) key.
pub fn lookup_font(id: u64, index: u32) -> Option<FontData> {
    FONTS.with_borrow(|m| m.get(&(id, index)).cloned())
}
