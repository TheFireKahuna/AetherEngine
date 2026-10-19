# LibDovi (local build)

libdovi, the C API of quietvoid's `dolby_vision` crate, built for this fork from dovi_tool tag `2.3.4`
(commit `614c816`) and packaged as the SwiftPM binary target `Dovi`. The packaging and `build.sh` come from
[superuser404notfound/LibDovi](https://github.com/superuser404notfound/LibDovi) 2.1.0 (MIT, see LICENSE).

Why not the published LibDovi: its `dolby_vision` 3.4.0 rejects CM v4.0 level 253 blocks (Disney+ v4.0
RPUs carry them), so the engine's Profile 7 routes dropped every RPU of a hybrid built on such a donor. The
2.3.4 tree is still versioned 3.4.0 and adds L253 parsing (`DoviDmData.level253`); nothing else in the
header changed.

## Build

```sh
rustup target add aarch64-apple-tvos aarch64-apple-tvos-sim x86_64-apple-darwin
cargo install cargo-c --version 0.10.25 --locked   # the last cargo-c for rustc 1.96; newer Rust: plain `cargo install cargo-c`
./build.sh
```

Writes `Dovi.xcframework` (gitignored, ~70 MB) with three slices: `tvos-arm64`, `tvos-arm64-simulator` and
`macos-arm64_x86_64`. iOS and visionOS builds of the engine need the published LibDovi again (its pin is
kept as a comment in the engine's `Package.swift`).
