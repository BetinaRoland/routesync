import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:material_ui/material_ui.dart';
import '../core/widgets.dart';

/// Personal notifications. Students and drivers also see recent announcements for everyone, their role or their bus.
class NotificationsPage extends StatelessWidget {
  final bool standalone;
  final String? audience; // 'students' or 'drivers'
  final String? busId;
  const NotificationsPage({
    super.key,
    this.standalone = false,
    this.audience,
    this.busId,
  });

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser!.uid;
    final list = DocList(
      query: FirebaseFirestore.instance
          .collection('notifications')
          .where('userId', isEqualTo: uid)
          .orderBy('createdAt', descending: true)
          .limit(50),
      empty: 'No notifications yet.',
      emptyIcon: Icons.notifications_none,
      itemBuilder: (c, d) {
        final n = d.data();
        final unread = n['read'] != true;
        return ListTile(
          leading: Icon(
            unread ? Icons.notifications_active : Icons.notifications_none,
          ),
          title: Text(
            '${n['title']}',
            style: TextStyle(
              fontWeight: unread ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          subtitle: Text('${n['body']}\n${fmt(n['createdAt'])}'),
          isThreeLine: true,
          onTap: unread ? () => d.reference.update({'read': true}) : null,
        );
      },
    );
    final body = audience == null
        ? list
        : Column(
            children: [
              _Announcements(audience: audience!, busId: busId),
              Expanded(child: list),
            ],
          );
    return standalone
        ? Scaffold(
            appBar: AppBar(title: const Text('Notifications')),
            body: body,
          )
        : body;
  }
}

class _Announcements extends StatelessWidget {
  final String audience;
  final String? busId;
  const _Announcements({required this.audience, this.busId});

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: busId == null
            ? null
            : FirebaseFirestore.instance.doc('buses/$busId').snapshots(),
        builder: (context, busSnapshot) {
          final busIsRunning =
              busId != null &&
              busSnapshot.data?.data()?['trackingStatus'] == 'active';
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('announcements')
                .orderBy('createdAt', descending: true)
                .limit(10)
                .snapshots(),
            builder: (c, s) {
              final items = (s.data?.docs ?? [])
                  .map((d) => d.data())
                  .where(
                    (a) =>
                        a['audience'] == 'all' ||
                        a['audience'] == audience ||
                        (busIsRunning && a['audience'] == 'running_buses') ||
                        (busId != null && a['audience'] == 'bus:$busId'),
                  )
                  .take(3)
                  .toList();
              if (items.isEmpty) return const SizedBox.shrink();
              return Column(
                children: [
                  for (final a in items)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.campaign_outlined),
                        title: Text(
                          '${a['title']}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Text('${a['body']}\n${fmt(a['createdAt'])}'),
                        isThreeLine: true,
                      ),
                    ),
                ],
              );
            },
          );
        },
      );
}
