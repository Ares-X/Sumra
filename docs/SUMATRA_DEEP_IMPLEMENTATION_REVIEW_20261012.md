# Sumatra 深度实现对比与替换（2026-10-12）

基准：Sumra `d1e234660697db0d271efd74c74b5cd43f1397d9`；
Sumatra `012d997f6a3a5c5c97b878e1a340db3bffde8c0e`；
MuPDF `f030eda1e472268667805f438e38cee8f1da61f8`。
MuPDF 对比读取已提交的上游文件，避免把本地补丁当作上游实现。
六个独立任务检查打开与状态、原生排版、渲染缓存、文本与浏览器、PDF 文档模型、归档与旧书解码；主代理核对证据并集成。

## 已替换的具体路径

| 原有问题 | 最终实现 | 成熟实现依据与验证 |
| --- | --- | --- |
| HUFF/CDIC、带 trailer 的 MOBI 已解压，随后再解压、重新拼装 PDB，让 MuPDF 再读一次 | 已解码正文和原编号资源直接交给既有 MuPDF MOBI HTML adapter；删除 repacker、填充、指针搬移、4096 字节重打包容量约束及旧接口 | `MobiDoc.cpp` 的 `LoadForPdbReader` / `GetRealRecordSize` 直接消费解码结果；MuPDF `source/html/mobi.c` 最终使用 HTML 文档。检查 HUFF 递归、trailer、编码、真实图片编号、导航与 Print Replica，新增真实 native opening 集成用例 |
| PDF 属性读取另外打开文件两次，重复创建 context、认证；已编辑文档却显示保存版本 | `Pages` 串行访问当前 `NativeFile`。属性和资源报告借用同一个 MuPDF context/document，复用上游 `pdfinfo.c` 的资源遍历与释放；删除文件输入 API、包装和私有 inspect 路径 | Sumatra `EngineMupdf.cpp:8088` / `:8643` 从当前文档取属性。检查源文件替换与删除后的资源、目录属性、未保存批注、Undo/Redo 不变、AES 认证、嵌入 XML 的 NUL 字节 |
| 阅读位置恢复先找源码所在页，再查同一源码；找到后仍 shaping 整个段落，最后丢弃无关字符 | 一次源码查找同时返回实际页号并绘制；用上游 `fz_html_restarter` 截止在目标 source word 后，保留前序跨 span 的组合字符上下文；移除旧的无消费者 source-page APIs 和补丁 | MuPDF `html-layout.c` 的 restarter 与 `html-outline.c` 的页号规则。检查分页首/中/末页、自然高度、连字、跨字体组合字符、空白及无效 source；没有跨重排指针缓存 |
| 图片缓存已命中，仍先加载 library、查 cookie symbols、分配取消对象 | `RasterDocument.prepareImage` 在同一 actor 操作内规范化宽度、定位、查询缓存一次；只有解码 miss 才创建 render cookie。实际正文测量、裁边与工程风格扫描仍持有可取消对象 | Sumatra `PageRenderService.cpp:240–245` 先检查请求/缓存，`EngineMupdf.cpp:7207–7212` 为实际渲染创建 cookie。检查缓存对象复用、取消命中、预测接续、内容适配、PDF 样式与可取消扫描 |
| 返回漫画 A 的缓存预览会关闭正在给 B 提供可见瓦片的 SVG decoder | 缓存命中先返回；区域请求或实际 cache miss 才按页退休 decoder | 缓存请求与实际解码分离。回归先渲染 B、删除测试拥有的 B 源文件，再命中 A 缓存，确认 B 的瓦片像素仍完全一致 |
| PDF / 原生页面 / 预热计算并排序整本已测量尺寸，返回值却无人消费 | 只对实际显示的图片集合计算估算尺寸，其他路径使用已取得的测量值 | Sumatra `DisplayModel.cpp:957–1005` 的尺寸估算用于图片集合；保留该真实消费者与初始相邻图片测量策略 |
| Markdown 初次 WebKit 导航与同页跳转再次检查源文件并决定 renderer | 当前已挂载文件及其 symlink alias 保留已选择的 renderer；真正的 sibling 文件继续执行类型与路由决定 | Sumatra `MarkdownModel::OnDocumentComplete` 更新显示文件身份。检查原文件变化、同文件 alias、不同行文密度的 sibling 与显式 reload |
| 浏览器更新源文件身份时求出了不会使用的有效 Markdown renderer | preference 查询有唯一 owner；实际 renderer 决定仍在打开 worker 执行，身份 retarget 不再扫源码密度 | 更新文件身份与打开决定各有实际调用者；与上一行使用同一策略 owner |
| 未分页章节目标的 bookmark.count=0 被当成旧有限分页位置，触发整章旧几何布局 | 只有 count>1 的真实旧分页记录做迁移；未解析章节直接使用最终自然几何 | Sumatra `DisplayModel::SyncWithEngineLayout` 与既有 ChapterTable。新 EPUB 用例检查正确章节、source、一次布局和一次发布；真实旧分页精确恢复用例保留 |
| 每次字号、主题、位置样式更新都遍历所有出版社 CSS / imports / inline style | 初始加载、stylesheet load、文档 CSS 开关承担规范化；日常 style update 不再重复遍历 | WebKit 已负责样式级联。实际 WebKit 用例检查重要作者颜色覆盖、背景图片保留、用户 CSS、CHM 字体/段落、模式与 source 位置 |
| 全文提取还保留每个 text node 和累计 offset 数组，没有生产消费者 | 删除数组与 indexed 分支；生产搜索继续使用有取消与让步的 streaming scan | 旧 Sumatra `BrowserDocView.cpp:95–110,166–182` 的全量字符串/节点索引会增加当前阅读器的物化成本。CHM 用实际 DOM Range 检查搜索 offset 与原文完整性 |
| 已捆绑 MuPDF 的计数 ABI 仍有旧接口 fallback | MuPDF 使用必需的 checked count ABI；其他实际解码器保留自己的 count ABI | 同一应用捆绑的 engine 与 caller 一起发布，不需要内部旧 ABI 兼容链；失败原因仍原样传播 |
| Markdown 遇到首个 raw HTML 节点后，继续遍历全部 AST 才选择普通 parser | 当分类已决定时立即结束遍历；正常 generated XML 与 raw HTML 路径不变 | cmark AST 提供 HTML 节点类型；已有表格、脚注、代码、跨段 raw HTML 用例验证输出 |

上一批预测任务接续、无用预热 metadata、Markdown 双重路由和当前 CHM topic refetch 的修复，
继续记录在[性能报告](LARGE_TEXT_PERFORMANCE_20261010.md#upstream-performance-audit-while-gui-access-is-unavailable-2026-10-12)，本批没有重复重写。

## 核对后保留的实现

- **PDF 模型**：旧 PDFKit 编辑对象桥已移除；当前 password、permissions、actions、annotations、MuJS forms、journal、saving 共用 MuPDF 文档。AppKit 控件与只读值快照有真实界面消费者。
- **缓存**：完整页预览、可见瓦片、替换期间保留的旧像素承担不同显示任务。删掉这些缓存会损失逆向滚动复用或连续显示；PDF 几何字典读取也不等同于渲染整本文档。
- **归档**：完整 entry cache、partial prefix、顺序游标、7z 解码与名称查找都有成熟实现依据和现有消费者；没有仅因其是本地代码而替换它们。
- **TXT / CHM / 自然正文流**：TXT 使用 TextKit 2 可见片段和共享内容存储；CHM 的中文硬换行重排是已要求的功能。Sumatra 的连续固定页面与旧 ebook 全文 `FormatAllPages` 不直接替代无纸页间隙的自然正文流。
- **source anchors、compact handles、width cache**：分别服务重开/重排位置、降低 flow 存储、复用实际字体测量。上游 live flow pointer bookmark 不能跨重新解析持久化。没有证据支持删掉这些功能或缓存。
- **边界检查**：源文件版本、保存目的地、实际密码权限、归档/格式记录边界、外部输出快照保护现有数据与消费者。本批未添加新的 dependency、重试、推断 fallback 或任意输入上限。

## 验证与未完成的验收

原生引擎重建成功。初次集成验证通过 29 项 core 与 62 项 reader/native 检查；
浏览器样式、CHM 重排/搜索与阅读模式 15 项通过。
缓存请求调整后的 40 项相关渲染、预测、PDF 内容/取消检查也通过。
最终集成后的 61 项原生、源码位置、渲染与 PDF 检查通过，覆盖新的源码定位用例及原有连字、跨字体组合字符、EPUB/旧位置恢复；
第一次原书探针在首次布局前传入旧位置，误用了要求已有布局的模式切换 API，报 Page out of range。
探针改为与正式初始打开相同的“首次布局 → source 恢复”顺序后，两本原书与 MOBI 全部通过。
失败日志保留，没有通过增加产品 fallback 掩盖探针错误。
发布构建成功，ARM64、最低 macOS 13；打包行为检查 58 项通过。
收据保留在 `build/validation-deep-upstream-20261012`。

### 实际本地图书的原生测量

每本书使用独立测试进程，读取原文件，不更改用户偏好或阅读记录。
未清除系统文件缓存；原生 decode/layout/region pixels 与测试进程峰值 RSS
不等同于安装客户端首屏或客户端总内存。

| 原书 | 打开 | 首次自然布局 | 首块区域像素 | 单页 / 双列 / 返回连续布局 | 换字体重开并恢复 source | 测试进程峰值 RSS |
| --- | --- | --- | --- | --- | --- | --- |
| 14.17 MB Markdown B02 | 0.129 s | 0.845 s | 0.003 s | 0.152 / 0.382 / 0.366 s | 0.976 s | 456 MB |
| 20.65 MB Markdown B04 | 0.148 s | 1.668 s | 0.003 s | 0.210 / 0.524 / 0.513 s | 1.855 s | 611 MB |
| 本地 MOBI B13 | 0.197 s | 0.046 s | 0.020 s | 0.012 / 0.011 / 0.011 s | 0.207 s | 131 MB |

三本均通过 source / sourceRevision 一致性、模式往返与重开验证；
打开前后 SHA-256 完全一致。实际本地扫描 PDF 的 live 信息/资源报告用时约 0.004 s，
报告 49,461 字节，dirty / Undo 状态不变。这是文档信息检查，没有替代扫描显示或 GUI 验收。
临时原书探针已从 Tests 移除，仅在本地 build 收据中保留复现源码与日志；不增加发布测试门槛。

**这些结果不是完整产品验收。** 当前 Mac 锁定，界面工具再次确认自动解锁失败。
新代码尚未在 Action 签名构建中完成用户原书的首开、模式切换、真实拖拽与内存验收；
原来的 13.528 秒只证明慢次 AX 可读状态，缺少同时的 first-paint、位置输入与线程采样，原因仍未查清。
不会用这批通过的测试或较快原生布局代替这个结论，也不会因此完成发布目标。

六个对比 agent 的闲置 Serena/SourceKit 进程已按各自 session log 归属后停止；
后续复查没有启动新索引或构建服务。共享进程保留。产品仍为 ARM64、macOS 13 起；
在 macOS 13 / M1 的实际 runtime 未验收。
