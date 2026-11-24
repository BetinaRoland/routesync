import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

// ---------------- Announcements ----------------
class AnnouncementsPage extends StatelessWidget {
  const AnnouncementsPage({super.key});

  Future<void> _new(BuildContext context) async {
    final r = await formDialog(context, 'New announcement', [
      F(
        'audience',
        'Send to',
        initial: 'all',
        choices: {
          'all': 'Everyone',
          'students': 'All students',
          'drivers': 'All drivers',
          'running_buses': 'Students and drivers on running buses',
        },
      ),
      const F('title', 'Title'),
      const F('body', 'Message', multiline: true),
    ], action: 'Send');
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      await Api.call('sendAnnouncement', {
        'audience': r['audience'],
        'title': r['title'],
        'body': r['body'],
      });
      return 'Published. Students and drivers see it under Alerts.';
    });
  }

  String _who(String a) => switch (a) {
    'all' => 'Everyone',
    'students' => 'All students',
    'drivers' => 'All drivers',
    'running_buses' => 'Students and drivers on running buses',
    _ => 'Legacy bus-specific audience',
  };

  @override
  Widget build(BuildContext context) => Scaffold(
    floatingActionButton: FloatingActionButton.extended(
      onPressed: () => _new(context),
      icon: const Icon(Icons.campaign_outlined),
      label: const Text('New'),
    ),
    body: DocList(
      query: _fs
          .collection('announcements')
          .orderBy('createdAt', descending: true)
          .limit(50),
      empty:
          'No announcements yet. Send one to reach students and drivers in the app.',
      emptyIcon: Icons.campaign_outlined,
      itemBuilder: (c, d) {
        final a = d.data();
        return ListTile(
          title: Text('${a['title']}'),
          subtitle: Text(
            '${a['body']}\n${_who('${a['audience']}')}, ${fmt(a['createdAt'])}',
          ),
          isThreeLine: true,
        );
      },
    ),
  );
}

// ---------------- Feedback inbox ----------------
class FeedbackInboxPage extends StatefulWidget {
  const FeedbackInboxPage({super.key});
  @override
  State<FeedbackInboxPage> createState() => _FeedbackInboxPageState();
}

class _FeedbackInboxPageState extends State<FeedbackInboxPage> {
  bool _open = true;

  Future<void> _reply(Doc d) async {
    final r = await formDialog(context, 'Reply to ${d['studentName']}', const [
      F('reply', 'Your reply', multiline: true),
    ], action: 'Send reply');
    if (r == null || !mounted) return;
    await runAction(context, () async {
      await Api.call('replyFeedback', {
        'feedbackId': d.id,
        'reply': r['reply'],
      });
      return 'Reply sent and report closed.';
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            ChoiceChip(
              label: const Text('Open'),
              selected: _open,
              onSelected: (_) => setState(() => _open = true),
            ),
            const SizedBox(width: 8),
            ChoiceChip(
              label: const Text('Closed'),
              selected: !_open,
              onSelected: (_) => setState(() => _open = false),
            ),
          ],
        ),
      ),
      Expanded(
        child: DocList(
          key: ValueKey(_open),
          query: _fs
              .collection('feedback')
              .where('status', isEqualTo: _open ? 'open' : 'resolved')
              .orderBy('createdAt', descending: true)
              .limit(100),
          empty: _open
              ? 'No open reports from students.'
              : 'No closed reports yet.',
          emptyIcon: Icons.forum_outlined,
          itemBuilder: (c, d) {
            final f = d.data();
            return ListTile(
              title: Text('${f['studentName']}'),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    children: [
                      chip('${f['category']}'),
                      chip(fmt(f['createdAt'])),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text('${f['message']}'),
                  if (f['reply'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Reply: ${f['reply']}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                ],
              ),
              trailing: _open
                  ? TextButton(
                      onPressed: () => _reply(d),
                      child: const Text('Reply'),
                    )
                  : null,
              isThreeLine: true,
            );
          },
        ),
      ),
    ],
  );
}
