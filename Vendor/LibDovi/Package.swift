// swift-tools-version: 6.0

import PackageDescription

// Local build of LibDovi (superuser404notfound/LibDovi 2.1.0's packaging) against dovi_tool 2.3.4, whose
// `dolby_vision` crate parses CM v4.0 level 253 blocks, which the published 3.4.0 rejects. Dovi.xcframework is
// not committed: run ./build.sh once after cloning. Slices: tvOS device, tvOS simulator, macOS only.
let package = Package(
    name: "LibDovi",
    platforms: [
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "Dovi",
            targets: ["Dovi"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "Dovi",
            path: "Dovi.xcframework"
        ),
    ]
)
