import UIKit
import Flutter

// 回退到经典 UIApplication 生命周期（不启用 UIScene/FlutterImplicitEngineDelegate）。
// 原因：UIScene 隐式引擎在 Flutter 3.41 才默认/自动迁移，本项目固定 3.38.3，
// 提前手动启用后顶部安全区 inset 异常，导航栏与灵动岛/状态栏重叠。
// 对齐 3.38.3 官方默认模板；将来升级到 3.41+ 可再由 flutter 自动迁移回 UIScene。
@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
