//! Spike B: the store-writing half of breakbulk-instantiate, on harmonia.
//!
//! bb-drv add <drv.json> <drv-cache-dir>
//!     Read a derivation in Nix's JSON format (version 4) with deferred
//!     input-addressed outputs, compute its output paths with harmonia's
//!     hash modulo (input .drv files are read from <drv-cache-dir> when this
//!     build wrote them, else from the store), print it as ATerm, and add it
//!     over $NIX_REMOTE with AddToStore (text hashing, explicit references).
//!     Prints {"drvPath": …, "outputs": {…}}.
//! bb-drv submit <drv path> <output name>
//!     SubmitOutput over $NIX_REMOTE (builder-rpc-v0).

use std::collections::{BTreeSet, HashMap};
use std::io::Cursor;
use std::path::Path;

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

fn read_drv(sd: &StoreDir, cache: &Path, p: &StorePath) -> Res<Derivation> {
    let base = p.to_string();
    let local = cache.join(&base);
    let file = if local.exists() { local } else { sd.to_path().join(&base) };
    let bytes = std::fs::read(&file).map_err(|e| format!("reading {}: {e}", file.display()))?;
    let name: StorePathName = base
        .split_once('-')
        .and_then(|(_, n)| n.strip_suffix(".drv"))
        .ok_or_else(|| format!("not a .drv: {base}"))?
        .parse()
        .map_err(|e| format!("{e}"))?;
    parse_derivation_aterm(sd, &bytes, name).map_err(|e| format!("parsing {base}: {e}"))
}

fn modulo(
    sd: &StoreDir,
    cache: &Path,
    memo: &mut HashMap<StorePath, HashModulo>,
    p: &StorePath,
) -> Res<HashModulo> {
    if let Some(h) = memo.get(p) {
        return Ok(h.clone());
    }
    let drv = read_drv(sd, cache, p)?;
    let h = hash_input_modulo(sd, &drv, |q| modulo(sd, cache, memo, q))
        .map_err(|e| format!("hash modulo of {p}: {e}"))?;
    memo.insert(p.clone(), h.clone());
    Ok(h)
}

fn socket() -> Res<String> {
    let remote = std::env::var("NIX_REMOTE").map_err(|_| "NIX_REMOTE not set".to_string())?;
    Ok(remote.strip_prefix("unix://").unwrap_or(&remote).to_string())
}

async fn add(json: &str, cache: &Path) -> Res<()> {
    let sd = StoreDir::new(std::env::var("NIX_STORE").unwrap_or("/nix/store".into()))
        .map_err(|e| format!("{e}"))?;
    let text = std::fs::read_to_string(json).map_err(|e| format!("{json}: {e}"))?;
    let drv: Derivation = serde_json::from_str(&text).map_err(|e| format!("{json}: {e}"))?;

    let mut memo = HashMap::new();
    let filled = fill_deferred_outputs(&sd, drv.clone().map_outputs(|_| UnfilledOutput), |q| {
        modulo(&sd, cache, &mut memo, q)
    })
    .map_err(|e| format!("{e}"))?;

    // Some(paths): input-addressed. None: an input is itself deferred or a
    // dynamic output (an embedded product), so this derivation stays
    // deferred, and dependents must reference its outputs by placeholder.
    let (full, mut outputs) = match filled {
        Some(filled) => {
            let outputs: serde_json::Map<String, serde_json::Value> = filled
                .outputs
                .iter()
                .map(|(o, p)| (o.to_string(), sd.display(p).to_string().into()))
                .collect();
            (filled.map_outputs(DerivationOutput::InputAddressed).into_full(), Some(outputs))
        }
        None => (drv.map_outputs(|_| DerivationOutput::Deferred).into_full(), None),
    };
    let aterm = print_derivation_aterm(&sd, &full);

    // References of a .drv: its input sources and input derivations, as
    // Store::writeDerivation does.
    let refs: BTreeSet<StorePath> =
        full.inputs.srcs.iter().chain(full.inputs.drvs.keys()).cloned().collect();

    let mut client = DaemonClientBuilder::new()
        .connect_unix(socket()?)
        .await
        .map_err(|e| format!("connect: {e}"))?;
    let info = client
        .add_ca_to_store(
            &format!("{}.drv", full.name),
            ContentAddressMethodAlgorithm::Text,
            &refs,
            false,
            Cursor::new(aterm.clone()),
        )
        .await
        .map_err(|e| format!("AddToStore: {e}"))?;
    std::fs::write(cache.join(info.path.to_string()), &aterm).map_err(|e| format!("{e}"))?;
    let outputs = outputs.get_or_insert_with(|| {
        full.outputs
            .keys()
            .map(|o| {
                let ph = Placeholder::ca_output(&info.path, o).render();
                (o.to_string(), ph.to_string_lossy().into_owned().into())
            })
            .collect()
    });
    println!(
        "{}",
        serde_json::json!({ "drvPath": sd.display(&info.path).to_string(), "outputs": outputs })
    );
    Ok(())
}

async fn submit(drv: &str, output: &str) -> Res<()> {
    let sd = StoreDir::new(std::env::var("NIX_STORE").unwrap_or("/nix/store".into()))
        .map_err(|e| format!("{e}"))?;
    let path: StorePath = sd.parse(drv).map_err(|e| format!("{drv}: {e}"))?;
    let output: OutputName = output.parse().map_err(|e| format!("{output}: {e}"))?;
    let mut client = DaemonClientBuilder::new()
        .connect_unix(socket()?)
        .await
        .map_err(|e| format!("connect: {e}"))?;
    client
        .submit_output(&SingleDerivedPath::Opaque(path), &output)
        .await
        .map_err(|e| format!("SubmitOutput: {e}"))
}

#[tokio::main(flavor = "current_thread")]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let r = match args.iter().map(String::as_str).collect::<Vec<_>>()[1..] {
        ["add", json, cache] => add(json, Path::new(cache)).await,
        ["submit", drv, output] => submit(drv, output).await,
        _ => Err("usage: bb-drv add <drv.json> <cache-dir> | submit <drv> <output>".into()),
    };
    if let Err(e) = r {
        eprintln!("bb-drv: {e}");
        std::process::exit(1);
    }
}
