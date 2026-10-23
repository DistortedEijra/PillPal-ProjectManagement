import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'caregiver_service.dart';

const Color _brand = Color(0xFF116FA9);

/// Chat-style list of the reminders one caregiver sent to one patient.
///
/// Caregiver side: types reminders at the bottom and sees, for each one,
/// whether the patient tapped Done (and when).
/// Patient side: sees the reminders and taps Done after taking the medicine.
class ReminderChatPage extends StatefulWidget {
  final String patientUid;
  final String caregiverUid;
  final String title;
  final bool isCaregiver;

  const ReminderChatPage({
    super.key,
    required this.patientUid,
    required this.caregiverUid,
    required this.title,
    required this.isCaregiver,
  });

  @override
  State<ReminderChatPage> createState() => _ReminderChatPageState();
}

class _ReminderChatPageState extends State<ReminderChatPage> {
  final CaregiverService _service = CaregiverService();
  final TextEditingController _text = TextEditingController();
  bool _sending = false;
  final Set<String> _marking = {};

  static const List<String> _quickReplies = [
    'Please take your medicine.',
    'Time for your next dose.',
    'Did you take your medicine?',
  ];

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Future<void> _send([String? preset]) async {
    final message = (preset ?? _text.text).trim();
    if (message.isEmpty || _sending) return;
    setState(() => _sending = true);
    try {
      await _service.sendNudge(widget.patientUid, message);
      if (preset == null) _text.clear();
    } catch (e) {
      _snack('Could not send: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _markDone(String id) async {
    setState(() => _marking.add(id));
    try {
      await _service.markReminderDone(id);
    } catch (e) {
      _snack('Could not mark as done: $e');
    } finally {
      if (mounted) setState(() => _marking.remove(id));
    }
  }

  String _time(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    final sameDay = t.year == now.year && t.month == now.month && t.day == now.day;
    return sameDay ? DateFormat('h:mm a').format(t) : DateFormat('MMM d, h:mm a').format(t);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF1F5F9),
      appBar: AppBar(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        title: Text(widget.title),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _service.reminderChat(widget.patientUid, widget.caregiverUid),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text('Could not load reminders: ${snap.error}', style: const TextStyle(color: Colors.red)),
                  );
                }
                if (!snap.hasData) return const Center(child: CircularProgressIndicator());
                final docs = snap.data!.docs.toList()
                  ..sort((a, b) => reminderTimeMs(b.data()).compareTo(reminderTimeMs(a.data()))); // newest first
                if (docs.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        widget.isCaregiver
                            ? 'No reminders yet. Type one below.'
                            : 'No reminders from this caregiver yet.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
                  );
                }
                // reverse: newest message sits at the bottom, like a chat.
                return ListView.builder(
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
                  itemCount: docs.length,
                  itemBuilder: (context, i) => _bubble(docs[i].id, docs[i].data()),
                );
              },
            ),
          ),
          widget.isCaregiver ? _composer() : _patientHint(),
        ],
      ),
    );
  }

  Widget _bubble(String id, Map<String, dynamic> d) {
    final done = d['done'] == true;
    final doneAtMs = d['doneAtMs'] as int?;
    final mine = widget.isCaregiver; // caregiver's messages are "mine" on their phone
    final message = (d['message'] as String?) ?? '';

    Widget status;
    if (done) {
      status = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle, color: Colors.green, size: 18),
          const SizedBox(width: 4),
          Text(
            doneAtMs == null ? 'Done' : 'Done • ${_time(doneAtMs)}',
            style: const TextStyle(color: Colors.green, fontWeight: FontWeight.w600, fontSize: 13),
          ),
        ],
      );
    } else if (widget.isCaregiver) {
      status = const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.hourglass_bottom, color: Colors.orange, size: 18),
          SizedBox(width: 4),
          Text('Not done yet', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      );
    } else {
      final busy = _marking.contains(id);
      status = ElevatedButton.icon(
        onPressed: busy ? null : () => _markDone(id),
        icon: busy
            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.check, size: 18),
        label: const Text('Done'),
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.green,
          foregroundColor: Colors.white,
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        decoration: BoxDecoration(
          color: mine ? const Color(0xFFDCEBF5) : Colors.white,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(mine ? 14 : 2),
            bottomRight: Radius.circular(mine ? 2 : 14),
          ),
          border: Border.all(color: done ? Colors.green.shade200 : Colors.black12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(message, style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 4),
            Text(_time(reminderTimeMs(d)), style: const TextStyle(color: Colors.black45, fontSize: 12)),
            const SizedBox(height: 6),
            status,
          ],
        ),
      ),
    );
  }

  Widget _composer() {
    return SafeArea(
      top: false,
      child: Container(
        color: Colors.white,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: _quickReplies
                    .map((q) => Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ActionChip(
                            label: Text(q),
                            onPressed: _sending ? null : () => _send(q),
                          ),
                        ))
                    .toList(),
              ),
            ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _text,
                    minLines: 1,
                    maxLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText: 'Type a reminder...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(24))),
                      contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    ),
                    onSubmitted: (_) => _send(),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton.filled(
                  onPressed: _sending ? null : () => _send(),
                  style: IconButton.styleFrom(backgroundColor: _brand, foregroundColor: Colors.white),
                  icon: _sending
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _patientHint() {
    return const SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'Tap Done after you take your medicine. Your caregiver will see it.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.black54),
        ),
      ),
    );
  }
}
