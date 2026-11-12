//! The base crate: [`Widget`] and the [`Render`] trait.

/// Something with a size. Rendered with [`Render::render`].
pub struct Widget {
    /// How big it is.
    pub size: u32,
}

/// Turns a value into text.
pub trait Render {
    /// The text. See [`itoa::Buffer`] for how numbers are written.
    fn render(&self) -> String;
}

impl Render for Widget {
    fn render(&self) -> String {
        itoa::Buffer::new().format(self.size).to_owned()
    }
}
