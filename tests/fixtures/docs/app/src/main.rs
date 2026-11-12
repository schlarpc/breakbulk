//! The app: prints a widget made by [`util::make`].

use base::Render;

/// Prints the [`util::Gadget`] and a [`base::Widget`].
fn main() {
    println!("{} {}", util::make(3).render(), util::Gadget.render());
}
