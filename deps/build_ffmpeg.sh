#!/bin/bash
set -e

# ============================================================================
# FFmpeg 6.1.2 Build Script for iOS Dynamic Framework
# ============================================================================
# Builds FFmpeg as individual .framework bundles plus an umbrella framework
# (FFmpeg.framework) for iOS arm64 with VideoToolbox hardware encoding/decoding.
#
# Each FFmpeg library (libavcodec, libavformat, etc.) is wrapped as its own
# .framework bundle in deps/frameworks/. The umbrella FFmpeg.framework is a
# thin wrapper that re-exports them and includes fftools (ffmpeg_main).
#
# The main() symbol in fftools/ffmpeg.c is renamed to ffmpeg_main() to
# avoid conflicts with the iOS app's entry point.
#
# Prerequisites:
#   - Xcode with iOS SDK
#   - pkg-config (brew install pkg-config) - optional
#
# Usage:
#   ./build_ffmpeg.sh [clean] [--simulator]
#   ./build_ffmpeg.sh --xcframeworks     only rewrap existing frameworks
#
# Output:
#   deps/frameworks/FFmpeg.framework/                          (device)
#   deps/frameworks/lib{avcodec,avformat,avutil,avfilter,swresample,swscale}.framework/
#   deps/frameworks/iphonesimulator/*.framework                (--simulator, arm64)
#   deps/frameworks/*.xcframework   what Xcode links and embeds: every platform
#                                   built so far, rewrapped after each run
#
# The Simulator build runs in its own copy of the patched source tree
# (ffmpeg-6.1.2-iphonesimulator/): FFmpeg configures in place and refuses an
# out-of-tree build once the device build has configured the source tree.
# MP3 encoding needs ./build_lame.sh --simulator first.
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FFMPEG_DIR="$SCRIPT_DIR/ffmpeg-6.1.2"
BUILD_DIR="$FFMPEG_DIR/build-ios"
FRAMEWORK_DIR="$SCRIPT_DIR/frameworks/FFmpeg.framework"
FRAMEWORKS_BASE="$SCRIPT_DIR/frameworks"

IOS_DEPLOYMENT_TARGET="14.0"

# Platform: iphoneos (default) or iphonesimulator (--simulator).
PLATFORM="iphoneos"
CLEAN=0
XCFRAMEWORKS_ONLY=0
for arg in "$@"; do
    case "$arg" in
        clean) CLEAN=1 ;;
        --simulator) PLATFORM="iphonesimulator" ;;
        --xcframeworks) XCFRAMEWORKS_ONLY=1 ;;
        *) echo "Unknown argument: $arg (expected clean, --simulator, --xcframeworks)" >&2; exit 1 ;;
    esac
done
PATCH_SOURCE_DIR="$FFMPEG_DIR"   # the tree the patches are applied to
MIN_FLAG="-miphoneos-version-min=$IOS_DEPLOYMENT_TARGET"
PLIST_PLATFORM="iPhoneOS"
LAME_DIR="$SCRIPT_DIR/lame-build"
if [ "$PLATFORM" == "iphonesimulator" ]; then
    FFMPEG_DIR="$SCRIPT_DIR/ffmpeg-6.1.2-iphonesimulator"
    BUILD_DIR="$FFMPEG_DIR/build-ios"
    FRAMEWORKS_BASE="$SCRIPT_DIR/frameworks/iphonesimulator"
    FRAMEWORK_DIR="$FRAMEWORKS_BASE/FFmpeg.framework"
    MIN_FLAG="-mios-simulator-version-min=$IOS_DEPLOYMENT_TARGET"
    PLIST_PLATFORM="iPhoneSimulator"
    LAME_DIR="$SCRIPT_DIR/lame-build-iphonesimulator"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

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
# Clean Build
# ============================================================================
clean_build() {
    log_info "Cleaning build artifacts..."

    rm -rf "$BUILD_DIR"
    rm -rf "$FRAMEWORK_DIR"
    rm -rf "$FRAMEWORKS_BASE"/lib*.framework
    rm -rf "$SCRIPT_DIR/ffmpeg-6.1.2-iphonesimulator" "$SCRIPT_DIR/frameworks/iphonesimulator"
    rm -rf "$FRAMEWORKS_BASE"/*.xcframework

    # Revert main rename patch if applied
    if [ -f "$FFMPEG_DIR/fftools/ffmpeg.c" ]; then
        cd "$FFMPEG_DIR"
        git checkout -- fftools/ffmpeg.c 2>/dev/null || true
        cd "$SCRIPT_DIR"
    fi

    # Revert source patches from ffmpeg-patch/*.patch (reverse order)
    shopt -s nullglob
    local patches=("$SCRIPT_DIR/ffmpeg-patch"/*.patch)
    shopt -u nullglob
    for ((i=${#patches[@]}-1; i>=0; i--)); do
        local p="${patches[$i]}"
        if (cd "$FFMPEG_DIR" && patch -p1 -R --dry-run -s -f < "$p") >/dev/null 2>&1; then
            (cd "$FFMPEG_DIR" && patch -p1 -R -s < "$p")
        fi
    done

    log_success "Clean completed"
}

# ============================================================================
# Check Prerequisites
# ============================================================================
check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! xcode-select -p &> /dev/null; then
        log_error "Xcode command line tools are required. Install with: xcode-select --install"
    fi

    # The FFmpeg source tree is not tracked in git (it is upstream source, not
    # ours), so fetch it on first run instead of failing on a fresh clone.
    if [ ! -d "$PATCH_SOURCE_DIR" ]; then
        fetch_ffmpeg_source
    fi

    log_success "Prerequisites check passed"
}

# ============================================================================
# Download the FFmpeg release tarball (first run / fresh clone)
# ============================================================================
fetch_ffmpeg_source() {
    local version="6.1.2"
    local tarball="ffmpeg-${version}.tar.xz"
    local url="https://ffmpeg.org/releases/${tarball}"
    local tmp
    tmp="$(mktemp -d)"

    log_info "FFmpeg source not present — downloading ${version}..."
    if ! curl -fL# "$url" -o "$tmp/$tarball"; then
        rm -rf "$tmp"
        log_error "Failed to download $url — check your network, or place the source at $FFMPEG_DIR manually."
    fi

    log_info "Extracting..."
    if ! tar -xf "$tmp/$tarball" -C "$tmp"; then
        rm -rf "$tmp"
        log_error "Failed to extract $tarball"
    fi

    mv "$tmp/ffmpeg-${version}" "$PATCH_SOURCE_DIR"
    rm -rf "$tmp"
    log_success "FFmpeg ${version} source ready at $PATCH_SOURCE_DIR"
}

# ============================================================================
# Patch ffmpeg main -> ffmpeg_main
# ============================================================================
patch_main_symbol() {
    log_info "Patching main() -> ffmpeg_main() in fftools/ffmpeg.c..."

    FFMPEG_C="$PATCH_SOURCE_DIR/fftools/ffmpeg.c"

    if grep -q 'int ffmpeg_main(' "$FFMPEG_C"; then
        log_info "Already patched, skipping"
        return
    fi

    sed -i '' 's/^int main(int argc, char \*\*argv)/int ffmpeg_main(int argc, char **argv)/' "$FFMPEG_C"

    if grep -q 'int ffmpeg_main(' "$FFMPEG_C"; then
        log_success "main() renamed to ffmpeg_main()"
    else
        log_error "Failed to patch main() in ffmpeg.c"
    fi
}

# ============================================================================
# Apply source patches from ffmpeg-patch/*.patch
# ============================================================================
apply_source_patches() {
    local patch_dir="$SCRIPT_DIR/ffmpeg-patch"

    shopt -s nullglob
    local patches=("$patch_dir"/*.patch)
    shopt -u nullglob

    if [ ${#patches[@]} -eq 0 ]; then
        return
    fi

    log_info "Applying FFmpeg source patches..."

    for p in "${patches[@]}"; do
        local name; name="$(basename "$p")"
        # Idempotent: skip if already applied (reverse dry-run succeeds)
        if (cd "$PATCH_SOURCE_DIR" && patch -p1 -R --dry-run -s -f < "$p") >/dev/null 2>&1; then
            log_info "  $name — already applied, skipping"
            continue
        fi
        if ! (cd "$PATCH_SOURCE_DIR" && patch -p1 --dry-run -s -f < "$p") >/dev/null 2>&1; then
            log_error "  $name — cannot apply cleanly"
        fi
        (cd "$PATCH_SOURCE_DIR" && patch -p1 -s < "$p")
        log_success "  $name"
    done
}

# ============================================================================
# Simulator: a separate copy of the patched source tree
# ============================================================================
prepare_platform_source() {
    [ "$PLATFORM" == "iphonesimulator" ] || return 0
    log_info "Preparing a separate source tree for the Simulator..."
    # A fresh copy each time, so nothing configured for the device survives.
    rm -rf "$FFMPEG_DIR"
    rsync -a --exclude 'build-ios' --exclude '*.o' --exclude '*.d' --exclude '*.dylib' \
        --exclude '*.a' "$PATCH_SOURCE_DIR/" "$FFMPEG_DIR/"
    (cd "$FFMPEG_DIR" && { [ ! -f ffbuild/config.mak ] || make distclean >/dev/null 2>&1 || true; })
    rm -f "$FFMPEG_DIR/config.h" "$FFMPEG_DIR/ffbuild/config.mak"
    log_success "Simulator source tree ready at $FFMPEG_DIR"
}

# ============================================================================
# Configure FFmpeg
# ============================================================================
configure_ffmpeg() {
    log_info "Configuring FFmpeg for $PLATFORM arm64..."

    IOS_SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
    CC="$(xcrun --sdk "$PLATFORM" -f clang)"

    mkdir -p "$BUILD_DIR"

    cd "$FFMPEG_DIR"

    # Check for libmp3lame (built by build_lame.sh)
    LAME_FLAGS=""
    if [ -f "$LAME_DIR/lib/libmp3lame.a" ]; then
        log_info "Found libmp3lame — enabling MP3 encoding"
        LAME_FLAGS="--enable-libmp3lame"
        LAME_CFLAGS="-I$LAME_DIR/include"
        LAME_LDFLAGS="-L$LAME_DIR/lib"
    else
        log_warning "libmp3lame not found — MP3 encoding will be unavailable"
        log_warning "Run ./build_lame.sh first to enable MP3 encoding"
        LAME_CFLAGS=""
        LAME_LDFLAGS=""
    fi

    ./configure \
        --prefix="$BUILD_DIR/install" \
        --enable-cross-compile \
        --arch=arm64 \
        --target-os=darwin \
        --cc="$CC" \
        --sysroot="$IOS_SDK" \
        --extra-cflags="-arch arm64 $MIN_FLAG -fembed-bitcode -DCONFIG_FFMPEG_MAIN=1 $LAME_CFLAGS" \
        --extra-ldflags="-arch arm64 $MIN_FLAG -isysroot $IOS_SDK $LAME_LDFLAGS" \
        --enable-pic \
        --enable-videotoolbox \
        --enable-hwaccel=h264_videotoolbox \
        --enable-hwaccel=hevc_videotoolbox \
        $LAME_FLAGS \
        --enable-shared \
        --disable-static \
        --disable-programs \
        --disable-doc \
        --disable-debug \
        --enable-optimizations \
        --enable-small \
        --disable-avdevice \
        --disable-postproc \
        --enable-network \
        --enable-securetransport \
        --disable-devices \
        --disable-protocols \
        --enable-protocol=file \
        --enable-protocol=pipe \
        --enable-protocol=http \
        --enable-protocol=https \
        --enable-protocol=hls \
        --enable-protocol=tcp \
        --enable-protocol=tls \
        --enable-demuxer=hls \
        --disable-filter=scale_vt \
        --install-name-dir='@rpath'

    cd "$SCRIPT_DIR"
    log_success "FFmpeg configured"
}

# ============================================================================
# Build FFmpeg
# ============================================================================
build_ffmpeg() {
    log_info "Building FFmpeg..."

    cd "$FFMPEG_DIR"
    make -j$(sysctl -n hw.ncpu)
    make install
    cd "$SCRIPT_DIR"

    log_success "FFmpeg built and installed"
}

# ============================================================================
# Build fftools (ffmpeg_main and supporting code)
# ============================================================================
build_fftools() {
    log_info "Building fftools (ffmpeg_main)..."

    IOS_SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
    CC="$(xcrun --sdk "$PLATFORM" -f clang)"
    INSTALL_DIR="$BUILD_DIR/install"

    FFTOOLS_OBJ_DIR="$BUILD_DIR/fftools-objs"
    mkdir -p "$FFTOOLS_OBJ_DIR"

    # ── Copy stdio redirect patch into fftools/ ──
    log_info "Copying stdio redirect patch files..."
    cp "$SCRIPT_DIR/ffmpeg-patch/fftools_stdio_redirect.h" "$FFMPEG_DIR/fftools/"
    cp "$SCRIPT_DIR/ffmpeg-patch/fftools_stdio_redirect.c" "$FFMPEG_DIR/fftools/"

    # fftools source files needed for ffmpeg
    FFTOOLS_SRCS=(
        fftools/ffmpeg.c
        fftools/ffmpeg_dec.c
        fftools/ffmpeg_demux.c
        fftools/ffmpeg_enc.c
        fftools/ffmpeg_filter.c
        fftools/ffmpeg_hw.c
        fftools/ffmpeg_mux.c
        fftools/ffmpeg_mux_init.c
        fftools/ffmpeg_opt.c
        fftools/objpool.c
        fftools/sync_queue.c
        fftools/thread_queue.c
        fftools/cmdutils.c
        fftools/opt_common.c
    )

    # Common CFLAGS: use the source tree for headers (has config.h, libav* headers, and libavdevice)
    FFTOOLS_CFLAGS="-arch arm64 $MIN_FLAG -isysroot $IOS_SDK"
    FFTOOLS_CFLAGS="$FFTOOLS_CFLAGS -I$FFMPEG_DIR -I$INSTALL_DIR/include"
    FFTOOLS_CFLAGS="$FFTOOLS_CFLAGS -DCONFIG_FFMPEG_MAIN=1 -Oz -fPIC"
    # Force-include the stdio redirect header so all fprintf/printf/fputs/vfprintf
    # calls in fftools are transparently intercepted without modifying ffmpeg source.
    FFTOOLS_CFLAGS="$FFTOOLS_CFLAGS -include fftools/fftools_stdio_redirect.h"

    cd "$FFMPEG_DIR"

    FFTOOLS_OBJS=()
    for src in "${FFTOOLS_SRCS[@]}"; do
        OBJ_NAME=$(basename "${src%.c}.o")
        log_info "  Compiling $src..."
        $CC $FFTOOLS_CFLAGS -c "$src" -o "$FFTOOLS_OBJ_DIR/$OBJ_NAME"
        FFTOOLS_OBJS+=("$FFTOOLS_OBJ_DIR/$OBJ_NAME")
    done

    # Compile the stdio redirect implementation WITHOUT the -include flag
    # to avoid recursive macro expansion.
    log_info "  Compiling fftools/fftools_stdio_redirect.c..."
    REDIRECT_CFLAGS="-arch arm64 $MIN_FLAG -isysroot $IOS_SDK"
    REDIRECT_CFLAGS="$REDIRECT_CFLAGS -I$FFMPEG_DIR -I$INSTALL_DIR/include -Oz -fPIC"
    $CC $REDIRECT_CFLAGS -c fftools/fftools_stdio_redirect.c -o "$FFTOOLS_OBJ_DIR/fftools_stdio_redirect.o"
    FFTOOLS_OBJS+=("$FFTOOLS_OBJ_DIR/fftools_stdio_redirect.o")

    # Create a static archive of fftools objects
    ar rcs "$BUILD_DIR/libfftools.a" "${FFTOOLS_OBJS[@]}"

    cd "$SCRIPT_DIR"
    log_success "fftools built ($(echo ${#FFTOOLS_SRCS[@]}) source files)"
}

# ============================================================================
# Package as individual .framework bundles + umbrella FFmpeg.framework
# ============================================================================
package_framework() {
    log_info "Packaging individual .framework bundles + FFmpeg.framework..."

    INSTALL_DIR="$BUILD_DIR/install"
    IOS_SDK=$(xcrun --sdk "$PLATFORM" --show-sdk-path)
    CC="$(xcrun --sdk "$PLATFORM" -f clang)"

    # Clean previous output
    rm -rf "$FRAMEWORK_DIR"
    rm -rf "$FRAMEWORKS_BASE"/lib*.framework
    mkdir -p "$FRAMEWORK_DIR/Headers"

    # Library list and header mapping
    LIBS=(avcodec avformat avutil avfilter swresample swscale)

    # Collect source dylib paths and their original install names
    declare -a REAL_DYLIBS
    declare -a ORIG_INSTALL_NAMES
    for lib in "${LIBS[@]}"; do
        REAL_DYLIB=$(find "$INSTALL_DIR/lib" -name "lib${lib}.*.*.*.dylib" -not -type l | head -1)
        if [ -z "$REAL_DYLIB" ] || [ ! -f "$REAL_DYLIB" ]; then
            log_error "lib${lib} dylib not found in $INSTALL_DIR/lib"
        fi
        ORIG_INSTALL_NAMES+=("$(otool -D "$REAL_DYLIB" | tail -1)")
        REAL_DYLIBS+=("$REAL_DYLIB")
        log_info "Found: $(basename "$REAL_DYLIB")"
    done

    # ── Create individual .framework bundles ──
    for idx in "${!LIBS[@]}"; do
        lib="${LIBS[$idx]}"
        FW_NAME="lib${lib}"
        FW_DIR="$FRAMEWORKS_BASE/${FW_NAME}.framework"
        mkdir -p "$FW_DIR/Headers"

        log_info "Creating ${FW_NAME}.framework..."

        # Copy dylib as framework binary
        cp "${REAL_DYLIBS[$idx]}" "$FW_DIR/$FW_NAME"

        # Set install name to framework path
        install_name_tool -id "@rpath/${FW_NAME}.framework/$FW_NAME" "$FW_DIR/$FW_NAME"

        # Fix inter-library references to point to framework paths
        for j in "${!LIBS[@]}"; do
            OTHER="lib${LIBS[$j]}"
            install_name_tool -change "${ORIG_INSTALL_NAMES[$j]}" \
                "@rpath/${OTHER}.framework/$OTHER" \
                "$FW_DIR/$FW_NAME" 2>/dev/null || true
        done

        # Copy headers
        if [ -d "$INSTALL_DIR/include/$FW_NAME" ]; then
            cp -R "$INSTALL_DIR/include/$FW_NAME/"* "$FW_DIR/Headers/"
        fi

        # Create Info.plist
        cat > "$FW_DIR/Info.plist" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>${FW_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>org.ffmpeg.${FW_NAME}</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>${FW_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>6.1.2</string>
    <key>CFBundleVersion</key>
    <string>6.1.2</string>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${PLIST_PLATFORM}</string>
    </array>
</dict>
</plist>
PLISTEOF

        # Code sign
        codesign --force --sign - "$FW_DIR"
        log_success "${FW_NAME}.framework created"
    done

    # ── Create umbrella FFmpeg.framework ──
    log_info "Creating umbrella FFmpeg.framework (with ffmpeg_main)..."

    REEXPORT_FLAGS=""
    for lib in "${LIBS[@]}"; do
        FW_NAME="lib${lib}"
        REEXPORT_FLAGS="$REEXPORT_FLAGS -Wl,-reexport_library,$FRAMEWORKS_BASE/${FW_NAME}.framework/$FW_NAME"
    done

    # Link fftools static archive into the umbrella dylib
    # -force_load ensures all symbols (including ffmpeg_main) are included
    $CC -arch arm64 \
        $MIN_FLAG \
        -isysroot "$IOS_SDK" \
        -dynamiclib \
        -install_name @rpath/FFmpeg.framework/FFmpeg \
        -o "$FRAMEWORK_DIR/FFmpeg" \
        -Wl,-force_load,"$BUILD_DIR/libfftools.a" \
        $REEXPORT_FLAGS \
        -framework VideoToolbox \
        -framework CoreMedia \
        -framework CoreVideo \
        -framework CoreFoundation \
        -framework CoreServices \
        -framework Security \
        -framework AudioToolbox \
        -lz \
        -lbz2 \
        -liconv

    # Fix umbrella re-export references to use framework paths
    for idx in "${!LIBS[@]}"; do
        FW_NAME="lib${LIBS[$idx]}"
        install_name_tool -change "${ORIG_INSTALL_NAMES[$idx]}" \
            "@rpath/${FW_NAME}.framework/$FW_NAME" \
            "$FRAMEWORK_DIR/FFmpeg" 2>/dev/null || true
    done

    # Copy headers into umbrella framework
    log_info "Copying headers..."
    for lib in "${LIBS[@]}"; do
        FW_NAME="lib${lib}"
        if [ -d "$INSTALL_DIR/include/$FW_NAME" ]; then
            cp -R "$INSTALL_DIR/include/$FW_NAME" "$FRAMEWORK_DIR/Headers/"
        fi
    done

    # Create umbrella header
    cat > "$FRAMEWORK_DIR/Headers/FFmpeg.h" << 'EOF'
/*
 * FFmpeg.framework - Umbrella Header
 * FFmpeg 6.1.2 built for iOS arm64 with VideoToolbox
 */

#ifndef FFMPEG_FRAMEWORK_H
#define FFMPEG_FRAMEWORK_H

#include "libavutil/avutil.h"
#include "libavutil/opt.h"
#include "libavutil/imgutils.h"
#include "libavutil/pixdesc.h"
#include "libavutil/hwcontext.h"
#include "libavutil/hwcontext_videotoolbox.h"

#include "libavcodec/avcodec.h"

#include "libavformat/avformat.h"

#include "libavfilter/avfilter.h"

#include "libswscale/swscale.h"

#include "libswresample/swresample.h"

// ffmpeg_main - renamed from main() to avoid symbol conflict
int ffmpeg_main(int argc, char **argv);

// Reset all file-scope and function-local statics in ffmpeg.c
// so ffmpeg_main() can be safely called more than once.
void ffmpeg_reset_statics(void);

#endif /* FFMPEG_FRAMEWORK_H */
EOF

    # Create Info.plist
    cat > "$FRAMEWORK_DIR/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>FFmpeg</string>
    <key>CFBundleIdentifier</key>
    <string>org.ffmpeg.FFmpeg</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>FFmpeg</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>6.1.2</string>
    <key>CFBundleVersion</key>
    <string>6.1.2</string>
    <key>MinimumOSVersion</key>
    <string>14.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${PLIST_PLATFORM}</string>
    </array>
</dict>
</plist>
EOF

    # Code sign umbrella framework
    log_info "Code signing FFmpeg.framework..."
    codesign --force --sign - "$FRAMEWORK_DIR"

    log_success "All frameworks packaged"
}

# ============================================================================
# Wrap the frameworks into .xcframework bundles
# ============================================================================
# The app references deps/frameworks/<name>.xcframework, so Xcode picks the
# device or Simulator slice from the build destination for both linking and
# embedding. Rebuilt from whatever platforms exist after every run: a machine
# that only ever builds for devices gets a device-only xcframework.
make_xcframeworks() {
    local base="$SCRIPT_DIR/frameworks"
    log_info "Packaging .xcframework bundles..."
    for name in FFmpeg libavcodec libavformat libavutil libavfilter libswresample libswscale; do
        local args=()
        for dir in "$base" "$base/iphonesimulator"; do
            [ -d "$dir/$name.framework" ] && args+=(-framework "$dir/$name.framework")
        done
        if [ ${#args[@]} -eq 0 ]; then
            log_warning "$name.framework not built for any platform, skipping"
            continue
        fi
        rm -rf "$base/$name.xcframework"
        xcodebuild -create-xcframework "${args[@]}" -output "$base/$name.xcframework" >/dev/null \
            || log_error "xcodebuild -create-xcframework failed for $name"
        log_success "$name.xcframework ($(( ${#args[@]} / 2 )) platform(s))"
    done
}

# ============================================================================
# Print Summary
# ============================================================================
print_summary() {
    echo ""
    echo "============================================================"
    echo -e "${GREEN}🎉 FFmpeg 6.1.2 iOS Framework Build Complete!${NC}"
    echo "============================================================"
    echo ""
    echo "Umbrella: $FRAMEWORK_DIR"
    ls -lh "$FRAMEWORK_DIR/FFmpeg" 2>/dev/null
    echo ""
    echo "Individual frameworks:"
    for lib in avcodec avformat avutil avfilter swresample swscale; do
        FW="$FRAMEWORKS_BASE/lib${lib}.framework/lib${lib}"
        if [ -f "$FW" ]; then
            echo -e "  ${GREEN}✅${NC} lib${lib}.framework  $(ls -lh "$FW" | awk '{print $5}')"
        else
            echo -e "  ${RED}❌${NC} lib${lib}.framework  MISSING"
        fi
    done
    echo ""
    echo "Architecture:"
    file "$FRAMEWORK_DIR/FFmpeg"
    echo ""

    # Verify ffmpeg_main symbol
    if nm "$FRAMEWORK_DIR/FFmpeg" 2>/dev/null | grep -q ffmpeg_main; then
        echo -e "${GREEN}✅ ffmpeg_main symbol found${NC}"
    else
        echo -e "${YELLOW}⚠️  ffmpeg_main symbol not in merged binary (expected if --disable-programs)${NC}"
    fi

    echo ""
    echo "============================================================"
}

# ============================================================================
# Main
# ============================================================================
main() {
    echo ""
    echo "============================================================"
    echo "  FFmpeg 6.1.2 iOS Dynamic Framework Builder"
    echo "  Target: arm64, iOS $IOS_DEPLOYMENT_TARGET+"
    echo "  Features: VideoToolbox hardware encoding/decoding"
    echo "============================================================"
    echo ""

    if [ "$CLEAN" == "1" ]; then
        clean_build
        exit 0
    fi
    if [ "$XCFRAMEWORKS_ONLY" == "1" ]; then
        make_xcframeworks
        exit 0
    fi

    check_prerequisites
    patch_main_symbol
    apply_source_patches
    prepare_platform_source
    configure_ffmpeg
    build_ffmpeg
    build_fftools
    package_framework
    make_xcframeworks
    print_summary
}

main "$@"
