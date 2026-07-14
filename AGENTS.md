# AGENTS.md

本文件为 AI Agent 提供项目上下文，涵盖分支策略、提交规范、CI/CD 打包流程和项目结构。

## 项目概览

**Simple Live** — 简简单单的看直播。支持虎牙、斗鱼、哔哩哔哩、抖音直播平台。

- Flutter SDK: `3.38.x`
- 语言: Dart / Kotlin (Android TV 原生插件) / Objective-C (macOS 原生模块)
- 仓库: `Grayon/dart_simple_live` (fork 自 xiaoyaocz/dart_simple_live)

## 项目结构

| 目录 | 说明 |
|------|------|
| `simple_live_core` | 核心库，各平台直播信息获取与弹幕 |
| `simple_live_app` | Flutter 手机/桌面客户端 (Android/iOS/macOS/Windows/Linux) |
| `simple_live_tv_app` | Flutter Android TV 客户端 |
| `simple_live_console` | 基于核心库的控制台程序 |
| `.github/workflows/` | CI/CD 打包工作流 |
| `assets/` | 版本信息文件 (`app_version.json`, `tv_app_version.json`) |

## 分支策略

| 分支 | 用途 |
|------|------|
| `master` | 正式发布分支，对应 Release 版打包 |
| `dev` | 手机/桌面 App 日常开发分支，对应 Dev 版打包 |
| `feat/*` | 功能开发分支，如 `feat/replace-player` (TV 端播放器抽象层重构) |

**注意**: 本仓库是 fork，本地 git 用户为 `Grayon`。

## 提交规范

使用 Conventional Commits 格式：

```
<type>(<scope>): <中文描述>
```

- **type**: `feat` / `fix` / `refactor` / `chore` / `docs`
- **scope**: `tv` / `app` / `core` / `macos` / `android`
- 描述用中文，简洁明了

示例：
- `fix(tv): MPVLogLevel 无 fatal 成员，映射到 error`
- `feat(tv): 硬解选项增加 mediacodec-copy 和中文说明`
- `fix(macos): 用 setFrameAutosaveName 替代直接赋值，frameAutosaveName 是只读属性`

### 提交注意事项

- 不要 amend 已有提交，创建新提交（用户明确要求"不要amend，生成新的提交"）
- 仅本地不推送，除非用户明确要求推送
- Bug 修复应从 `dev` 拉 `fix/xxx` 分支提交，不要在功能分支上修

## CI/CD 打包流程

**所有打包均由推送 Tag 触发**，不会在普通 push 时自动构建。

### 版本号自动同步

CI 构建时会自动从 Tag 提取版本号并写入 `pubspec.yaml`（Release 版还会同步更新 `assets/*_version.json`），**无需手动维护版本号**。

同步脚本: `.github/scripts/sync_version.py`

版本号计算规则:
- Tag `dev_v1.11.5` → `pubspec.yaml` version: `1.11.5+11105`
- Tag `dev_tv_v1.6.7_202607111430` → `pubspec.yaml` version: `1.6.7+10607`（时间戳后缀自动忽略）
- build number = `major*10000 + minor*100 + patch`（如 `1.11.5` → `11105`）

**因此: Tag 名称就是版本号的唯一来源。** 打 Tag 时确保版本号正确即可，不需要再手动改 `pubspec.yaml`。

### Tag 与工作流对应关系

| Tag 格式 | 工作流 | 构建目标 | 签出分支 | Release 名称来源 | App 内显示版本 |
|----------|--------|----------|----------|-----------------|---------------|
| `dev_v*` | `publish_app_dev.yaml` | 手机/桌面 App Dev 版 (全平台) | `dev` | 无 (仅 Artifact) | Tag 自动同步 |
| `v*` | `publish_app_release.yml` | 手机/桌面 App Release 版 | `master` | Tag 值 (如 `v1.11.5`) | Tag 自动同步 |
| `dev_tv_v*` | `publish_tv_app_dev.yaml` | Android TV Dev 版 | tag 所在分支 | 无 (仅 Artifact) | Tag 自动同步 |
| `tv_*` | `publish_tv_app_release.yaml` | Android TV Release 版 | tag 所在分支 | `assets/tv_app_version.json` (Tag 自动同步) | Tag 自动同步 |

### Tag 生成规范

Tag 中的版本号会被自动写入 App，所以 Tag 格式必须规范:

```
# 手机/桌面 App
git tag dev_v1.11.5          # Dev 版
git tag v1.11.5              # Release 版

# Android TV
git tag dev_tv_v1.6.7        # Dev 版（简洁格式）
git tag dev_tv_v1.6.7_202607111430  # Dev 版（带时间戳，同一天多次构建时用）
git tag tv_v1.6.7            # Release 版
```

TV Dev tag 可附加 `_YYYYMMDDHHMM` 时间戳后缀，便于同一天多次构建时区分（实际项目中大量使用此格式）。

### Release 版更新日志

Release 工作流的更新日志 (`version_desc`) 仍需手动编辑 `assets/app_version.json` / `assets/tv_app_version.json`，脚本只自动同步 `version` 和 `version_num`，不会覆盖 `version_desc`。

### 触发打包示例

```bash
# 手机/桌面 App Dev 版
git tag dev_v1.11.5 && git push origin dev_v1.11.5

# Android TV Dev 版（当前 feat/replace-player 分支用这个）
git tag dev_tv_v1.0.13 && git push origin dev_tv_v1.0.13

# 带时间戳的 TV Dev 版（同一天多次构建）
git tag dev_tv_v1.6.7_202607111430 && git push origin dev_tv_v1.6.7_202607111430

# 手机/桌面 App Release 版
git tag v1.11.5 && git push origin v1.11.5

# Android TV Release 版
git tag tv_v1.6.7 && git push origin tv_v1.6.7
```

### 构建细节

- Android APK 使用 `--split-per-abi`，产出 arm64-v8a / armeabi-v7a / x86_64 三个包
- Android TV Dev 版会自动改包名为 `com.xycz.simple_live_tv_dev`，可与 Release 版共存
- iOS/macOS 在 macOS runner 上构建，iOS 产出未签名 IPA
- Linux/Windows 使用 `flutter_distributor` 打包
- 所有工作流均支持 `workflow_dispatch` 手动触发

## Git 操作注意事项

本项目的 `.git/` 目录在沙箱环境中受保护，执行 git 写操作（commit、push、checkout 等）时**必须**使用 `dangerouslyDisableSandbox: true` 参数，否则会报 `Operation not permitted` 错误。

```bash
# 示例：需要禁用沙箱的 git 操作
git checkout <branch>      # 创建 index.lock
git commit                 # 写入 .git/
git push                   # 网络 + .git/
git tag                    # 写入 .git/refs/tags/
git pull                   # 写入 .git/
```

## 播放器架构 (feat/replace-player 分支)

TV 端正在进行播放器抽象层重构，核心文件：

| 文件 | 说明 |
|------|------|
| `base_player.dart` | `BasePlayer` 抽象接口 + `PlayerState`/`PlayerLogLevel`/`PlayerConfig` 等数据类 |
| `mediakit_player.dart` | media_kit (mpv) 播放器实现 |
| `exoplayer_player.dart` | ExoPlayer (Media3) 播放器实现 |
| `player_controller.dart` | 播放器控制器，通过 `BasePlayer` 接口管理播放器实例 |
| `player_video.dart` | `PlayerVideo` 渲染组件，自动选择渲染 widget |
| `LiveExoPlayerPlugin.kt` | Android 原生 ExoPlayer 插件 |

关键设计：
- 上层业务只依赖 `BasePlayer` 接口，不直接依赖具体播放器库
- 支持运行时切换播放器引擎 (mpv / ExoPlayer)
- VO/解码器崩溃后自动重建播放器 (`recreate()` + `recreateStream`)
- `mediakit_player.dart` 中需 `hide PlayerState` 避免与 media_kit 包冲突
