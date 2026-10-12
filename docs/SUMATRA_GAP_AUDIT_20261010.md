# Sumatra 源码能力对照（2026-10-10）

2026-10-12 的[深度实现对比与直接替换](SUMATRA_DEEP_IMPLEMENTATION_REVIEW_20261012.md)
核对实际 owner、重复工作和已删除代码；本页保留能力差异，不重复列出实现历史。

三个子 agent 分别检查引擎、阅读交互和系统集成，主代理核对重要证据。
基准为本地 Sumatra `012d997f6a3a5c5c97b878e1a340db3bffde8c0e` 与当前 Sumra 工作树。
这是源码审计；不代表这些路径均已通过当前安装版本的真实 GUI 验收。

## 主要待补能力

| 能力 | 当前差距 | Sumatra 代码 | Sumra 代码 |
| --- | --- | --- | --- |
| 固定页 PDF／DjVu 跨页短语搜索 | 按页搜索，页尾与下一页开头之间的短语可能漏掉；原生重排文档已有跨页搜索路径 | `src/TextSearch.cpp:470` | `Sources/Sumra/Native.swift:960`、`Native/MuPDF.c:1571` |
| CHM 关键词索引 | 已有主题目录；未将 `.hhk` 解析成可导航的关键词索引 | `src/EngineEbook.cpp:1995` | `Sources/Sumra/BrowserReader.swift:59`、`:188` |
| 正向 SyncTeX | 已有 PDF 到源码的反向查询；未提供源码行列到 PDF 的 GUI 集成入口 | `src/PdfSync.cpp:929`、`src/PdfSync.h:38` | `Sources/Sumra/Synchronizer.swift:90`、`Native/SyncTeX.c` |
| 选区浮动工具栏 | 复制、朗读、批注动作已有；未提供选中文字后自动显示的快速工具栏 | `src/SelectionToolbar.cpp:690` | `Sources/Sumra/Pages.swift` 的选择结束和右键菜单 |
| 放大时翻页保持页内偏移 | 下一／上一页通常回到页首，没有上游可选的偏移保留行为 | `src/DisplayModel.cpp:2643`、`:2775` | `Sources/Sumra/ReaderState.swift:1265` |
| PDF 导航落点提示与保留缩放选项 | 已支持目的地落点和缩放；没有短暂标出目标位置及忽略目的地缩放的开关 | `src/SearchAndDDE.cpp:2276`、`src/DisplayModel.cpp:3624` | `Sources/Sumra/NativePDFActions.swift:105`、`Sources/Sumra/Pages.swift` 的链接导航 |
| 高级打印 | 没有自有奇偶页过滤及按文档各页尺寸选择纸张的选项；已有原尺寸／缩小／适配／拉伸、旋转、居中、页范围 | `src/Print.cpp`、`src/SumatraDialogs.cpp` | `Sources/Sumra/ReaderPrinting.swift:148` |
| 对象级 Smart Dark | 当前使用图像保留和栅格颜色处理，未移植上游对象 replay 阶段的深色处理；上游自身标为实验能力 | `src/EngineMupdf.cpp:7290` | `Native/PDFColors.c:1`、`:270` |

上游路径相对于 `build/deps/sumatra/`，Sumra 路径相对于仓库根目录。
建议优先补搜索准确性、CHM 索引；正向 SyncTeX 对 LaTeX 工作流价值较高。
浮动工具栏和 PDF 导航提示可改善日常阅读；实验深色渲染需要单独评估实际效果。

## 次要交互与定制差异

- 点击页边翻页：`src/Canvas.cpp:2768`；Sumra 现有工具栏、键盘和滚轮入口。
- 强制滚轮逐页／禁止边界翻页选项：`src/Canvas.cpp:4514`、`:4624`；Sumra 已有边界翻页和惯性处理。
- 末页之后额外滚动空间：`src/DocumentLayout.cpp:232`。
- Ctrl+Tab 松键确认的可视预览：`src/SumatraPDF.cpp:12318`；Sumra 已有 MRU 切换与显式 tabs palette。
- 固定页／漫画页间距定制：`src/DisplayModel.cpp:846`；Sumra 使用固定间距。
- 选区颜色定制：`src/Selection.cpp:548`；Sumra 使用 macOS 系统选区色。

## 已有实现与排除项

主要格式、页／章导航、单页／双页／连续入口、目录过滤、书签、选择复制、主要缩放、RTL、旋转、演示、自动滚动、PDF 密码权限、MuJS 表单、注释、journal 撤销、附件、保存、PDF 工具和签名均有实际 owner。
系统打开、最近文件、会话恢复、Open With、原生 tabs／工具栏和 Sparkle 更新已有 macOS 实现。
这些代码入口的存在不等于全部真实书籍的性能、效果和功能都已验收。

Windows shell 扩展、CLI 和静默打印不在图形 macOS 产品范围。
XFA、OCR、DRM 移除、云同步与完整 PAdES-LTV 未被本次对照证明为上游成熟且可直接迁移的缺失能力。
自然高度的无分页正文滚动是当前修复主线；Sumatra 本身的连续页面拼接不等同于这种正文流。
