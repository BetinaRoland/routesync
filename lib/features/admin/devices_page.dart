import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import '../../core/api.dart';
import '../../core/widgets.dart';

final _fs = FirebaseFirestore.instance;

/// Dedicated GPS trackers. Each has its own key; a device linked to another bus is rejected.
class DevicesPage extends StatelessWidget {
  const DevicesPage({super.key});

  Future<void> _register(BuildContext context) async {
    final buses = await _fs.collection('buses').orderBy('busNumber').get();
    if (!context.mounted) return;
    final r = await formDialog(context, 'Register GPS device', [
      F('busId', 'Bus', choices: {for (final b in buses.docs) b.id: 'Bus ${b.data()['busNumber']}'}),
      const F('deviceId', 'Device ID (4-40 letters, numbers, - or _)'),
    ], action: 'Register');
    if (r == null || !context.mounted) return;
    await runAction(context, () async {
      final out = await Api.call('registerDevice', {'busId': r['busId'], 'deviceId': r['deviceId']});
      if (context.mounted) {
        await info(
          context,
          'Tracker sign-in (shown once)',
          'Each tracker signs in with its own account, then writes its position. Both steps are plain HTTPS.\n\n'
          '1. Sign in (repeat when the token expires, about every hour):\n'
          'POST https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${out['apiKey']}\n'
          'Body: {"email":"${out['email']}","password":"${out['password']}","returnSecureToken":true}\n'
          'Keep the idToken from the reply.\n\n'
          '2. Every 5 to 10 seconds:\n'
          'PUT ${out['databaseUrl']}/liveLocations/${out['busId']}.json?auth=<idToken>\n'
          'Body: {"lat":0.0,"lng":0.0,"speed":0,"heading":0,"accuracy":10,"ts":<time in milliseconds>}\n\n'
          'This password cannot be shown again. Register the device again if it is lost.',
        );
      }
      return null;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        floatingActionButton: FloatingActionButton(onPressed: () => _register(context), child: const Icon(Icons.add)),
        body: DocList(
          query: _fs.collection('devices').orderBy('createdAt', descending: true),
          empty: 'No GPS devices yet. Until you add one, buses are tracked from the driver\'s phone.',
          emptyIcon: Icons.satellite_alt_outlined,
          itemBuilder: (c, d) {
            final v = d.data(), active = v['status'] == 'active';
            final seen = v['lastSeenMs'] == null ? 'never seen' : 'last seen ${fmt(DateTime.fromMillisecondsSinceEpoch((v['lastSeenMs'] as num).toInt()))}';
            return ListTile(
              leading: Icon(Icons.satellite_alt_outlined, color: active ? Colors.green : Colors.grey),
              title: Text('${v['deviceId']}'),
              subtitle: Wrap(children: [chip('Bus ${v['busId']}'), chip(seen), chip(active ? 'Active' : 'Revoked', active ? Colors.green : Colors.grey)]),
              trailing: active
                  ? IconButton(
                      tooltip: 'Revoke',
                      icon: const Icon(Icons.block),
                      onPressed: () async {
                        if (await confirm(c, 'Revoke ${v['deviceId']}?', 'The tracker stops being accepted immediately.', action: 'Revoke') && c.mounted) {
                          await runAction(c, () async { await Api.call('revokeDevice', {'deviceId': d.id}); return 'Device revoked.'; });
                        }
                      },
                    )
                  : null,
            );
          },
        ),
      );
}
