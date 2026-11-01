import Foundation

/// 真 AppEnv 住在 Demo.swift，那个文件 import 了 AppKit/SwiftUI，进不了这份只有 Foundation 的测试二进制。
/// VaultSync 只用到 `AppEnv.vaultURL` 这一格（`activeRoot()`），测试里给一个可写变量就够。
enum AppEnv {
    nonisolated(unsafe) static var vaultURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vault-shim-idle", isDirectory: true)
}
