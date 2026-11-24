import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/api.dart';
import '../../core/widgets.dart';

const _categories = [
  'Bus condition',
  'Driver',
  'Timing',
  'Safety',
  'Fees',
  'Other',
];

/// Students report a problem; the Route Admin replies here and by notification.
class FeedbackPage extends StatefulWidget {
  const FeedbackPage({super.key});
  @override
  State<FeedbackPage> createState() => _FeedbackPageState();
}

class _FeedbackPageState extends State<FeedbackPage> {
  String _cat = _categories.first;
  final _msg = TextEditingController();
  bool _busy = false;

  Future<void> _send() async {
    setState(() => _busy = true);
    await runAction(context, () async {
      await Api.call('submitFeedback', {
        'category': _cat,
        'message': _msg.text.trim(),
      });
      _msg.clear();
      return 'Sent. You will get a reply here and in notifications.';
    });
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Report a problem')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: _cat,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final c in _categories)
                    DropdownMenuItem(value: c, child: Text(c)),
                ],
                onChanged: (v) => _cat = v ?? _cat,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _msg,
                maxLines: 4,
                maxLength: 1000,
                decoration: const InputDecoration(labelText: 'What happened?'),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _busy ? null : _send,
                  child: const Text('Send report'),
                ),
              ),
            ],
          ),
        ),
        sectionLabel(context, 'Your reports'),
        Expanded(
          child: DocList(
            query: FirebaseFirestore.instance
                .collection('feedback')
                .where(
                  'authUid',
                  isEqualTo: FirebaseAuth.instance.currentUser!.uid,
                )
                .orderBy('createdAt', descending: true)
                .limit(30),
            empty: 'You have not sent any reports.',
            emptyIcon: Icons.forum_outlined,
            itemBuilder: (c, d) {
              final f = d.data(), open = f['status'] == 'open';
              return ListTile(
                title: Text('${f['category']}'),
                subtitle: Text(
                  '${f['message']}${f['reply'] != null ? '\nReply: ${f['reply']}' : ''}',
                ),
                isThreeLine: f['reply'] != null,
                trailing: chip(
                  open ? 'Open' : 'Answered',
                  open ? Colors.orange : Colors.green,
                ),
              );
            },
          ),
        ),
      ],
    ),
  );
}
