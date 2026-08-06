import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdf_ai_parser/pdf_ai_parser.dart';

/// 构造一个最小的有效 PDF（单个内容流页），内容流为 [contentStr]
Uint8List _buildMinimalPdf(String contentStr) {
  final streamData = utf8.encode(contentStr);
  final pdfHeader = '%PDF-1.4\n'
      '1 0 obj\n'
      '<< /Length ${streamData.length} >>\n'
      'stream\n';
  final pdfBytesList = <int>[];
  pdfBytesList.addAll(utf8.encode(pdfHeader));
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
  group('PdfParserService 基础解析', () {
    test('解析简单路径并输出合法 SVG', () {
      final pdfBytes = _buildMinimalPdf('10 20 m 30 40 l S');
      final svg = PdfParserService.convertPdfToSvg(pdfBytes);
      expect(svg.trim().isNotEmpty, true);
      expect(svg.contains('<svg'), true);
      expect(svg.contains('M 10.0 20.0'), true);
    });

    test('解析路径填充并保留元素', () {
      final pdfBytes = _buildMinimalPdf('10 20 m 30 40 l 50 20 l h f');
      final svg = PdfParserService.convertPdfToSvg(pdfBytes);
      expect(svg.contains('M 10.0 20.0'), true);
      expect(svg.contains('fill='), true);
    });

    test('解析矩形 re 算子', () {
      final pdfBytes = _buildMinimalPdf('10 10 50 30 re f');
      final svg = PdfParserService.convertPdfToSvg(pdfBytes);
      // re → M x y L x+w y L x+w y+h L x y+h Z
      expect(svg.contains('M 10.0 10.0'), true);
      expect(svg.contains('L 60.0 10.0'), true);
      expect(svg.contains('L 60.0 40.0'), true);
      expect(svg.contains('L 10.0 40.0'), true);
      expect(svg.contains('Z'), true);
    });

    test('输出 SVG 带垂直翻转矩阵', () {
      final pdfBytes = _buildMinimalPdf('0 0 100 100 re f');
      final svg = PdfParserService.convertPdfToSvg(pdfBytes);
      expect(svg.contains('matrix(1 0 0 -1 0 841.89)'), true);
    });
  });
}
