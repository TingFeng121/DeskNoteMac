#!/bin/sh
# vault 层的回归测试：把仓库里那几个「只有 Foundation」的源文件符号链接进临时目录，
# 和测试代码一起用 swiftc 编成命令行程序跑。
#
# 为什么不塞进 Package.swift 的 test target：这个包只有一个 .executableTarget，
# swift-testing/XCTest 都要额外拉依赖，而这条路径 6 行就能跑，且能在装了旧 toolchain 的机器上照跑。
# 为什么用符号链接而不是拷贝：/tmp 里那份拷贝曾经悄悄过期过一次，测过的和发的不是同一份代码。
#
# 用法：./Tools/vault-tests/run.sh          （全部都跑）
#       ./Tools/vault-tests/run.sh sync     （只跑同步层）
#       ./Tools/vault-tests/run.sh reader   （只跑阅读层的解析与缓存）
#       ./Tools/vault-tests/run.sh tree     （只跑文件树层）
set -e
cd "$(dirname "$0")/../.."
SRC=Sources/DeskNote
OUT=$(mktemp -d "${TMPDIR:-/tmp}/desknote-vault-tests.XXXXXX")
trap 'rm -rf "$OUT"' EXIT

run_layer() {
    name=$1; shift
    dir="$OUT/$name"
    mkdir -p "$dir"
    for f in "$@"; do ln -s "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" "$dir/"; done
    ln -s "$PWD/Tools/vault-tests/$name"/*.swift "$dir/"
    swiftc -swift-version 5 -o "$dir/run" "$dir"/*.swift
    echo "── $name"
    "$dir/run"
}

case "${1:-all}" in
    vault) run_layer VaultLayer "$SRC/Model.swift" "$SRC/Vault.swift" ;;
    sync)  run_layer SyncLayer "$SRC/Model.swift" "$SRC/Vault.swift" "$SRC/FileStamp.swift" "$SRC/VaultSync.swift" ;;
    library) run_layer LibraryLayer "$SRC/Model.swift" "$SRC/Vault.swift" "$SRC/FileStamp.swift" \
                                      "$SRC/LibraryFiles.swift" "$SRC/LibraryTreeIndex.swift" "$SRC/LibraryScan.swift" \
                                      "$SRC/LibrarySearch.swift" ;;
    tree)  run_layer TreeLayer "$SRC/LibraryTreeIndex.swift" "$SRC/LibraryTreeState.swift" ;;
    reader) run_layer ReaderLayer "$SRC/ReaderParse.swift" "$SRC/ReaderCache.swift" ;;
    all)
        run_layer VaultLayer "$SRC/Model.swift" "$SRC/Vault.swift"
        run_layer SyncLayer "$SRC/Model.swift" "$SRC/Vault.swift" "$SRC/FileStamp.swift" "$SRC/VaultSync.swift"
        run_layer LibraryLayer "$SRC/Model.swift" "$SRC/Vault.swift" "$SRC/FileStamp.swift" \
                               "$SRC/LibraryFiles.swift" "$SRC/LibraryTreeIndex.swift" "$SRC/LibraryScan.swift" \
                               "$SRC/LibrarySearch.swift"
        run_layer TreeLayer "$SRC/LibraryTreeIndex.swift" "$SRC/LibraryTreeState.swift"
        run_layer ReaderLayer "$SRC/ReaderParse.swift" "$SRC/ReaderCache.swift"
        ;;
    *) echo "用法：$0 [vault|sync|library|tree|reader|all]" >&2; exit 2 ;;
esac
