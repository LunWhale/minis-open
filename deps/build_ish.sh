#!/bin/bash
set -e

# ============================================================================
# iSH-ARM64 Build Script for iOS Static Library
# ============================================================================
# This script builds libish, libish_emu, and libfakefs as static libraries
# for iOS (arm64) integration, using the ish-arm64 fork which emulates an
# ARM64 Linux guest on iOS.
#
# Repository: https://github.com/OpenMinis/ish-arm64 (branch: feature-arm64)
#
# Prerequisites:
#   - Xcode with iOS SDK
#   - Python 3 with meson (pip3 install meson)
#   - Ninja (brew install ninja)
#   - LLVM/Clang (brew install llvm) - required for VDSO compilation
#   - libarchive (brew install libarchive)
#
# Usage:
#   ./build_ish.sh [clean|debug|release] [--simulator|--all]
#
#   (no flag)     iOS device, arm64            -> deps/libs/
#   --simulator   iOS Simulator, arm64 only    -> deps/libs/iphonesimulator/
#   --all         both of the above
#
# The Xcode target picks the right directory per SDK through ISH_LIBS_DIR
# (deps/libs for iphoneos, deps/libs/iphonesimulator for iphonesimulator), so
# a Simulator build links the simulator copies without any manual switch.
# There is no x86_64 simulator slice: Intel simulators are excluded in Xcode.
#
# Output:
#   deps/libs/      - Static libraries (.a files), device
#   deps/libs/iphonesimulator/ - the same libraries for the Simulator
#   deps/include/   - Header files
#   deps/resources/ - VDSO and other resources
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ISH_DIR="$SCRIPT_DIR/ish"
OUTPUT_LIBS="$SCRIPT_DIR/libs"
OUTPUT_INCLUDE="$SCRIPT_DIR/include"
OUTPUT_RESOURCES="$SCRIPT_DIR/resources"

# Build configuration
BUILD_TYPE="release"
# Platforms to build, in order: iphoneos (device) and/or iphonesimulator.
PLATFORMS="iphoneos"
for arg in "$@"; do
    case "$arg" in
        clean|debug|release) BUILD_TYPE="$arg" ;;
        --simulator) PLATFORMS="iphonesimulator" ;;
        --all) PLATFORMS="iphoneos iphonesimulator" ;;
        *) echo "Unknown argument: $arg (expected clean|debug|release, --simulator, --all)" >&2; exit 1 ;;
    esac
done
ARCHS="arm64"
IOS_DEPLOYMENT_TARGET="14.0"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

log_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

log_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

log_error() {
    echo -e "${RED}❌ $1${NC}"
    exit 1
}

# ============================================================================
# Check Prerequisites
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check for Python 3
    if ! command -v python3 &> /dev/null; then
        log_error "Python 3 is required. Install with: brew install python3"
    fi

    # Check for meson
    if ! command -v meson &> /dev/null; then
        log_error "Meson is required. Install with: pip3 install meson"
    fi

    # Check for ninja
    if ! command -v ninja &> /dev/null; then
        log_error "Ninja is required. Install with: brew install ninja"
    fi

    # Check for Xcode
    if ! xcode-select -p &> /dev/null; then
        log_error "Xcode command line tools are required. Install with: xcode-select --install"
    fi

    # Check for LLVM (needed for VDSO)
    LLVM_CLANG=""
    for clang_path in "/opt/homebrew/opt/llvm/bin/clang" "/usr/local/opt/llvm/bin/clang" "/opt/local/bin/clang"; do
        if [ -x "$clang_path" ]; then
            LLVM_CLANG="$clang_path"
            break
        fi
    done

    if [ -z "$LLVM_CLANG" ]; then
        log_warning "LLVM Clang not found. VDSO may not build correctly."
        log_warning "Install with: brew install llvm"
    else
        log_info "Found LLVM Clang: $LLVM_CLANG"
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Apply Fork Patches
# ============================================================================
# `deps/ish` is a submodule of upstream's ish-arm64 repo, so changes this fork
# needs cannot live in the parent repository's history — and pushing to upstream
# is not an option. They are kept as .patch files here and replayed on every
# build instead. Each patch is skipped when it is already applied, so a dirty
# submodule from a previous run is not an error.
apply_fork_patches() {
    local patch_dir="$SCRIPT_DIR/patches"
    [ -d "$patch_dir" ] || return 0

    log_info "Applying fork patches to $ISH_DIR..."
    cd "$ISH_DIR"

    local applied=0 skipped=0
    for patch in "$patch_dir"/*.patch; do
        [ -e "$patch" ] || continue
        local name
        name="$(basename "$patch")"
        if git apply --check "$patch" 2>/dev/null; then
            git apply "$patch"
            log_success "  applied $name"
            applied=$((applied + 1))
        elif git apply --check --reverse "$patch" 2>/dev/null; then
            log_info "  already applied: $name"
            skipped=$((skipped + 1))
        else
            # Neither applies nor reverses: the submodule moved under us and the
            # patch needs rebasing. Fail loudly rather than build a tree that
            # silently lacks a fix the app depends on.
            log_error "  $name does not apply and is not already applied — rebase it against the current deps/ish pin"
        fi
    done

    cd "$SCRIPT_DIR"
    log_info "Patches: $applied applied, $skipped already present"
}

# ============================================================================
# Initialize Submodules
# ============================================================================
init_submodules() {
    log_info "Initializing iSH submodules..."

    cd "$ISH_DIR"

    if [ ! -d "deps/libapps/.git" ] && [ ! -f "deps/libapps/.git" ]; then
        git submodule update --init --recursive
        log_success "Submodules initialized"
    else
        log_info "Submodules already initialized"
    fi

    cd "$SCRIPT_DIR"
}

# ============================================================================
# Clean Build
# ============================================================================
clean_build() {
    log_info "Cleaning build artifacts..."

    rm -rf "$ISH_DIR/build-ios"
    rm -rf "$ISH_DIR/build-ios-sim"
    rm -rf "$OUTPUT_LIBS"
    rm -rf "$OUTPUT_INCLUDE"
    rm -rf "$OUTPUT_RESOURCES"

    log_success "Clean completed"
}

# ============================================================================
# Select Platform
# ============================================================================
# Sets the per-platform variables every later step reads. Device and Simulator
# get separate meson build directories so switching never reuses objects
# compiled for the other platform.
select_platform() {
    PLATFORM="$1"
    case "$PLATFORM" in
        iphoneos)
            BUILD_DIR="$ISH_DIR/build-ios"
            PLATFORM_LIBS="$OUTPUT_LIBS"
            MIN_VERSION_FLAG="-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
            ;;
        iphonesimulator)
            BUILD_DIR="$ISH_DIR/build-ios-sim"
            PLATFORM_LIBS="$OUTPUT_LIBS/iphonesimulator"
            MIN_VERSION_FLAG="-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
            ;;
        *) log_error "Unknown platform: $PLATFORM" ;;
    esac
    CROSS_FILE="$BUILD_DIR/ios-cross.txt"
}

# ============================================================================
# Setup Cross Compilation
# ============================================================================
setup_cross_compile() {
    log_info "Setting up cross-compilation for $PLATFORM..."

    mkdir -p "$BUILD_DIR"

    # Get the SDK path for this platform
    IOS_SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)

    # Create cross-compilation file for meson
    cat > "$CROSS_FILE" << EOF
[binaries]
c = ['clang', '-arch', 'arm64', '-isysroot', '$IOS_SDK', '$MIN_VERSION_FLAG']
ar = 'ar'
strip = 'strip'
pkg-config = 'false'

[host_machine]
system = 'darwin'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'

[built-in options]
c_args = []
c_link_args = ['-L$IOS_SDK/usr/lib']

[properties]
needs_exe_wrapper = true
sys_root = '$IOS_SDK'
library_dirs = ['$IOS_SDK/usr/lib']
EOF

    log_success "Cross-compilation file created"
}

# ============================================================================
# Build iSH Libraries
# ============================================================================
build_ish() {
    log_info "Building iSH libraries for $PLATFORM ($BUILD_TYPE)..."

    cd "$ISH_DIR"

    # Configure meson build
    MESON_BUILDTYPE="release"
    # meson's `release` buildtype only implies -O3; it does NOT define NDEBUG
    # (that is a separate `b_ndebug` option). Without it every assert() in the
    # kernel stays live in a shipping build, so a failed assertion calls
    # abort() on a user's device instead of being a development-only check.
    # That is how the mem_ptr() CoW assert reached TestFlight as a SIGABRT in
    # sys_execve/args_copy. Keep asserts in debug builds, compile them out of
    # release ones.
    MESON_NDEBUG="true"
    if [ "$BUILD_TYPE" == "debug" ]; then
        MESON_BUILDTYPE="debug"
        MESON_NDEBUG="false"
    fi

    # [T-aojit-needs-images] -Djit=true -Djit_emit=false is an AOT-ONLY runtime:
    # it never maps executable memory and can only run code from the AOT images
    # linked into the app (libish_aot.a). Those images are ~1 GB of assembly and
    # are gitignored, so a fresh clone has none — and an AOT-only libish with
    # zero images can execute no guest instruction at all, which looked like a
    # crash the moment the sandbox started.
    #
    # So: use the AOT runtime only when images are actually present, and
    # otherwise build the plain interpreter — the configuration this fork
    # shipped up to 1.14 and the one that is known to run on device.
    if compgen -G "$SCRIPT_DIR/aot/aot_*.S" > /dev/null; then
        ISH_JIT_FLAGS="-Djit=true -Djit_emit=false"
        log_info "AOT images present: building the AOT-only runtime"
    else
        # [T-aojit-needs-images] No images, so keep the translator ON. This is
        # iSH's default and the configuration the fork shipped up to 1.14:
        # blocks are translated at run time into a dual-mapped (RW + RX views of
        # the same pages) region, which needs no JIT entitlement and no AOT
        # images. Building with -Djit=false instead would drop the whole JIT
        # symbol set the app's crash-recovery path links against.
        ISH_JIT_FLAGS="-Djit=true -Djit_emit=true"
        log_warning "No AOT images in deps/aot: building with the run-time translator (AOJIT unavailable in the app)"
    fi

    # Check if already configured
    if [ ! -f "$BUILD_DIR/build.ninja" ]; then
        log_info "Configuring meson build..."

        meson setup "$BUILD_DIR" \
            --cross-file "$CROSS_FILE" \
            --buildtype="$MESON_BUILDTYPE" \
            -Db_ndebug="$MESON_NDEBUG" \
            -Dlog="" \
            -Dlog_handler=nslog \
            -Dkernel=ish \
            -Dengine=asbestos \
            -Dguest_arch=arm64 \
            $ISH_JIT_FLAGS
    else
        # Reconfigure both options: an existing build-ios/ from before
        # b_ndebug was introduced would otherwise keep asserts enabled.
        log_info "Meson already configured, reconfiguring..."
        meson configure "$BUILD_DIR" \
            --buildtype="$MESON_BUILDTYPE" \
            -Db_ndebug="$MESON_NDEBUG" \
            $ISH_JIT_FLAGS
    fi

    # Build libraries
    log_info "Building with ninja..."
    ninja -C "$BUILD_DIR" libish.a libish_emu.a libfakefs.a

    # Also build VDSO (arm64 guest VDSO is at vdso/arm64/libvdso.so.elf)
    log_info "Building VDSO..."
    ninja -C "$BUILD_DIR" vdso/arm64/libvdso.so.elf || log_warning "VDSO build failed (may need LLVM)"

    cd "$SCRIPT_DIR"
    log_success "iSH libraries built successfully"
}

# ============================================================================
# Copy Output Files
# ============================================================================
# Libraries are per platform; everything else (headers, VDSO, RootfsPatch) is
# the same for device and Simulator and is copied once, by copy_outputs.
copy_libs() {
    log_info "Copying $PLATFORM libraries to $PLATFORM_LIBS..."
    mkdir -p "$PLATFORM_LIBS"
    cp "$BUILD_DIR/libish.a" "$PLATFORM_LIBS/"
    cp "$BUILD_DIR/libish_emu.a" "$PLATFORM_LIBS/"
    cp "$BUILD_DIR/libfakefs.a" "$PLATFORM_LIBS/"
}

copy_outputs() {
    log_info "Copying output files..."

    # Create output directories
    mkdir -p "$OUTPUT_INCLUDE/ish"
    mkdir -p "$OUTPUT_INCLUDE/ish/emu"
    mkdir -p "$OUTPUT_INCLUDE/ish/kernel"
    mkdir -p "$OUTPUT_INCLUDE/ish/fs"
    mkdir -p "$OUTPUT_INCLUDE/ish/fs/proc"
    mkdir -p "$OUTPUT_INCLUDE/ish/util"
    mkdir -p "$OUTPUT_INCLUDE/ish/platform"
    mkdir -p "$OUTPUT_INCLUDE/ish/asbestos"
    mkdir -p "$OUTPUT_RESOURCES"

    # Copy VDSO if built (arm64 guest VDSO path)
    if [ -f "$BUILD_DIR/vdso/arm64/libvdso.so.elf" ]; then
        cp "$BUILD_DIR/vdso/arm64/libvdso.so.elf" "$OUTPUT_RESOURCES/"
        log_success "VDSO copied"
    elif [ -f "$BUILD_DIR/vdso/libvdso.so.elf" ]; then
        cp "$BUILD_DIR/vdso/libvdso.so.elf" "$OUTPUT_RESOURCES/"
        log_success "VDSO copied"
    fi

    # Copy header files
    log_info "Copying header files..."

    # Root headers
    cp "$ISH_DIR/debug.h" "$OUTPUT_INCLUDE/ish/"
    cp "$ISH_DIR/misc.h" "$OUTPUT_INCLUDE/ish/"
    cp "$ISH_DIR/xX_main_Xx.h" "$OUTPUT_INCLUDE/ish/"

    # EMU headers
    cp "$ISH_DIR"/emu/*.h "$OUTPUT_INCLUDE/ish/emu/"

    # Kernel headers
    cp "$ISH_DIR"/kernel/*.h "$OUTPUT_INCLUDE/ish/kernel/"

    # FS headers
    cp "$ISH_DIR"/fs/*.h "$OUTPUT_INCLUDE/ish/fs/"
    if [ -d "$ISH_DIR/fs/proc" ]; then
        cp "$ISH_DIR"/fs/proc/*.h "$OUTPUT_INCLUDE/ish/fs/proc/" 2>/dev/null || true
    fi

    # Util headers
    cp "$ISH_DIR"/util/*.h "$OUTPUT_INCLUDE/ish/util/" 2>/dev/null || true

    # Platform headers
    cp "$ISH_DIR"/platform/*.h "$OUTPUT_INCLUDE/ish/platform/"

    # Asbestos headers
    cp "$ISH_DIR"/asbestos/*.h "$OUTPUT_INCLUDE/ish/asbestos/"
    # ARM64 guest gadgets
    mkdir -p "$OUTPUT_INCLUDE/ish/asbestos/guest-arm64/gadgets-aarch64"
    cp "$ISH_DIR"/asbestos/guest-arm64/gadgets-aarch64/*.h "$OUTPUT_INCLUDE/ish/asbestos/guest-arm64/gadgets-aarch64/" 2>/dev/null || true
    cp "$ISH_DIR"/asbestos/gadgets-generic.h "$OUTPUT_INCLUDE/ish/asbestos/" 2>/dev/null || true

    # ARM64 emu headers
    mkdir -p "$OUTPUT_INCLUDE/ish/emu/arch/arm64"
    cp "$ISH_DIR"/emu/arch/arm64/*.h "$OUTPUT_INCLUDE/ish/emu/arch/arm64/" 2>/dev/null || true

    # ARM64 kernel arch headers
    mkdir -p "$OUTPUT_INCLUDE/ish/kernel/arch/arm64"
    cp "$ISH_DIR"/kernel/arch/arm64/*.h "$OUTPUT_INCLUDE/ish/kernel/arch/arm64/" 2>/dev/null || true

    # Copy generated headers if exist
    if [ -f "$BUILD_DIR/cpu-offsets.h" ]; then
        cp "$BUILD_DIR/cpu-offsets.h" "$OUTPUT_INCLUDE/ish/"
    fi

    # Deps config
    if [ -f "$ISH_DIR/deps/config.h" ]; then
        mkdir -p "$OUTPUT_INCLUDE/ish/deps"
        cp "$ISH_DIR/deps/config.h" "$OUTPUT_INCLUDE/ish/deps/"
    fi

    # Copy RootfsPatch bundle (rootfs overlay patches applied on boot)
    if [ -d "$ISH_DIR/app/RootfsPatch.bundle" ]; then
        cp -r "$ISH_DIR/app/RootfsPatch.bundle" "$OUTPUT_RESOURCES/"
        log_success "RootfsPatch.bundle copied"
    fi

    log_success "Output files copied"
}

# ============================================================================
# Create Umbrella Header
# ============================================================================
create_umbrella_header() {
    log_info "Creating umbrella header..."

    cat > "$OUTPUT_INCLUDE/ish/ish.h" << 'EOF'
/*
 * iSH-ARM64 - Linux shell for iOS (ARM64 guest emulation)
 * Umbrella header for static library integration
 *
 * https://github.com/OpenMinis/ish-arm64
 */

#ifndef ISH_H
#define ISH_H

#include "misc.h"
#include "debug.h"
#include "util/verbosetrace.h"

// Kernel
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "kernel/fs.h"
#include "kernel/memory.h"
#include "kernel/signal.h"
#include "kernel/errno.h"

// File System
#include "fs/fd.h"
#include "fs/stat.h"
#include "fs/tty.h"
#include "fs/fake.h"
#include "fs/real.h"
#include "fs/poll.h"
#include "fs/dev.h"

// EMU
#include "emu/cpu.h"
#include "emu/tlb.h"
#include "emu/mmu.h"
#if defined(GUEST_X86)
#include "emu/float80.h"
#endif

// Platform
#include "platform/platform.h"

#endif /* ISH_H */
EOF

    log_success "Umbrella header created"
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    echo ""
    echo "============================================================"
    echo -e "${GREEN}🎉 iSH-ARM64 Build Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Libraries:"
    ls -lh "$OUTPUT_LIBS"/*.a 2>/dev/null || echo "  (none)"
    if [ -d "$OUTPUT_LIBS/iphonesimulator" ]; then
        echo "Simulator libraries:"
        ls -lh "$OUTPUT_LIBS/iphonesimulator"/*.a 2>/dev/null || echo "  (none)"
    fi
    echo ""
    echo "Headers:   $OUTPUT_INCLUDE/ish/"
    echo "Resources: $OUTPUT_RESOURCES/"
    echo ""
    echo "To integrate with Xcode:"
    echo "  1. Add libs/*.a to 'Link Binary With Libraries'"
    echo "  2. Add include/ to 'Header Search Paths'"
    echo "  3. Add resources/ to 'Copy Bundle Resources'"
    echo "  4. Link with: libsqlite3.tbd"
    echo ""
    echo "============================================================"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  iSH-ARM64 Static Library Builder for iOS"
    echo "  Guest arch: arm64 (aarch64 Linux emulation)"
    echo "============================================================"
    echo ""

    if [ "$BUILD_TYPE" == "clean" ]; then
        clean_build
        exit 0
    fi

    # Check if ish directory exists
    if [ ! -d "$ISH_DIR" ]; then
        log_error "iSH directory not found at $ISH_DIR"
    fi

    check_prerequisites
    init_submodules
    apply_fork_patches
    for platform in $PLATFORMS; do
        select_platform "$platform"
        setup_cross_compile
        build_ish
        copy_libs
        # Headers and resources are platform-independent. They come from the
        # device build, so a --simulator run never swaps the headers out from
        # under device libraries built from an older deps/ish; it only fills
        # them in when nothing has been built yet.
        if [ "$PLATFORM" == "iphoneos" ] || [ ! -f "$OUTPUT_INCLUDE/ish/ish.h" ]; then
            copy_outputs
            create_umbrella_header
        fi
        # [T-ios-aojit] AOT images (deps/aot/aot_*.S) -> <platform libs>/libish_aot.a.
        # Always produced (a stub when there are no images), because the app
        # force-loads it: an image registers itself from a constructor, and a
        # plain -l would drop objects nothing references.
        IOS_DEPLOYMENT_TARGET="$IOS_DEPLOYMENT_TARGET" PLATFORM="$PLATFORM" \
            bash "$SCRIPT_DIR/build_aot.sh"
    done
    print_summary
}

main "$@"
