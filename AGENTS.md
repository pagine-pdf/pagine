# pagine 开发与协作指南

本项目是面向 **Zig 0.17+** 的高性能声明式分页文档引擎，灵感源自 .NET QuestPDF，底层基于 `skia-zig`（Skia + HarfBuzz + ICU + SkParagraph + PDF/SVG/Raster）。

## 架构铁律

1. **纯 Zig 核心与 Skia 后端解耦**：`src/core.zig` 及其传递依赖（`geometry.zig`、`style.zig`、`tree.zig`、`state.zig`、`builder.zig`、`layout/*`、`backend/sink.zig`）禁止直接 `@import("skia")`，保证 `zig build test-core` 无需链接 Skia 即可毫秒级验证全部布局与分页算法。
2. **不可变 Arena 树 + 外置平铺 `StateStore`**：
   - 文档树节点、字符串与表单元全部存储在 `Tree.arena` 连续数组中，组合完成后保持只读；
   - 所有分页游标与 `Dynamic` 用户状态集中在 `StateStore` 平铺缓冲区（`u32_slots` / `bool_slots` / `hard_bool_slots` / `align(16) dyn_bytes`），通过 `@memcpy` 实现 O(N) `checkpoint`/`restore` 与跨 Pass 重置，禁止向节点树注入可变代理对象。
3. **热路径零多余 `try` 与粘滞错误**：组合期 Builder 方法（`Slot` / `ColumnBuilder` / `TableBuilder` / `RichTextBuilder` 等）不返回错误联合，所有 OOM 或结构冲突（如单子项槽位重复赋值）写入 `Tree.compose_error`，在 `validate()` 或 `render*()` 边界统一返回。
4. **严格生命周期与零泄漏底线**：所有测试必须使用 Zig 0.17 `std.heap.SafeAllocator` 并校验 `deinit() == 0`；Skia 原生句柄（`Image`、`SvgDom`、`Paragraph`、`StructureElementNode` 等）必须有确定的 `deinit()` 释放路径。
5. **Zig 版本约定**：遵循 **Zig 0.17.x** 惯用写法（`@backingInt`/`@fromBackingInt`、`@splat`、`std.heap.SafeAllocator`、`allocator.print`/`dupeSentinel`、`run.addPassthruArgs()`、显式 `std.Io`）。

## 常用验证命令

```bash
# 纯 Zig 布局核心单测（不链接 Skia，最快反馈）
zig build test-core

# 全量单元测试 + Skia PDF/PNG/SVG 集成测试（SafeAllocator 零泄漏）
zig build test

# 构建并运行精选示例（临时输出请写到 /tmp，避免污染仓库）
zig build examples
zig build run-invoice -- /tmp/pagine_invoice.pdf
zig build run-report -- /tmp/pagine_report.pdf

# ReleaseFast 吞吐基准与代码格式检查
zig build bench
zig build fmt-check
```

- 默认通过 `../../skia-zig/skia-zig/.skia/out/<arch>-<os>-release` 加载本地 Skia 静态库，可用 `-Dskia-lib-dir=<dir>` 覆盖。

## 文档与工程规范

- 核心文档归属（修改对应能力时同步更新）：
  - 架构与设计决策：[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
  - 开发者使用指南：[docs/GUIDE.md](docs/GUIDE.md)
  - 工作进度与交接存档：[docs/PROGRESS.md](docs/PROGRESS.md)
- 代码测试按风险覆盖：布局核心用 `RecordingSink` + `MockTextEngine` 做精确坐标/分页断言；集成测试验证真实 PDF/PNG/SVG 产物与零泄漏，不堆积低价值样板测试。
- 及时清理临时生成的 `.pdf`/`.png`/`.svg` 文件；**永不启用 git worktree**。
