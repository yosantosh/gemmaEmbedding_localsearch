import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../theme.dart';

/// Folder picker dialog. Returns the chosen roots, or null on cancel.
class IndexDialog extends StatefulWidget {
  final List<String> initial;
  const IndexDialog({super.key, required this.initial});

  @override
  State<IndexDialog> createState() => _IndexDialogState();
}

class _IndexDialogState extends State<IndexDialog> {
  late List<String> _roots;
  final _path = TextEditingController();

  @override
  void initState() {
    super.initState();
    _roots = [...widget.initial];
  }

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTokens.surface,
      title: const Text('Indexed folders', style: TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final r in _roots)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(r, style: const TextStyle(fontSize: 13)),
                trailing: IconButton(
                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                  color: AppTokens.textDim,
                  tooltip: 'Remove folder',
                  onPressed: () => setState(() => _roots.remove(r)),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _path,
                    decoration: const InputDecoration(
                      hintText: '/home/you/Documents',
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Browse',
                  icon: const Icon(Icons.folder_open),
                  color: AppTokens.textDim,
                  onPressed: () async {
                    final dir = await FilePicker.platform.getDirectoryPath();
                    if (dir != null) setState(() => _path.text = dir);
                  },
                ),
                IconButton(
                  tooltip: 'Add',
                  icon: const Icon(Icons.add),
                  color: AppTokens.accent,
                  onPressed: () {
                    final p = _path.text.trim();
                    if (p.isNotEmpty && !_roots.contains(p)) {
                      setState(() {
                        _roots.add(p);
                        _path.clear();
                      });
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Indexing embeds every file locally. Large folders take a while on first run.',
              style: TextStyle(color: AppTokens.textFaint, fontSize: 12),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(
            'Cancel',
            style: TextStyle(color: AppTokens.textDim),
          ),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: AppTokens.accent,
            foregroundColor: Colors.black,
          ),
          onPressed: _roots.isEmpty ? null : () => Navigator.pop(context, _roots),
          child: const Text('Index'),
        ),
      ],
    );
  }
}
