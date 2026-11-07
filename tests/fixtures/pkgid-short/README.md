Git dependencies built through breakbulk units (found in the field trials:
datboi2's emu workspace depends on kelpsyberry/dust, emu-utils and
arm-decoder). Cargo's package id of a git crate keeps the `git+` protocol
and the reference query (`git+https://example.invalid/me/tools?rev=…#helper@0.2.0`),
and leaves the name out when it equals the URL's last path segment
(`git+https://example.invalid/me/gitdep#0.1.0`). repo/ and tools/ stand in
for the fetched git trees; the URLs are never contacted.
