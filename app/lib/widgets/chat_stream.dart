import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';
import 'result_cards.dart';

/// Filter chips. `active` holds backend kind values; empty means All.
class FilterRow extends StatelessWidget {
  final Map<String, List<String>> filters;
  final List<String> active;
  final ValueChanged<List<String>> onPick;
  const FilterRow({
    super.key,
    required this.filters,
    required this.active,
    required this.onPick,
  });

  bool _is(String label) {
    final kinds = filters[label]!;
    if (kinds.isEmpty) return active.isEmpty;
    return active.length == kinds.length && kinds.every(active.contains);
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Row(
        children: [
          for (final label in filters.keys)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(label, style: const TextStyle(fontSize: 12)),
                selected: _is(label),
                onSelected: (_) => onPick(filters[label]!),
              ),
            ),
        ],
      ),
    );
  }
}

class Empty extends StatelessWidget {
  final ValueChanged<String> onPick;
  final bool offline;
  final bool needsIndex;
  final VoidCallback onRetry;
  final VoidCallback onAddFolder;
  const Empty({
    super.key,
    required this.onPick,
    this.offline = false,
    this.needsIndex = false,
    required this.onRetry,
    required this.onAddFolder,
  });

  static const _starters = [
    'photo where I wore a blue tshirt',
    'CNN notes',
    'last week PDFs',
  ];

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 64),
      children: [
        const Text(
          'Ask anything.',
          style: TextStyle(fontSize: 28, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        const Text(
          'Your files, searchable in plain language. 100% on-device.',
          style: TextStyle(color: AppTokens.textDim),
        ),
        const SizedBox(height: 24),
        if (offline)
          _ActionCard(
            text: 'Backend not running. Start it, then try again.',
            button: 'Retry',
            onPressed: onRetry,
          )
        else if (needsIndex)
          _ActionCard(
            text: 'No files indexed yet. Add a folder and I can search it.',
            button: 'Add a folder',
            onPressed: onAddFolder,
          )
        else
          for (final s in _starters) _Starter(text: s, onPick: onPick),
      ],
    );
  }
}

class _ActionCard extends StatelessWidget {
  final String text;
  final String button;
  final VoidCallback onPressed;
  const _ActionCard({
    required this.text,
    required this.button,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTokens.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTokens.lineMed),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text, style: const TextStyle(color: AppTokens.textDim)),
          const SizedBox(height: 12),
          OutlinedButton(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.black,
              backgroundColor: AppTokens.accent,
              side: BorderSide.none,
            ),
            onPressed: onPressed,
            child: Text(button),
          ),
        ],
      ),
    );
  }
}

class _Starter extends StatelessWidget {
  final String text;
  final ValueChanged<String> onPick;
  const _Starter({required this.text, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTokens.text,
          side: const BorderSide(color: AppTokens.lineMed),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        ),
        onPressed: () => onPick(text),
        child: Text(text),
      ),
    );
  }
}

class UserBubble extends StatelessWidget {
  final String text;
  const UserBubble({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: AppTokens.elevated,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTokens.lineSoft),
        ),
        child: Text(text),
      ),
    );
  }
}

class AnswerBlock extends StatelessWidget {
  final SearchApi api;
  final Answer answer;
  final SearchResult? selected;
  final ValueChanged<SearchResult> onOpen;
  final VoidCallback onRetry;
  final KeyFor keyFor;
  const AnswerBlock({
    super.key,
    required this.api,
    required this.answer,
    required this.selected,
    required this.onOpen,
    required this.onRetry,
    required this.keyFor,
  });

  @override
  Widget build(BuildContext context) {
    if (answer.searching) return const SearchingSkeleton();
    if (answer.stopped) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Stopped.',
                style: TextStyle(color: AppTokens.textDim),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (answer.error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Something went wrong. Try again.',
                style: TextStyle(color: AppTokens.danger),
              ),
            ),
            TextButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
    }
    if (answer.results.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Text(
          'No matches. Try different words.',
          style: TextStyle(color: AppTokens.textDim),
        ),
      );
    }
    final images = answer.results.where((r) => r.kind == 'image').toList();
    final rest = answer.results.where((r) => r.kind != 'image').toList();
    final grid = images.length >= 2;
    final best = answer.results.first;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Found ${answer.results.length} — best: ${best.name} (${(best.score * 100).round()}%)',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (grid)
            PhotoGrid(
              api: api,
              images: images,
              selected: selected,
              onOpen: onOpen,
              keyFor: keyFor,
            ),
          for (final r in (grid ? rest : answer.results))
            ResultCard(
              key: keyFor(r),
              api: api,
              result: r,
              active: r == selected,
              onTap: () => onOpen(r),
            ),
        ],
      ),
    );
  }
}

/// Pulsing placeholder cards while the backend works. No new packages.
class SearchingSkeleton extends StatefulWidget {
  const SearchingSkeleton({super.key});

  @override
  State<SearchingSkeleton> createState() => _SearchingSkeletonState();
}

class _SearchingSkeletonState extends State<SearchingSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Searching…', style: TextStyle(color: AppTokens.textDim)),
          const SizedBox(height: 8),
          for (var i = 0; i < 3; i++)
            FadeTransition(
              opacity: Tween(begin: 0.4, end: 1.0).animate(
                CurvedAnimation(parent: _c, curve: Interval(i * 0.2, 1.0)),
              ),
              child: Container(
                height: 64,
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: AppTokens.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTokens.lineSoft),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class Composer extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  const Composer({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.busy,
    required this.onSend,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onSubmitted: (_) => onSend(),
              decoration: const InputDecoration(
                hintText: 'Search your files…',
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            style: IconButton.styleFrom(
              backgroundColor: AppTokens.accent,
              foregroundColor: Colors.black,
            ),
            tooltip: busy ? 'Stop search' : 'Search',
            icon: busy
                ? const Icon(Icons.stop)
                : const Icon(Icons.arrow_upward),
            onPressed: busy ? onStop : onSend,
          ),
        ],
      ),
    );
  }
}
