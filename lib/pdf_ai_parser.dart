/// PDF / AI 文件解析导入组件。
///
/// 将 Adobe PDF / Illustrator (AI) 文件解析为轻量级矢量元素列表
/// （[ParsedElement] 体系），可用于标签设计、图形编辑等场景。
///
/// 两段式流水线：
/// 1. [PdfParserService.convertPdfToSvg]：PDF/AI → SVG 字符串
/// 2. [SvgParserService.parseSvgToElements]：SVG → [ParsedElement] 列表
library pdf_ai_parser;

export 'src/models/parsed_element.dart';
export 'src/pdf_parser_service.dart';
export 'src/svg_parser_service.dart';
export 'src/utils/id_generator.dart';
