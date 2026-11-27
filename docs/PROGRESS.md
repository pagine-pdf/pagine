# pagine 进度与交接存档

## 已对齐的核心决策
1. **DX 风格**：Zig 惯用 Scoped Builder Handle + Struct Options + 粘滞错误（零闭包、无缝配合 `for`/`if`、链式无多余 `try`）。
2. **V1 能力边界**：
   - 包含：QuestPDF 核心分页排版能力 + 现代视觉增强（圆角、虚线边框、渐变背景、阴影）+ 原生 `skia.Canvas` 逃生舱 + PDF/UA 无障碍结构树 & PDF 书签大纲。
   - 不包含：外部 `qpdf` 依赖（不做已有 PDF 读写/加密）、XPS、GUI Companion App。
3. **字体策略**：默认走系统字体（`FontMgr.default()`）+ 显式 `FontRegistry.registerBytes/File`（支持 `@embedFile`，核心库不强制内嵌大字体）。
4. **`skia-zig` 协作边界**：允许按需小幅补充 `skia-zig` C 桥接。
   - **已同步修复**：
     - `~/Repos/skia-zig/skia-zig/csrc/sk_canvas.cpp` 中 `skz_canvas_annotate_url` / `annotate_named_destination` / `annotate_link_to_destination` 补齐 `SkData` 末尾 `\0`（修复 Skia `SkPDFDocument::ToValidUtf8String` 对非 NUL 结尾字符串返回空串的问题），已提交上游 `b9d63c9`。
     - `~/Repos/skia-zig/skia-zig` 暴露 `FontCollection.setParagraphCacheEnabled(bool)`（`csrc/sk_paragraph.cpp`、`csrc/include/skia_c.h`、`src/c.zig`、`src/paragraph.zig`），已增量重编 `libskia_zig_c.a`（本地未提交，待用户确认）。

## 里程碑进度
- [x] **M0**：工程骨架、`skia-zig` 桥接、几何/单位/颜色/样式、`FontRegistry`
- [x] **M1**：Arena 扁平节点树、外置 `StateStore`、双阶段分页引擎、基础页面与容器（`Page`/`Column`/`Row`/盒模型/分页控制）
- [x] **M2**：富文本引擎（`SkParagraph` 跨页分行、UTF-16 范围映射、样式继承、BiDi/RTL/CJK、动态页码、`Section`/`SectionLink`/`Hyperlink`、行内组件）
- [x] **M3**：`Table`（跨行列自动规划与冲突校验、重复表头表尾、跨页延展）、`Decoration`/`Layers`/`Inlined`/`MultiColumn`（含二分高度均衡）
- [x] **M4**：`Image`/`Svg`/`Canvas` 逃生舱、`Dynamic` 页感知状态组件、圆角/虚线/渐变/阴影、PDF/UA 结构标签与大纲、PNG/JPEG/WebP/SVG 多后端
- [x] **M5**：`LayoutOverflow` 诊断树（含 `@src()` 源码定位）、多文档 `mergePdf`、精选示例（`invoice.zig`、`report.zig`）、ReleaseFast 吞吐基准与 `README.md`
- [x] **M6（生产级加固与性能跃升）**：
  - `Table` O(N log N) 扫描线重叠单元格碰撞校验、`DynamicContextInfo.measureElement` 子元素测量、`check_missing_glyphs` 缺字报错与 `Slot.svgPath` 轻量矢量路径
  - DPI 感知图片自动下采样 + JPEG/PNG 重编码与去重缓存（800×800 缩略图场景 PDF 体积缩减 > 5×）
  - 预规划 `TableCache` + O(log N) 行二分定位 + 逐页 `SkParagraph` 淘汰 + 静态子树 `SkPicture` 快照缓存（ReleaseFast 基准从 259.8 pages/s 提升至 **525.0 pages/s**，**2.02×** 加速）
  - `FontRegistry.setParagraphCacheEnabled(false)` 并发开关与 4 线程并发 PDF 零泄漏集成测试
