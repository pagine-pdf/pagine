# pagine

[English](README.md) | [简体中文](README.zh_CN.md)

面向 **Zig 0.17+** 的高性能声明式分页文档引擎，灵感源自 .NET QuestPDF，底层基于 [skia-zig](https://github.com/skia-zig/skia-zig)（Skia + HarfBuzz + ICU + SkParagraph）。

## 核心特性

- **贴合 Zig 习惯的 DX（零闭包、热路径零 `try`）**：通过轻量栈值句柄（`Slot`、`ColumnBuilder`、`RowBuilder`、`TableBuilder`、`RichTextBuilder`）自然配合 Zig 原生 `for` / `if` / `switch` 与局部变量；内置 Arena 格式化 `slot.print(...)` 与粘滞错误收集。
- **高性能内存与分页架构**：
  - 全树存储在连续 Arena 节点池（`NodeId` 索引，零 GC、O(1) 整树释放、CPU Cache 友好）。
  - 不可变文档树 + 外置平铺 `StateStore`（`@memcpy` 快照回滚，无需代理树重写；同一 `Document` 可反复导出 PDF / PNG / SVG）。
  - 两阶段分页引擎，自动解析总页数 `totalPages()`、章节起止页码与可点击目录跳转。
- **完备的排版与分页能力**：
  - 多 `PageSet`（固定尺寸、连续卷纸、弹性页；5 槽位：`background` / `header` / `content` / `footer` / `foreground`）与多文档合并 `mergePdf`（连续或独立页码）。
  - 容器：`Column`、`Row`（`constant` / `relative` / `auto`）、`Table`（`ColSpan` / `RowSpan` 自动排布与冲突校验、跨页重复表头表尾）、`Decoration`、`Layers`、`Inlined` 换行流、`MultiColumn`（多栏排布 + 二分高度均衡）。
  - 分页控制：`pageBreak`、`showEntire`、`ensureSpace`、`showOnce`、`skipOnce`、`stopPaging`、`repeat`、`showIf` 以及页感知状态组件 `dynamic`。
  - 富文本排版：基于 `SkParagraph`，支持样式继承、BiDi/RTL/CJK、段落间距、首行缩进、行数截断、行内超链接与内部跳转、行内嵌入元素。
- **基于 Skia 的现代增强能力**：
  - 原生支持圆角、虚线边框、线性渐变背景、阴影与融合容器 `.box(...)`。
  - 提供类型安全的 `pagine.drawCanvas(slot, ctx, drawFn)` 逃生舱，在布局任意位置直接用 `skia.Canvas` 绘制图表、条码与矢量路径。
  - 原生 PDF/UA 无障碍结构标签（`heading(1..6)`、`semantic(...)`）与 PDF 书签大纲（Outlines）。
  - 同一份文档支持导出 **PDF**（含 PDF/A、PDF/UA）、**PNG / JPEG / WebP** 与每页 **SVG**。
- **可行动的布局溢出诊断**：约束冲突时立即返回 `error.LayoutOverflow`，避免死循环，并支持输出含 `@src()` 源码定位的约束追踪树。

## 快速开始

```zig
const std = @import("std");
const pagine = @import("pagine");

pub fn buildDoc(allocator: std.mem.Allocator) !pagine.skia.Data {
    var doc = pagine.Document.init(allocator, .{});
    defer doc.deinit();

    var page = doc.addPage(.{
        .size = .a4,
        .margin = .{ .all = pagine.mm(18) },
        .default_text_style = .{ .size = 10, .color = .slate_800 },
    });

    page.header().text("Hello pagine!", .{ .size = 20, .weight = .bold, .color = .blue_700 });

    var col = page.content().padding(.{ .vertical = 12 }).column(.{ .spacing = 8 });
    col.item().text("使用 Zig 0.17 + Skia 构建高性能声明式 PDF 文档。", .{});

    var ftr = page.footer().alignCenter().richText(.{});
    ftr.span("第 ", .{});
    ftr.currentPageNumber(.{ .weight = .bold });
    ftr.span(" 页 / 共 ", .{});
    ftr.totalPages(.{ .weight = .bold });
    ftr.span(" 页", .{});

    return try pagine.renderPdf(&doc, .{ .title = "Hello pagine" });
}
```

## 构建、测试与基准

```bash
# 纯 Zig 布局核心单元测试（无需链接 Skia）
zig build test-core

# 全量单元测试 + Skia 集成测试（SafeAllocator 零泄漏校验）
zig build test

# 构建并运行精选示例（商业发票 & 财务研报）
zig build examples
zig build run-invoice -- /tmp/invoice.pdf
zig build run-report -- /tmp/report.pdf

# ReleaseFast 吞吐性能基准
zig build bench

# Zig 代码格式检查
zig build fmt-check
```

## 文档

- [架构与设计文档](docs/ARCHITECTURE.md) · [开发者使用指南](docs/GUIDE.md) · [开发进度](docs/PROGRESS.md)

## 许可证

MIT — Copyright (c) 2026 Dacheng Gao，详见 [LICENSE](LICENSE)。
