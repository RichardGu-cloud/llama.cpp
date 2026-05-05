#!/usr/bin/env bash
#
# Revol custom build-xcframework.sh
#
# 改动 (相对官方):
#   1. LLAMA_BUILD_TOOLS=ON                 -- 编 mtmd
#   2. LLAMA_BUILD_COMMON=ON                -- mtmd 依赖 common
#   3. headers 加 mtmd.h / mtmd-helper.h
#   4. module.modulemap 加 mtmd headers
#   5. libs 数组加 libcommon.a / libmtmd.a / libmtmd_helper.a
#   6. 砍掉 visionOS / tvOS (Revol 是 macOS app, 用不到)
#

# Options
IOS_MIN_OS_VERSION=16.4
MACOS_MIN_OS_VERSION=13.3

BUILD_SHARED_LIBS=OFF
LLAMA_BUILD_EXAMPLES=OFF
LLAMA_BUILD_TOOLS=ON
LLAMA_BUILD_TESTS=OFF
LLAMA_BUILD_SERVER=OFF
LLAMA_BUILD_COMMON=ON
GGML_METAL=ON
GGML_METAL_EMBED_LIBRARY=ON
GGML_BLAS_DEFAULT=ON
GGML_METAL_USE_BF16=ON
GGML_OPENMP=OFF

COMMON_C_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"
COMMON_CXX_FLAGS="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g"

COMMON_CMAKE_ARGS=(
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
    -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEBUG_INFORMATION_FORMAT="dwarf-with-dsym"
    -DCMAKE_XCODE_ATTRIBUTE_GCC_GENERATE_DEBUGGING_SYMBOLS=YES
    -DCMAKE_XCODE_ATTRIBUTE_COPY_PHASE_STRIP=NO
    -DCMAKE_XCODE_ATTRIBUTE_STRIP_INSTALLED_PRODUCT=NO
    -DCMAKE_XCODE_ATTRIBUTE_DEVELOPMENT_TEAM=ggml
    -DBUILD_SHARED_LIBS=${BUILD_SHARED_LIBS}
    -DLLAMA_BUILD_EXAMPLES=${LLAMA_BUILD_EXAMPLES}
    -DLLAMA_BUILD_TOOLS=${LLAMA_BUILD_TOOLS}
    -DLLAMA_BUILD_TESTS=${LLAMA_BUILD_TESTS}
    -DLLAMA_BUILD_SERVER=${LLAMA_BUILD_SERVER}
    -DLLAMA_BUILD_COMMON=${LLAMA_BUILD_COMMON}
    -DGGML_METAL_EMBED_LIBRARY=${GGML_METAL_EMBED_LIBRARY}
    -DGGML_BLAS_DEFAULT=${GGML_BLAS_DEFAULT}
    -DGGML_METAL=${GGML_METAL}
    -DGGML_METAL_USE_BF16=${GGML_METAL_USE_BF16}
    -DGGML_NATIVE=OFF
    -DGGML_OPENMP=${GGML_OPENMP}
)

check_required_tool() {
    local tool=$1
    local install_message=$2
    if ! command -v $tool &> /dev/null; then
        echo "Error: $tool is required but not found."
        echo "$install_message"
        exit 1
    fi
}

echo "Checking for required tools..."
check_required_tool "cmake" "Please install CMake 3.28.0 or later (brew install cmake)"
check_required_tool "xcrun" "Please install Xcode and Xcode Command Line Tools (xcode-select --install)"

XCODE_VERSION=$(xcrun xcodebuild -version 2>/dev/null | head -n1 | awk '{ print $2 }')
MAJOR_VERSION=$(echo $XCODE_VERSION | cut -d. -f1)
MINOR_VERSION=$(echo $XCODE_VERSION | cut -d. -f2)
echo "Detected Xcode version: $XCODE_VERSION"

set -e

# Clean up previous builds
rm -rf build-apple
rm -rf build-ios-sim
rm -rf build-ios-device
rm -rf build-macos

# Setup the xcframework build directory structure
setup_framework_structure() {
    local build_dir=$1
    local min_os_version=$2
    local platform=$3  # "ios" or "macos"
    local framework_name="llama"

    echo "Creating ${platform}-style framework structure for ${build_dir}"

    if [[ "$platform" == "macos" ]]; then
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Headers
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Modules
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Versions/A/Resources

        ln -sf A ${build_dir}/framework/${framework_name}.framework/Versions/Current
        ln -sf Versions/Current/Headers ${build_dir}/framework/${framework_name}.framework/Headers
        ln -sf Versions/Current/Modules ${build_dir}/framework/${framework_name}.framework/Modules
        ln -sf Versions/Current/Resources ${build_dir}/framework/${framework_name}.framework/Resources
        ln -sf Versions/Current/${framework_name} ${build_dir}/framework/${framework_name}.framework/${framework_name}

        local header_path=${build_dir}/framework/${framework_name}.framework/Versions/A/Headers/
        local module_path=${build_dir}/framework/${framework_name}.framework/Versions/A/Modules/
    else
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Headers
        mkdir -p ${build_dir}/framework/${framework_name}.framework/Modules
        rm -rf ${build_dir}/framework/${framework_name}.framework/Versions

        local header_path=${build_dir}/framework/${framework_name}.framework/Headers/
        local module_path=${build_dir}/framework/${framework_name}.framework/Modules/
    fi

    # Headers
    cp include/llama.h             ${header_path}
    cp ggml/include/ggml.h         ${header_path}
    cp ggml/include/ggml-opt.h     ${header_path}
    cp ggml/include/ggml-alloc.h   ${header_path}
    cp ggml/include/ggml-backend.h ${header_path}
    cp ggml/include/ggml-metal.h   ${header_path}
    cp ggml/include/ggml-cpu.h     ${header_path}
    cp ggml/include/ggml-blas.h    ${header_path}
    cp ggml/include/gguf.h         ${header_path}
    # mtmd headers
    cp tools/mtmd/mtmd.h           ${header_path}
    if [ -f tools/mtmd/mtmd-helper.h ]; then
        cp tools/mtmd/mtmd-helper.h    ${header_path}
        local has_mtmd_helper_header=1
    else
        echo "  (mtmd-helper.h 在这个版本不存在, 跳过)"
        local has_mtmd_helper_header=0
    fi

    # Module map (条件性加 mtmd-helper.h)
    local mtmd_helper_header_line=""
    if [ "$has_mtmd_helper_header" = "1" ]; then
        mtmd_helper_header_line='    header "mtmd-helper.h"'
    fi
    cat > ${module_path}module.modulemap << EOF
framework module llama {
    header "llama.h"
    header "ggml.h"
    header "ggml-alloc.h"
    header "ggml-backend.h"
    header "ggml-metal.h"
    header "ggml-cpu.h"
    header "ggml-blas.h"
    header "gguf.h"
    header "mtmd.h"
${mtmd_helper_header_line}

    link "c++"
    link framework "Accelerate"
    link framework "Metal"
    link framework "Foundation"

    export *
}
EOF

    # Info.plist
    local platform_name=""
    local sdk_name=""
    local supported_platform=""

    case "$platform" in
        "ios")
            platform_name="iphoneos"
            sdk_name="iphoneos${min_os_version}"
            supported_platform="iPhoneOS"
            local plist_path="${build_dir}/framework/${framework_name}.framework/Info.plist"
            local device_family='    <key>UIDeviceFamily</key>
    <array>
        <integer>1</integer>
        <integer>2</integer>
    </array>'
            ;;
        "macos")
            platform_name="macosx"
            sdk_name="macosx${min_os_version}"
            supported_platform="MacOSX"
            local plist_path="${build_dir}/framework/${framework_name}.framework/Versions/A/Resources/Info.plist"
            local device_family=""
            ;;
    esac

    cat > ${plist_path} << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>llama</string>
    <key>CFBundleIdentifier</key>
    <string>org.ggml.llama</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>llama</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>${min_os_version}</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>${supported_platform}</string>
    </array>${device_family}
    <key>DTPlatformName</key>
    <string>${platform_name}</string>
    <key>DTSDKName</key>
    <string>${sdk_name}</string>
</dict>
</plist>
EOF
}

# Combine static libraries into a dynamic framework binary
combine_static_libraries() {
    local build_dir="$1"
    local release_dir="$2"
    local platform="$3"  # "ios" or "macos"
    local is_simulator="$4"
    local base_dir="$(pwd)"
    local framework_name="llama"

    local output_lib=""
    if [[ "$platform" == "macos" ]]; then
        output_lib="${build_dir}/framework/${framework_name}.framework/Versions/A/${framework_name}"
    else
        output_lib="${build_dir}/framework/${framework_name}.framework/${framework_name}"
    fi

    local libs=(
        "${base_dir}/${build_dir}/src/${release_dir}/libllama.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-base.a"
        "${base_dir}/${build_dir}/ggml/src/${release_dir}/libggml-cpu.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-metal/${release_dir}/libggml-metal.a"
        "${base_dir}/${build_dir}/ggml/src/ggml-blas/${release_dir}/libggml-blas.a"
        "${base_dir}/${build_dir}/common/${release_dir}/libllama-common.a"
        "${base_dir}/${build_dir}/tools/mtmd/${release_dir}/libmtmd.a"
    )

    # ⚠️ Debug: 检查每个 .a 是否存在, 不存在的话搜一下实际位置
    echo "===== checking expected libs for ${platform} (${release_dir}) ====="
    local missing=0
    for lib in "${libs[@]}"; do
        if [ -f "$lib" ]; then
            echo "  ✅ $(basename $lib)  ($lib)"
        else
            echo "  ❌ MISSING: $lib"
            missing=$((missing + 1))
        fi
    done

    if [ $missing -gt 0 ]; then
        echo ""
        echo "===== searching for any *.a in ${build_dir} ====="
        find "${base_dir}/${build_dir}" -name "*.a" 2>/dev/null | head -50
        echo ""
        echo "❌ $missing 个 lib 文件缺失, 退出. 用上面 find 的输出修正路径."
        exit 1
    fi

    local temp_dir="${base_dir}/${build_dir}/temp"
    mkdir -p "${temp_dir}"

    # 把 stderr 也输出, 不要 2>/dev/null 吞掉
    echo "===== running libtool ====="
    xcrun libtool -static -o "${temp_dir}/combined.a" "${libs[@]}"

    local sdk=""
    local archs=""
    local min_version_flag=""
    local install_name=""

    case "$platform" in
        "ios")
            if [[ "$is_simulator" == "true" ]]; then
                sdk="iphonesimulator"
                archs="arm64 x86_64"
                min_version_flag="-mios-simulator-version-min=${IOS_MIN_OS_VERSION}"
            else
                sdk="iphoneos"
                archs="arm64"
                min_version_flag="-mios-version-min=${IOS_MIN_OS_VERSION}"
            fi
            install_name="@rpath/llama.framework/llama"
            ;;
        "macos")
            sdk="macosx"
            archs="arm64 x86_64"
            min_version_flag="-mmacosx-version-min=${MACOS_MIN_OS_VERSION}"
            install_name="@rpath/llama.framework/Versions/Current/llama"
            ;;
    esac

    local arch_flags=""
    for arch in $archs; do
        arch_flags+=" -arch $arch"
    done

    echo "Creating dynamic library for ${platform}."
    xcrun -sdk $sdk clang++ -dynamiclib \
        -isysroot $(xcrun --sdk $sdk --show-sdk-path) \
        $arch_flags \
        $min_version_flag \
        -Wl,-force_load,"${temp_dir}/combined.a" \
        -framework Foundation -framework Metal -framework Accelerate \
        -install_name "$install_name" \
        -o "${base_dir}/${output_lib}"

    if [[ "$is_simulator" == "false" && "$platform" == "ios" ]]; then
        if xcrun -f vtool &>/dev/null; then
            echo "Marking binary as a framework binary for iOS..."
            xcrun vtool -set-build-version ios ${IOS_MIN_OS_VERSION} ${IOS_MIN_OS_VERSION} -replace \
                -output "${base_dir}/${output_lib}" "${base_dir}/${output_lib}"
        else
            echo "Warning: vtool not found."
        fi
    fi

    echo "Creating properly formatted dSYM..."
    mkdir -p "${base_dir}/${build_dir}/dSYMs"

    if [[ "$platform" == "ios" ]]; then
        xcrun dsymutil "${base_dir}/${output_lib}" -o "${base_dir}/${build_dir}/dSYMs/llama.dSYM"
        cp "${base_dir}/${output_lib}" "${temp_dir}/binary_to_strip"
        xcrun strip -S "${temp_dir}/binary_to_strip" -o "${temp_dir}/stripped_lib"
        mv "${temp_dir}/stripped_lib" "${base_dir}/${output_lib}"
    else
        xcrun strip -S "${base_dir}/${output_lib}" -o "${temp_dir}/stripped_lib"
        xcrun dsymutil "${base_dir}/${output_lib}" -o "${base_dir}/${build_dir}/dSYMs/llama.dSYM"
        mv "${temp_dir}/stripped_lib" "${base_dir}/${output_lib}"
    fi

    if [ -d "${base_dir}/${output_lib}.dSYM" ]; then
        rm -rf "${base_dir}/${output_lib}.dSYM"
    fi

    rm -rf "${temp_dir}"
}

echo "Building for iOS simulator..."
cmake -B build-ios-sim -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DIOS=ON \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphonesimulator \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF \
    -S .
cmake --build build-ios-sim --config Release -- -quiet

echo "Building for iOS devices..."
cmake -B build-ios-device -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${IOS_MIN_OS_VERSION} \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS=iphoneos \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF \
    -S .
cmake --build build-ios-device --config Release -- -quiet

echo "Building for macOS..."
cmake -B build-macos -G Xcode \
    "${COMMON_CMAKE_ARGS[@]}" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=${MACOS_MIN_OS_VERSION} \
    -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64" \
    -DCMAKE_C_FLAGS="${COMMON_C_FLAGS}" \
    -DCMAKE_CXX_FLAGS="${COMMON_CXX_FLAGS}" \
    -DLLAMA_OPENSSL=OFF \
    -S .
cmake --build build-macos --config Release -- -quiet

echo "Setting up framework structures..."
setup_framework_structure "build-ios-sim" ${IOS_MIN_OS_VERSION} "ios"
setup_framework_structure "build-ios-device" ${IOS_MIN_OS_VERSION} "ios"
setup_framework_structure "build-macos" ${MACOS_MIN_OS_VERSION} "macos"

echo "Creating dynamic libraries from static libraries..."
combine_static_libraries "build-ios-sim" "Release-iphonesimulator" "ios" "true"
combine_static_libraries "build-ios-device" "Release-iphoneos" "ios" "false"
combine_static_libraries "build-macos" "Release" "macos" "false"

echo "Creating XCFramework..."
mkdir -p build-apple
xcrun xcodebuild -create-xcframework \
    -framework $(pwd)/build-ios-sim/framework/llama.framework \
    -debug-symbols $(pwd)/build-ios-sim/dSYMs/llama.dSYM \
    -framework $(pwd)/build-ios-device/framework/llama.framework \
    -debug-symbols $(pwd)/build-ios-device/dSYMs/llama.dSYM \
    -framework $(pwd)/build-macos/framework/llama.framework \
    -debug-symbols $(pwd)/build-macos/dSYMs/llama.dSYM \
    -output $(pwd)/build-apple/llama.xcframework

echo ""
echo "✅ Done. XCFramework: build-apple/llama.xcframework"
echo "   Slices: ios-sim (arm64+x86_64), ios-device (arm64), macos (arm64+x86_64)"
echo "   包含 mtmd: 是 (libmtmd.a + libmtmd_helper.a + libcommon.a)"
