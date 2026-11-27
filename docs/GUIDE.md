# pagine 开发者使用指南

本指南面向在 Zig 0.17+ 项目中使用 `pagine` 生成 PDF、光栅图或 SVG 文档的开发者，涵盖接入步骤、核心心智模型、高频布局配方、多后端导出与排错方法。

---

## 1. 安装与项目接入

### 1.1 配置 `build.zig.zon`

```zig
.{
    .name = .my_app,
    .version = "0.1.0",
    .minimum_zig_version = "0.17.0",
    .dependencies = .{
        .pagine = .{
            .path = "../pagine", // 或通过 zig fetch 引入远程版本
        },
    },
    .paths = .{ "build.zig", "build.zig.zon", "src" },
}
```

### 1.2 配置 `build.zig`

```zig
const pagine_dep = b.dependency("pagine", .{
    .target = target,
    .optimize = optimize,
    // 若 Skia 预编译库不在默认相对路径，显式指定目录：
    // .@"skia-lib-dir" = "/path/to/skia-prebuilt",
});
const pagine_mod = pagine_dep.module("pagine");

exe.root_module.addImport("pagine", pagine_mod);
```

---

## 2. 核心心智模型

### 2.1 三步构建流程
1. 创建文档：`var doc = pagine.Document.init(allocator, .{}); defer doc.deinit();`
2. 添加一个或多个页面集（`doc.addPage(...)`），往页面槽位里组合布局与内容。
3. 导出产物：`pagine.renderPdf(&doc, .{ ... })` / `renderImages` / `renderSvg`（同一 `Document` 可多次导出不同格式）。

### 2.2 链式槽位（`Slot`）与顺序语义
- 所有单子项修饰方法都挂在 `Slot` 上并返回新的子 `Slot`，**自外向内生效**，修饰顺序直接决定视觉结果：
  - `slot.padding(.{ .all = 10 }).background(.slate_100)` → 先留 10pt 外边距，再填浅灰背景（CSS `margin` 效果）。
  - `slot.background(.slate_100).padding(.{ .all = 10 })` → 先填浅灰背景，再在内侧留 10pt 内边距（CSS `padding` 效果）。
  - 常规卡片推荐直接使用融合容器 `.box(.{ .padding = ..., .background = ..., .border = ..., .radius = ..., .shadow = ... })`，节点更少、代码更紧凑。
- **单子项约束**：一个 `Slot` 只能挂载一个子元素；如果重复往同一个 `Slot` 变量塞入两个子元素，不会立即崩溃，而是在 `doc.validate()` 或 `render*()` 时返回 `error.MultipleChildrenAssigned`。

### 2.3 零闭包与热路径零 `try`
组合阶段无需写满屏 `try`，也不需要把上下文打包成回调结构体——直接用 Zig 原生 `for`、`if`、`switch`、局部变量和 `slot.print(...)`（自动分配在文档 Arena 内）：

```zig
var col = page.content().column(.{ .spacing = 8 });
for (items, 1..) |item, i| {
    if (item.hidden) continue;
    col.item().print("{d}. {s}", .{ i, item.name }, .{ .weight = .medium });
}
```

---

## 3. 页面配置与单位

单位辅助函数统一换算为 PDF 点（`1 pt = 1/72 inch`）：`pagine.pt(12)`、`pagine.mm(15)`、`pagine.cm(2)`、`pagine.inch(0.5)`。

### 页面尺寸模式（`PageSizeMode`）
- **固定纸张**：`.a4`、`.a4_landscape`、`.letter`、`.letter_landscape`、`.a5`、`.postcard`，或自定义 `.{ .fixed = pagine.PageSize.custom(210, 148, .millimeter) }`。
- **连续卷纸（热敏小票/长图）**：`.{ .continuous = pagine.mm(80) }`（定宽，高度随内容自适应）。
- **弹性页面**：`.{ .flexible = .{ .min = .a5, .max = .a4 } }`。

### 页面 5 个槽位
| 槽位 | 是否受 `margin` 影响 | 是否跨页重复 | 典型用途 |
| --- | --- | --- | --- |
| `page.background()` | 否（满页） | 是 | 封面渐变、底纹、全页边框 |
| `page.header()` | 是 | 是 | 页眉标题、Logo、公司抬头 |
| `page.content()` | 是 | 否（**自动分页**） | 主体流式内容、表格、长文 |
| `page.footer()` | 是 | 是 | 页脚免责声明、动态页码 |
| `page.foreground()` | 否（满页） | 是 | 半透明水印（如 `CONFIDENTIAL`） |

一个文档可连续调用多次 `doc.addPage(...)`，实现「竖版封面 + 横版数据表 + 竖版附录」混排。

---

## 4. 布局容器配方

### 4.1 垂直流（`Column`）与水平行（`Row`）

```zig
var col = page.content().column(.{ .spacing = 10 });

var r = col.item().row(.{ .spacing = 12 });
r.constant(80).text("固定80pt", .{ .weight = .bold }); // 固定宽
r.auto().text("按内容自适应", .{});                    // 测量自然宽
r.relative(2).text("占剩余 2/3", .{});                // 按权重分剩余空间
r.relative(1).alignRight().text("占剩余 1/3", .{});
```

### 4.2 自动跨页表格（`Table`）
`Table` 自动支持表头/表尾每页重复、自动网格占位与 `ColSpan`/`RowSpan` 冲突校验（非法跨列在渲染前立即返回 `error.InvalidTableConfiguration`）：

```zig
var tbl = col.item().table(.{
    .columns = &.{ .fixed(36), .rel(3), .fixed(80) },
    .extend_last_cells_to_bottom = true, // 跨页底部对齐
});

// 每页重复的表头
tbl.headerCell().background(.slate_800).padding(.{ .all = 6 }).text("#", .{ .color = .white, .weight = .bold });
tbl.headerCell().background(.slate_800).padding(.{ .all = 6 }).text("项目", .{ .color = .white, .weight = .bold });
tbl.headerCell().background(.slate_800).padding(.{ .all = 6 }).alignRight().text("金额", .{ .color = .white, .weight = .bold });

// 表体单元格（支持自动顺序填充或 cellAt 指定行列与跨度）
tbl.cellAt(.{ .row_span = 2 }).background(.slate_50).padding(.{ .all = 6 }).text("合并两行", .{});
tbl.cell().padding(.{ .all = 6 }).text("子项 A", .{});
tbl.cell().padding(.{ .all = 6 }).alignRight().text("$100.00", .{});
tbl.cell().padding(.{ .all = 6 }).text("子项 B", .{});
tbl.cell().padding(.{ .all = 6 }).alignRight().text("$200.00", .{});

// 每页重复的表尾
tbl.footerCellAt(.{ .col_span = 3 }).background(.slate_100).padding(.{ .all = 4 }).alignRight().text("续下页 / 表尾", .{ .size = 8 });
```

### 4.3 流式换行（`Inlined`）与多栏均衡（`MultiColumn`）

```zig
// 标签流自动换行（支持 .left / .center / .right / .justify / .space_around）
var tags = col.item().inlined(.{ .horizontal_spacing = 6, .vertical_spacing = 6 });
for ([_][]const u8{ "Zig", "Skia", "PDF/UA", "Zero-GC" }) |tag| {
    tags.item()
        .box(.{ .padding = .{ .horizontal = 8, .vertical = 3 }, .background = .blue_100, .radius = 4 })
        .text(tag, .{ .size = 9, .color = .blue_900 });
}

// 报纸式双栏排版 + 自动二分高度均衡 + 中间竖线分割
var mc = col.item().multiColumn(.{ .columns = 2, .spacing = 16, .balance_height = true });
mc.spacer().alignCenter().lineVertical(.{ .thickness = 0.5, .color = .slate_300 });
mc.content().text(long_article_text, .{});
```

### 4.4 分页控制与复用组件
- **防拆分**：`col.item().showEntire()`（整块留在同一页，放不下则整体移至下一页；注意整块高度不能超过单页内容区，否则触发 `LayoutOverflow`）。
- **防孤立**：`col.item().ensureSpace(120)`（仅在元素首次出现的页面若剩余高度不足 120pt 则推至下一页）。
- **强制换页**：`col.item().pageBreak()`。
- **首/次页差异**：`showOnce()`（仅首现页显示）、`skipOnce()`（跳过首现页，次页起显示）——放在 `page.header()` 中可轻松实现「首页完整抬头 + 续页精简抬头」。
- **零装箱组件复用**：
  - 函数式：`renderAddressCard(col.item(), addr);`
  - 结构体组件：定义 `pub fn compose(self: Badge, slot: pagine.Slot) void` 后调用 `col.item().component(Badge{ .label = "PAID" });`。

---

## 5. 字体、富文本与跨页引用

### 5.1 字体注册（`FontRegistry`）
默认不传 `fonts` 时自动走系统字体；生产环境推荐显式创建并复用 `FontRegistry`，支持从文件或 `@embedFile` 零路径依赖注册：

```zig
var fonts = try pagine.FontRegistry.init(.{});
defer fonts.deinit();

// 方式 1：编译期嵌入字体（推荐发布二进制使用）
// try fonts.registerBytes(@embedFile("assets/Inter-Regular.ttf"), "Inter");

// 方式 2：运行时按文件路径加载
try fonts.registerFile("assets/fonts/Roboto-Regular.ttf", "Roboto");
```

### 5.2 富文本、动态页码、目录链接与行内组件

```zig
// 在目标章节外层打上 Section 标记
col.item().section("sec_summary").heading(1).text("财务汇总", .{ .size = 18, .weight = .bold });

// 富文本块：支持多样式 Span、外链、内部跳转、动态页码与行内微件
var rt = page.footer().alignCenter().richText(.{
    .alignment = .center,
    .style = .{ .size = 9, .color = .slate_600 },
});
rt.span("第 ", .{});
rt.currentPageNumber(.{ .weight = .bold });
rt.span(" / ", .{});
rt.totalPages(.{ .weight = .bold });
rt.span(" 页  ·  ", .{});
rt.sectionLink("跳转汇总(第", "sec_summary", .{ .color = .blue_600, .underline = true });
rt.sectionBeginPage("sec_summary", .{ .color = .blue_600, .weight = .bold });
rt.span("页)  ·  ", .{});
rt.hyperlink("官网", "https://example.com", .{ .color = .blue_600, .underline = true });
rt.span(" ", .{});
rt.element(.middle)
    .box(.{ .padding = .{ .horizontal = 4, .vertical = 1 }, .background = .green_200, .radius = 3 })
    .text("OK", .{ .size = 7.5, .weight = .bold, .color = .green_700 });
```

段落还支持 `paragraph_spacing`（`\n` 段间距）、`first_line_indent`（首行缩进）、`clamp_lines` + `clamp_ellipsis`（行数截断）及页面/容器级 `.direction(.rtl)`。

---

## 6. 图片、SVG、原生 Skia 画布与动态组件

### 6.1 图片（自动 DPI 压缩）、矢量 SVG 与内联 `svgPath`

```zig
var logo_img = try pagine.Image.fromBytes(png_bytes);
defer logo_img.deinit();
// retainRef() 会增加引用计数并由 Document.deinit() 自动释放
// 默认按排版尺寸与 target_dpi / PdfOptions.raster_dpi 自动下采样并用 JPEG/PNG 去重嵌入
col.item().width(120).imageRef(logo_img.retainRef(), .{
    .scaling = .fit_area,
    .target_dpi = 150, // 可选：单图覆盖目标 DPI
    .quality = .high,  // 可选：.very_low / .low / .medium / .high / .very_high / .best
});

var icon_svg = try pagine.Svg.fromBytes(svg_xml, &fonts);
defer icon_svg.deinit();
col.item().width(48).svgRef(icon_svg.retainRef(), .{ .scaling = .fit_area });

// 轻量内联 SVG Path（图标/徽章，无需完整 XML DOM）
col.item().size(20, 20).svgPath("M12 2L2 22h20Z", .{ .color = .blue_600 });
col.item().size(20, 20).svgPath("M4 12h16M12 4v16", .{ .color = .green_600, .stroke_width = 2.0 });
```

若希望某份 PDF 保留原始图片字节不做下采样，可在 `PdfOptions` 中传入 `.use_original_images = true`。

### 6.2 原生 `skia.Canvas` 逃生舱
需要绘制折线图、柱状图、二维码、印章或复杂贝塞尔路径时，直接在任意 `Slot` 中获取已平移到局部坐标系的 `skia.Canvas`：

```zig
fn drawSparkline(points: *const [6]f32, canvas: pagine.skia.Canvas, size: pagine.Size) void {
    var paint = pagine.skia.Paint.init(.{
        .color = pagine.colorToSkia(.blue_600),
        .style = .stroke,
        .stroke_width = 2.0,
        .anti_alias = true,
    });
    defer paint.deinit();
    // 使用 size.width / size.height 在 (0,0)..(w,h) 局部坐标系内绘制
    canvas.drawLine(0, size.height, size.width, 0, paint);
}

const slot = col.item().height(80);
pagine.drawCanvas(slot, &my_points, drawSparkline);
```

### 6.3 页感知状态组件（`dynamic` 与子元素测量）
当某块内容需要根据每页当前页码或剩余空间动态生成（如「变高行精确装箱 + 每页小计行」），使用 `slot.dynamic(State, init_state, composeFn)`，并通过 `info.measureElement(...)` 在提交前测量候选块尺寸。引擎自动隔离 `measure` 试算状态与两阶段重置：

```zig
const State = struct { cursor: usize = 0, items: []const []const u8 };
fn buildRow(txt: []const u8, s: pagine.Slot) void {
    s.padding(.{ .vertical = 4 }).text(txt, .{});
}
fn composePage(st: *State, info: pagine.DynamicContextInfo, slot: pagine.Slot) pagine.DynamicResult {
    var remaining_h = info.available_size.height - 24; // 预留每页小计高度
    var c = slot.column(.{});
    while (st.cursor < st.items.len) {
        const probe = info.measureElement(
            .{ .width = info.available_size.width, .height = remaining_h },
            st.items[st.cursor],
            buildRow,
        );
        if (!probe.fits_completely) break;
        buildRow(st.items[st.cursor], c.item());
        remaining_h -= probe.size.height;
        st.cursor += 1;
    }
    c.item().height(24).print("第 {d} 页累计处理 {d} 项", .{ info.page_number, st.cursor }, .{ .weight = .bold });
    return .{ .has_more_content = st.cursor < st.items.len };
}

page.content().dynamic(State, .{ .items = my_items }, composePage);
```

---

## 7. 多后端导出、PDF/UA 书签与文档合并

```zig
// 1. 导出 PDF（含 PDF/UA 标签、缺字检测与标题书签大纲）
var pdf = try pagine.renderPdf(&doc, .{
    .fonts = &fonts,
    .title = "年度报告",
    .author = "pagine",
    .lang = "zh-CN",
    .outline = .structure_element_headers, // 自动将 .heading(1..6) 转为 PDF 书签目录
    // .check_missing_glyphs = true,       // 缺字时立即返回 error.MissingGlyphs
    // .pdfa = true,                       // 按需开启 PDF/A-3b 合规模式
});
defer pdf.deinit();

// 2. 导出每页光栅图（.png / .jpeg / .webp）
var pngs = try pagine.renderImages(&doc, .{
    .fonts = &fonts,
    .format = .png,
    .dpi = 144.0,
});
defer pngs.deinit();
// pngs.items[0].bytes() 即第 1 页 PNG 字节

// 3. 导出每页矢量 SVG
var svgs = try pagine.renderSvg(&doc, .{ .fonts = &fonts });
defer svgs.deinit();

// 4. 合并多个 Document（.continuous 连续页码 / .independent 各自从 1 编号）
const docs = [_]*const pagine.Document{ &cover_doc, &body_doc };
var merged = try pagine.mergePdf(allocator, &docs, .continuous, .{ .fonts = &fonts });
defer merged.deinit();
```

---

## 8. 排错与布局溢出诊断

当出现约束冲突（例如 `showEntire` 内嵌高度大于整页可用高度，或定宽列总和超出页宽）时，`render*()` 会立刻返回 `error.LayoutOverflow` 防止死循环。

传入 `LayoutDiagnostic` 并在关键区域挂上 `.source(@src())`，即可获取可读的根因追踪树：

```zig
var diag: pagine.LayoutDiagnostic = .{ .allocator = allocator };
defer diag.deinit();

var pdf = pagine.renderPdf(&doc, .{
    .fonts = &fonts,
    .diagnostic = &diag,
}) catch |err| {
    if (err == error.LayoutOverflow) {
        std.log.err("{s}", .{diag.report});
    }
    return err;
};
defer pdf.deinit();
```

此外，在任意槽位链上临时插入 `.debugArea("header", .red_500)` 可在渲染结果中绘制半透明调试线框，辅助排查对齐与间距问题。

### 多线程并行渲染建议
高并发后端服务中同时生成多份 PDF 时，推荐每个工作线程独立创建 `FontRegistry` 并关闭 SkParagraph 内部缓存以消除锁竞争：

```zig
var fonts = try pagine.FontRegistry.init(.{
    .enable_paragraph_cache = false,
});
defer fonts.deinit();
```

完整端到端用法可参考 [examples/invoice.zig](../examples/invoice.zig) 与 [examples/report.zig](../examples/report.zig)。
