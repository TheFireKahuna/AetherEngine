# LibDovi (local build)

libdovi, the C API of quietvoid's `dolby_vision` crate, built for this fork from dovi_tool tag `2.3.4`
(commit `614c816`) and packaged as the SwiftPM binary target `Dovi`. The packaging and `build.sh` come from
[superuser404notfound/LibDovi](https://github.com/superuser404notfound/LibDovi) 2.1.0 (MIT, see LICENSE).

Why not the published LibDovi: its `dolby_vision` 3.4.0 rejects CM v4.0 level 253 blocks (Disney+ v4.0
RPUs carry them), so the engine's Profile 7 routes dropped every RPU of a hybrid built on such a donor. The
2.3.4 tree is still versioned 3.4.0 and adds L253 parsing (`DoviDmData.level253`); nothing else in the
header changed.

## Local patches

`build.sh` applies `patches/*.patch` to the pinned checkout, in name order.

- `0001-ext-blocks-carry-reserved-levels.patch`: DM extension blocks to ETSI TS 103 572 (clause 4.3), ATSC A/341
  (Annex E) and ETSI GS CCM 001 (6.2.2), which say blocks using reserved levels "shall be ignored". Upstream
  failed the whole RPU on any level outside a list's own set (an unknown level, a CM v4.0 level in the CM v2.9
  list, the ST 2094-10 L3 that TS 103 572 defines there), and the engine then dropped that frame's display
  metadata. Such a block is now kept as its payload bytes (`ReservedExtMetadataBlock`, reporting its real level)
  and written back unchanged. The CM v2.9 L2 cap goes from 8 to A/341's 16. Doc comments: the C API's real mode
  numbers (2 and 3 = 8.1, 4 = 8.4, anything else = no conversion) and L4's spec field names. Tests: five new
  crate tests (`extension_metadata/tests.rs`); the two upstream tests that asserted the L3 rejection now assert
  the byte-exact round trip. Not yet upstream.

- `0002-p7-to-81-keeps-dm-coefficients.patch`: the 8.1 conversion of a profile 7 or 8 RPU (modes 2 and 3, and the
  mapping-preserving form) keeps the DM data's `YCCtoRGB` / `RGBtoLMS` coefficients and offsets. Upstream replaced
  them with the 8.1 defaults (limited BT.2020 YCbCr), which describe a different picture whenever the source states
  another range or matrix: a full-range output (luma offset 0) would be described as video range. They describe the
  output picture, which that conversion leaves as it is, so the source's are the right ones; on every disc measured
  they equal the defaults anyway. A profile 5 source, whose representation the conversion does change, and 8.4 still
  get the defaults. Tests: `rpu/conversion_tests.rs` (P7 full-range offsets survive both 8.1 forms and the write;
  P5 to 8.1 and 8.4 get the defaults). Not yet upstream.

The patches are one series: `build.sh` stages the checkout into a scratch index and reverses them there, newest first;
landing exactly on the pinned commit means the series is applied and the rebuild is a no-op. Otherwise it applies the
series to a clean checkout, and refuses a checkout carrying anything else.

To change a patch: edit `build/dovi_tool`, then write the diff of that patch's own change (on top of the patches before
it) to `patches/<name>.patch`.

## Build

```sh
rustup target add aarch64-apple-tvos aarch64-apple-tvos-sim x86_64-apple-darwin
cargo install cargo-c --version 0.10.25 --locked   # the last cargo-c for rustc 1.96; newer Rust: plain `cargo install cargo-c`
./build.sh
```

Writes `Dovi.xcframework` (gitignored, ~70 MB) with three slices: `tvos-arm64`, `tvos-arm64-simulator` and
`macos-arm64_x86_64`. iOS and visionOS builds of the engine need the published LibDovi again (its pin is
kept as a comment in the engine's `Package.swift`).
