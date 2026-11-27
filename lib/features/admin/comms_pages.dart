import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:material_ui/material_ui.dart';
import '../../core/api.dart';
import '../../core/components.dart';
import '../../core/theme.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

const _audiences = {
  'all': 'Everyone',
  'students': 'All students',
  'drivers': 'All drivers',
  'running_buses': 'Students and drivers on running buses',
};

String _who(String a) => _audiences[a] ?? 'Legacy bus-specific audience';

// ---------------- Announcements ----------------
class AnnouncementsPage extends StatefulWidget {
  const AnnouncementsPage({super.key});
  @override
  State<AnnouncementsPage> createState() => _AnnouncementsPageState();
}

class _AnnouncementsPageState extends State<AnnouncementsPage> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _audience = 'all';
  String _filter = 'all';
  bool _sending = false;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _publish() async {
    final title = _title.text.trim(), body = _body.text.trim();
    if (title.isEmpty || body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a title and a message first.')),
      );
      return;
    }
    setState(() => _sending = true);
    final ok = await runAction(context, () async {
      await Api.call('sendAnnouncement', {
        'audience': _audience,
        'title': title,
        'body': body,
      });
      return 'Published. Students and drivers see it under Alerts.';
    });
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        _title.clear();
        _body.clear();
      }
    });
  }

  /// The form an admin fills in to write an announcement.
  Widget _composer() => SectionCard(
    title: 'New announcement',
    icon: Icons.edit_outlined,
    bodyPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Send to', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final e in _audiences.entries)
              ChoiceChip(
                label: Text(e.value),
                selected: _audience == e.key,
                onSelected: (_) => setState(() => _audience = e.key),
              ),
          ],
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _title,
          maxLength: 120,
          decoration: const InputDecoration(labelText: 'Title'),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _body,
          minLines: 4,
          maxLines: 8,
          decoration: const InputDecoration(
            labelText: 'Message',
            alignLabelWithHint: true,
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _sending ? null : _publish,
            icon: _sending
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: Text(_sending ? 'Publishing...' : 'Publish'),
          ),
        ),
      ],
    ),
  );

  /// How the message will look to the people who receive it.
  Widget _preview() {
    final scheme = Theme.of(context).colorScheme;
    final empty = _title.text.trim().isEmpty && _body.text.trim().isEmpty;
    return SectionCard(
      title: 'Live preview',
      icon: Icons.visibility_outlined,
      bodyPadding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: scheme.primaryContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(Rd.control),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CircleAvatar(
              backgroundColor: scheme.primary,
              foregroundColor: scheme.onPrimary,
              child: const Icon(Icons.campaign_outlined),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _title.text.trim().isEmpty
                        ? 'Your title appears here'
                        : _title.text.trim(),
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: empty ? scheme.onSurfaceVariant : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _body.text.trim().isEmpty
                        ? 'Your message appears here.'
                        : _body.text.trim(),
                    style: TextStyle(
                      color: _body.text.trim().isEmpty
                          ? scheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'To: ${_who(_audience)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Published announcements, newest first, with an audience filter.
  Widget _feed() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Text(
          'Published announcements',
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final e in {'all': 'All', ..._audiences}.entries)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(e.key == 'all' ? 'All' : e.value),
                  selected: _filter == e.key,
                  onSelected: (_) => setState(() => _filter = e.key),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _fs
            .collection('announcements')
            .orderBy('createdAt', descending: true)
            .limit(50)
            .snapshots(),
        builder: (context, s) {
          if (s.hasError) {
            return const ErrorState('Could not load announcements.');
          }
          if (!s.hasData) {
            return const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            );
          }
          final docs = s.data!.docs
              .where((d) => _filter == 'all' || d.data()['audience'] == _filter)
              .toList();
          if (docs.isEmpty) {
            return const EmptyState(
              'No announcements here yet. Write one to reach students and drivers in the app.',
              icon: Icons.campaign_outlined,
            );
          }
          return Column(
            children: [
              for (final d in docs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: RsCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${d.data()['title']}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                            ),
                            statusPill(
                              context,
                              Tone.success,
                              'Published',
                              icon: Icons.check_circle_outline,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Text('${d.data()['body']}'),
                        const SizedBox(height: 8),
                        Wrap(
                          children: [
                            chip(_who('${d.data()['audience']}')),
                            chip(fmt(d.data()['createdAt'])),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth >= 900) {
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              flex: 2,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 8, 32),
                children: [_composer(), const SizedBox(height: 16), _preview()],
              ),
            ),
            Expanded(
              flex: 3,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(8, 16, 16, 32),
                children: [_feed()],
              ),
            ),
          ],
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          _composer(),
          const SizedBox(height: 16),
          _preview(),
          const SizedBox(height: 24),
          _feed(),
        ],
      );
    },
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
  String _q = '';
  String? _selected;
  bool _sending = false;
  final _reply = TextEditingController();

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  void _select(String id) => setState(() {
    _selected = _selected == id ? null : id;
    _reply.clear();
  });

  Future<void> _send(Doc d) async {
    final text = _reply.text.trim();
    if (text.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Write a reply first.')));
      return;
    }
    setState(() => _sending = true);
    final ok = await runAction(context, () async {
      await Api.call('replyFeedback', {'feedbackId': d.id, 'reply': text});
      return 'Reply sent and report closed.';
    });
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (ok) {
        _selected = null;
        _reply.clear();
      }
    });
  }

  Widget _card(Doc d) {
    final scheme = Theme.of(context).colorScheme;
    final f = d.data();
    final selected = _selected == d.id;
    final name = '${f['studentName'] ?? 'Student'}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: RsCard(
        selected: selected,
        onTap: () => _select(d.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 18,
                  backgroundColor: scheme.primaryContainer,
                  foregroundColor: scheme.onPrimaryContainer,
                  child: Text(name.isEmpty ? '?' : name[0].toUpperCase()),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        fmt(f['createdAt']),
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                chip('${f['category']}'),
                statusPill(
                  context,
                  _open ? Tone.warning : Tone.success,
                  _open ? 'Open' : 'Resolved',
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${f['message']}',
              maxLines: selected ? null : 2,
              overflow: selected ? null : TextOverflow.ellipsis,
            ),
            if (selected) ...[
              const SizedBox(height: 12),
              if (f['reply'] != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer.withValues(alpha: 0.55),
                    borderRadius: BorderRadius.circular(Rd.control),
                  ),
                  child: Text('Reply: ${f['reply']}'),
                ),
              if (_open) ...[
                TextField(
                  controller: _reply,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Your reply',
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.icon(
                    onPressed: _sending ? null : () => _send(d),
                    icon: const Icon(Icons.reply),
                    label: Text(_sending ? 'Sending...' : 'Send reply and close'),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              children: [
                TextField(
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: 'Search by student, category or message',
                  ),
                  onChanged: (v) => setState(() => _q = v.trim().toLowerCase()),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    ChoiceChip(
                      avatar: const Icon(Icons.mark_email_unread_outlined, size: 18),
                      label: const Text('Open'),
                      selected: _open,
                      onSelected: (_) => setState(() {
                        _open = true;
                        _selected = null;
                      }),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      avatar: const Icon(Icons.task_alt, size: 18),
                      label: const Text('Closed'),
                      selected: !_open,
                      onSelected: (_) => setState(() {
                        _open = false;
                        _selected = null;
                      }),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              key: ValueKey(_open),
              stream: _fs
                  .collection('feedback')
                  .where('status', isEqualTo: _open ? 'open' : 'resolved')
                  .orderBy('createdAt', descending: true)
                  .limit(100)
                  .snapshots(),
              builder: (context, s) {
                if (s.hasError) {
                  return const ErrorState('Could not load reports.');
                }
                if (!s.hasData) return loading();
                final docs = s.data!.docs.where((d) {
                  if (_q.isEmpty) return true;
                  final f = d.data();
                  return '${f['studentName']} ${f['category']} ${f['message']}'
                      .toLowerCase()
                      .contains(_q);
                }).toList();
                if (docs.isEmpty) {
                  return EmptyState(
                    _q.isNotEmpty
                        ? 'No report matches that search.'
                        : (_open
                              ? 'No open reports from students.'
                              : 'No closed reports yet.'),
                    icon: Icons.forum_outlined,
                  );
                }
                return ListView(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
                  children: [for (final d in docs) _card(d)],
                );
              },
            ),
          ),
        ],
      ),
    ),
  );
}
