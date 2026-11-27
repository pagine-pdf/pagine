# pagine 架构与设计文档

> 状态：V1 已落地并验证（Zig 0.17.1 + `skia-zig`）。本文记录当前已实现的产品边界、核心架构决策、执行契约、内存模型与演进方向。

---

## 1. 产品定位与 V1 边界

`pagine` 是面向数据驱动业务文档（发票、报表、合同、对账单、手册）的 **Code-First 声明式自动分页文档引擎**，设计目标是在保持 QuestPDF 级排版表现力与 DX 的同时，发挥 Zig 零 GC、值语义与 Skia 原生图形优势。

### V1 范围与明确不做项（No-Gos）

| 维度 | V1 已包含 | 明确不做 / 延后 |
| --- | --- | --- |
| **文档模型** | 多 `PageSet`（固定/连续卷纸/弹性页）、5 槽位页面、多文档 `mergePdf`（连续/独立页码） | 外部已有 PDF 的读取、合并、加密或附件写入（不引入 `qpdf` C++ 依赖） |
| **布局与分页** | `Column`/`Row`/`Table`（跨行列+重复表头表尾）/`Decoration`/`Layers`/`Inlined`/`MultiColumn`（高度均衡）、全套盒模型与分页控制、`Dynamic` 页感知组件 | HTML/CSS 模板解析引擎 |
| **文本与语言** | 基于 `SkParagraph` 的富文本、样式继承、BiDi/RTL/CJK、动态页码与 Section 引用、行内链接与行内嵌入元素 | 默认 `@embedFile` 内嵌大体积字体（默认走系统字体 + 显式 `FontRegistry` 注册） |
| **图形与增强** | `Image`（按 DPI 自动下采样 + JPEG/PNG 去重缓存）、`Svg`、`svgPath`、`pagine.drawCanvas` 原生 `skia.Canvas` 逃生舱、圆角/虚线/渐变/阴影、PDF/UA 结构标签与大纲书签 | — |
| **输出与诊断** | PDF（含 PDF/A、PDF/UA）、PNG/JPEG/WebP、每页 SVG、`LayoutOverflow` 诊断树、`check_missing_glyphs` 缺字检测与 `debugArea` | Windows 专属 XPS 后端、独立 GUI 桌面端 Companion 预览器 |

---

## 2. 核心架构取舍（针对 QuestPDF 痛点的 5 项决策）

在调研 [QuestPDF](https://github.com/QuestPDF/QuestPDF) 源码（特别是 `DocumentGenerator.cs` 中记录的 GC 生命周期、指针追逐 Cache Miss、代理树重写与并发锁瓶颈）后，`pagine` 作出 5 项核心架构决策：

| 决策 | `pagine` 选定方案 | 放弃的备选及原因 | 接受的代价 |
| --- | --- | --- | --- |
| **D1 节点存储** | **Arena 扁平节点池（`NodeId = u32` + Tagged Union + 侵入式子链表）** | 每元素独立堆分配 + 虚函数多态：在 Zig 中既繁琐又破坏缓存局部性 | 单个节点不可提前独立释放（符合文档一次性构建/释放生命周期） |
| **D2 分页状态** | **不可变文档树 + 外置平铺 `StateStore`**（`u32_slots` / `bool_slots` / `hard_bool_slots` / `align(16) dyn_bytes`） | 状态内嵌在节点对象中：导致 `MultiColumn` 二分试算必须重写代理树并装箱状态 | 新增有状态节点时需在 `StateStore.initForTree` / `resetSubtree` 登记槽位 |
| **D3 DX 范式** | **Scoped Builder Handle + Struct Options + 粘滞错误**（16 字节栈值句柄，热路径无 `try`） | 回调闭包风格（Zig 无捕获闭包导致大量 `Ctx` 结构体样板）或全量值树构造（动态循环需手工管切片） | 组合错误延迟至 `validate()` / `render*()` 暴露 |
| **D4 核/端解耦** | **纯 Zig 布局核心（`src/core.zig`）通过极薄 `RenderSink` 与 `TextEngine` 接口隔离 Skia** | 布局引擎直接调用 `skia.*`：每次改算法都需链接 27 个 C++ 静态库且难以做确定性坐标断言 | 跨边界媒体/段落通过不透明句柄与轻量 vtable 转发（每个绘制元素一次间接调用，开销可忽略） |
| **D5 字体与画布** | **显式注入 `FontRegistry` + 原生 `drawCanvas` 逃生舱** | 全局隐式字体单例（易引发多线程锁竞争与初始化顺序问题）；放弃原生 Canvas（QuestPDF 因 ABI 冲突移除） | 多线程场景需调用方按线程持有或共享 `FontRegistry` |

---

## 3. 分层结构与模块职责

依赖严格单向向下，`core` 层对 `skia` 零依赖：

```text
用户代码 / examples / tests
         │
         ▼
  src/pagine.zig                 (完整公开入口：re-export core + media + fonts + backends + drawCanvas)
  ├── src/core.zig               (纯 Zig 布局核心入口，供 `zig build test-core` 无 Skia 独立测试)
  │   ├── geometry.zig           (Unit, pt/mm/cm/inch, Size, Point, Rect, EdgeInsets, PageSize/Mode)
  │   ├── style.zig              (Color, TextStyle 继承/解析, BorderStyle, LinearGradient, ShadowStyle)
  │   ├── tree.zig               (Arena 扁平节点池, NodeId, NodePayload, 粘滞错误, 外部资源清理表)
  │   ├── builder.zig            (Document, PageBuilder, Slot 及各容器/富文本 Builder 句柄)
  │   ├── state.zig              (外置 StateStore, checkpoint/restore, PageContext 页码与 Section 表)
  │   ├── backend/sink.zig       (RenderSink 接口, NullSink)
  │   └── layout/
  │       ├── space_plan.zig     (SpacePlan 四态协议)
  │       ├── text_engine.zig    (TextEngine 接口, PageNumber 格式化)
  │       ├── table.zig          (Table 自动占位规划, 跨行列冲突校验, 列宽计算)
  │       ├── engine.zig         (双阶段分页驱动, 全元素 Measure/Draw, 多文档合并)
  │       └── diagnostics.zig    (LayoutOverflow 根因追踪与树形报告格式化)
  ├── src/fonts.zig              (FontRegistry：系统 FontMgr + TypefaceFontProvider + FontCollection)
  ├── src/media.zig              (Image / Svg 引用计数封装与 retainRef 自动释放桥接)
  └── src/backend/
      ├── skia_canvas.zig        (SkiaCanvasDrawer：矩形/圆角/渐变/虚线边框/阴影/裁剪/媒体/注解)
      ├── skia_text.zig          (SkiaTextEngine：SkParagraph 构建、缓存、UTF-16 链接范围映射)
      ├── pdf.zig                (PdfBackend：PDF / PDF-A / PDF-UA StructureTree & Outline / mergePdf)
      ├── image.zig              (ImageBackend：PNG / JPEG / WebP 多页光栅渲染)
      └── svg.zig                (SvgBackend：每页矢量 SVG 导出)
```

---

## 4. 核心机制与关键契约

### 4.1 `SpacePlan` 四态协议与纯度不变量
每个布局节点实现 `measure(id, available) -> SpacePlan` 与 `draw(id, available)`：

- **`empty`**：空节点或在前序页已全部绘制完成，不占空间。
- **`wrap(reason)`**：在给定空间内连部分内容都无法放下；父容器据此换页，若根 `Page` 返回 `wrap` 则立即触发 `error.LayoutOverflow`（杜绝死循环）。
- **`partial_render(size)`**：本页绘制一部分，推进 `StateStore` 游标，剩余部分在下一页继续。
- **`full_render(size)`**：本页完整绘制完毕。

> **核心不变量**：`measure()` 必须纯且幂等，严禁修改 `StateStore` 游标或发出真实绘制；只有 `draw()` 允许推进状态游标。`MultiColumn` 与 `Dynamic` 在 `measure()` 中如需试算子内容，必须先通过 `StateStore.checkpoint()` / 临时副本隔离状态并在返回前恢复。

### 4.2 两阶段渲染（Two-Pass）与状态重置语义
`renderTree` 对同一棵不可变 `Tree` 执行两轮遍历：
1. **Pass 1（`NullSink` 干跑）**：走完完整分页循环，统计 `PageContext.document_length`（总页数）与全部 `Section` 的起止页码（`page_start..page_end`）。
2. **Pass 2（真实输出后端）**：执行 `state.resetAll(true)`（硬重置），带入已解析的总页数与章节表正式绘制。

**软重置 vs 硬重置**：
- 页眉、页脚、背景/前景水印、`Decoration.before/after` 与 `Repeat` 容器在每页绘制完毕后调用 `state.resetSubtree(root, false)`（软重置），使普通子项在下一页重复出现。
- `ShowOnce`、`SkipOnce`、`EnsureSpace` 的状态存放在 `hard_bool_slots` 中，**忽略软重置、仅响应硬重置**——因此页眉内嵌 `.showOnce()` 仅在第 1 页显示、`.skipOnce()` 从第 2 页起显示，与 QuestPDF 语义严格一致。

### 4.3 富文本缓存、逐页淘汰与 UTF-16 范围契约
- `SkiaTextEngine` 按 `NodeId` 缓存已构建的 `skia.paragraph.Paragraph` 与 `LineMetrics`；静态文本块在相同 `max_width` 下命中 O(1) 缓存；含动态页码的文本块仅在页码或渲染阶段变化时重建。
- **逐页 `SkParagraph` 淘汰**：非重复上下文（页眉/页脚/`Decoration.before/after`/`Repeat`/`MultiColumn.spacer` 之外）的 `TextBlock` 一旦完成最终绘制（Pass 2，或 Pass 1 已录制进 `SkPicture` 快照），立即调用 `TextEngine.evict(node_id)` 释放原生 `Paragraph`，将超大文档的排版峰值内存压至 O(1 页)。
- **缺字校验**：支持 `check_missing_glyphs = true`，基于 `SkParagraph::unresolvedGlyphs()` 在任意字体缺字时返回 `error.MissingGlyphs`。
- `Dynamic` 组件每页生成的临时子树标记 `is_ephemeral = true`，缓存键置高位掩码避免与主树 `NodeId` 冲突；同时通过 `DynamicContextInfo.measureElement` 支持在回调内精确测量候选元素尺寸以实现变高行装箱与每页小计。
- Skia `Paragraph::getRectsForRange` 按 **UTF-16 码元索引**（占位符占 1 码元）计算文本选区；`skia_text.zig` 精确维护 `utf16_pos` 偏移，确保中英文混排、Emoji、首行缩进与段间距场景下行内超链接与 `sectionLink` 点击热区坐标准确。

### 4.4 生产级性能优化机制
1. **预规划 `TableCache` 与 O(log N) 行定位**：渲染前仅对每个 `table_section` 执行一次 `planAndValidate`（含 O(N log N) 扫描线重叠单元格碰撞校验）并缓存于 `plan_arena`；跨页布局时通过 `lowerBoundByEndRow` 二分直达当前行、配合同页单条缓存与 O(本页单元格数) 行推进，彻底消除 `O(Pages × Cells)` 扫描与重复排序。
2. **静态子树 `SkPicture` 快照缓存**：在进入 Pass 1 前自底向上标记静态子树（不含动态页码、`Dynamic`、`ShowIf`、链接/节注解、PDF/UA 语义标签和自定义 `Canvas`）；对静态 `Page.content` 在 Pass 1 同步录制 `SkPicture` 显示列表，Pass 2 在可用空间一致时直接 O(1) `drawPicture` 回放并立即释放快照。
3. **DPI 感知图片下采样与编码去重缓存**：PDF/SVG 后端根据图片实际排版尺寸与 `target_dpi`/`raster_dpi`（默认 288 DPI）计算像素目标，对超大光栅图采用 Mitchell 立方滤波下采样；不透明图按 `quality` 编码为 JPEG、含透明通道图编码为 PNG，并通过 `SkImage::fromEncoded` 让 Skia PDF 直接内嵌压缩流；按 `(unique_id, width, height, quality)` 去重缓存避免跨页重复编码。
4. **多线程并发扩展**：`FontRegistry.InitOptions.enable_paragraph_cache` / `setParagraphCacheEnabled(false)` 透传至 `skia-zig` `FontCollection::getParagraphCache()->turnOn(false)`，配合每工作线程独立 `FontRegistry` 可实现无锁竞争的多核并行 PDF 生成。

### 4.5 内存与所有权模型

| 类型 | 所有权与释放方式 | 失败语义 |
| --- | --- | --- |
| `Document` / `Tree` | 独占内部 `ArenaAllocator` + 外部句柄清理表，`defer doc.deinit()` 一次性释放 | 组合期粘滞记录 `ComposeError`，渲染/校验期返回 |
| `Slot` / `*Builder` | 16 字节栈值借用句柄，无 `deinit`；生命周期受宿主 `Document` 约束 | 无错误返回；越界或重复挂载写入 `Tree.compose_error` |
| `FontRegistry` / `Image` / `Svg` | 包装 Skia 引用计数句柄，调用方 `defer x.deinit()`；传入 `Document` 时通过 `retainRef()` 增引用并随 `doc.deinit()` 自动 `unref` | 构造/解码失败返回明确错误集 |
| `skia.Data` / `RenderedPages` | 渲染产物独占返回，调用方 `defer out.deinit()` | 渲染错误时内部 `errdefer` 清理全部已分配资源，保障 `SafeAllocator` 0 泄漏 |

---

## 5. 实测性能基线

### 当前实测数据（Apple Silicon aarch64-macos, `zig build bench` ReleaseFast）
- **场景**：2,000 行 × 4 列（8,000 个富文本单元格）跨页表格 + 重复页眉/表头 + 动态 `Page X / Y` 页脚 → **55 页、192 KB 矢量 PDF**。
- **优化前基线**：`compose = 4.09 ms`，`render = 207.62 ms`，总耗时 `211.71 ms`（**259.8 pages/s**）。
- **当前实测**（启用预规划 `TableCache` + O(log N) 行定位 + 逐页 `SkParagraph` 淘汰 + `SkPicture` 静态快照缓存）：
  - `compose = 3.98 ms`，`render = 100.78 ms`，总耗时 `104.76 ms`（**525.0 pages/s**，约 1.9 ms/页，**总吞吐提升 2.02×**，含双 Pass、HarfBuzz 排版、字体子集化与 PDF 压缩）。
