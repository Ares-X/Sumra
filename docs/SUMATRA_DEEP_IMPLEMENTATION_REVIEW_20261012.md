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
| 未分页章节起点的 bookmark.count=0 被当成旧有限分页位置，触发整章旧几何布局 | count>1 或位置在后续页的真实旧分页记录做迁移；未解析章节起点直接使用最终自然几何 | Sumatra `DisplayModel::SyncWithEngineLayout` 与既有 ChapterTable。新 EPUB 用例检查正确章节、source、一次布局和一次发布；真实旧分页精确恢复用例保留 |
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

## 第二轮无效路径与设计检查

以 `cee5afbd2c34a8675a018d1da4295ae3ca2a73f3` 为基准，再次核对生产调用者、实际输入与上游 owner。

- 页面几何只消费已缩放尺寸：删除仅由测试调用的旧缩放入口、恒为 1 的 scale 和单字段 Placement 包装，直接使用 CGRect。缩放由现有 ReadingZoom / RasterLayout 承担，行布局测试迁到实际 displaySizes 入口。
- Palm 正文由 palmContent 消费，Print Replica 由 PDF 提取消费：删除没有产品调用者的 raw Palm 分支和测试解压转换包装；MOBI PDF 提取复用已经解析的数据库。章节与行偏移由同一次 index 扫描产生，删除仅测试使用的第二扫描入口及其开关。
- PDF 签名使用 SigningIdentity：删除没有产品调用者的 URL / SecIdentity 适配器、未读取的证书元数据及 C 输出、签名对话框的无效坐标标记。重复签名校验在 sign 合并；批注 preset 的校验和多页 edit 翻译在实际输入 owner 执行一次。
- 文本页跳转直接使用 restore；浏览器当前页直接使用 immutable identity。搜索只使用实际调用者提供的解码器，删除独立 fetch/parser fallback、Promise 链、恒真的 scroll 参数、重复样式初始化状态及不可能的零宽 literal-match 分支。
- 删除没有消费者的 RasterMatch.lastRects 和与合成 Codable 完全相同的手写键表。MuPDF bounds 使用上游页查找的合法性检查；源码 anchor 的 page loader 已确保布局，无需额外计数。内部旧 lf_count 没有 MuPDF 调用者，codec 的真实 lf_count 保留。

完整页/瓦片缓存、章节 generation、实际读取取消、旧阅读位置迁移、保存源版本与密码权限有当前消费者；本轮没有用删除这些功能来减少代码。
四个子agent完成后，核对会话日志与父子关系，停止三组闲置 Serena/SourceKit 进程；PDF 与 native 任务报告的同一组 PID 只清理一次，共享服务保留。

本轮原生重建与 ARM64/macOS 13 发布构建通过；101 项 core 检查通过，283 项 reader/native 检查中 282 项通过。
连续小幅滚轮的一项用例出现三处断言失败，不能报告整组通过。使用修改前的 TextReader 单独复测，结果相同；
直接交给 NSScrollView 也没有位移，换正式滚轮事件或显示测试窗口均未解决。探针和无效尝试已撤回，原测试未削弱。
界面工具再次确认 Mac 锁定且自动解锁失败；尚不能把这个失败归因于锁屏，也没有证据支持加入产品 workaround。
该用例需在可用界面下定位，签名客户端的原书验收仍未完成。

本轮再次读取同一 20.65 MB Markdown B04 原文件：打开 0.165 s，首次自然布局 1.699 s，
首块区域像素 0.004 s；单页、双列、返回连续布局分别为 0.205 / 0.533 / 0.519 s。
换字体重新打开并恢复 source 用时 1.845 s；测试进程峰值 RSS 为 605,323,264 字节。
source / sourceRevision、模式往返、重开检查通过，原文件前后 SHA-256 相同。
这是独立原生测试进程，未清除系统文件缓存，没有写用户偏好或阅读记录；
不能代替客户端首屏、总内存和历史 13.528 秒事件的验证。
本轮日志与收据保留在 `build/validation-minimal-round2-20261012`，临时测试与源码比较副本已退休。

## 第三轮行为与实际开销复查

基准为 `f2e7bfe77e1ab7698efe105f3b45e286e1caf970`。三个独立任务复查打开状态、
浏览器/PDF 调用链与 native 开销，主代理增加跨书位置反例并核对最终实现。

- Markdown 首次打开错误地用离开书籍的历史策略读取本书位置。旧实现的回归用例出现三处断言失败；
  只纠正策略后，窗口失焦保存旧书仍会把旧书的内存坐标传给新书，反例继续失败。
  最终由 persistedMarkdownPosition 只读取指定书籍的持久化记录，并接受本次打开已捕获的历史策略；
  内存位置仅在同书模式切换分支读取。清空内存的位置合并到成功发布新书时，旧书在打开失败后仍保有状态。
- RasterMatchFragment.start/length 没有产品消费者，已从 native JSON、Swift 模型/解码与回退构造中删除。
  连续 Markdown 搜索不再 flatten 整块结构文本、分配字符映射、计算无用 UTF-16 范围。
  既有字符/矩形遍历同时判断 source 是否出现，遵循上游 util.c::do_flatten 的软连字符和 joined-line 规则；
  直接复用结果 JSON 缓冲区，不增加第二个矩形缓冲区。分页的真实导航 index 保留，找到首个 source 后结束 offset 扫描。
- 浏览器搜索取消、页身份、签名坐标/校验、preset owner、live PDF 信息复查未发现可证明的新增缺陷，未为其增加封装或防御分支。

最终 75 项相关检查通过，覆盖新的历史/跨书反例、原有模式位置、跨页搜索、source、几何、取消、
隐藏内容、空白、连字、emoji 与重排。原生引擎重建通过。
三个任务结束后，三组闲置 Serena/SourceKit 进程已按 session log 和父子关系停止，主代理复查均已消失；共享服务保留。

滚轮对照使用一个独立的标准 NSScrollView，不含 Sumra 文本控件。直接传入合成 began 事件时，
采样显示系统 concurrent gesture monitor 等待下一事件；试验已停止，日志/采样保留。
无 phase 的精确事件在标准控件同样没有位移。这说明该直接调用探针不能证明实际滚轮工作，
尚不能据此判断 Sumra 的真实滚动缺陷或把问题归因于锁屏。临时诊断已移出 Tests，原滚轮用例未削弱。
界面工具再次确认 Mac 锁定，真实手势验收与历史 13.528 秒事件仍未完成。
本轮证据保留在 `build/validation-careful-round3-20261012`。

最终发布构建通过（ARM64、最低 macOS 13）。同一 20.65 MB Markdown B04 原书再次通过独立 native 探针：
打开 0.150 s、自然布局 1.678 s、首块区域像素 0.003 s；单页/双列/返回连续布局为 0.208 / 0.533 / 0.529 s。
32 条实际搜索结果在连续、单页、双列、返回连续模式分别用时 0.052 / 0.025 / 0.025 / 0.052 s，
命中数、首个 source 与非空高亮矩形保持一致。换字体重开并恢复 source 为 1.848 s；
本次包含搜索的测试进程峰值 RSS 为 614,793,216 字节。原书前后 SHA-256 相同。
未清除系统文件缓存，没有用户偏好或阅读记录写入；这些数字不代表客户端首屏或客户端总内存，
没有用原生布局的快次结果替代 13.528 秒事件的定位。临时原书测试已退休，复现源码和日志仅保留在本轮本地收据。

## 首批验证与未完成的验收

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

## 解锁后的签名客户端原书验收

Action `38220287510` 的 `34eb9705` 候选 ZIP、源归档、provenance、checksum 和
feed 均通过校验；应用 181 个文件与冻结 inventory 一致，严格签名校验通过。
实际运行的是这些签名文件，ARM64，最低 macOS 13；没有本地重签名。

20.65 MB 原书 B04 从 load-entry 到首次 canvas draw 为 2.282 s，首次自然布局
1.779 s。小幅连续滚轮产生 103 / 207 px 位移，没有纸页跳转；单页、双页与
返回连续、426 个搜索命中和实际高亮、章节跳转、全新进程重开同一章节位置均通过。
首次采样峰值 physical footprint 为 840 MB；模式/搜索/章节操作后约 586 MB，
该进程生存期峰值约 916 MB。14.17 MB 原书 B02 首次布局 0.973 s，
load-entry 到新 canvas draw 为 1.757 s，模式往返恢复原文和同一滚动比例。
TXT 原书在实际 scroll area 中正反向小幅滚动、单页翻页及双页→连续保持原段落也通过。
这些运行没有清除系统文件缓存，canvas draw 计时不等于合成器首屏呈现时间。
TXT 的实际滚轮结果没有抹去前述合成事件测试的失败与诊断限制。

随后用原签名 0.2.1 的实际 GUI 执行 Check for Updates、Install Update、
Install and Relaunch。Sparkle 安装后的 181 个文件仍与 Action 候选完全一致。
**阅读位置验收失败**：旧版第 130 页的 source passage 未恢复，新版显示书首。
原文件 FileVersion 与旧 sourceRevision 完全相同；Markdown 直接打开原书，
未经过临时 HTML。真正的不匹配是旧版浅色主题只散列用户 CSS，而新版
effectiveUserCSS 包含生成的浅色 palette，样式签名因此改变。

修复在 NativeFile 只增加精确的旧浅色 identity：只有当前浅色主题且 CSS
以其完整生成 palette 前缀开头时，才认可去掉该前缀后的旧 hash。
现有候选记录仍认可；原源、真实用户 CSS 和出版社 CSS 开关改变仍拒绝旧记录。
11 项 viewport/source 回归通过，发布构建通过。Action `38269882069` 的
`dc894452` 签名候选随后完成同一旧位置的真实 Sparkle 升级重放：旧记录、原文件
与失败次相同，安装后 181 个文件与 Action inventory 一致，原段落恢复。
load-entry 到首次 canvas draw 为 2.480 s，首次自然布局 1.875 s；采样峰值
physical footprint 809 MB，末 5 秒中位数 514 MB。单页、双页与返回连续保持原段落；
双页 AX 文本只有前 500 字符，该段通过真实画面确认。模式往返、完全退出后新进程
重开均恢复相同的 0.0042069324 滚动比例。原书 SHA-256 不变。
临时 feed 覆盖已恢复，测试应用已退出，相关子agent的闲置 Serena/SourceKit
已按自己的 session 与日志确认归属后停止。原始失败和测量保留在
`build/validation-gui-round3-20261012`。

历史 13.528 s 事件仍未查清。原 PID 的系统记录有 5.044 / 7.593 s 空档，
但缺少同时阶段计时和线程采样；空档不能证明在执行哪项阻塞工作。
其他 PID 的 Malware 拒绝不是该事件原因，后来的较快原书结果也不能替代定位。
性能/发布目标尚未完成，候选仍未公开。

## 连续正文进度与旧 EPUB 位置复查

签名客户端 Home 实际将自然正文的“第 1 页／共 1 页”显示为 100%，而 B04
实际滚动比例仅 0.0042069324。两个现有 native 滚动 owner 直接用文档与 clip
几何记录可选 scrollFraction；Home 对完整单画布显示百分比，固定分页仍按页数显示。
隐藏滚动条不影响记录。旧自然流记录没有比例时不再推断 100%；模式目标只使用
所属坐标的比例，兼容浏览器模式清除 native 比例。真实隐藏滚动视图首／中／末
位置通过捕获→JSON 保存检查。Action `38274383226` / `37dc3ac` 的签名 GUI
确认 B04 Home 显示 0.4%，与实际滚动比例完全一致；完全退出重开和
Single/Two/Continuous 往返均恢复同一原文与比例。首次 canvas draw 2.304 s，
自然布局 1.846 s，采样峰值 physical footprint 779 MB，末 5 秒中位数 527 MB。
模式往返后为 452 MB。六个发布资产和 Ed25519 更新签名通过，应用 181 文件
与 Action inventory 完全一致，没有重签名。

实际多章节 EPUB B01 重开恢复了全部已捕获原文，但相同 source 的全画布滚动
比例从 0.0161819 变为 0.00356286：尚未布局章节使用估算高度，比例随布局变化。
Home 因此只在完整单画布显示滚动百分比；多章节自然流使用已有稳定章节位置，
标为 Chapter，而不把临时估算高度当成全书阅读进度。Action `38277846630` /
`989e646` 的最终签名 GUI 通过：EPUB 重开前后均显示 Chapter 3、进度
0.0050675676，原文 512 字符逐字一致；MOBI B13 的实际与 Home 比例均为
0.1962451207，显示 19.6%；B04 保持 0.4%。不改 source 恢复或原生布局。
六个新资产、Ed25519 更新签名与应用完整 inventory 均通过。正常版已装入同一
签名文件；9 个 Mach-O 均包含 ARM64，最低系统不高于 macOS 13，物理 macOS 13
执行仍未验收。历史 13.528 s 原因仍未查清，未因此公开新 Release。
正常版全新进程再次打开 B04：首次 canvas draw 2.268 s，自然布局 1.779 s，
120 次采样峰值 physical footprint 799 MB、末 5 秒中位数 547 MB；11 个 viewport
事件，原文与同一滚动比例恢复。实际反向小幅滚动回到升级验收前原段落与
0.0042069324 比例。原书字节不变，验收应用与采样／日志进程已退出。

相关检查发现旧两段式 EPUB bookmark `20:1` 的 source 恢复失败：没有 count
被当成未分页章节，旧有限页坐标直接进入自然正文。撤去新增比例捕获时仍有相同
12 处失败。初始布局判断现在保留后续页代表旧有限分页这一语义；未解析的章节
起点仍直接使用自然几何，不增加整章旧布局。原恢复断言保留。
修复后 15 项相关 source、滚动比例、PDF 与模式恢复检查全部通过；旧 EPUB 的
12 处坐标断言全部恢复通过。四项初始布局检查也通过，未分页章节只布局一次，
真实旧有限分页仍先解析 source 再使用最终自然几何。
