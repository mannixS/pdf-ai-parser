## 0.1.0

- 首个发布版本：PDF/AI 文件解析导入组件
- 提供 `PdfParserService.convertPdfToSvg`（PDF/AI → SVG）
- 提供 `SvgParserService.parseSvgToElements`（SVG → `ParsedElement` 轻量元素列表）
- 支持：路径、矩形、圆形、椭圆、线段、多边形、文本、内嵌位图
- 支持 PDF 裁剪路径（`W n`）、专色（Separation）、Indexed 色彩空间、图片 XObject、`re` 矩形算子
- 不依赖宿主项目元素模型，返回中性 DTO，方便集成到任意 Flutter 项目
