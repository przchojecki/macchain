#!/bin/bash
set -e

# MacChain build script — standalone path when SwiftPM isn't available

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
SOURCES="$PROJECT_DIR/Sources/MacChainLib"
CLI_SOURCES="$PROJECT_DIR/Sources/MacChain"
BENCH_SOURCES="$PROJECT_DIR/Sources/MacChainBenchmark"
SHADER_DIR="$SOURCES/Shaders"

SDK=$(xcrun --show-sdk-path)
TARGET="arm64-apple-macosx13.0"

mkdir -p "$BUILD_DIR/release"
mkdir -p "$BUILD_DIR/metallib"

echo "=== MacChain Build ==="
echo "SDK: $SDK"
echo ""

# Step 1: Compile Metal shaders
echo "[1/4] Compiling Metal shaders..."
METAL_FILES=$(find "$SHADER_DIR" -name "*.metal" 2>/dev/null)
if [ -n "$METAL_FILES" ]; then
    AIR_FILES=""
    for metal_file in $METAL_FILES; do
        base=$(basename "$metal_file" .metal)
        xcrun metal -c "$metal_file" -o "$BUILD_DIR/metallib/$base.air" 2>/dev/null || true
        if [ -f "$BUILD_DIR/metallib/$base.air" ]; then
            AIR_FILES="$AIR_FILES $BUILD_DIR/metallib/$base.air"
        fi
    done
    if [ -n "$AIR_FILES" ]; then
        xcrun metallib $AIR_FILES -o "$BUILD_DIR/metallib/default.metallib" 2>/dev/null || true
    fi
fi
echo "  Done."

# Step 2: Compile MacChainLib as a module
echo "[2/4] Compiling MacChainLib..."
LIB_SOURCES=$(find "$SOURCES" -name "*.swift" -not -path "*/Shaders/*")

swiftc \
    -module-name MacChainLib \
    -emit-module \
    -emit-module-path "$BUILD_DIR/release/MacChainLib.swiftmodule" \
    -emit-library \
    -o "$BUILD_DIR/release/libMacChainLib.dylib" \
    -sdk "$SDK" \
    -target "$TARGET" \
    -O \
    -framework Metal \
    -framework Accelerate \
    -framework CryptoKit \
    -swift-version 5 \
    $LIB_SOURCES

echo "  Done."

# Step 3: Compile MacChain CLI executable
echo "[3/4] Compiling MacChain CLI..."
CLI_FILES=$(find "$CLI_SOURCES" -name "*.swift")

swiftc \
    -module-name MacChain \
    -o "$BUILD_DIR/release/macchain" \
    -sdk "$SDK" \
    -target "$TARGET" \
    -O \
    -I "$BUILD_DIR/release" \
    -L "$BUILD_DIR/release" \
    -lMacChainLib \
    -framework Metal \
    -framework Accelerate \
    -framework CryptoKit \
    -swift-version 5 \
    $CLI_FILES

echo "  Done."

# Step 4: Compile Benchmark executable
echo "[4/4] Compiling MacChain Benchmark..."
BENCH_FILES=$(find "$BENCH_SOURCES" -name "*.swift")

swiftc \
    -module-name MacChainBenchmark \
    -o "$BUILD_DIR/release/macchain-bench" \
    -sdk "$SDK" \
    -target "$TARGET" \
    -O \
    -I "$BUILD_DIR/release" \
    -L "$BUILD_DIR/release" \
    -lMacChainLib \
    -framework Metal \
    -framework Accelerate \
    -framework CryptoKit \
    -swift-version 5 \
    $BENCH_FILES

echo "  Done."

echo ""
echo "=== Build complete ==="
echo "  Library:   $BUILD_DIR/release/libMacChainLib.dylib"
echo "  CLI:       $BUILD_DIR/release/macchain"
echo "  Benchmark: $BUILD_DIR/release/macchain-bench"
echo ""
echo "Run: $BUILD_DIR/release/macchain bench"
