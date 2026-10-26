#!/bin/zsh
# build-shader-archive.sh: Sources/AetherEngine/Resources/AetherEngine-pipelines.metallib, the Metal 4 binary archive of
# the engine's own pipelines for the Apple TV 4K (3rd generation, A15).
#
# The package's kernels (Sources/AetherEngine/Shaders, Sources/AetherFELShaders/Shaders) compile when an app builds the
# package; a Release build for tvOS devices compiles them to the same bytes whether Xcode or swift build does it. This
# builds them so, records every pipeline of the planned set (EngineShaderArchive.requests: the finisher's and the FEL
# composer's) with a Metal 4 compiler on this Mac, and translates the script for the A15 on TVOS_ARCHIVE_OS. Metal
# takes the archive only on that tvOS release and only for those exact libraries: run this again after any change to a
# shader, and for a new tvOS release. A pipeline the archive misses is compiled and logged ([GPUPipelines]).
#
# Needs Xcode 27.2 (DEVELOPER_DIR=~/Downloads/Xcode-beta.app/Contents/Developer: metal-tt) on macOS 26 or later.
set -euo pipefail

HERE=${0:A:h}
ROOT=${HERE:h}
SCRATCH=${SCRATCH:-${ROOT:h}/aether-build-app}
TVOS_ARCHIVE_OS=${TVOS_ARCHIVE_OS:-27.0}
ARCHIVE_GPUS=(applegpu_g14p)
TRAITS=DualLayerDolbyVision,TrueHDObjectAudio,DTSXObjectAudio,DolbyVisionStillReshaping,APACObjectOutput,MLSubtitleUpscale
OUT=$ROOT/Sources/AetherEngine/Resources/AetherEngine-pipelines.metallib

cd $ROOT
print "== the kernels, as a tvOS device Release build compiles them"
swift build -c release --triple arm64-apple-tvos --sdk "$(xcrun --sdk appletvos --show-sdk-path)" --traits $TRAITS \
  --scratch-path $SCRATCH/tvos --target AetherEngine -q
products=$SCRATCH/tvos/out/Products/Release-appletvos
engine=$products/AetherEngine_AetherEngine.bundle/default.metallib
fel=$products/AetherEngine_AetherFELShaders.bundle/default.metallib

print "== the planned set, recorded"
swift build -c release --traits $TRAITS --scratch-path $SCRATCH --product ShaderHarvest -q
script=$SCRATCH/tvos/pipelines.mtl4-json
$SCRATCH/out/Products/Release/ShaderHarvest $engine $fel $script

print "== translated (tvOS $TVOS_ARCHIVE_OS: ${ARCHIVE_GPUS[*]})"
gpus=()
for gpu in $ARCHIVE_GPUS; do gpus+=(-arch $gpu); done
# The script names its libraries.
xcrun metal-tt $gpus -tvos-version-min $TVOS_ARCHIVE_OS $script -o $OUT
print "wrote $OUT"
