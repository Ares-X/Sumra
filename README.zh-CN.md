<p align="center">
  <img src="docs/images/sumra-brand.png" alt="Sumra — 轻量、免费开源的 macOS 阅读器" width="720">
</p>

# Sumra — 轻量、纯粹的 macOS 阅读器

**电子书、漫画、PDF、图片与 Markdown，一个原生 Mac 应用，专注阅读。**

[English](README.md) · **简体中文** · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md)

**macOS 13+ · Apple Silicon · 免费开源**

[**下载 Mac 版**](https://github.com/Ares-X/Sumra/releases/latest) · [版本说明](https://github.com/Ares-X/Sumra/releases) · [支持格式](#支持的格式) · [从源码构建](#从源码构建) · [问题反馈](https://github.com/Ares-X/Sumra/issues)

从 Finder 打开 EPUB 小说、漫画压缩包、图片文件夹、Markdown 笔记或 PDF。在原生 Mac 窗口和标签页中阅读，选择合适的布局，用目录、搜索和书签找到想读的内容。

![Sumra 浅色界面，展示 Markdown 阅读笔记与目录](docs/images/reader-light.png)

<details>
<summary>更多截图：双页阅读、最近文件与深色界面</summary>

![双页阅读与目录侧栏](docs/images/reader-two-pages.png)

![首页中的最近文档](docs/images/home-light.png)

![深色阅读界面](docs/images/reader-dark.png)

截图均使用仓库内的[原创演示文档](docs/demos/Reading-Notes.md)。

</details>

## 安装与开始阅读

1. 从[最新版下载页](https://github.com/Ares-X/Sumra/releases/latest)下载应用 ZIP 并解压。
2. 将 **Sumra.app** 移入 **应用程序** 文件夹，然后打开。
3. 按 **⌘O** 打开文件，或将文件拖入窗口；按 **⌘F** 搜索正文。

公开构建使用维护者的 **Ares-X Code Signing** 自签名证书，不是 Apple Developer ID 证书，也未经 Apple 公证。若 macOS 阻止首次启动，且你确认下载来源可信，可按 [Apple 的说明](https://support.apple.com/zh-cn/102445)，前往 **系统设置 → 隐私与安全性 → 仍要打开**，再确认打开。

**在线更新：**选择 **帮助 → 检查更新**，或在设置中启用自动检查。Sparkle 验证更新后，在你确认时安装。每个发行版同时提供对应源码和 SHA-256 校验值。

<details>
<summary>兼容性与旧版安装说明</summary>

发行版面向 **Apple Silicon（arm64）**，最低系统目标为 **macOS 13**。打包时检查可执行文件与库的 arm64 支持、最低系统和运行时依赖。GUI 已在 macOS 27.0.1 验收，macOS 13 的实机兼容性尚未验证。

0.2.0 没有更新源，需要手动安装一次新版；0.2.1 及更新版本支持应用内更新。PostScript 与 EPS 需另行安装 Ghostscript。

</details>

## 专注阅读

- **原生窗口与标签页。**从 Finder 打开、拖入文件，或从首页继续阅读。在设置中启用 **使用窗口标签页**，即可把多本书放在同一窗口中。
- **适合文档的布局。**支持单页、连续滚动、双页阅读，以及主题和排版设置。重排电子书适应窗口，固定页面保留原有版式。
- **随时找到阅读位置。**目录、章节标题搜索、全文搜索、缩略图、书签，以及可选的阅读位置记录。没有作者目录的 TXT 和 MOBI 可识别独立章节标题。
- **浏览漫画合集。**压缩包内的文件夹会成为目录，保留名称与层级。适用的 solid LZMA2 压缩包通过内存区段索引加快远距离跳页，不修改原文件，也不把整本解压缓存到磁盘。
- **处理 PDF。**填写表单、编辑注释、撤销和重做、提取或合并页面，并保存修改。PDF 默认锁定编辑，选择 **启用编辑** 后才能修改；**存储副本** 保留可编辑的表单与注释，**导出 PDF** 生成静态阅读副本。
- **朗读、打印与导出。**使用系统语音朗读正文或选中文字，通过 macOS 打印面板打印，或导出 PDF。可用操作取决于文档格式与权限。

侧栏用于目录、缩略图和书签，**显示** 菜单用于布局与主题，设置中可调整排版、历史记录与标签页。**帮助 → 键盘快捷键** 列出可用命令，快捷键可在设置中自定义。

可从五种内置阅读主题中选择，也可自定义并保存正文、背景和链接颜色。现有自定义主题和已保存的设置仍可继续使用：

![Sumra 五种内置阅读主题预览](docs/images/themes.png)

工具栏 **Aa** 打开即时生效的阅读设置，集中调整已安装字体、字号、行距、边距、配色与布局，也可输入补充字体名称。CHM 带有关键词索引时，侧栏会提供独立的 **索引** 页签。EPUB 和漫画支持 Finder 缩略图与 Quick Look 翻页预览。详见[阅读控件](docs/READER_CONTROLS.md)和 [SyncTeX 编辑器集成](docs/SYNCTEX.md)。

## 支持的格式

| 类型 | 格式 |
| --- | --- |
| PDF 与固定页面 | PDF、XPS / OXPS、SVG、DjVu |
| 电子书 | EPUB、MOBI、AZW、PRC、FB2 / 压缩 FB2 |
| 漫画与图片 | CBZ、CBR、CB7、CBT、图片文件夹；常见图片格式，包括 GIF、TIFF、JPEG XL |
| 文本与网页 | Markdown、HTML / XHTML、CHM、TXT 等纯文本、TCR |
| 其他兼容格式 | PDF 兼容的 AI、P7M 封装、LIT |
| 需额外软件 | PostScript / EPS：另行安装 Ghostscript |

支持范围取决于具体文件变体。Sumra 不提供 OCR 或 DRM 移除；扫描件需要自带文本层才能搜索文字。

<details>
<summary>渲染说明与格式限制</summary>

- Markdown 使用 MuPDF，也可选择 WebKit 兼容模式。HTML 与 CHM 使用 WebKit 阅读，打印和 PDF 导出则通过 MuPDF 排版，输出效果可能与阅读界面不同。
- 重排电子书和原生 Markdown 会压缩普通正文的重复空白行与空段落，保留预格式化文字、表格、图片和明确分页。识别到的 CHM 正文也采用紧凑段落间距；调整字体、字号或行距会覆盖作者样式。
- PDF 中的黑白文字扫描页会自动增强对比度。在 **显示 → 文档颜色** 中关闭 **增强扫描页面**，即可查看原始显示效果，原文件保持不变。
- 漫画区段索引可跳过适用压缩包中更早的独立区段；首次跳页仍需解码目标区段内的前置数据，并非所有未读位置都能瞬间打开。

更多信息见[格式与引擎支持范围](docs/SUMATRA_ENGINE_PARITY.md)、[Markdown 渲染说明](docs/MARKDOWN_RENDERER_DECISION.md)和[漫画区段索引](docs/COMIC_SEEK_INDEX_20261020.md)。

</details>

## 从源码构建

需要 macOS、Apple Swift 工具链与 macOS SDK，以及 CMake。首次构建需联网获取固定版本的原生依赖与 Sparkle。项目构建和打包脚本使用 Swift 与系统工具，不需要 Python。

```sh
git clone https://github.com/Ares-X/Sumra.git
cd Sumra
./scripts/build-app.sh --release
open dist/Sumra.app
```

如未安装 CMake，可使用现有包管理器，例如 `brew install cmake`。开发构建与启动可用 `./scripts/run-dev.sh`。本地构建默认使用临时签名。

Sumra 是图形应用，文件打开、文档工具与打印均通过界面操作。开发相关信息见[实现说明](docs/IMPLEMENTATION_STATUS.md)、[本地检查](scripts/check-source.sh)和[发布流程](docs/RELEASE_ACTIONS.md)。

## 参与贡献与翻译

设置提供 25 个常用界面语言／地区选项，受管理的界面文案已补齐，欢迎母语使用者继续校订。正文的字体覆盖取决于内嵌、随附和已安装字体。完整名单、已测文字与排版限制见[语言支持与验证](docs/LANGUAGE_SUPPORT.md)。

欢迎[报告问题、提出功能建议](https://github.com/Ares-X/Sumra/issues)或提交 Pull Request。反馈时请尽量提供 macOS 与 Sumra 版本、文件格式、复现步骤，以及可公开分享的样本。

README 提供英文、简体中文、繁体中文和日语版本。以 [README.md](README.md) 为内容参考，保持章节顺序一致；公共信息变化时同步更新其他版本。各语言共用截图，并链接到技术文档。

## 许可与致谢

新编写的 Sumra 代码采用 **[AGPL-3.0-or-later](LICENSE)**。上游与移植组件保留各自的许可及版权声明；来源、版本与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)。

Sumra 借鉴 [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf)，复用 MuPDF 和 SumatraPDF 的部分文档处理实现，并以 SwiftUI 和 AppKit 构建界面。感谢 [MuPDF](https://mupdf.com/) 及其他上游项目。Sumra 是独立开发的项目，功能覆盖与现有差异见[对标说明](docs/SUMATRA_PARITY.md)。
