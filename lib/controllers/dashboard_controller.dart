import 'dart:async';
import 'package:flutter/foundation.dart';
import '../models/dashboard_models.dart';
import '../services/dashboard_api.dart';

class RequestEntry {
  final DateTime time;
  final String method, route;
  final int status;
  RequestEntry(this.method, this.route, this.status) : time = DateTime.now();
}

class DashboardController extends ChangeNotifier {
  final DashboardApi api;
  final DateTime Function() now;
  Timer? _timer;
  DateTime? _lastMaintenance;
  bool _maintainingSession = false;
  int _generation = 0;
  bool _disposed = false;
  bool expired = false, loading = false;
  Session? get session => api.session;
  ConnectionSettings get settings => api.settings;
  Device? selected;
  late DateTime start, end;
  List<EventItem> vms = [], recordings = [], ai = [];
  final Map<String, String> errors = {};
  final List<RequestEntry> requests = [];
  int pages = 0;
  String? vmsNotice;
  DateTime? fetchedAt;
  DashboardController(this.api, {DateTime Function()? now, bool tick = true})
    : now = now ?? DateTime.now {
    end = this.now();
    start = DateTime(end.year, end.month, end.day);
    selected =
        settings.devices
            .where((d) => d.productType == 'videoDoorbellPro')
            .firstOrNull ??
        settings.devices.firstOrNull;
    api.onExpired = expire;
    api.onRequest = (method, path, status) {
      // Log route and status only; never tokens, query strings or request bodies.
      requests.insert(0, RequestEntry(method, path, status));
      if (requests.length > 100) requests.removeLast();
      _emit();
    };
    if (tick) {
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => checkExpiry());
    }
  }
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void checkExpiry() {
    final current = session;
    if (current == null) return;
    final time = now();
    if ((current.refreshToken?.isNotEmpty ?? false) &&
        current.expiresWithin(time, const Duration(minutes: 5))) {
      if (!_maintainingSession &&
          (_lastMaintenance == null ||
              time.difference(_lastMaintenance!) >=
                  const Duration(seconds: 30))) {
        unawaited(maintainSession());
      }
    } else if (current.expired(time)) {
      expire();
    }
  }

  Future<void> maintainSession() async {
    if (_maintainingSession || session == null) return;
    _maintainingSession = true;
    _lastMaintenance = now();
    final before = session;
    try {
      await api.ensureValidSession();
      if (!identical(before, session)) _emit();
    } on ApiException {
      // DashboardApi invokes expire for a terminal refresh failure. A transient
      // failure keeps the still-valid access token and is retried after backoff.
    } finally {
      _maintainingSession = false;
    }
  }

  void expire() {
    if (expired && session == null) return;
    _generation++;
    expired = true;
    api.session = null;
    loading = false;
    _emit();
  }

  void signIn(Session s) {
    if (s.expired(now()) && (s.refreshToken?.isEmpty ?? true)) {
      throw const ApiException(
        'This token has already expired. Sign in again.',
      );
    }
    _generation++;
    api.session = s;
    _lastMaintenance = null;
    expired = false;
    loading = false;
    vms = [];
    ai = [];
    recordings = [];
    errors.clear();
    requests.clear();
    vmsNotice = null;
    pages = 0;
    fetchedAt = null;
    _emit();
  }

  Future<void> signInAndDiscover(Session s) async {
    if (s.expired(now()) && (s.refreshToken?.isEmpty ?? true)) {
      throw const ApiException(
        'This token has already expired. Sign in again.',
      );
    }
    api.session = s;
    try {
      final discovery = await api.discoverAccount();
      if (!identical(api.session, s)) {
        throw const ApiException(
          'The Qubo session changed during account discovery.',
          auth: true,
        );
      }
      settings.unit = discovery.units.first;
      settings.devices = discovery.devices;
      selected =
          discovery.devices.where((d) => d.isCamera).firstOrNull ??
          discovery.devices.first;
      signIn(s);
    } catch (_) {
      if (identical(api.session, s)) api.session = null;
      rethrow;
    }
  }

  void signOut() {
    _generation++;
    api.session = null;
    _lastMaintenance = null;
    expired = false;
    loading = false;
    vms = [];
    ai = [];
    recordings = [];
    errors.clear();
    requests.clear();
    vmsNotice = null;
    pages = 0;
    fetchedAt = null;
    _emit();
  }

  void changeDevice(Device d) {
    _generation++;
    selected = d;
    if (d.unit.isNotEmpty) settings.unit = d.unit;
    loading = false;
    vms = [];
    recordings = [];
    ai = [];
    errors.clear();
    fetchedAt = null;
    vmsNotice = null;
    pages = 0;
    _emit();
  }

  void setRange(DateTime from, DateTime to) {
    if (from.isAfter(to)) throw const ApiException('Start must be before end.');
    _generation++;
    start = from;
    end = to;
    loading = false;
    vms = [];
    recordings = [];
    ai = [];
    errors.clear();
    fetchedAt = null;
    vmsNotice = null;
    pages = 0;
    _emit();
  }

  Future<void> fetch({String? only}) async {
    if (loading || selected == null) return;
    if (session == null ||
        (session!.expired(now()) && (session!.refreshToken?.isEmpty ?? true))) {
      expire();
      return;
    }
    final gen = ++_generation;
    final device = selected!;
    final from = start, to = end;
    loading = true;
    if (only == null) {
      errors.clear();
    } else {
      errors.remove(only);
    }
    _emit();
    bool current() => !_disposed && gen == _generation;
    Future<void> run(String key, Future<void> Function() action) async {
      if (only != null && key != only) return;
      try {
        await action();
      } catch (e) {
        if (current()) errors[key] = '$e';
      }
      if (current()) _emit();
    }

    await Future.wait([
      run('vms', () async {
        var cursor = to.millisecondsSinceEpoch;
        final found = <String, EventItem>{};
        String? notice;
        int count = 0;
        // The capture suggests backward pagination. Stop if the server does not advance.
        for (; count < 50; count++) {
          final rows = await api.vms(device, cursor);
          if (!current()) return;
          if (rows.isEmpty) break;
          final events = rows
              .map(EventItem.vms)
              .where((event) => event.deviceId == device.id)
              .toList();
          final valid = events.where((e) => e.timestamp > 0).toList();
          if (valid.isEmpty) {
            notice =
                'Some records have no usable timestamp. Results may be incomplete.';
            break;
          }
          int oldest = valid
              .map((e) => e.timestamp)
              .reduce((a, b) => a < b ? a : b);
          final before = found.length;
          for (final e in valid) {
            if (e.timestamp >= from.millisecondsSinceEpoch &&
                e.timestamp <= to.millisecondsSinceEpoch) {
              found[e.id] = e;
            }
          }
          vms = found.values.toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
          pages = count + 1;
          _emit();
          if (oldest <= from.millisecondsSinceEpoch || rows.length < 20) break;
          if (oldest >= cursor || (count > 0 && found.length == before)) {
            notice =
                'The server did not advance through history. Narrow the range; results may be incomplete.';
            break;
          }
          // Re-use the oldest timestamp to avoid skipping ties. Deduplication handles inclusive cursors.
          cursor = oldest;
          if (count == 49) {
            notice =
                'Stopped after 50 pages. Choose a smaller range to fetch the remaining history.';
          }
        }
        if (current()) {
          vms = found.values.toList()
            ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
          vmsNotice = notice;
        }
      }),
      run('recording', () async {
        final rows = await api.timeline(device, from, to);
        if (current()) {
          recordings =
              rows
                  .map(EventItem.recording)
                  .where(
                    (event) =>
                        event.deviceId == device.id && event.overlaps(from, to),
                  )
                  .toList()
                ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        }
      }),
      run('ai', () async {
        final rows = await api.latest();
        if (current()) {
          ai =
              rows
                  .map(EventItem.ai)
                  .whereType<EventItem>()
                  .where(
                    (e) =>
                        e.deviceId == device.id &&
                        e.timestamp >= from.millisecondsSinceEpoch &&
                        e.timestamp <= to.millisecondsSinceEpoch,
                  )
                  .toList()
                ..sort((a, b) => b.timestamp.compareTo(a.timestamp));
        }
      }),
    ]);
    if (current()) {
      loading = false;
      fetchedAt = now();
      _emit();
    }
  }

  EventItem? matchingRecording(EventItem event) {
    if (event.kind == 'recording') return event;
    final instant = event.mediaTimestamp;
    for (final recording in recordings) {
      if (recording.deviceId == event.deviceId &&
          recording.timestamp <= instant &&
          (recording.endTime ?? recording.timestamp) >= instant) {
        return recording;
      }
    }
    return null;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    api.onExpired = null;
    api.onRequest = null;
    api.dispose();
    super.dispose();
  }
}
