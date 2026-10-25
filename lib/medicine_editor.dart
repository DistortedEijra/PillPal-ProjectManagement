import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import 'time_utils.dart';

const Color _brand = Color(0xFF116FA9);

/// The editable parts of a scheduled medicine.
class MedicineEdit {
  final String name;
  final String dosage;
  final List<TimeOfDay> times;
  final List<String> days;

  const MedicineEdit({
    required this.name,
    required this.dosage,
    required this.times,
    required this.days,
  });

  /// From a schedule document (Firestore data: times as {hour, minute}).
  factory MedicineEdit.fromFirestore(Map<String, dynamic> d) => MedicineEdit(
        name: (d['name'] ?? '').toString(),
        dosage: (d['dosage'] ?? '').toString(),
        times: ((d['schedules'] as List?) ?? [])
            .map((t) => TimeOfDay(hour: (t['hour'] as num).toInt(), minute: (t['minute'] as num).toInt()))
            .toList(),
        days: ((d['repeatDays'] as List?) ?? []).cast<String>(),
      );

  /// From the dashboard's local list (times already TimeOfDay).
  factory MedicineEdit.fromLocal(Map<String, dynamic> m) => MedicineEdit(
        name: (m['name'] ?? '').toString(),
        dosage: (m['dosage'] ?? '').toString(),
        times: List<TimeOfDay>.of((m['schedules'] as List).cast<TimeOfDay>()),
        days: List<String>.of((m['repeatDays'] as List).cast<String>()),
      );

  String get timesText => times.map(formatTime12h).join(', ');
  String get daysText => days.length == 7 ? 'Every day' : sortDays(days).join(', ');
}

List<String> sortDays(Iterable<String> days) => kDaysOfWeek.where(days.contains).toList();

List<TimeOfDay> _sortTimes(List<TimeOfDay> t) =>
    t..sort((a, b) => (a.hour * 60 + a.minute) - (b.hour * 60 + b.minute));

/// Saves an edited schedule. Works for the patient (their own schedule) and
/// for a linked caregiver (the patient's schedule; allowed by firestore.rules).
class ScheduleEdits {
  static Future<void> save({
    required String ownerUid,
    required String scheduleId,
    required MedicineEdit edit,
    required String oldName,
    String? editorName,
  }) async {
    final me = FirebaseAuth.instance.currentUser;
    final byCaregiver = me != null && me.uid != ownerUid;
    final renamed = edit.name.trim().toLowerCase() != oldName.trim().toLowerCase();
    await FirebaseFirestore.instance
        .collection('users')
        .doc(ownerUid)
        .collection('schedules')
        .doc(scheduleId)
        .update({
      'name': edit.name.trim(),
      'dosage': edit.dosage.trim(),
      'schedules': edit.times.map((t) => {'hour': t.hour, 'minute': t.minute}).toList(),
      'repeatDays': sortDays(edit.days),
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': me?.uid,
      'updatedByName': editorName,
      // A caregiver can't change the patient's PillPalBox slots, so the
      // patient's app renames the slot when it sees this.
      if (byCaregiver && renamed) 'renamedFrom': oldName,
    });
  }
}

/// Opens the edit form. Returns the changes, or null if cancelled.
Future<MedicineEdit?> showMedicineEditor(
  BuildContext context, {
  required MedicineEdit initial,
  String title = 'Edit medicine',
  String? subtitle,
}) {
  return showDialog<MedicineEdit>(
    context: context,
    builder: (_) => _MedicineEditorDialog(initial: initial, title: title, subtitle: subtitle),
  );
}

class _MedicineEditorDialog extends StatefulWidget {
  final MedicineEdit initial;
  final String title;
  final String? subtitle;
  const _MedicineEditorDialog({required this.initial, required this.title, this.subtitle});

  @override
  State<_MedicineEditorDialog> createState() => _MedicineEditorDialogState();
}

class _MedicineEditorDialogState extends State<_MedicineEditorDialog> {
  late final TextEditingController _name = TextEditingController(text: widget.initial.name);
  late final TextEditingController _dosage = TextEditingController(text: widget.initial.dosage);
  late final List<TimeOfDay> _times = _sortTimes(List.of(widget.initial.times));
  late final Set<String> _days = widget.initial.days.toSet();
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
    if (_times.any((t) => t.hour == picked.hour && t.minute == picked.minute)) return;
    setState(() {
      if (index == null) {
        _times.add(picked);
      } else {
        _times[index] = picked;
      }
      _sortTimes(_times);
    });
  }

  void _save() {
    if (_name.text.trim().isEmpty || _dosage.text.trim().isEmpty) {
      setState(() => _error = 'Please enter the medicine name and dosage.');
      return;
    }
    if (_times.isEmpty || _days.isEmpty) {
      setState(() => _error = 'Please keep at least one time and one day.');
      return;
    }
    Navigator.pop(
      context,
      MedicineEdit(
        name: _name.text.trim(),
        dosage: _dosage.text.trim(),
        times: List.of(_times),
        days: sortDays(_days),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.subtitle != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(widget.subtitle!, style: const TextStyle(fontSize: 13, color: Colors.black54)),
              ),
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
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
            const SizedBox(height: 14),
            const Text('Times', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Wrap(
              spacing: 6,
              runSpacing: 4,
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
            const SizedBox(height: 14),
            Row(
              children: [
                const Text('Days', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                TextButton(
                  onPressed: () => setState(() {
                    if (_days.length == 7) {
                      _days.clear();
                    } else {
                      _days.addAll(kDaysOfWeek);
                    }
                  }),
                  child: Text(_days.length == 7 ? 'Clear' : 'Every day'),
                ),
              ],
            ),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: kDaysOfWeek
                  .map((day) => FilterChip(
                        label: Text(day),
                        selected: _days.contains(day),
                        selectedColor: _brand.withOpacity(0.2),
                        onSelected: (on) => setState(() => on ? _days.add(day) : _days.remove(day)),
                      ))
                  .toList(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(_error!, style: const TextStyle(color: Colors.red, fontSize: 13)),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: _save,
          style: ElevatedButton.styleFrom(backgroundColor: _brand, foregroundColor: Colors.white),
          child: const Text('Save changes'),
        ),
      ],
    );
  }
}
