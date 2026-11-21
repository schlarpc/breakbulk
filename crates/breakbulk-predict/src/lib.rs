//! Source prediction: which files of a source view a unit reads, read from
//! the sources alone, without building the crate's dependencies.
//!
//! - [`predict_crate`]: the files rustc reads for a crate root. The module
//!   tree, by rustc's own rules (`rustc_expand/src/module.rs`), plus every
//!   `include!`, `include_str!` and `include_bytes!` with a literal path,
//!   `concat!(env!("CARGO_MANIFEST_DIR"), "…")` and
//!   `#[debugger_visualizer]` files.
//! - [`predict_build_script_run`]: the paths a build script declares with
//!   literal `rerun-if-changed` directives, which are all Cargo reruns it
//!   for.
//!
//! A prediction may hold more files than are read (a module behind a false
//! `#[cfg]`, a candidate file rustc does not pick); that costs only
//! rebuilds. When the sources hold something whose files cannot be known
//! without expanding it, the prediction says why in `fallback`, and the
//! unit must see its whole view. A file read in a way no rule here sees (a
//! proc macro reading a file, a module a proc macro generates) is a miss:
//! the compile fails naming the file, because rustc fails on every module
//! and include it cannot read.
//!
//! Paths are relative to the view root, `/`-separated and normalized
//! without touching the file system (`a/../b` is `b`); a path that leaves
//! the view is dropped, since no view can hold it.

use std::collections::{BTreeSet, HashSet};
use std::fmt;
use std::path::Path;

use proc_macro2::{Delimiter, TokenStream, TokenTree};
use syn::punctuated::Punctuated;
use syn::visit::{self, Visit};
use syn::{Expr, Lit, LitStr, Meta, Token};

pub mod view;

#[cfg(test)]
mod tests;

/// The files of one crate root.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct Prediction {
    /// Files rustc may read, relative to the view root.
    pub files: BTreeSet<String>,
    /// Why the files cannot be predicted; when not empty, the unit needs
    /// its whole view.
    pub fallback: Vec<Fallback>,
}

/// The paths of one build-script run.
#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct RunPrediction {
    /// Paths declared with `rerun-if-changed`, relative to the view root.
    /// A directory stands for everything under it, as Cargo scans it.
    pub declared: BTreeSet<String>,
    /// Why the paths cannot be predicted; when not empty, the run needs
    /// its whole view.
    pub fallback: Vec<Fallback>,
}

/// One reason a prediction cannot be trusted, and the file it is in.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Fallback {
    /// The file, relative to the view root.
    pub file: String,
    pub reason: Reason,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Reason {
    /// syn could not parse the file (or an `include!`d file).
    Parse(String),
    /// The file is not UTF-8, or could not be read.
    Read(String),
    /// An `include*!` whose path is not a literal, nor a literal under
    /// `CARGO_MANIFEST_DIR` or `OUT_DIR`.
    NonLiteralInclude(String),
    /// `mod $name;` in a macro: the module's name is known only after
    /// expansion.
    MacroGeneratedMod,
    /// A `mod`, `#[path]` or `include*!` inside a `macro_rules!` body: it
    /// resolves where the macro is invoked, which is not known.
    InMacroRules,
    /// `#[cfg_attr(…, path = …)]` on an inline module.
    CfgPathOnInlineModule,
    /// A `rerun-if-changed` directive whose path is built at run time.
    NonLiteralRerunIfChanged(String),
    /// "rerun-if-changed" in a form the prediction does not read.
    UnreadableRerunIfChanged(String),
    /// The script prints no `rerun-if-changed` or `rerun-if-env-changed`
    /// directive, so Cargo treats the whole package as its input.
    NoRerunIf,
}

impl fmt::Display for Reason {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Reason::Parse(e) => write!(f, "cannot be parsed: {e}"),
            Reason::Read(e) => write!(f, "cannot be read: {e}"),
            Reason::NonLiteralInclude(m) => {
                write!(f, "`{m}!` with a path that is not a string literal")
            }
            Reason::MacroGeneratedMod => f.write_str("a macro declares a module whose name is a macro variable"),
            Reason::InMacroRules => {
                f.write_str("a `macro_rules!` body declares a module or includes a file, which resolves where the macro is used")
            }
            Reason::CfgPathOnInlineModule => f.write_str("`cfg_attr(…, path = …)` on an inline module"),
            Reason::NonLiteralRerunIfChanged(s) => {
                write!(f, "a `rerun-if-changed` path built at run time (`{s}`)")
            }
            Reason::UnreadableRerunIfChanged(s) => {
                write!(f, "`rerun-if-changed` in a form source prediction does not read (`{s}`)")
            }
            Reason::NoRerunIf => f.write_str(
                "the build script prints no `rerun-if-changed` or `rerun-if-env-changed`, so Cargo treats the whole package as its input",
            ),
        }
    }
}

impl fmt::Display for Fallback {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}: {}", self.file, self.reason)
    }
}

/// The files rustc reads for the crate root `crate_root`, in the view at
/// `view`. `crate_root` and `manifest_dir` (the package directory, for
/// `CARGO_MANIFEST_DIR`) are relative to the view root.
pub fn predict_crate(view: &Path, crate_root: &str, manifest_dir: &str) -> Prediction {
    let w = walk(view, crate_root, manifest_dir);
    Prediction {
        files: w.files,
        fallback: w.fallback,
    }
}

/// The paths a build script's run declares: the literal `rerun-if-changed`
/// directives in the script's sources (its module tree and the files it
/// `include!`s). Declared paths are relative to the package directory, as
/// Cargo reads them.
pub fn predict_build_script_run(
    view: &Path,
    build_script: &str,
    manifest_dir: &str,
) -> RunPrediction {
    let w = walk(view, build_script, manifest_dir);
    let mut out = RunPrediction {
        declared: BTreeSet::new(),
        fallback: w.fallback,
    };
    let mut any = false;
    for (file, value) in &w.literals {
        for line in value.lines() {
            let line = line.trim();
            let directive = line
                .strip_prefix("cargo::")
                .or_else(|| line.strip_prefix("cargo:"));
            match directive.and_then(|d| d.split_once('=')) {
                Some(("rerun-if-changed", path)) => {
                    any = true;
                    if path.is_empty() || path.contains('{') {
                        out.fallback.push(Fallback {
                            file: file.clone(),
                            reason: Reason::NonLiteralRerunIfChanged(line.to_owned()),
                        });
                    } else if let Some(p) = join(manifest_dir, path) {
                        out.declared.insert(p);
                    }
                }
                Some(("rerun-if-env-changed", _)) => any = true,
                _ if line.contains("rerun-if-changed") => out.fallback.push(Fallback {
                    file: file.clone(),
                    reason: Reason::UnreadableRerunIfChanged(line.to_owned()),
                }),
                _ => {}
            }
        }
    }
    if !any {
        out.fallback.push(Fallback {
            file: build_script.to_owned(),
            reason: Reason::NoRerunIf,
        });
    }
    out
}

/// What a walk of a crate's sources found.
struct Walk<'a> {
    view: &'a Path,
    manifest_dir: String,
    files: BTreeSet<String>,
    fallback: Vec<Fallback>,
    /// Every string literal, with its file: in the syntax tree and in
    /// macro arguments (`println!`'s format string).
    literals: Vec<(String, String)>,
    /// Files already walked, with the module they were walked as.
    seen: HashSet<(String, Module)>,
}

fn walk<'a>(view: &'a Path, crate_root: &str, manifest_dir: &str) -> Walk<'a> {
    let mut w = Walk {
        view,
        manifest_dir: normalize(manifest_dir).unwrap_or_default(),
        files: BTreeSet::new(),
        fallback: Vec::new(),
        literals: Vec::new(),
        seen: HashSet::new(),
    };
    match normalize(crate_root) {
        Some(root) => {
            let module = Module {
                dir: parent(&root),
                own: Own::Owned(None),
            };
            w.file(&root, module, false);
        }
        None => w.fallback.push(Fallback {
            file: crate_root.to_owned(),
            reason: Reason::Read("the crate root is outside the view".into()),
        }),
    }
    w
}

/// rustc's `ModuleData::dir_path` and `DirOwnership` for the module items
/// are declared in.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct Module {
    /// The directory out-of-line modules and `#[path]` resolve against.
    dir: String,
    own: Own,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum Own {
    /// `Some(name)`: in a non-`mod.rs` file `name.rs`, whose submodules
    /// are in `dir/name/`.
    Owned(Option<String>),
    /// Inside a block (a function body): rustc loads a module file there
    /// only with `#[path]`.
    Block,
}

impl Walk<'_> {
    fn exists(&self, rel: &str) -> bool {
        self.view.join(rel).is_file()
    }

    fn fall(&mut self, file: &str, reason: Reason) {
        self.fallback.push(Fallback {
            file: file.to_owned(),
            reason,
        });
    }

    /// Walk one file as `module`'s source. `included`: the file is an
    /// `include!`'s, which rustc parses as items or as an expression.
    fn file(&mut self, rel: &str, module: Module, included: bool) {
        if !self.seen.insert((rel.to_owned(), module.clone())) {
            return;
        }
        self.files.insert(rel.to_owned());
        let text = match std::fs::read(self.view.join(rel)) {
            Ok(b) => match String::from_utf8(b) {
                Ok(t) => t,
                Err(_) => return self.fall(rel, Reason::Read("not UTF-8".into())),
            },
            Err(e) => return self.fall(rel, Reason::Read(e.to_string())),
        };
        let mut v = FileVisitor {
            w: self,
            file: rel.to_owned(),
            dir: parent(rel),
            stack: vec![module],
        };
        match syn::parse_file(&text) {
            Ok(f) => v.visit_file(&f),
            Err(e) if included => match syn::parse_str::<Expr>(&text) {
                Ok(x) => v.visit_expr(&x),
                Err(_) => v.w.fall(rel, Reason::Parse(e.to_string())),
            },
            Err(e) => v.w.fall(rel, Reason::Parse(e.to_string())),
        }
    }
}

/// The walk of one file's syntax tree.
struct FileVisitor<'w, 'v> {
    w: &'w mut Walk<'v>,
    /// This file, and its directory: `include*!` paths and
    /// `#[debugger_visualizer]` files are relative to the file.
    file: String,
    dir: String,
    /// The module of the items being visited: the file's module, then one
    /// more for each inline module or block entered.
    stack: Vec<Module>,
}

/// The `#[path]` attributes of a module item: the first plain one (rustc
/// takes only that), and every `cfg_attr(…, path = …)` (any may apply).
#[derive(Default)]
struct PathAttrs {
    plain: Option<String>,
    cfg: Vec<String>,
}

impl PathAttrs {
    fn add_meta(&mut self, meta: &Meta) {
        match meta {
            Meta::NameValue(nv) if nv.path.is_ident("path") => {
                if let Some(s) = lit_str(&nv.value)
                    && self.plain.is_none()
                {
                    self.plain = Some(s);
                }
            }
            Meta::List(l) if l.path.is_ident("cfg_attr") => {
                for m in cfg_attr_metas(&l.tokens) {
                    let mut inner = PathAttrs::default();
                    inner.add_meta(&m);
                    self.cfg.extend(inner.plain);
                    self.cfg.extend(inner.cfg);
                }
            }
            _ => {}
        }
    }
}

/// The attributes `cfg_attr(cond, a, b, …)` applies: `a, b, …`.
fn cfg_attr_metas(tokens: &TokenStream) -> Vec<Meta> {
    let parser = Punctuated::<Meta, Token![,]>::parse_terminated;
    match syn::parse::Parser::parse2(parser, tokens.clone()) {
        Ok(p) => p.into_iter().skip(1).collect(),
        Err(_) => Vec::new(),
    }
}

fn lit_str(e: &Expr) -> Option<String> {
    match e {
        Expr::Lit(l) => match &l.lit {
            Lit::Str(s) => Some(s.value()),
            _ => None,
        },
        _ => None,
    }
}

impl FileVisitor<'_, '_> {
    fn module(&self) -> &Module {
        self.stack.last().expect("the file's module")
    }

    /// rustc's `mod_dir_path` for `mod name { … }`.
    fn inline_module(&self, name: &str, paths: &PathAttrs) -> Module {
        let m = self.module();
        if let Some(p) = &paths.plain {
            // An inline module's `#[path]` names its directory.
            return Module {
                dir: join(&m.dir, p).unwrap_or_default(),
                own: Own::Owned(None),
            };
        }
        let mut dir = m.dir.clone();
        if let Own::Owned(Some(rel)) = &m.own {
            dir = join(&dir, rel).unwrap_or_default();
        }
        Module {
            dir: join(&dir, name).unwrap_or_default(),
            own: match &m.own {
                Own::Block => Own::Block,
                Own::Owned(_) => Own::Owned(None),
            },
        }
    }

    /// `mod name;`: every file rustc may load for it, walked as the module
    /// rustc would make of it. Both default candidates are kept when both
    /// exist, so that rustc still reports the ambiguity.
    fn out_of_line_module(&mut self, name: &str, paths: &PathAttrs) {
        let m = self.module().clone();
        let mut candidates: Vec<(String, Module)> = Vec::new();
        let by_attr = |p: &str| {
            join(&m.dir, p).map(|f| {
                // A `#[path]` file is a `mod.rs` file.
                let dir = parent(&f);
                (
                    f,
                    Module {
                        dir,
                        own: Own::Owned(None),
                    },
                )
            })
        };
        if let Some(p) = &paths.plain {
            candidates.extend(by_attr(p));
        } else {
            candidates.extend(paths.cfg.iter().filter_map(|p| by_attr(p)));
            match &m.own {
                // rustc refuses a module file in a block without `#[path]`.
                Own::Block => {}
                Own::Owned(rel) => {
                    let base = match rel {
                        Some(r) => join(&m.dir, r).unwrap_or_default(),
                        None => m.dir.clone(),
                    };
                    if let Some(f) = join(&base, &format!("{name}.rs")) {
                        candidates.push((
                            f,
                            Module {
                                dir: base.clone(),
                                own: Own::Owned(Some(name.to_owned())),
                            },
                        ));
                    }
                    if let Some(d) = join(&base, name) {
                        candidates.push((
                            format!("{d}/mod.rs"),
                            Module {
                                dir: d,
                                own: Own::Owned(None),
                            },
                        ));
                    }
                }
            }
        }
        for (f, module) in candidates {
            if self.w.exists(&f) {
                self.w.file(&f, module, false);
            }
        }
    }

    /// `include!`, `include_str!` or `include_bytes!` with these arguments.
    fn include(&mut self, which: &str, args: TokenStream) {
        let parser = Punctuated::<Expr, Token![,]>::parse_terminated;
        let arg = match syn::parse::Parser::parse2(parser, args) {
            Ok(p) if p.len() == 1 => p.into_iter().next(),
            _ => None,
        };
        let path = match arg.as_ref().map(include_path) {
            Some(IncludePath::Relative(p)) => join(&self.dir, &p),
            Some(IncludePath::Manifest(p)) => join(&self.w.manifest_dir, p.trim_start_matches('/')),
            // Generated or absolute: outside every view.
            Some(IncludePath::Outside) => return,
            Some(IncludePath::Unknown) | None => {
                let f = self.file.clone();
                return self.w.fall(&f, Reason::NonLiteralInclude(which.to_owned()));
            }
        };
        let Some(path) = path else { return };
        if which == "include" {
            // rustc resolves an included file's `mod` items and includes
            // against the file's own directory, as in a `mod.rs` file
            // (rustc_builtin_macros `source_util.rs`, `expand_include`).
            if self.w.exists(&path) {
                let m = Module {
                    dir: parent(&path),
                    own: Own::Owned(None),
                };
                self.w.file(&path, m, true);
            } else {
                self.w.files.insert(path);
            }
        } else {
            self.w.files.insert(path);
        }
    }

    /// Attributes in a token stream: `debugger_visualizer` files, and
    /// includes in `cfg_attr`'s attributes and other lists.
    fn meta(&mut self, meta: &Meta) {
        match meta {
            Meta::NameValue(nv) => self.visit_expr(&nv.value),
            Meta::List(l) if l.path.is_ident("cfg_attr") => {
                for m in cfg_attr_metas(&l.tokens) {
                    self.meta(&m);
                }
            }
            Meta::List(l) if l.path.is_ident("debugger_visualizer") => {
                let parser = Punctuated::<Meta, Token![,]>::parse_terminated;
                if let Ok(p) = syn::parse::Parser::parse2(parser, l.tokens.clone()) {
                    for m in p {
                        if let Meta::NameValue(nv) = m
                            && (nv.path.is_ident("natvis_file")
                                || nv.path.is_ident("gdb_script_file"))
                            && let Some(s) = lit_str(&nv.value)
                            && let Some(f) = join(&self.dir, &s)
                        {
                            self.w.files.insert(f);
                        }
                    }
                }
            }
            Meta::List(l) => self.tokens(l.tokens.clone(), false),
            Meta::Path(_) => {}
        }
    }

    /// A token stream that syn does not parse: a macro's arguments. Items
    /// in it expand in place for macros such as `cfg_if!`, so `mod`
    /// items, `#[path]` and includes in it count. `opaque`: inside a
    /// `macro_rules!` body, where they resolve wherever the macro is
    /// invoked; one there makes the prediction fall back.
    fn tokens(&mut self, ts: TokenStream, opaque: bool) {
        let tts: Vec<TokenTree> = ts.into_iter().collect();
        let mut paths = PathAttrs::default();
        let mut i = 0;
        while i < tts.len() {
            match &tts[i] {
                TokenTree::Punct(p) if p.as_char() == '#' => {
                    let mut j = i + 1;
                    if matches!(tts.get(j), Some(TokenTree::Punct(b)) if b.as_char() == '!') {
                        j += 1;
                    }
                    if let Some(TokenTree::Group(g)) = tts.get(j)
                        && g.delimiter() == Delimiter::Bracket
                    {
                        match syn::parse2::<Meta>(g.stream()) {
                            Ok(meta) => {
                                let before = (paths.plain.is_some(), paths.cfg.len());
                                paths.add_meta(&meta);
                                if opaque && before != (paths.plain.is_some(), paths.cfg.len()) {
                                    let f = self.file.clone();
                                    self.w.fall(&f, Reason::InMacroRules);
                                }
                                if !opaque {
                                    self.meta(&meta);
                                } else {
                                    self.tokens(g.stream(), true);
                                }
                            }
                            Err(_) => self.tokens(g.stream(), opaque),
                        }
                        i = j + 1;
                        continue;
                    }
                }
                TokenTree::Punct(p) if p.as_char() == ';' => paths = PathAttrs::default(),
                TokenTree::Ident(id) if id == "mod" => match (tts.get(i + 1), tts.get(i + 2)) {
                    (Some(TokenTree::Punct(d)), _) if d.as_char() == '$' => {
                        let f = self.file.clone();
                        self.w.fall(&f, Reason::MacroGeneratedMod);
                        i += 2;
                        continue;
                    }
                    (Some(TokenTree::Ident(name)), Some(next)) => {
                        let name = name.to_string();
                        let name = name.strip_prefix("r#").unwrap_or(&name).to_owned();
                        match next {
                            TokenTree::Punct(s) if s.as_char() == ';' => {
                                if opaque {
                                    let f = self.file.clone();
                                    self.w.fall(&f, Reason::InMacroRules);
                                } else {
                                    self.out_of_line_module(&name, &paths);
                                }
                                paths = PathAttrs::default();
                                i += 3;
                                continue;
                            }
                            TokenTree::Group(g) if g.delimiter() == Delimiter::Brace => {
                                if !opaque {
                                    if !paths.cfg.is_empty() {
                                        let f = self.file.clone();
                                        self.w.fall(&f, Reason::CfgPathOnInlineModule);
                                    }
                                    let m = self.inline_module(&name, &paths);
                                    self.stack.push(m);
                                    self.tokens(g.stream(), false);
                                    self.stack.pop();
                                } else {
                                    self.tokens(g.stream(), true);
                                }
                                paths = PathAttrs::default();
                                i += 3;
                                continue;
                            }
                            _ => {}
                        }
                    }
                    _ => {}
                },
                TokenTree::Ident(id)
                    if (id == "include"
                        || id == "include_str"
                        || id == "include_bytes"
                        || id == "macro_rules")
                        && matches!(tts.get(i + 1), Some(TokenTree::Punct(b)) if b.as_char() == '!') =>
                {
                    let which = id.to_string();
                    if which == "macro_rules" {
                        // `macro_rules! name { … }`: its body is opaque.
                        let mut j = i + 2;
                        while let Some(tt) = tts.get(j) {
                            j += 1;
                            if let TokenTree::Group(g) = tt {
                                self.tokens(g.stream(), true);
                                break;
                            }
                        }
                        i = j;
                        continue;
                    }
                    if let Some(TokenTree::Group(g)) = tts.get(i + 2) {
                        if opaque {
                            let f = self.file.clone();
                            self.w.fall(&f, Reason::InMacroRules);
                        } else {
                            self.include(&which, g.stream());
                        }
                        i += 3;
                        continue;
                    }
                }
                TokenTree::Literal(l) => {
                    if let Ok(s) = syn::parse2::<LitStr>(TokenTree::Literal(l.clone()).into()) {
                        let f = self.file.clone();
                        self.w.literals.push((f, s.value()));
                    }
                }
                TokenTree::Group(g) => {
                    if g.delimiter() == Delimiter::Brace {
                        paths = PathAttrs::default();
                    }
                    self.tokens(g.stream(), opaque);
                }
                _ => {}
            }
            i += 1;
        }
    }
}

impl<'ast> Visit<'ast> for FileVisitor<'_, '_> {
    fn visit_item_mod(&mut self, m: &'ast syn::ItemMod) {
        for a in &m.attrs {
            self.visit_attribute(a);
        }
        let mut paths = PathAttrs::default();
        for a in &m.attrs {
            paths.add_meta(&a.meta);
        }
        let name = m.ident.to_string();
        let name = name.strip_prefix("r#").unwrap_or(&name).to_owned();
        match &m.content {
            Some((_, items)) => {
                if !paths.cfg.is_empty() {
                    let f = self.file.clone();
                    self.w.fall(&f, Reason::CfgPathOnInlineModule);
                }
                let module = self.inline_module(&name, &paths);
                self.stack.push(module);
                for item in items {
                    self.visit_item(item);
                }
                self.stack.pop();
            }
            None => self.out_of_line_module(&name, &paths),
        }
    }

    fn visit_block(&mut self, b: &'ast syn::Block) {
        let m = Module {
            dir: self.module().dir.clone(),
            own: Own::Block,
        };
        self.stack.push(m);
        visit::visit_block(self, b);
        self.stack.pop();
    }

    fn visit_macro(&mut self, mac: &'ast syn::Macro) {
        let name = mac
            .path
            .segments
            .last()
            .map(|s| s.ident.to_string())
            .unwrap_or_default();
        match name.as_str() {
            "include" | "include_str" | "include_bytes" => self.include(&name, mac.tokens.clone()),
            "macro_rules" => self.tokens(mac.tokens.clone(), true),
            _ => self.tokens(mac.tokens.clone(), false),
        }
    }

    fn visit_attribute(&mut self, a: &'ast syn::Attribute) {
        self.meta(&a.meta);
    }

    fn visit_lit_str(&mut self, s: &'ast LitStr) {
        let f = self.file.clone();
        self.w.literals.push((f, s.value()));
    }
}

/// Where an `include*!` argument points.
enum IncludePath {
    /// Relative to the including file (or absolute, which `join` drops).
    Relative(String),
    /// Under `CARGO_MANIFEST_DIR`.
    Manifest(String),
    /// Under `OUT_DIR` (generated), or absolute: in no view.
    Outside,
    Unknown,
}

fn include_path(e: &Expr) -> IncludePath {
    if let Some(s) = lit_str(e) {
        return if s.starts_with('/') {
            IncludePath::Outside
        } else {
            IncludePath::Relative(s)
        };
    }
    let Expr::Macro(m) = e else {
        return IncludePath::Unknown;
    };
    let name = m.mac.path.segments.last().map(|s| s.ident.to_string());
    let parser = Punctuated::<Expr, Token![,]>::parse_terminated;
    let Ok(args) = syn::parse::Parser::parse2(parser, m.mac.tokens.clone()) else {
        return IncludePath::Unknown;
    };
    let args: Vec<Expr> = args.into_iter().collect();
    match name.as_deref() {
        Some("env") => match args.first().and_then(lit_str).as_deref() {
            Some("OUT_DIR") => IncludePath::Outside,
            _ => IncludePath::Unknown,
        },
        Some("concat") => {
            let Some((first, rest)) = args.split_first() else {
                return IncludePath::Unknown;
            };
            let tail: Option<String> = rest.iter().map(lit_str).collect();
            let Some(tail) = tail else {
                return IncludePath::Unknown;
            };
            match include_path(first) {
                IncludePath::Relative(s) => IncludePath::Relative(s + &tail),
                IncludePath::Outside => IncludePath::Outside,
                IncludePath::Unknown => match first {
                    Expr::Macro(env)
                        if env.mac.path.is_ident("env")
                            && syn::parse2::<LitStr>(env.mac.tokens.clone())
                                .is_ok_and(|s| s.value() == "CARGO_MANIFEST_DIR") =>
                    {
                        IncludePath::Manifest(tail)
                    }
                    _ => IncludePath::Unknown,
                },
                IncludePath::Manifest(_) => IncludePath::Unknown,
            }
        }
        _ => IncludePath::Unknown,
    }
}

/// `base/rel`, normalized; None when it leaves the view root or `rel` is
/// absolute.
fn join(base: &str, rel: &str) -> Option<String> {
    if rel.starts_with('/') {
        return None;
    }
    normalize(&format!("{base}/{rel}"))
}

/// `a/./b/../c` as `a/c`; None when it leaves the root.
fn normalize(p: &str) -> Option<String> {
    let mut out: Vec<&str> = Vec::new();
    for c in p.split('/') {
        match c {
            "" | "." => {}
            ".." => {
                out.pop()?;
            }
            c => out.push(c),
        }
    }
    Some(out.join("/"))
}

fn parent(rel: &str) -> String {
    match rel.rfind('/') {
        Some(i) => rel[..i].to_owned(),
        None => String::new(),
    }
}
