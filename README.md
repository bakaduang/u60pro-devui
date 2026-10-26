# U60 Pro 屏幕管理（u60pro-devui）

ZTE U60 Pro 小屏的社区界面插件，适配 **UFI-TOOLS-ZWRT 1.0**。包含：

- **扩展版渲染程序** `u60pro-devui-aarch64`：基于 [scoltzero/u60pro-devui-remix](https://github.com/scoltzero/u60pro-devui-remix) NewUI，加上扩展页接口 xpage（插件页面 + 同名 shell 适配脚本，本地标签与分页）。
- **Clean 页面 UI**：首页网速大字卡、彩色功能磁贴、扁平卡片；「更多功能」里有 **小海关** 和 **Clash** 控制页（对应插件装了才显示）。
- **UFI-TOOLS 插件** `u60pro-screen-plugin-vX.Y.Z.txt`：安装 / 更新渲染程序和页面、开机自启、回退与卸载。

渲染程序和页面包由 GitHub Actions 从源码构建，每个版本发布到 [Releases](../../releases)。插件里选 **「从 GitHub 在线更新」** 就能直接在设备上下载、校验 SHA-256 并安装，不需要再从电脑上传文件。

## 安装

1. 在 Releases 下载 `u60pro-screen-plugin-vX.Y.Z.txt`，在 UFI-TOOLS 插件管理里安装（先移除旧的屏幕插件），刷新网页。
2. 打开「功能 → 屏幕管理」，安装来源选「从 GitHub 在线更新」，可先点「检查更新」，再点「安装 / 更新」。
3. 看一眼设备小屏，显示正常后点「写入开机自启」。黑屏就点「停止（恢复原厂）」，没写自启前重启也会回到原厂屏幕。

国内网络：在线更新依次尝试你填的 GitHub 加速地址、GitHub 直连、gh-proxy.com / ghfast.top，最后是 jsDelivr 上的 `dist` 分支镜像；本机 7890 端口有代理（例如 Clash 已启动）时还会经代理再试一次。下载的渲染程序和页面包都会按 `version.json` 里的 SHA-256 校验，不一致不会安装。

## Clash 屏幕页

配合「Clash 管理」插件（mihomo 内核，设备端脚本 `/data/plugins/clash/clashctl.sh`）使用。屏幕上可以：

| 标签 | 功能 |
| --- | --- |
| 概览 | 运行状态、实时网速、当前节点、接管范围、连接数和内存；启动 / 停止 / 重启；规则 / 全局 / 直连 |
| 节点 | 逐个浏览策略组，点节点切换，测速 |
| 接管 | 关闭 / 白名单 / 黑名单 / 全部（点两次确认），本机代理、UDP 代理开关，设备名单 |
| 订阅 | 订阅列表（流量、到期），点两次切换订阅，更新当前订阅，开机自启 |

所有修改都交给 `clashctl.sh` 校验并执行，和网页端用的是同一套逻辑。

## 扩展页协议（xpage API 2）

在 `ui/functions/` 放 `名字.html` 和同名 `名字.sh`：

- 页面打开时，渲染程序每隔 `INTERVAL` 秒（默认 3）在后台执行 `XP_VIEW=<视图> sh 名字.sh status`，输出的 `KEY=VALUE` 变成模板令牌 `{{X_KEY}}`（自动 HTML 转义；键名以 `_HTML` 结尾的原样输出）。
- `<a href="act:x:动作">` 后台执行 `sh 名字.sh 动作`；`act:xc:动作` 要在 4 秒内点两次。动作名只允许字母、数字和 `_ . : = -`，输出的第一行非空文字作为提示。
- `act:xv:视图` 本地切换视图（`{{XS_VIEW:视图}}`），`act:xp:列表:prev|next` 本地翻页（脚本输出 `PAGES_列表`、`CURPAGE_列表`，每页包在 `class="xpg xpg-列表-页号"` 里，页面放 `{{XS_STATECSS}}`）。
- 内置令牌：`{{XS_BUSY}}`、`{{XS_LOG}}`、`{{XS_AGE}}`、`{{XS_ARM:动作}}`、`{{XS_API}}`、`{{XS_PAGE:列表}}`、`{{XS_PAGES:列表}}`、`{{XS_PREV:列表}}`、`{{XS_NEXT:列表}}`。
- meta：`devui-requires`（路径不存在时隐藏入口）、`devui-icon`、`devui-tint`、`devui-desc`。

完整示例见 `ui/functions/customs.*`（小海关）和 `ui/functions/uclash.*`（Clash）。

## 目录

| 路径 | 说明 |
| --- | --- |
| `renderer/devui-xpage.patch` | 对上游 remix（`version.config.json` 里固定的提交）的补丁 |
| `renderer/build.sh` | 拉取上游、打补丁、下载 litehtml v0.10 与 FreeType 2.13.3，用 zig 0.13 静态编译 aarch64-musl |
| `ui/` | 页面 UI 源码 |
| `plugin/` | 插件源码与打包脚本（把 `ui/` 内嵌进插件，生成 `ui.tar.gz`、`version.json`、`SHA256SUMS`） |
| `version.config.json` | 版本号与仓库信息 |
| `.github/workflows/build.yml` | CI：检查脚本（LF、BusyBox ash 语法）、编译、打包；推送 `v*` 标签时发布 Release 并更新 `dist` 分支 |

本地构建：

```sh
ZIG=/path/to/zig bash renderer/build.sh work work/u60pro-devui
node plugin/build-plugin.js work/u60pro-devui dist
```

发布新版本：改 `version.config.json` 里的 `plugin` / `ui` 版本号，提交后打同名标签（例如 `v1.2.1`）推送即可。

## 致谢与许可

渲染程序和页面基于 [33333s/u60pro-devui](https://github.com/33333s/u60pro-devui) 与 [scoltzero/u60pro-devui-remix](https://github.com/scoltzero/u60pro-devui-remix)（MIT）；双卡页面的初始实现来自 Aawuxing，飞猫页面来自 Zhengjian12345。静态链接了 litehtml（BSD）、Gumbo（Apache-2.0）、FreeType（FTL）和 stb（MIT/公有领域），许可证全文见 `licenses/`。
Portions of this software are copyright © 2024 The FreeType Project (www.freetype.org). All rights reserved.
