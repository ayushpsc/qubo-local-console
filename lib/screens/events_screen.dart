import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../controllers/dashboard_controller.dart';
import '../models/dashboard_models.dart';
import '../widgets/dashboard_widgets.dart';

class EventsScreen extends StatefulWidget {
  final DashboardController controller;
  final bool timeline;
  const EventsScreen({
    super.key,
    required this.controller,
    this.timeline = false,
  });
  @override
  State<EventsScreen> createState() => _EventsScreenState();
}

class _EventsScreenState extends State<EventsScreen> {
  String filter = 'all';
  int visible = 24;
  final search = TextEditingController();
  late DateTime from = widget.controller.start, to = widget.controller.end;
  String? rangeError;
  @override
  void dispose() {
    search.dispose();
    super.dispose();
  }

  Future<void> pick(bool isStart) async {
    final initial = isStart ? from : to;
    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (day == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;
    final value = DateTime(
      day.year,
      day.month,
      day.day,
      time.hour,
      time.minute,
      isStart ? 0 : 59,
      isStart ? 0 : 999,
    );
    setState(() {
      if (isStart) {
        from = value;
      } else {
        to = value;
      }
      rangeError = null;
    });
  }

  void fetch() {
    if (from.isAfter(to)) {
      setState(() => rangeError = 'Choose an end time after the start time.');
      return;
    }
    widget.controller.setRange(from, to);
    widget.controller.fetch();
  }

  void details(EventItem e) {
    final c = widget.controller;
    final d =
        c.settings.devices.where((d) => d.id == e.deviceId).firstOrNull ??
        c.selected!;
    showDialog<void>(
      context: context,
      builder: (_) => EventDetails(
        event: e,
        device: d,
        api: c.api,
        matchingRecording: c.matchingRecording(e),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    var items = [...c.vms, ...c.ai, ...c.recordings];
    items.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    items = items
        .where(
          (e) =>
              (filter == 'all' || e.kind == filter || widget.timeline) &&
              '${e.title} ${e.id}'.toLowerCase().contains(
                search.text.toLowerCase(),
              ),
        )
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageTitle(
          eyebrow: 'Home / ${widget.timeline ? 'Playback' : 'Activity'}',
          title: widget.timeline
              ? 'Your unified event timeline'
              : 'Every moment, in view.',
          subtitle: widget.timeline
              ? 'See recordings, AI detections and doorbell calls together, then prepare an SD-card clip for playback.'
              : 'Doorbell calls, latest detections and camera recordings in one place.',
          trailing: c.fetchedAt == null
              ? null
              : Text(
                  'Updated ${DateFormat.Hm().format(c.fetchedAt!)}',
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
        ),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 16,
                runSpacing: 16,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<String>(
                      initialValue: c.selected?.id,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Camera / device',
                        prefixIcon: Icon(Icons.videocam_outlined),
                      ),
                      items: c.settings.devices
                          .map(
                            (d) => DropdownMenuItem(
                              value: d.id,
                              child: Text(
                                d.name,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: c.loading
                          ? null
                          : (id) {
                              if (id != null) {
                                c.changeDevice(
                                  c.settings.devices.firstWhere(
                                    (d) => d.id == id,
                                  ),
                                );
                              }
                            },
                    ),
                  ),
                  dateButton('Start date & time', from, () => pick(true)),
                  dateButton('End date & time', to, () => pick(false)),
                  FilledButton.icon(
                    onPressed: c.loading || c.selected == null ? null : fetch,
                    icon: c.loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search, size: 18),
                    label: Text(
                      c.loading ? 'Fetching events…' : 'Fetch events',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Wrap(
                spacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  const Text(
                    'Quick range',
                    style: TextStyle(color: muted, fontSize: 12),
                  ),
                  TextButton(
                    onPressed: c.loading
                        ? null
                        : () => setState(() {
                            to = DateTime.now();
                            from = DateTime(to.year, to.month, to.day);
                          }),
                    child: const Text('Today'),
                  ),
                  TextButton(
                    onPressed: c.loading
                        ? null
                        : () => setState(() {
                            to = DateTime.now();
                            from = to.subtract(const Duration(hours: 24));
                          }),
                    child: const Text('Last 24 hours'),
                  ),
                  TextButton(
                    onPressed: c.loading
                        ? null
                        : () => setState(() {
                            to = DateTime.now();
                            from = to.subtract(const Duration(days: 7));
                          }),
                    child: const Text('Last 7 days'),
                  ),
                  const Text(
                    'Times shown in your local timezone',
                    style: TextStyle(color: muted, fontSize: 11),
                  ),
                ],
              ),
              if (rangeError != null) Notice(rangeError!, error: true),
              if (from != c.start || to != c.end)
                const Text(
                  'Range changed. Fetch events to apply it.',
                  style: TextStyle(color: green, fontSize: 12),
                ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        LayoutBuilder(
          builder: (context, box) => Wrap(
            spacing: 16,
            runSpacing: 16,
            children: [
              metric(
                'Doorbell calls',
                '${c.vms.length}',
                Icons.doorbell_outlined,
                const Color(0xFFEAF3EC),
                box.maxWidth,
              ),
              metric(
                'Latest AI alert',
                '${c.ai.length}',
                Icons.auto_awesome_outlined,
                const Color(0xFFFFF1D7),
                box.maxWidth,
              ),
              metric(
                'Recordings',
                '${c.recordings.length}',
                Icons.video_library_outlined,
                const Color(0xFFE9EFF8),
                box.maxWidth,
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        if (c.loading)
          const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: LinearProgressIndicator(minHeight: 3),
          ),
        for (final entry in c.errors.entries)
          Notice(
            '${entry.key == 'ai'
                ? 'Latest AI events'
                : entry.key == 'vms'
                ? 'Doorbell history'
                : 'Recordings'}: ${entry.value}',
            error: true,
            action: TextButton(
              onPressed: c.loading ? null : () => c.fetch(only: entry.key),
              child: const Text('Retry'),
            ),
          ),
        if (c.vmsNotice != null) Notice(c.vmsNotice!),
        if (!widget.timeline)
          const Notice(
            'AI shows only the latest event for the selected device, if it falls within this range. An API for historical AI events is not established.',
          ),
        if (widget.timeline && items.isNotEmpty) ...[
          Surface(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Event and recording availability',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Green segments are recordings; blue markers are doorbell calls; amber markers are AI detections.',
                  style: TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Wrap(
                  spacing: 18,
                  runSpacing: 8,
                  children: [
                    _TimelineLegend(color: green, label: 'SD recording'),
                    _TimelineLegend(
                      color: Color(0xFF3478C7),
                      label: 'Doorbell call',
                    ),
                    _TimelineLegend(
                      color: Color(0xFFF2A51A),
                      label: 'AI detection',
                    ),
                  ],
                ),
                const SizedBox(height: 22),
                SizedBox(
                  height: 50,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: _TimelinePainter(c.start, c.end, [
                      ...c.recordings,
                      ...c.vms,
                      ...c.ai,
                    ]),
                  ),
                ),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      dateTimeFormat.format(c.start),
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                    Text(
                      dateTimeFormat.format(c.end),
                      style: const TextStyle(fontSize: 11, color: muted),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
        ],
        Surface(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 18,
                runSpacing: 16,
                children: [
                  Text(
                    widget.timeline
                        ? 'Timeline event library'
                        : 'Event library',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (!widget.timeline)
                    Wrap(
                      spacing: 6,
                      children:
                          [
                                ('all', 'All events'),
                                ('vms', 'Doorbell'),
                                ('ai', 'AI'),
                                ('recording', 'Recordings'),
                              ]
                              .map(
                                (item) => ChoiceChip(
                                  label: Text(item.$2),
                                  selected: filter == item.$1,
                                  onSelected: (_) =>
                                      setState(() => filter = item.$1),
                                ),
                              )
                              .toList(),
                    ),
                  SizedBox(
                    width: 220,
                    child: TextField(
                      controller: search,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        hintText: 'Search events',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              if (items.isEmpty)
                EmptyState(
                  title: c.loading
                      ? 'Finding your moments…'
                      : c.fetchedAt == null
                      ? 'Ready when you are'
                      : 'No matching events',
                  description: c.loading
                      ? 'Fetching data from your configured devices.'
                      : c.fetchedAt == null
                      ? 'Choose a device and a time range, then fetch events.'
                      : 'Try a different range or filter. Check any API errors above.',
                ),
              if (items.isNotEmpty)
                LayoutBuilder(
                  builder: (context, box) {
                    final columns = box.maxWidth >= 1050
                        ? 3
                        : box.maxWidth >= 620
                        ? 2
                        : 1;
                    final width = (box.maxWidth - (columns - 1) * 16) / columns;
                    return Wrap(
                      spacing: 16,
                      runSpacing: 16,
                      children: items
                          .take(visible)
                          .map(
                            (e) => SizedBox(width: width, child: eventCard(e)),
                          )
                          .toList(),
                    );
                  },
                ),
              if (items.length > visible)
                Padding(
                  padding: const EdgeInsets.only(top: 20),
                  child: Center(
                    child: OutlinedButton(
                      onPressed: () => setState(() => visible += 24),
                      child: Text(
                        'Show more (${items.length - visible} remaining)',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget dateButton(String label, DateTime value, VoidCallback tap) => SizedBox(
    width: 220,
    child: OutlinedButton(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        side: const BorderSide(color: line),
      ),
      onPressed: widget.controller.loading ? null : tap,
      child: Row(
        children: [
          const Icon(Icons.calendar_today_outlined, size: 17, color: muted),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 10, color: muted)),
              const SizedBox(height: 5),
              Text(
                dateTimeFormat.format(value),
                style: const TextStyle(fontSize: 12, color: ink),
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget metric(
    String label,
    String value,
    IconData icon,
    Color color,
    double available,
  ) => SizedBox(
    width: available < 550 ? available : (available - 32) / 3,
    child: Surface(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: ink),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    fontSize: 27,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(label, style: const TextStyle(fontSize: 12, color: muted)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
  Widget eventCard(EventItem e) => Material(
    color: Colors.white,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: const BorderSide(color: line),
    ),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: () => details(e),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (e.kind != 'recording')
            Snapshot(
              api: widget.controller.api,
              url: e.imageUrl,
              detection: e.detection,
              emptyMessage: e.kind == 'ai'
                  ? 'AI snapshot URL not returned by API'
                  : 'Snapshot not provided',
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      e.kind == 'recording'
                          ? Icons.videocam_outlined
                          : e.kind == 'ai'
                          ? Icons.person_outline
                          : Icons.doorbell_outlined,
                      size: 18,
                      color: green,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    const Icon(Icons.arrow_outward, size: 16, color: muted),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: e.kind == 'ai'
                          ? const Color(0xFFFFF1D7)
                          : e.kind == 'vms'
                          ? const Color(0xFFE9EFF8)
                          : const Color(0xFFEAF3EC),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      e.sourceLabel,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  stamp(e.timestamp),
                  style: const TextStyle(color: muted, fontSize: 12),
                ),
                const SizedBox(height: 8),
                Text(
                  e.kind == 'recording'
                      ? '${e.raw['storageType'] ?? 'Storage'} · ${e.endTime == null ? 'Duration unavailable' : '${((e.endTime! - e.timestamp) / 1000).round()} sec'}'
                      : e.kind == 'vms'
                      ? 'Doorbell event · View details'
                      : '${e.captureTimestamp == null ? 'Latest device event' : 'Frame ${stamp(e.captureTimestamp!)}'} · ${widget.controller.matchingRecording(e) == null ? 'View details' : 'Recording available'}',
                  style: const TextStyle(color: green, fontSize: 11),
                ),
                if (e.imageUrl != null &&
                    SignedUrlInfo.parse(e.imageUrl)?.expired() == true) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'Signed snapshot link expired',
                    style: TextStyle(color: Colors.deepOrange, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _TimelinePainter extends CustomPainter {
  final DateTime start, end;
  final List<EventItem> events;
  _TimelinePainter(this.start, this.end, this.events);
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = const Color(0xFFEAF0EB);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 8, size.width, 22),
        const Radius.circular(5),
      ),
      bg,
    );
    final span = (end.millisecondsSinceEpoch - start.millisecondsSinceEpoch)
        .clamp(1, 1 << 62);
    final recordings = events.where((event) => event.kind == 'recording');
    for (final event in recordings) {
      final left =
          ((event.timestamp - start.millisecondsSinceEpoch) / span * size.width)
              .clamp(0.0, size.width);
      final right =
          (((event.endTime ?? event.timestamp) - start.millisecondsSinceEpoch) /
                  span *
                  size.width)
              .clamp(0.0, size.width);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, 8, (right - left).clamp(1.0, size.width), 22),
          const Radius.circular(3),
        ),
        Paint()..color = green,
      );
    }
    for (final event in events.where((event) => event.kind != 'recording')) {
      final x =
          ((event.mediaTimestamp - start.millisecondsSinceEpoch) /
                  span *
                  size.width)
              .clamp(0.0, size.width);
      final color = event.kind == 'ai'
          ? const Color(0xFFF2A51A)
          : const Color(0xFF3478C7);
      canvas.drawCircle(
        Offset(x, 19),
        event.kind == 'ai' ? 6 : 5,
        Paint()
          ..color = color
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        Offset(x, 19),
        event.kind == 'ai' ? 7 : 6,
        Paint()
          ..color = Colors.white
          ..strokeWidth = 1.5
          ..style = PaintingStyle.stroke,
      );
    }
    for (var i = 0; i <= 6; i++) {
      canvas.drawLine(
        Offset(size.width * i / 6, 36),
        Offset(size.width * i / 6, 43),
        Paint()..color = line,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TimelinePainter old) =>
      old.start != start || old.end != end || old.events != events;
}

class _TimelineLegend extends StatelessWidget {
  final Color color;
  final String label;
  const _TimelineLegend({required this.color, required this.label});
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      ),
      const SizedBox(width: 6),
      Text(label, style: const TextStyle(fontSize: 11, color: muted)),
    ],
  );
}
