# 0.2.24 发布与安装验收

[0.2.24 (26)](https://github.com/Ares-X/Sumra/releases/tag/v0.2.24) 已于 2026-11-02
发布。它交付 [PR #79](https://github.com/Ares-X/Sumra/pull/79) 的 EPUB 后台章节计数
双页配对修复；此前已显示的左右源页不会仅因前序章节完成计数而换边或换邻页。
实际字体重排、模式及封面变化仍重新建立配对。没有加入全书首屏前预计算。

## 产物与公开交付

- 源码：`ce282673679c8dd2c7bab011da5989313cec8f33`；版本准备为
  [PR #80](https://github.com/Ares-X/Sumra/pull/80)。修复验收后仅修改版本号和发布说明。
- [候选构建 41433023722](https://github.com/Ares-X/Sumra/actions/runs/41433023722)
  与 [发布 41436538790](https://github.com/Ares-X/Sumra/actions/runs/41436538790)
  均成功；发布复用已验收候选的六个附件，未重新构建。
- ZIP 为 17,012,587 字节，SHA-256：
  `f641794e93d3ae8a2e5e7ac4bee1dd21068588ff146352aa3120383d6ded3228`。
- 主程序 SHA-256：`cba4147c6dac0334f3ce09155d66bbff2af9c2a3ea5c5f1c661210d5dea10238`；
  Mach-O UUID：`1A956E8E-EB03-3094-BACD-F4CD2F8BE94A`。
- 候选的 140 个文件、91 个目录、5 个链接与 provenance 对应，深度严格签名通过；
  源码归档与发布提交对应。签名继续使用既有自签名证书，不声称 Developer ID 或公证。
- 匿名下载六个公开附件并逐个核对大小和哈希；公开 main appcast 与附件一致，
  ZIP 的 Sparkle Ed25519 签名通过。直连下载曾发生 TLS 握手失败，改用机器已有的
  系统代理后完成验证；未更改代理设置，未关闭 TLS 验证。

## 行为验收

| 范围 | 实际结果 |
| --- | --- |
| 修复代码 | 沿用最终 51 个相关用例通过、零失败、零跳过及实际 AppKit/MuPDF 红绿位图；详见[复查记录](RECHECK_0_2_23_20261102.zh-CN.md)。版本准备未改产品代码。 |
| 正式签名包 EPUB | 虚拟机内实际打开固定源标记 EPUB；后章前后翻页 `C4P1+P2 → P3+P4 → P1+P2`，封面开关重新配对。620×560 和 1060×610 窗口完成重排；报告者原始 C EPUB 混合图文双页在这两个尺寸实际绘制并查看。 |
| 正式签名包 PDF | 原始 454 页 PDF 能打开并通过目录跳转；实际操作双页、浮层、Auto Hide、全屏及退出。保留的稳态画面未见持续白带遮挡。 |
| Quick Look | Finder 预览实际加载此候选的 SumraPreview 扩展，绘出源样本首页。 |
| 公开自动更新 | 本机通过 Help → 检查更新，从 0.2.23 (25) 下载正式 0.2.24，实际点击 Install and Relaunch，安装后版本为 0.2.24 (26)。首次自动化等待下载 100 秒超时，未计通过；随后重新观察确认 Ready to Install，再执行安装通过。 |
| 最终安装及加载 | `/Applications/Sumra.app` 全部文件、目录、链接及签名与候选一致；新进程实际映射安装目录的主程序及 MuPDF.dylib。通过原生打开面板重新打开原始 PDF，封面正常，目录点击第三章后显示正文（印刷页 72、73）。原件 SHA-256 未变。 |

主机此时 `restoreSession=false`、`disableHistory=true`、`disableReadingState=true`。
更新重启回首页符合现有配置；本轮不把它记作窗口或阅读位置自动恢复验收。

## 边界与报告者确认

- 封装应用中仍未捕获首次显示与后台计数发布之间的自然时序；不能用稳定截图冒充
  这一瞬间的正式包动画复现。修复依据是实际 AppKit 画布红绿对照和相关回归。
- 本轮未重跑未改动的 HTML、标签组、邮件、Chrome Lens、Graphite 等所有历史项；
  它们沿用 0.2.23 的[已有实证](RELEASE_0_2_23_ACCEPTANCE_20261101.md)。
  发布前修复候选的标签新增/取消/关闭、TXT 双页、顶栏拖动、目录与重排复查记录
  保存在 `build/candidate-feedback-20261102/REPORT.zh-CN.md`。
- Brave、报告者原显示及辅助功能环境、原书与 0.2.19 的间距对照和实体 macOS 13
  未验收；朗读依用户要求免测。PDF 仍为固定版式，不声称实现文字重排。
- 尚未证明报告者 #69 的 resize 抖动与本次后台配对问题同根因。
  维护者审计 #78 在交付后关闭；真实用户 #68、#69、#74 保持开放等待本人确认。

## 证据与清理

本机收据在 `build/release-0.2.24/`：`candidate-acceptance.json`、
`correspondence-check.json`、`public-existing-proxy/public-check.json`、
`installed-identity.json`、`installed-runtime.json`、所选 PNG 与自动更新测试日志/摘要。
下载超时记录保留，未改写为通过。

已移除本轮源码归档副本、解压应用、重复下载、Xcode 派生构建及含录屏的 xcresult；
本轮目录用量由 551,332 KiB 降至 24,948 KiB，仅保留一份正式 ZIP、provenance
和必要证据。客机临时应用、预览扩展注册及阶段目录已移除，偏好恢复原值；共享
虚拟机与 Peekaboo 保留。临时浏览器标签组已关闭。活动自动化模式已关闭，用户
授权保留的免认证配置未更改。新正式安装保留供使用；证据和唯一 ZIP 供交付追溯。
