#[test]
fn offline_ok() {}

/// Needs the network: skipped in the sandbox by the binary's skip list, run
/// through the test app.
#[test]
fn needs_network() {
    use std::net::{TcpStream, ToSocketAddrs};
    let addr = ("example.com", 80)
        .to_socket_addrs()
        .expect("resolving example.com")
        .next()
        .unwrap();
    TcpStream::connect_timeout(&addr, std::time::Duration::from_secs(10))
        .expect("connecting to example.com");
    println!("network test reached example.com");
}
