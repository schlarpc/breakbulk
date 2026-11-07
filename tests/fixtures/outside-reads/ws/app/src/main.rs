fn main() {
    let asset: &str = embed::embed!("../../assets/data.txt");
    println!("{} | {}", reader::GREETING.trim(), asset.trim());
}
