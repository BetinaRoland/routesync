import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'theme.dart';

typedef Doc = QueryDocumentSnapshot<Map<String, dynamic>>;

String fmt(Object? v) {
  DateTime? d;
  if (v is Timestamp) d = v.toDate();
  if (v is DateTime) d = v;
  if (d == null) return '-';
  d = d.toLocal();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(d.day)}/${p(d.month)} ${p(d.hour)}:${p(d.minute)}';
}

/// Runs an async action, shows its returned message (or the error) in a snackbar.
Future<bool> runAction(
  BuildContext context,
  Future<String?> Function() fn,
) async {
  final m = ScaffoldMessenger.of(context);
  try {
    final msg = await fn();
    if (msg != null) m.showSnackBar(SnackBar(content: Text(msg)));
    return true;
  } catch (e) {
    m.showSnackBar(
      SnackBar(content: Text('$e'), backgroundColor: Colors.red.shade700),
    );
    return false;
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = 'Confirm',
}) async {
  final r = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(action),
        ),
      ],
    ),
  );
  return r ?? false;
}

Future<void> info(BuildContext context, String title, String body) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: SelectableText(body)),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );

class F {
  final String key, label, initial;
  final bool number, multiline, obscure;
  final Map<String, String>? choices; // value -> label
  const F(
    this.key,
    this.label, {
    this.initial = '',
    this.number = false,
    this.multiline = false,
    this.obscure = false,
    this.choices,
  });
}

Future<Map<String, String>?> formDialog(
  BuildContext context,
  String title,
  List<F> fields, {
  String action = 'Save',
}) {
  final c = {
    for (final f in fields) f.key: TextEditingController(text: f.initial),
  };
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final f in fields)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: f.choices != null
                        ? DropdownButtonFormField<String>(
                            initialValue: f.choices!.containsKey(c[f.key]!.text)
                                ? c[f.key]!.text
                                : null,
                            isExpanded: true,
                            decoration: InputDecoration(labelText: f.label),
                            items: [
                              for (final e in f.choices!.entries)
                                DropdownMenuItem(
                                  value: e.key,
                                  child: Text(
                                    e.value,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                            ],
                            onChanged: (v) => c[f.key]!.text = v ?? '',
                          )
                        : TextField(
                            controller: c[f.key],
                            obscureText: f.obscure,
                            maxLines: f.obscure ? 1 : (f.multiline ? 4 : 1),
                            keyboardType: f.number
                                ? const TextInputType.numberWithOptions(
                                    decimal: true,
                                    signed: true,
                                  )
                                : TextInputType.text,
                            decoration: InputDecoration(labelText: f.label),
                          ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              for (final e in c.entries) e.key: e.value.text.trim(),
            }),
            child: Text(action),
          ),
        ],
      ),
    ),
  );
}

class DocList extends StatelessWidget {
  final Query<Map<String, dynamic>> query;
  final Widget Function(BuildContext, Doc) itemBuilder;
  final String empty;
  final bool Function(Map<String, dynamic>)? filter;
  final IconData emptyIcon;
  const DocList({
    super.key,
    required this.query,
    required this.itemBuilder,
    this.empty = 'Nothing here yet.',
    this.filter,
    this.emptyIcon = Icons.inbox_outlined,
  });

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: query.snapshots(),
        builder: (context, s) {
          if (s.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not load this list.\n${s.error}'),
              ),
            );
          }
          if (!s.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = s.data!.docs
              .where((d) => filter == null || filter!(d.data()))
              .toList();
          if (docs.isEmpty) return EmptyState(empty, icon: emptyIcon);
          return ListView.separated(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: docs.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (c, i) => itemBuilder(c, docs[i]),
          );
        },
      );
}

/// Small outlined status tag.
Widget chip(String text, [Color? color]) {
  final c = color ?? Colors.blueGrey;
  return Container(
    margin: const EdgeInsets.only(right: 6, top: 4),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      border: Border.all(color: c.withValues(alpha: 0.5)),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(text, style: TextStyle(fontSize: 11.5, color: c)),
  );
}

/// Quiet placeholder used by every empty list.
class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  const EmptyState(this.message, {super.key, this.icon = Icons.inbox_outlined});
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: Theme.of(context).colorScheme.outline),
          const SizedBox(height: 12),
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    ),
  );
}

Widget sectionLabel(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
  child: Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 11,
      letterSpacing: 1,
      fontWeight: FontWeight.w600,
      color: Theme.of(context).colorScheme.outline,
    ),
  ),
);

Widget loading() => const Center(child: CircularProgressIndicator());

String csvCell(Object? v) {
  final s = '${v ?? ''}';
  return s.contains(',') || s.contains('"') || s.contains('\n')
      ? '"${s.replaceAll('"', '""')}"'
      : s;
}

Future<void> copyCsv(
  BuildContext context,
  List<String> header,
  List<List<Object?>> rows,
) async {
  final b = StringBuffer('${header.map(csvCell).join(',')}\n');
  for (final r in rows) {
    b.writeln(r.map(csvCell).join(','));
  }
  await Clipboard.setData(ClipboardData(text: b.toString()));
  if (context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '${rows.length} rows copied. Paste into Excel or Sheets.',
        ),
      ),
    );
  }
}

/// Shows an invitation: code, link and a QR code a student can scan with their phone camera.
Future<void> showInviteDialog(
  BuildContext context, {
  required String name,
  required String email,
  required String code,
  String? link,
}) => showDialog<void>(
  context: context,
  builder: (ctx) => AlertDialog(
    title: Text('Invitation for $name'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Send to $email. It works once and expires in 14 days. The Email button opens your mail app.',
          ),
          const SizedBox(height: 12),
          if (link != null)
            Center(
              child: QrImageView(
                data: link,
                size: 190,
                backgroundColor: Colors.white,
              ),
            ),
          if (link == null)
            const Text(
              'Set the app web address in System settings to get a link and QR code.',
              style: TextStyle(fontSize: 12),
            ),
          const SizedBox(height: 8),
          const Text('Code', style: TextStyle(fontWeight: FontWeight.bold)),
          SelectableText(code),
          if (link != null) ...[
            const SizedBox(height: 8),
            const Text('Link', style: TextStyle(fontWeight: FontWeight.bold)),
            SelectableText(link),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Clipboard.setData(ClipboardData(text: link ?? code)),
        child: Text(link != null ? 'Copy link' : 'Copy code'),
      ),
      TextButton(
        onPressed: () {
          final body =
              'Hello $name,\n\nYour college has invited you to RouteSync for bus transport.\n${link != null ? 'Open this link: $link\n' : ''}Your invitation code: $code\nIt works once and expires in 14 days.';
          launchUrl(
            Uri.parse(
              Uri(
                scheme: 'mailto',
                path: email,
                queryParameters: {
                  'subject': 'Your RouteSync invitation',
                  'body': body,
                },
              ).toString().replaceAll('+', '%20'),
            ),
          );
        },
        child: const Text('Email'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(ctx),
        child: const Text('Close'),
      ),
    ],
  ),
);

const alertNames = {
  'gps_failure': 'GPS stopped',
  'tracking_problem': 'Tracking problem',
  'route_deviation': 'Route deviation',
  'emergency': 'Emergency',
  'emergency_review': 'Emergency needs review',
  'preflight': 'Not ready for the day',
  'delay': 'Running late',
  'driver_breakdown': 'Driver: breakdown',
  'driver_delay': 'Driver: running late',
  'driver_road_blocked': 'Driver: road blocked',
  'driver_accident': 'Driver: accident',
  'unauthorized_device': 'Unknown GPS device',
  'driver_other': 'Driver: problem',
};

Color amberTint(BuildContext context) => amber.withValues(alpha: 0.18);
