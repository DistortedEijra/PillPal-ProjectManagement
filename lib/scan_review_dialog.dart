import 'package:flutter/material.dart';

import 'medicine_editor.dart';
import 'scan_to_schedule.dart';
import 'time_utils.dart';

const Color _brand = Color(0xFF116FA9);

/// One medicine found on a scanned prescription, as the user reviews it.
class ScannedMedicineDraft {
  String name;
  String dosage;
  List<TimeOfDay> times;
  List<String> days;
  String? endDate; // last day ('yyyy-MM-dd'), null = ongoing
  bool selected;
  bool timesGuessed; // no time/frequency was written; we used 8:00 AM
  final bool alreadyScheduled;

  ScannedMedicineDraft({
    required this.name,
    required this.dosage,
    required this.times,
    required this.days,
    this.endDate,
    required this.selected,
    required this.timesGuessed,
    required this.alreadyScheduled,
  });

  static const String defaultDosage = 'As prescribed';

  factory ScannedMedicineDraft.fromScan(ScanResult r, Set<String> existingNamesLower) {
    final name = r.name!.trim();
    final dup = existingNamesLower.contains(name.toLowerCase());
    return ScannedMedicineDraft(
      name: name,
      dosage: (r.dosage ?? '').trim(),
      times: List.of(r.times),
      days: List.of(r.days),
      endDate: r.durationDays == null ? null : endDateForDays(r.durationDays!),
      selected: !dup, // don't add a second copy by default
      timesGuessed: !r.foundFrequency,
      alreadyScheduled: dup,
    );
  }

  String get daysText {
    if (days.length == 7) return 'Every day';
    final order = {for (int i = 0; i < kDaysOfWeek.length; i++) kDaysOfWeek[i]: i};
    final sorted = List.of(days)..sort((a, b) => (order[a] ?? 9) - (order[b] ?? 9));
    return sorted.join(', ');
  }

  String get timesText => times.map(formatTime12h).join(', ');
}

/// Shows every medicine found on the prescription. The user can untick ones
/// they don't want, fix any of them, and add all the ticked ones at once.
/// Returns the medicines to add, or null if cancelled.
Future<List<ScannedMedicineDraft>?> showScanReviewDialog(
  BuildContext context,
  List<ScanResult> results,
  Iterable<String> existingMedicineNames,
) {
  final existing = existingMedicineNames.map((n) => n.trim().toLowerCase()).toSet();
  final seen = <String>{};
  final drafts = <ScannedMedicineDraft>[];
  for (final r in results) {
    if (r.name == null || r.name!.trim().isEmpty) continue;
    if (!seen.add(r.name!.trim().toLowerCase())) continue; // same medicine twice
    drafts.add(ScannedMedicineDraft.fromScan(r, existing));
  }

  return showDialog<List<ScannedMedicineDraft>>(
    context: context,
    barrierDismissible: false,
    builder: (dCtx) => _ScanReviewDialog(drafts: drafts),
  );
}

class _ScanReviewDialog extends StatefulWidget {
  final List<ScannedMedicineDraft> drafts;
  const _ScanReviewDialog({required this.drafts});

  @override
  State<_ScanReviewDialog> createState() => _ScanReviewDialogState();
}

class _ScanReviewDialogState extends State<_ScanReviewDialog> {
  int get _selectedCount => widget.drafts.where((d) => d.selected).length;

  Future<void> _edit(ScannedMedicineDraft d) async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _EditDraftDialog(draft: d),
    );
    if (changed == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final drafts = widget.drafts;
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text('Found ${drafts.length} medicines'),
      contentPadding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                'Check each one. Tap ✎ to fix the name, dose, times or days. '
                'Only ticked medicines are added.',
                style: TextStyle(fontSize: 13, color: Colors.black54),
              ),
            ),
            const SizedBox(height: 8),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: drafts.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final d = drafts[i];
                  final notes = <Widget>[
                    Text('${d.timesText} • ${d.daysText}', style: const TextStyle(fontSize: 13)),
                    if (d.endDate != null)
                      Text(courseText(d.endDate), style: const TextStyle(fontSize: 12, color: _brand)),
                    if (d.timesGuessed)
                      const Text('No time written — set to 8:00 AM. Please check.',
                          style: TextStyle(fontSize: 12, color: Colors.orange)),
                    if (d.dosage.isEmpty)
                      const Text('No dose found — will be saved as "As prescribed".',
                          style: TextStyle(fontSize: 12, color: Colors.orange)),
                    if (d.alreadyScheduled)
                      const Text('Already in your schedules.',
                          style: TextStyle(fontSize: 12, color: Colors.redAccent)),
                  ];
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Checkbox(
                        value: d.selected,
                        activeColor: _brand,
                        onChanged: (v) => setState(() => d.selected = v ?? false),
                      ),
                      Expanded(
                        child: InkWell(
                          onTap: () => setState(() => d.selected = !d.selected),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  d.dosage.isEmpty ? d.name : '${d.name} — ${d.dosage}',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                                ...notes,
                              ],
                            ),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Edit',
                        icon: const Icon(Icons.edit, size: 20),
                        onPressed: () => _edit(d),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _selectedCount == 0
              ? null
              : () => Navigator.pop(context, drafts.where((d) => d.selected).toList()),
          style: ElevatedButton.styleFrom(backgroundColor: _brand, foregroundColor: Colors.white),
          child: Text(_selectedCount == 1 ? 'Add 1 medicine' : 'Add $_selectedCount medicines'),
        ),
      ],
    );
  }
}

/// Small form to fix one scanned medicine.
class _EditDraftDialog extends StatefulWidget {
  final ScannedMedicineDraft draft;
  const _EditDraftDialog({required this.draft});

  @override
  State<_EditDraftDialog> createState() => _EditDraftDialogState();
}

class _EditDraftDialogState extends State<_EditDraftDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.draft.name);
  late final TextEditingController _dosage = TextEditingController(text: widget.draft.dosage);
  late List<TimeOfDay> _times = List.of(widget.draft.times);
  late List<String> _days = List.of(widget.draft.days);
  late String? _endDate = widget.draft.endDate;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _dosage.dispose();
    super.dispose();
  }

  Future<void> _pickTime(int? index) async {
    final picked = await showTimePicker(
      context: context,
      initialTime: index == null ? const TimeOfDay(hour: 8, minute: 0) : _times[index],
    );
    if (picked == null) return;
    setState(() {
      if (index == null) {
        _times.add(picked);
      } else {
        _times[index] = picked;
      }
      _times.sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));
    });
  }

  void _save() {
    if (_name.text.trim().isEmpty || _times.isEmpty || _days.isEmpty) {
      setState(() => _error = 'Please enter a name, at least one time, and one day.');
      return;
    }
    final d = widget.draft;
    d.name = _name.text.trim();
    d.dosage = _dosage.text.trim();
    d.times = _times;
    d.days = _days;
    d.endDate = _endDate;
    d.timesGuessed = false; // the user has checked them
    d.selected = true;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit medicine'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: 'Medicine name', border: OutlineInputBorder()),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _dosage,
              decoration: const InputDecoration(
                labelText: 'Dosage (e.g., 1 tablet)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            const Text('Times', style: TextStyle(fontWeight: FontWeight.bold)),
            Wrap(
              spacing: 6,
              children: [
                for (int i = 0; i < _times.length; i++)
                  InputChip(
                    label: Text(formatTime12h(_times[i])),
                    onPressed: () => _pickTime(i),
                    onDeleted: () => setState(() => _times.removeAt(i)),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 18),
                  label: const Text('Add time'),
                  onPressed: () => _pickTime(null),
                ),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Days', style: TextStyle(fontWeight: FontWeight.bold)),
            Wrap(
              spacing: 4,
              children: kDaysOfWeek
                  .map((day) => FilterChip(
                        label: Text(day),
                        selected: _days.contains(day),
                        onSelected: (on) => setState(() {
                          if (on) {
                            _days.add(day);
                          } else {
                            _days.remove(day);
                          }
                        }),
                      ))
                  .toList(),
            ),
            const SizedBox(height: 12),
            const Text('How long', style: TextStyle(fontWeight: FontWeight.bold)),
            CourseLengthPicker(endDate: _endDate, onChanged: (v) => setState(() => _endDate = v)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(backgroundColor: _brand, foregroundColor: Colors.white),
          child: const Text('Done'),
        ),
      ],
    );
  }
}
