# CLIProxy Pool Watch

English | [中文](#中文说明)

A small native macOS app for monitoring CLIProxyAPI ChatGPT/Codex account quotas.

It shows a simple pool overview with account availability, Plus-base remaining capacity, 5-hour quota, weekly quota, plan weights, and restore forecasts.

> Community project. Not an official CLIProxyAPI component.

## Overview


![App overview](docs/screenshots/app-overview.png)

## Features

- Native SwiftUI macOS app
- CLIProxyAPI Management API integration
- ChatGPT `wham/usage` quota display through `/v0/management/api-call`
- 5-hour and weekly quota bars
- Graphical restore forecast segment on each quota bar
- Plus / Pro Lite / Pro plan weights
- Weekly kill-line handling to avoid over-counting accounts with exhausted weekly quota
- Local-only settings storage

## How It Works

The app uses the same CLIProxyAPI Management API flow as the web control panel.

First it reads auth files:

```http
GET /v0/management/auth-files
Authorization: Bearer <management-key>
```

Then, for selected Codex/OpenAI-like accounts, it calls ChatGPT usage through CLIProxyAPI:

```http
POST /v0/management/api-call
Authorization: Bearer <management-key>
Content-Type: application/json

{
  "authIndex": "<auth_index>",
  "method": "GET",
  "url": "https://chatgpt.com/backend-api/wham/usage",
  "header": {
    "Authorization": "Bearer $TOKEN$",
    "Accept": "application/json",
    "Content-Type": "application/json"
  }
}
```

CLIProxyAPI replaces `$TOKEN$` with the selected account token.

## Install

1. Download `CLIProxyPoolWidget.dmg` from Releases.
2. Open the DMG.
3. Drag `CLIProxyPoolWidget.app` to `Applications`.
4. Open the app and configure:
   - Pool URL
   - Management key
   - Refresh options
   - Plan weights
5. Click `Test Fetch`.

Unsigned community builds may require extra macOS confirmation on first launch:

```bash
xattr -dr com.apple.quarantine /Applications/CLIProxyPoolWidget.app
```

Unsigned builds should only be installed from trusted sources.

## Build From Source

Requirements:

- macOS 14 or newer
- Xcode 16 or newer

Build from Terminal:

```bash
xcodebuild \
  -scheme CLIProxyPoolWidget \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

For local unsigned development, ad-hoc sign the app after building:

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/CLIProxyPoolWidget-*/Build/Products/Release/CLIProxyPoolWidget.app"

codesign --force --sign - \
  --entitlements App/CLIProxyPoolWidget.entitlements \
  "$APP"
```

The app bundle does not include a locally configured Management key by default. The key is stored at runtime in macOS user defaults on the user's machine.

## Settings And Privacy

Settings are stored locally on the user's Mac.

- The app stores settings in normal app `UserDefaults`.
- The Management key is not sent anywhere except to the configured CLIProxyAPI Management endpoint.
- This project does not use third-party analytics or telemetry.

The Management key is currently stored in user defaults for local convenience. For stronger security, a future version should move the key to Keychain.

## Quota Model

The app shows two quota windows:

- `5h`: primary short window
- `Week`: weekly or secondary window

Each quota bar has two visual layers:

- Solid segment: current remaining quota
- Translucent segment: next grouped restore amount, projected to the quota level after the next restore batch

Progress colors:

- Red: 0-20% remaining
- Yellow: 20-70% remaining
- Green: 70-100% remaining

Default Plus-base weights:

- Plus: `1x`
- Pro Lite: `10x`
- Pro: `20x`

If an account's weekly quota falls below the configured kill line, it does not contribute to total remaining capacity. The account row still shows the raw 5-hour bar in a muted state with `weekKILL`.

The pool-level `5h` balance uses the raw 5-hour remaining quota for accounts that are not week-killed. Weekly quota is used as a kill switch, not as a cap on ordinary 5-hour restore calculation.

Quota or rate-limit responses from `/api-call` are treated as quota state when they include reset information. They do not automatically mean the account is unavailable.

## Roadmap

- Keychain storage for the Management key
- Signed and notarized release workflow
- Desktop widgets after the WidgetKit implementation is stable
- Multiple pool profiles
- Custom account labels

## License

MIT License. See [LICENSE](LICENSE).

---

# 中文说明

[English](#cliproxy-pool-watch) | 中文

CLIProxy Pool Watch 是一个简单的原生 macOS 应用，用来监控 CLIProxyAPI 里的 ChatGPT/Codex 账号额度。

它只提供一个主应用 overview：账号可用状态、Plus 基准剩余额度、5 小时额度、周额度、套餐权重，以及下一批恢复预测。

> 社区项目，不是 CLIProxyAPI 官方组件。

## 概览

![应用概览](docs/screenshots/app-overview.png)

## 功能

- 原生 SwiftUI macOS 应用
- 接入 CLIProxyAPI Management API
- 通过 `/v0/management/api-call` 获取 ChatGPT `wham/usage` 额度
- 显示 5 小时额度和周额度
- 每条额度进度条显示图形化恢复预测段
- Plus / Pro Lite / Pro 套餐权重
- 支持周额度 kill line，避免周额度耗尽的账号造成总额度虚高
- 设置只保存在本机

## 工作原理

应用使用和 CLIProxyAPI Web 管理面板类似的 Management API 流程。

首先读取 auth files：

```http
GET /v0/management/auth-files
Authorization: Bearer <management-key>
```

然后对选中的 Codex/OpenAI 类账号，通过 CLIProxyAPI 请求 ChatGPT usage：

```http
POST /v0/management/api-call
Authorization: Bearer <management-key>
Content-Type: application/json

{
  "authIndex": "<auth_index>",
  "method": "GET",
  "url": "https://chatgpt.com/backend-api/wham/usage",
  "header": {
    "Authorization": "Bearer $TOKEN$",
    "Accept": "application/json",
    "Content-Type": "application/json"
  }
}
```

CLIProxyAPI 会把 `$TOKEN$` 替换为对应账号的 token。

## 安装

1. 从 Releases 下载 `CLIProxyPoolWidget.dmg`。
2. 打开 DMG。
3. 把 `CLIProxyPoolWidget.app` 拖到 `Applications`。
4. 打开应用并配置：
   - Pool URL
   - Management key
   - 刷新选项
   - 套餐权重
5. 点击 `Test Fetch`。

未签名的社区构建第一次打开时，macOS 可能需要额外确认：

```bash
xattr -dr com.apple.quarantine /Applications/CLIProxyPoolWidget.app
```

未签名构建只应从可信来源安装。

## 从源码构建

要求：

- macOS 14 或更新版本
- Xcode 16 或更新版本

用 Terminal 构建：

```bash
xcodebuild \
  -scheme CLIProxyPoolWidget \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

本地无签名开发可以在构建后做 ad-hoc 签名：

```bash
APP="$HOME/Library/Developer/Xcode/DerivedData/CLIProxyPoolWidget-*/Build/Products/Release/CLIProxyPoolWidget.app"

codesign --force --sign - \
  --entitlements App/CLIProxyPoolWidget.entitlements \
  "$APP"
```

默认情况下，app bundle 不会包含本地配置过的 Management key。key 是用户运行应用后保存在自己 Mac 的 user defaults 里。

## 设置与隐私

设置保存在用户本机。

- 应用把设置保存在普通 app `UserDefaults`。
- Management key 只会发送到用户配置的 CLIProxyAPI Management endpoint。
- 本项目没有第三方分析或遥测。

目前 Management key 为了本地使用方便，仍保存在 user defaults。更安全的后续版本应该改用 Keychain。

## 额度模型

应用显示两个额度窗口：

- `5h`：短周期主窗口
- `Week`：周额度或 secondary window

每条额度条有两层图形：

- 实色段：当前剩余额度
- 半透明段：下一批恢复额度，表示恢复后会到达的位置

进度条颜色：

- 红色：剩余 0-20%
- 黄色：剩余 20-70%
- 绿色：剩余 70-100%

默认 Plus 基准权重：

- Plus：`1x`
- Pro Lite：`10x`
- Pro：`20x`

如果某个账号的周额度低于配置的 kill line，它不会计入总剩余额度。账号行仍会以灰色显示原始 5 小时进度，并标记 `weekKILL`。

池子级别的 `5h` 余额会使用未被 week kill 的账号的原始 5 小时剩余额度。周额度只作为 kill switch，不会在普通情况下截断 5 小时恢复额度。

如果 `/api-call` 返回的是额度不足或 rate limit，并且响应里包含 reset 信息，应用会把它当作额度状态解析，不会自动认为账号不可用。

## Roadmap

- 用 Keychain 保存 Management key
- 签名和 notarized 发布流程
- 等 WidgetKit 实现稳定后再加入桌面小组件
- 多个 pool 配置
- 自定义账号名称

## License

MIT License. See [LICENSE](LICENSE).
