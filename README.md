# pdf_ai_parser

PDF / AI 文件解析导入组件。将 Adobe PDF / Illustrator (AI) 文件解析为轻量级矢量元素列表（`ParsedElement`），可用于标签设计、图形编辑、打印排版等场景。

## 特性

- **两段式解析流水线**：PDF/AI → SVG → 元素列表，中间产物 SVG 也可直接使用
- **轻量中性 DTO**：返回 `ParsedElement`（形状/文本/SVG块/图片），不依赖宿主项目元素模型，方便集成
- **完整的 PDF 图形状态支持**：
  - 路径操作符（m/l/c/v/y/re/h 等）
  - 变换层（cm）与图形状态栈（q/Q）
  - **裁剪路径（W n）**：AI 导出的"山丘弧形裁剪"等
  - 专色（Separation）、Indexed 色彩空间、图片 XObject、嵌入字体
- **SVG 打散**：原生图元（rect/circle/ellipse/line/text）→ 独立元素；复杂 path/polygon → 独立 SVG 子文档
- **视图等比缩放**：导入元素自动缩放到目标尺寸

## 快速开始

```dart
import 'package:pdf_ai_parser/pdf_ai_parser.dart';

// 1. 读取 PDF/AI 文件字节
final Uint8List pdfBytes = File('label.ai').readAsBytesSync();

// 2. 两段式解析
final String svg = PdfParserService.convertPdfToSvg(pdfBytes);
final List<ParsedElement> elements = SvgParserService.parseSvgToElements(svg);

// 3. 使用解析结果
for (final el in elements) {
  switch (el.type) {
    case ParsedElementType.shape:
      final shape = el as ParsedShapeElement;
      print('矩形: ${shape.shapeType} ${shape.fillColor}');
    case ParsedElementType.text:
      final text = el as ParsedTextElement;
      print('文本: ${text.text}');
    case ParsedElementType.svg:
      final svgEl = el as ParsedSvgElement;
      // svgEl.svgContent 是独立 SVG 文档，可直接用 flutter_svg 渲染
    case ParsedElementType.image:
      final img = el as ParsedImageElement;
      // img.base64 是内嵌位图数据
  }
}
```

## 目录结构

```
pdf_ai_parser/
├── lib/
│   ├── pdf_ai_parser.dart              # 公开 API 入口
│   └── src/
│       ├── pdf_parser_service.dart     # PDF/AI → SVG（纯 Dart，零内部依赖）
│       ├── svg_parser_service.dart     # SVG → ParsedElement 列表
│       ├── models/
│       │   └── parsed_element.dart     # 轻量 DTO 元素模型
│       └── utils/
│           └── id_generator.dart       # ID 生成器
├── example/                            # 使用示例
└── test/                               # 单元测试
```

## 安装

在 `pubspec.yaml` 中添加：

```yaml
dependencies:
  pdf_ai_parser:
    path: ../pdf_ai_parser  # 本地路径依赖
```

或发布到 pub.dev 后：

```yaml
dependencies:
  pdf_ai_parser: ^0.1.0
```

## 解析说明

### 两段式流水线

1. **`PdfParserService.convertPdfToSvg(bytes)`**
   纯 Dart 状态机逐 token 解析 PDF 内容流，输出带垂直翻转变换的 SVG 字符串。支持 FlateDecode 压缩流、图片 XObject、Indexed 色彩空间、Separation 专色、裁剪路径等。

2. **`SvgParserService.parseSvgToElements(svg)`**
   将 SVG 递归打散为轻量元素列表。复杂路径包裹为独立 SVG 子文档，保留 clip-path 引用与 CSS 样式内联。

### 返回的 DTO

| 类 | 说明 |
|---|---|
| `ParsedShapeElement` | 矩形/圆形/椭圆/线段/多边形/路径，含 fill/stroke 颜色与线宽 |
| `ParsedTextElement` | 文本内容、字号、颜色、字体 |
| `ParsedSvgElement` | 复杂路径打散后的独立 SVG 文档片段 |
| `ParsedImageElement` | 内嵌 base64 位图 |

每个元素均含：`id`、`name`、`x/y/width/height`（画布坐标）、`zIndex`。

## 测试

```bash
flutter test
```

## License

MIT
