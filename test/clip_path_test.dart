import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_ai_parser/pdf_ai_parser.dart';

Uint8List _buildMinimalPdf(String contentStr) {
  final streamData = utf8.encode(contentStr);
  final pdfBytesList = <int>[];
  pdfBytesList.addAll(utf8.encode('%PDF-1.4\n1 0 obj\n<< /Length ${streamData.length} >>\nstream\n'));
  pdfBytesList.addAll(streamData);
  pdfBytesList.addAll(utf8.encode(
      '\nendstream\nendobj\n'
      '2 0 obj\n<< /Type /Page /Parent 3 0 R /MediaBox [0 0 595.276 841.89] /Contents 1 0 R >>\nendobj\n'
      '3 0 obj\n<< /Type /Pages /Kids [2 0 R] /Count 1 >>\nendobj\n'
      '4 0 obj\n<< /Type /Catalog /Pages 3 0 R >>\nendobj\n'
      'xref\n0 5\n0000000000 65535 f \n0000000015 00000 n \n0000000100 00000 n \n0000000200 00000 n \n0000000300 00000 n \n'
      'trailer\n<< /Size 5 /Root 4 0 R >>\nstartxref\n400\n%%EOF\n'));
  return Uint8List.fromList(pdfBytesList);
}

void main() {
  group('PdfParserService W n 裁剪路径解析', () {
    test('W 路径定义生成 clipPath：y 坐标预翻转，无 transform', () {
      // 模拟 AI 导出的"山丘弧形裁剪"：
      // q 裁剪路径 ... W n，后续 path 在 cm 变换层内填充
      final contentStr = 'q 320.475 736.108 m 320.96 735.578 c '
          '321.727 736.285 322.877 736.285 323.521 735.578 323.521 735.578 l '
          '324.099 736.108 c 323.643 736.609 323.009 736.859 322.352 736.859 322.352 736.859 c '
          '321.695 736.859 321.018 736.609 320.475 736.108 h W n '
          'q 1 0 0 1 322.9316 733.8844 cm 0 0 m -3.056 2.105 l -1.29 4.667 l 1.766 2.562 l h f Q Q';
      final svg = PdfParserService.convertPdfToSvg(_buildMinimalPdf(contentStr));

      // 1. clipPath 定义必须存在
      expect(svg, contains('<clipPath id="clip_1">'));
      // 2. y 坐标预翻转：736.108 → 841.89 - 736.108 = 105.782
      expect(svg, contains('320.475 105.782'));
      // 3. clipPath 内不允许 transform（flutter_svg 渲染异常）
      final clipMatch =
          RegExp(r'<clipPath[^>]*>(.*?)</clipPath>', dotAll: true).firstMatch(svg);
      expect(clipMatch, isNotNull);
      expect(clipMatch!.group(1)!.contains('transform='), false);
    });

    test('W n 后的 path 生成 clip-path 引用', () {
      final contentStr = 'q 320.475 736.108 m 320.96 735.578 c '
          '321.727 736.285 322.877 736.285 323.521 735.578 323.521 735.578 l '
          '324.099 736.108 c 323.643 736.609 323.009 736.859 322.352 736.859 322.352 736.859 c '
          '321.695 736.859 321.018 736.609 320.475 736.108 h W n '
          'q 1 0 0 1 322.9316 733.8844 cm 0 0 m -3.056 2.105 l -1.29 4.667 l 1.766 2.562 l h f Q Q';
      final svg = PdfParserService.convertPdfToSvg(_buildMinimalPdf(contentStr));

      // 被裁剪 path 应引用 clip_1
      expect(svg, contains('clip-path="url(#clip_1)"'));
      // 且 clip 引用在 transform 外层（避免局部坐标系错位）
      final refIdx = svg.indexOf('clip-path="url(#clip_1)"');
      expect(refIdx, greaterThan(0));
    });
  });
}
