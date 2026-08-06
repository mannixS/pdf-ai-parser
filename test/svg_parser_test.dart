import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_ai_parser/pdf_ai_parser.dart';

void main() {
  group('SvgParserService CSS 内联与打散单元测试', () {
    test('将 SVG 内部 style 规则成功 inline 到行内 fill 属性 (支持多选择器与注释)', () {
      final svgWithStyle = '''
<svg viewBox="0 0 100 100">
  <defs>
    <style>
      /* 这是一个多选测试样式 */
      .cls-1, .cls-3 { fill: #ff0000; stroke: #000000; stroke-width: 2; }
      .cls-2 { fill: none; }
    </style>
  </defs>
  <path class="cls-1" d="M 0 0 L 10 10" />
  <rect class="cls-2" x="10" y="10" width="20" height="20" />
  <circle class="cls-3" cx="50" cy="50" r="10" />
</svg>
''';

      final inlinedSvg = SvgParserService.inlineSvgStyles(svgWithStyle);

      expect(inlinedSvg.contains('fill="#ff0000"'), true);
      expect(inlinedSvg.contains('stroke="#000000"'), true);
      expect(inlinedSvg.contains('stroke-width="2"'), true);
      expect(inlinedSvg.contains('fill="none"'), true);
      expect(inlinedSvg.contains('<style>'), false);
    });

    test('将 SVG 解析打散为可独立编辑的原生图元列表', () {
      final compositeSvg = '''
<svg viewBox="0 0 200 200" width="200" height="200">
  <rect x="10" y="20" width="50" height="30" rx="5" fill="#ff0000" />
  <circle cx="100" cy="100" r="20" fill="#00ff00" />
  <text x="50" y="150" font-size="12" fill="#0000ff">Hello World</text>
  <path d="M 10 10 L 20 20 Z" fill="#ffff00" />
  <g transform="translate(100, 100)">
    <path d="M 5 5 L 15 15" fill="#00ffff" />
  </g>
</svg>
''';

      final elements = SvgParserService.parseSvgToElements(
        compositeSvg,
        maxImportSize: 100.0,
        startX: 10.0,
        startY: 10.0,
      );

      expect(elements.length, 5);

      // rect
      final elRect = elements[0] as ParsedShapeElement;
      expect(elRect.shapeType, ParsedShapeType.rectangle);
      expect(elRect.name, '#1 矩形图层');
      expect(elRect.fillColor?.toARGB32(), 0xFFFF0000);
      expect(elRect.x, 15.0);
      expect(elRect.width, 25.0);
      expect(elRect.height, 15.0);
      expect(elRect.cornerRadius, 2.5);

      // circle
      final elCircle = elements[1] as ParsedShapeElement;
      expect(elCircle.shapeType, ParsedShapeType.circle);
      expect(elCircle.name, '#2 圆形图层');
      expect(elCircle.fillColor?.toARGB32(), 0xFF00FF00);

      // text
      final elText = elements[2] as ParsedTextElement;
      expect(elText.text, 'Hello World');
      expect(elText.name, '#3 文本图层');
      expect(elText.color.toARGB32(), 0xFF0000FF);

      // path → svg
      final elPath = elements[3] as ParsedSvgElement;
      expect(elPath.name, '#4 路径图层');
      expect(elPath.svgContent.contains('<path'), true);
      expect(elPath.svgContent.contains('viewBox="10.0 10.0 10.0 10.0"'), true);

      // nested path
      final elNestedPath = elements[4] as ParsedSvgElement;
      expect(elNestedPath.name, '#5 路径图层');
      expect(elNestedPath.svgContent.contains('translate(100, 100)'), true);
      expect(elNestedPath.x, 62.5);
    });

    test('修复回归：text 自身 matrix 平移定位（无 x/y 属性）不再堆叠左上角', () {
      final illustratorSvg = '''
<svg viewBox="0 0 400 300" width="400" height="300">
  <text transform="matrix(1 0 0 1 150 100)" font-size="20" fill="#000000">Alpha</text>
  <text x="50" y="200" font-size="16" fill="#000000">Beta</text>
</svg>
''';

      final elements = SvgParserService.parseSvgToElements(
        illustratorSvg,
        maxImportSize: 200.0,
        startX: 0.0,
        startY: 0.0,
      );

      expect(elements.length, 2);

      final textA = elements[0] as ParsedTextElement;
      expect(textA.text, 'Alpha');
      expect(textA.x, closeTo(150.0, 0.001));
      expect(textA.y, closeTo(80.0, 0.001));

      final textB = elements[1] as ParsedTextElement;
      expect(textB.text, 'Beta');
      expect(textB.x, closeTo(50.0, 0.001));
      expect(textB.y, closeTo(184.0, 0.001));
    });

    test('修复回归：嵌套 g 平移叠加 text 缩放 matrix 时按正确顺序级联', () {
      final nestedSvg = '''
<svg viewBox="0 0 400 300">
  <g transform="translate(100, 50)">
    <text transform="matrix(2 0 0 2 10 20)" font-size="10" fill="#000000">Hi</text>
  </g>
</svg>
''';

      final elements = SvgParserService.parseSvgToElements(
        nestedSvg,
        maxImportSize: 200.0,
        startX: 0.0,
        startY: 0.0,
      );

      expect(elements.length, 1);
      final text = elements[0] as ParsedTextElement;
      expect(text.x, closeTo(110.0, 0.001));
      expect(text.y, closeTo(50.0, 0.001));
    });

    test('修复回归：Illustrator 空格分隔 translate + 嵌套 tspan 文本块逐行正确定位', () {
      final illustratorSvg = '''
<svg viewBox="0 0 595.28 841.89">
  <text transform="translate(179.4 84.32)" font-size="5" fill="#000000">
    <tspan><tspan x="0" y="0">产品名称: 智能轻云盒</tspan></tspan>
    <tspan><tspan x="0" y="5.5">产品型号: </tspan></tspan>
    <tspan x="0" y="11">电源输入: 5V 2A</tspan>
  </text>
</svg>
''';

      final elements = SvgParserService.parseSvgToElements(
        illustratorSvg,
        maxImportSize: 200.0,
        startX: 0.0,
        startY: 0.0,
      );

      expect(elements.length, 3);
      expect((elements[0] as ParsedTextElement).text, '产品名称: 智能轻云盒');
      expect(elements[0].x, closeTo(179.4, 0.001));
      expect(elements[0].y, closeTo(79.32, 0.001));

      expect((elements[1] as ParsedTextElement).text, '产品型号:');
      expect(elements[1].x, closeTo(179.4, 0.001));
      expect(elements[1].y, closeTo(84.82, 0.001));

      expect((elements[2] as ParsedTextElement).text, '电源输入: 5V 2A');
      expect(elements[2].x, closeTo(179.4, 0.001));
      expect(elements[2].y, closeTo(90.32, 0.001));
    });

    test('修复回归：逗号/空格/混合分隔的 translate 与 matrix 均被正确解析', () {
      final mixedSepSvg = '''
<svg viewBox="0 0 400 300">
  <text transform="translate(100,50)" font-size="10" fill="#000000">A</text>
  <text transform="matrix(1, 0, 0, 1, 200, 150)" font-size="10" fill="#000000">B</text>
  <text transform="matrix(1,0,0,1,250,180)" font-size="10" fill="#000000">C</text>
  <text transform="translate(300 200)" font-size="10" fill="#000000">D</text>
</svg>
''';

      final elements = SvgParserService.parseSvgToElements(
        mixedSepSvg,
        maxImportSize: 200.0,
        startX: 0.0,
        startY: 0.0,
      );

      expect(elements.length, 4);
      expect(elements[0].x, closeTo(100.0, 0.001));
      expect(elements[0].y, closeTo(40.0, 0.001));
      expect(elements[1].x, closeTo(200.0, 0.001));
      expect(elements[1].y, closeTo(140.0, 0.001));
      expect(elements[2].x, closeTo(250.0, 0.001));
      expect(elements[2].y, closeTo(170.0, 0.001));
      expect(elements[3].x, closeTo(300.0, 0.001));
      expect(elements[3].y, closeTo(190.0, 0.001));
    });

    test('修复回归：中文文本宽度逐字符精确估算，避免画布换行后裁剪缺失', () {
      final cjkSvg = '''
<svg viewBox="0 0 400 300">
  <text x="10" y="50" font-size="10" fill="#000000">产品名称: 智能轻云盒</text>
</svg>
''';

      final elements = SvgParserService.parseSvgToElements(
        cjkSvg,
        maxImportSize: 200.0,
        startX: 0.0,
        startY: 0.0,
      );

      expect(elements.length, 1);
      final text = elements[0] as ParsedTextElement;
      expect(text.text, '产品名称: 智能轻云盒');
      // 9 个全角 × 1.0 × 10 + 2 个半角 × 0.7 × 10 = 104
      expect(text.width, closeTo(104.0, 0.001));
      expect(text.width, greaterThan(100.0));
    });
  });
}
