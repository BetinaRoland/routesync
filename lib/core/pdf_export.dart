import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class PdfSection {
  final String title;
  final List<String> headers;
  final List<List<String>> rows;
  PdfSection(this.title, this.headers, this.rows);
}

/// Builds a simple tabular PDF and opens the print / save dialog (works on web and mobile).
Future<void> exportPdf(String title, List<PdfSection> sections) async {
  final doc = pw.Document();
  doc.addPage(
    pw.MultiPage(
      build: (ctx) => [
        pw.Header(
          level: 0,
          child: pw.Text(
            title,
            style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold),
          ),
        ),
        pw.Text(
          'Generated ${DateTime.now().toString().substring(0, 16)}',
          style: pw.TextStyle(fontSize: 9),
        ),
        for (final s in sections) ...[
          pw.SizedBox(height: 14),
          pw.Text(
            s.title,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 4),
          pw.TableHelper.fromTextArray(
            headers: s.headers,
            data: s.rows,
            cellStyle: pw.TextStyle(fontSize: 10),
            headerStyle: pw.TextStyle(
              fontSize: 10,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ],
      ],
    ),
  );
  await Printing.layoutPdf(
    name: '$title.pdf',
    onLayout: (_) async => doc.save(),
  );
}
