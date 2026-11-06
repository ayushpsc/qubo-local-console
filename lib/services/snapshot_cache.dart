import 'dart:convert';
import 'dart:typed_data';
import 'package:shared_preferences/shared_preferences.dart';

/// An explicit, bounded cache for snapshots the user chooses to retain.
/// Signed URLs are never persisted; only the downloaded image bytes are kept.
class SnapshotCache {
  static const _indexKey = 'qubo.snapshot-cache.v1.index';
  static const _prefix = 'qubo.snapshot-cache.v1.';
  static const maxItems = 12;
  static const maxImageBytes = 5 * 1024 * 1024;
  final SharedPreferencesAsync preferences;

  SnapshotCache({SharedPreferencesAsync? preferences})
    : preferences = preferences ?? SharedPreferencesAsync();

  String _storageKey(String key) =>
      '$_prefix${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}';

  Future<Uint8List?> read(String key) async {
    final value = await preferences.getString(_storageKey(key));
    if (value == null) return null;
    try {
      return base64Decode(value);
    } catch (_) {
      await remove(key);
      return null;
    }
  }

  Future<void> write(String key, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > maxImageBytes) {
      throw const FormatException('Snapshot exceeds the 5 MB offline limit.');
    }
    final storageKey = _storageKey(key);
    await preferences.setString(storageKey, base64Encode(bytes));
    final index = await preferences.getStringList(_indexKey) ?? <String>[];
    index.remove(storageKey);
    index.insert(0, storageKey);
    while (index.length > maxItems) {
      await preferences.remove(index.removeLast());
    }
    await preferences.setStringList(_indexKey, index);
  }

  Future<void> remove(String key) async {
    final storageKey = _storageKey(key);
    await preferences.remove(storageKey);
    final index = await preferences.getStringList(_indexKey) ?? <String>[];
    if (index.remove(storageKey)) {
      await preferences.setStringList(_indexKey, index);
    }
  }
}
