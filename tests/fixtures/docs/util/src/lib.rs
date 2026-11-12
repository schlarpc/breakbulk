//! Helpers over [`base`]: [`make`] builds a [`base::Widget`].

pub use base::Widget;

/// Makes a [`Widget`] of the given size; see [`base::Render`].
pub fn make(size: u32) -> Widget {
    Widget { size }
}

/// A thing that renders. Derives [`derive::Describe`].
#[derive(derive::Describe)]
pub struct Gadget;

impl base::Render for Gadget {
    fn render(&self) -> String {
        "gadget".to_owned()
    }
}

#[doc = env!("UTIL_NOTE")]
#[cfg(util_generated)]
pub fn generated() {}
