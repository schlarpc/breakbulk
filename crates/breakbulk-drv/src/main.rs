//! `breakbulk-drv`: the builder of a dynamic-derivation-mode outer derivation.
//!
//! ```text
//! breakbulk-drv --plan <plan.json> --sources <file> --toolchains <file>
//!     --overrides <file> --roots <file> --values <file> --outer <file>
//! ```
//!
//! It runs instantiation exactly as IFD mode does (`breakbulk_instantiate`),
//! resolves every derivation with the real paths (`dynamic::resolve`, the
//! same substitution `lib/instantiate.nix` does), and writes the units, the
//! root stubs and one wrapper per root, in dependency order, over the
//! restricted daemon socket that `builder-rpc-v0` provides (`$NIX_REMOTE`).
//! Each wrapper is then submitted as its output of the outer derivation.
//!
//! Writing follows spike B (docs/spikes/B-delivery.md at the spikes-archive
//! tag): output paths are computed here with harmonia's
//! `hashDerivationModulo`, the ATerm is printed and added as a text-hashed
//! store object whose references are its input sources and input derivations,
//! as `Store::writeDerivation` does. `nix derivation add` cannot be used: it
//! reads input `.drv` files on the client side, and paths added during the
//! build are not visible in its sandbox. The daemon recomputes input-addressed
//! outputs when it registers a `.drv`, so a wrong hash cannot get into the
//! store.
//!
//! A unit whose inputs include a content-addressed or deferred derivation
//! (an embedded product) stays deferred: its outputs are placeholders, and
//! so are those of every unit that depends on it. Nix resolves them at
//! build time.

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Cursor;
use std::process::ExitCode;

use breakbulk_format::Plan;
use breakbulk_instantiate::dynamic::{self, Outer, Resolved, Values, Written};
use breakbulk_instantiate::{Inputs, instantiate};
use harmonia_protocol::types::DaemonStore as _;
use harmonia_store_aterm::hash_modulo::{HashModulo, fill_deferred_outputs, hash_input_modulo};
use harmonia_store_aterm::input_address::UnfilledOutput;
use harmonia_store_aterm::{parse_derivation_aterm, print_derivation_aterm};
use harmonia_store_content_address::ContentAddressMethodAlgorithm;
use harmonia_store_derivation::derivation::{Derivation, DerivationOutput};
use harmonia_store_derivation::derived_path::{OutputName, SingleDerivedPath};
use harmonia_store_derivation::placeholder::Placeholder;
use harmonia_store_path::{StoreDir, StorePath, StorePathName};
use harmonia_store_remote::DaemonClientBuilder;

type Res<T> = Result<T, String>;

const USAGE: &str = "usage: breakbulk-drv --plan <plan.json> --sources <file> \
    --toolchains <file> --overrides <file> --roots <file> --values <file> --outer <file>";

fn read(path: &str) -> Res<String> {
    std::fs::read_to_string(path).map_err(|e| format!("reading {path}: {e}"))
}

fn parse<T: serde::de::DeserializeOwned>(path: &str) -> Res<T> {
    serde_json::from_str(&read(path)?).map_err(|e| format!("{path}: {e}"))
}

/// `.drv` files: the ones this build wrote (it cannot read them back from
/// the store, spike B), else the store's, which the outer derivation has in
/// its input closure.
struct Drvs {
    sd: StoreDir,
    written: HashMap<StorePath, Vec<u8>>,
    memo: HashMap<StorePath, HashModulo>,
}

impl Drvs {
    fn read(&self, p: &StorePath) -> Res<Derivation> {
        let base = p.to_string();
        let bytes = match self.written.get(p) {
            Some(b) => b.clone(),
            None => {
                let file = self.sd.to_path().join(&base);
                std::fs::read(&file).map_err(|e| {
                    format!(
                        "reading {}: {e} (is it in the outer derivation's context?)",
                        file.display()
                    )
                })?
            }
        };
        let name: StorePathName = base
            .split_once('-')
            .and_then(|(_, n)| n.strip_suffix(".drv"))
            .ok_or_else(|| format!("not a .drv: {base}"))?
            .parse()
            .map_err(|e| format!("{base}: {e}"))?;
        parse_derivation_aterm(&self.sd, &bytes, name).map_err(|e| format!("parsing {base}: {e}"))
    }

    fn modulo(&mut self, p: &StorePath) -> Res<HashModulo> {
        if let Some(h) = self.memo.get(p) {
            return Ok(h.clone());
        }
        let drv = self.read(p)?;
        let sd = self.sd.clone();
        let h = hash_input_modulo(&sd, &drv, |q| self.modulo(q))
            .map_err(|e| format!("hash modulo of {p}: {e}"))?;
        self.memo.insert(p.clone(), h.clone());
        Ok(h)
    }
}

/// The store path's base name (`<hash>-<name>`).
fn base(sd: &StoreDir, path: &str) -> Res<String> {
    let dir = format!("{}/", sd.to_str().trim_end_matches('/'));
    path.strip_prefix(&dir)
        .filter(|b| !b.contains('/'))
        .map(str::to_owned)
        .ok_or_else(|| format!("{path} is not a store path"))
}

/// Nix's derivation JSON (format version 4) for harmonia, with deferred
/// outputs. Every output variable is present and empty: Nix masks them
/// before hashing, and a missing one hashes differently (spike B).
fn to_json(sd: &StoreDir, r: &Resolved) -> Res<serde_json::Value> {
    let mut env: serde_json::Map<String, serde_json::Value> = r
        .env
        .iter()
        .map(|(k, v)| (k.clone(), v.clone().into()))
        .collect();
    for o in &r.outputs {
        env.insert(o.clone(), "".into());
    }
    let mut drvs = serde_json::Map::new();
    for (d, outs) in &r.input_drvs {
        drvs.insert(
            base(sd, d)?,
            serde_json::json!({ "outputs": outs, "dynamicOutputs": {} }),
        );
    }
    let srcs = r
        .input_srcs
        .iter()
        .map(|s| base(sd, s))
        .collect::<Res<BTreeSet<_>>>()?;
    Ok(serde_json::json!({
        "version": 4,
        "name": r.name,
        "system": r.system,
        "builder": r.builder,
        "args": r.args,
        "env": env,
        "inputs": { "drvs": drvs, "srcs": srcs },
        "outputs": r.outputs.iter().map(|o| (o.clone(), serde_json::json!({}))).collect::<serde_json::Map<_, _>>(),
    }))
}

async fn run() -> Res<()> {
    let mut args = std::env::args().skip(1);
    let mut opts = BTreeMap::new();
    while let Some(flag) = args.next() {
        let name = flag
            .strip_prefix("--")
            .filter(|n| {
                matches!(
                    *n,
                    "plan" | "sources" | "toolchains" | "overrides" | "roots" | "values" | "outer"
                )
            })
            .ok_or_else(|| format!("unknown argument `{flag}`\n{USAGE}"))?;
        let value = args
            .next()
            .ok_or_else(|| format!("`{flag}` needs a value\n{USAGE}"))?;
        if opts.insert(name.to_owned(), value).is_some() {
            return Err(format!("`{flag}` given twice\n{USAGE}"));
        }
    }
    let need = |n: &str| {
        opts.get(n)
            .cloned()
            .ok_or_else(|| format!("missing --{n}\n{USAGE}"))
    };
    let plan_path = need("plan")?;
    let plan = Plan::from_json(&read(&plan_path)?).map_err(|e| format!("{plan_path}: {e}"))?;
    let inputs = Inputs {
        plan,
        sources: parse(&need("sources")?)?,
        toolchains: parse(&need("toolchains")?)?,
        overrides: parse(&need("overrides")?)?,
        // `null` for plans without predicted roots (check and clippy).
        roots: parse(&need("roots")?)?,
    };
    let values: Values = parse(&need("values")?)?;
    let outer: Outer = parse(&need("outer")?)?;

    let units = instantiate(&inputs).map_err(|e| e.to_string())?;
    let dplan = dynamic::dynamic_plan(&inputs, &units, &outer).map_err(|e| e.to_string())?;

    let sd = StoreDir::new(std::env::var("NIX_STORE").unwrap_or_else(|_| "/nix/store".into()))
        .map_err(|e| format!("{e}"))?;
    let remote = std::env::var("NIX_REMOTE").map_err(|_| {
        "NIX_REMOTE is not set: breakbulk-drv runs as the builder of a derivation with \
         requiredSystemFeatures = [ \"builder-rpc-v0\" ]"
            .to_owned()
    })?;
    let socket = remote.strip_prefix("unix://").unwrap_or(&remote).to_owned();
    let mut client = DaemonClientBuilder::new()
        .connect_unix(socket)
        .await
        .map_err(|e| format!("connecting to {remote}: {e}"))?;

    let mut drvs = Drvs {
        sd: sd.clone(),
        written: HashMap::new(),
        memo: HashMap::new(),
    };
    let mut written: BTreeMap<String, Written> = BTreeMap::new();
    let mut deferred = 0usize;
    for node in &dplan.nodes {
        let r = dynamic::resolve(&node.drv, &values, &written, units.pass_as_file_above)
            .map_err(|e| format!("{}: {e}", node.key))?;
        let json = to_json(&sd, &r)?;
        let drv: Derivation =
            serde_json::from_value(json).map_err(|e| format!("{}: {e}", node.key))?;
        let filled = fill_deferred_outputs(&sd, drv.clone().map_outputs(|_| UnfilledOutput), |q| {
            drvs.modulo(q)
        })
        .map_err(|e| format!("{}: computing output paths: {e}", node.key))?;
        // Some: input-addressed. None: an input is content-addressed or
        // deferred, so this derivation is deferred too.
        let (full, paths) = match filled {
            Some(f) => {
                let paths: BTreeMap<String, String> = f
                    .outputs
                    .iter()
                    .map(|(o, p)| (o.to_string(), sd.display(p).to_string()))
                    .collect();
                (
                    f.map_outputs(DerivationOutput::InputAddressed).into_full(),
                    Some(paths),
                )
            }
            None => (
                drv.map_outputs(|_| DerivationOutput::Deferred).into_full(),
                None,
            ),
        };
        let aterm = print_derivation_aterm(&sd, &full);
        let refs: BTreeSet<StorePath> = full
            .inputs
            .srcs
            .iter()
            .chain(full.inputs.drvs.keys())
            .cloned()
            .collect();
        let info = client
            .add_ca_to_store(
                &format!("{}.drv", full.name),
                ContentAddressMethodAlgorithm::Text,
                &refs,
                false,
                Cursor::new(aterm.clone()),
            )
            .await
            .map_err(|e| format!("{}: adding {}.drv: {e}", node.key, full.name))?;
        let path = info.path.clone();
        drvs.written.insert(path.clone(), aterm);
        let outputs = match paths {
            Some(p) => p,
            None => {
                deferred += 1;
                full.outputs
                    .keys()
                    .map(|o| {
                        let ph = Placeholder::ca_output(&path, o).render();
                        (o.to_string(), ph.to_string_lossy().into_owned())
                    })
                    .collect()
            }
        };
        let drv_path = sd.display(&path).to_string();
        // One line per derivation; tests read these from the build log.
        println!("breakbulk-drv: wrote {} {drv_path}", node.key);
        if let Some(output) = &node.submit_as {
            let name: OutputName = output.parse().map_err(|e| format!("{output}: {e}"))?;
            client
                .submit_output(&SingleDerivedPath::Opaque(path.clone()), &name)
                .await
                .map_err(|e| format!("submitting {drv_path} as {output}: {e}"))?;
            println!("breakbulk-drv: submitted {drv_path} as {output}");
        }
        written.insert(node.key.clone(), Written { drv_path, outputs });
    }
    eprintln!(
        "breakbulk-drv: {} derivations written ({deferred} deferred), {} roots submitted",
        dplan.nodes.len(),
        dplan.nodes.iter().filter(|n| n.submit_as.is_some()).count()
    );
    Ok(())
}

fn main() -> ExitCode {
    let rt = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("breakbulk-drv: {e}");
            return ExitCode::FAILURE;
        }
    };
    match rt.block_on(run()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("breakbulk-drv: {e}");
            ExitCode::FAILURE
        }
    }
}
