#!/bin/zsh
# 构建 DiskHealth.app（菜单栏磁盘健康监控）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="DiskHealth"
BUILD="build"
mkdir -p "$BUILD"
staging=$(mktemp -d "$BUILD/.DiskHealth.XXXXXXXX")
trap 'rm -rf -- "$staging"' EXIT
trap 'exit 1' HUP INT TERM
APP="$staging/$APP_NAME.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
  -target arm64-apple-macos14.0 \
  Sources/*.swift Sources/smart_bridge.c \
  -import-objc-header Sources/smart_bridge.h \
  -framework IOKit -framework CoreFoundation -framework SwiftUI -framework AppKit -framework DiskArbitration \
  -o "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/bin/plutil -lint "$APP/Contents/Info.plist"

# ad-hoc 签名（本机运行需要）
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"

# 首次发布用排他重命名；已有产物则在同一文件系统中原子交换两个包。
swift - "$APP" "$BUILD/$APP_NAME.app" <<'SWIFT'
import Darwin

let source = CommandLine.arguments[1], destination = CommandLine.arguments[2]
if renamex_np(source, destination, UInt32(RENAME_EXCL)) != 0 {
    guard errno == EEXIST, renamex_np(source, destination, UInt32(RENAME_SWAP)) == 0 else {
        perror("发布应用失败")
        exit(EXIT_FAILURE)
    }
}
SWIFT

echo "构建完成: $PWD/$BUILD/$APP_NAME.app"
