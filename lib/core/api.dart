import 'package:cloud_firestore/cloud_firestore.dart';
import '../services/common.dart' show Fail;
import '../services/registry.dart';

Map<String, dynamic> asMap(Object? v) =>
    v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};

List<Map<String, dynamic>> asList(Object? v) =>
    v is List ? v.map(asMap).toList() : <Map<String, dynamic>>[];

String _friendly(String code, String? message) => switch (code) {
  'permission-denied' || 'PERMISSION_DENIED' || 'permission_denied' =>
    'Not allowed. Your account may not have access to this, or it is disabled.',
  'unavailable' ||
  'network-error' ||
  'disconnected' => 'No connection. Check your internet and try again.',
  'failed-precondition' =>
    message != null && message.contains('index')
        ? 'This screen is still being prepared. Try again in a few minutes.'
        : (message ?? 'That could not be done right now.'),
  _ => message ?? 'Something went wrong. Try again.',
};

/// Runs an action. There is no server: the work happens here, limited by the database security rules.
/// Errors come back as readable text.
class Api {
  static Future<Map<String, dynamic>> call(
    String name, [
    Map<String, dynamic>? data,
  ]) async {
    try {
      return await runService(name, data ?? {});
    } on Fail catch (e) {
      throw e.message;
    } on FirebaseException catch (e) {
      throw _friendly(e.code, e.message);
    } catch (e) {
      throw 'Something went wrong. ($e)';
    }
  }
}
