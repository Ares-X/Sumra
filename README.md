# Sumra

**一个原生 macOS 文档阅读器，让阅读回到内容本身。**

中文 · [English](README.en.md)

PDF、电子书、漫画和 Markdown，用同一个应用打开。Sumra 以 SwiftUI 和 AppKit 构建，使用 macOS 的窗口、标签页、菜单与系统对话框。紧凑的工具栏和明暗主题，让文档成为界面的中心。

Sumra 借鉴 [SumatraPDF](https://www.sumatrapdfreader.org/) 的阅读体验，复用 MuPDF 等成熟文档引擎，并为 macOS 重新设计界面与交互。

![Sumra 浅色首页，显示最近阅读的文档](docs/images/home-light.png)

![浅色阅读界面，展示原创阅读笔记与目录](docs/images/reader-light.png)

![深色阅读界面](docs/images/reader-dark.png)

截图使用仓库内的[原创演示文档](docs/demos/Reading-Notes.md)，不包含私人书籍或用户资料。

## 下载与安装

从[最新版下载页](https://github.com/Ares-X/Sumra/releases/latest)获取应用 ZIP。同一发行版提供对应源码和 SHA-256 摘要。

当前发行目标为 **Apple Silicon（arm64）**，最低系统目标为 **macOS 13**。实际 GUI 已在 macOS 27.0.1 验证，macOS 13 的实机兼容性尚未验证。

安装步骤：

1. 下载并解压应用 ZIP。
2. 将 **Sumra.app** 拖入 **应用程序** 文件夹。
3. 打开 Sumra。如果 macOS 阻止打开，请前往 **系统设置 → 隐私与安全性**，在对应提示处选择 **仍要打开**，再按系统提示确认。

公开构建使用维护者的个人自签名身份 **Ares-X Code Signing**。它不是 Apple Developer ID 签名，也未经 Apple 公证，因此首次打开可能需要上述确认。安装提示可参考 [Apple 的说明](https://support.apple.com/zh-cn/102445)。

## 适合怎样的阅读

- **直接打开文件**：从 Finder 打开、拖入窗口，或从首页和最近文件继续阅读；支持多个窗口与 macOS 标签页。
- **在长文档中定位**：目录与目录标题搜索、全文搜索、缩略图、书签和阅读位置记录。
- **调整阅读方式**：缩放、旋转、连续或分页布局、双页阅读与演示模式；电子书和文本提供字体与排版设置。
- **读给你听**：使用系统朗读阅读文档文字，或朗读选中的内容。
- **处理 PDF**：填写表单、添加与修改注释、撤销和重做、保存或另存副本；文档工具支持提取与合并页面等操作。
- **打印与导出**：通过 macOS 系统打印面板打印，或导出 PDF。可用操作取决于文档格式与权限。

PDF 默认锁定编辑，方便安心阅读。需要修改时，先选择 **启用编辑**；完成后保存，或另存副本保留原文件。保存副本可保留可编辑的表单和注释，导出 PDF 则用于生成静态阅读副本。

## 支持的格式

| 类型 | 格式 |
| --- | --- |
| PDF 与固定页面文档 | PDF、XPS / OXPS、SVG、DjVu |
| 电子书 | EPUB、MOBI、AZW、PRC、FB2 / 压缩 FB2 |
| 漫画与图片 | CBZ、CBR、CB7、CBT、图片文件夹；常见图片格式，包括 GIF、TIFF、JPEG XL |
| 文本与网页 | Markdown、HTML / XHTML、CHM、TXT 等纯文本、TCR |
| 其他兼容格式 | PDF 兼容的 AI、P7M 封装、LIT |
| 需额外软件 | PostScript / EPS：需自行安装 Ghostscript |

大型 Markdown 使用 MuPDF 分页阅读，也可选择 WebKit 兼容模式；HTML 和 CHM 使用 WebKit 阅读。HTML、CHM 与 Markdown 兼容模式的打印及 PDF 导出通过 MuPDF 排版，输出效果可能与阅读界面有所不同。

格式支持不代表覆盖每一种文件变体。Sumra 不提供 OCR 或 DRM 移除；扫描件的文字搜索需要文件本身具有文本层。更详细的支持范围见[格式与引擎说明](docs/SUMATRA_ENGINE_PARITY.md)。

## 快速开始

1. 按 **⌘O** 打开文件，或将文件拖入 Sumra。
2. 打开侧边栏查看目录、缩略图或书签；目录中的搜索框用于查找章节标题。
3. 按 **⌘F** 搜索文档文字。
4. 在 **显示** 菜单中调整布局与主题；电子书和文本可进一步调整排版。
5. 下次从首页或最近文件打开，继续上次的阅读位置。

更多操作可在应用的 **帮助 → 键盘快捷键** 中查看，快捷键也可在设置中自定义。

## 从源码构建

需要 macOS、Apple Swift 工具链与 macOS SDK，以及 CMake。原生依赖使用构建脚本指定的版本，首次构建需要联网；Swift Package Manager 获取固定版本的 Sparkle。

```sh
git clone https://github.com/Ares-X/Sumra.git
cd Sumra
./scripts/build-app.sh
open dist/Sumra.app
```

如尚未安装 CMake，可通过现有包管理器安装；使用 Homebrew 时为 `brew install cmake`。优化构建使用 `./scripts/build-app.sh --release`，构建并启动开发实例使用 `./scripts/run-dev.sh`。本地构建默认采用临时签名，不会自动发布。

Sumra 是图形应用，文件打开、文档工具与打印均通过界面操作。依赖来源、版本与许可见 [THIRD_PARTY.md](THIRD_PARTY.md)；实现进展见[开发说明](docs/IMPLEMENTATION_STATUS.md)。

## 许可与致谢

新编写的 Sumra 代码采用 **[AGPL-3.0-or-later](LICENSE)**。上游与移植组件保留各自的许可及版权声明，详见 [THIRD_PARTY.md](THIRD_PARTY.md)。

感谢 [SumatraPDF](https://github.com/sumatrapdfreader/sumatrapdf)、[MuPDF](https://mupdf.com/) 及其他上游项目。Sumra 是独立的 macOS 项目，并非 SumatraPDF 官方 macOS 版本，也不承诺与其全部功能完全一致。
