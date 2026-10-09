import 'package:flutter/material.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';

/// Relative "edited 3d ago" label. Empty when mtime is unknown.
String relativeDate(double mtime) {
  if (mtime <= 0) return '';
  final d = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch((mtime * 1000).round()),
  );
  if (d.inSeconds < 60) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes}m ago';
  if (d.inHours < 24) return '${d.inHours}h ago';
  if (d.inDays < 30) return '${d.inDays}d ago';
  final dt = DateTime.now().subtract(d);
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
}

/// Splits "[MM:SS-…] rest" media snippets into a badge + remainder.
/// Returns (null, full snippet) for plain text.
({String? badge, String rest}) splitSnippet(String snippet) {
  final m = RegExp(r'^\[([\d:\-]+)\]\s*(.*)$').firstMatch(snippet);
  if (m == null) return (badge: null, rest: snippet);
  return (badge: m.group(1), rest: m.group(2)!);
}

typedef KeyFor = GlobalKey Function(SearchResult);

/// Visual order of an answer's hits: photo grid first (when shown),
/// then the remaining cards. Single source for display and keyboard nav.
List<SearchResult> visibleOrder(List<SearchResult> results) {
  final images = results.where((r) => r.kind == 'image').toList();
  if (images.length >= 2) {
    return [...images, ...results.where((r) => r.kind != 'image')];
  }
  return results;
}

/// 56px leading tile: thumbnail for images, monochrome icon otherwise.
class KindTile extends StatelessWidget {
  final SearchApi api;
  final SearchResult result;
  const KindTile({super.key, required this.api, required this.result});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 56,
        height: 56,
        color: AppTokens.elevated,
        child: switch (result.kind) {
          'image' => Image.network(
              api.fileUrl(result.path),
              fit: BoxFit.cover,
              cacheWidth: 160,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.image_outlined,
                color: AppTokens.textDim,
                size: 24,
              ),
            ),
          'video' => Image.network(
              api.posterUrl(result.path),
              fit: BoxFit.cover,
              cacheWidth: 160,
              errorBuilder: (_, __, ___) => const Icon(
                Icons.movie_outlined,
                color: AppTokens.textDim,
                size: 24,
              ),
            ),
          'audio' => const Icon(
              Icons.audio_file_outlined,
              color: AppTokens.textDim,
              size: 24,
            ),
          _ => const Icon(
              Icons.description_outlined,
              color: AppTokens.textDim,
              size: 24,
            ),
        },
      ),
    );
  }
}

/// Emerald-tinted range/duration pill for audio/video rows.
class RangeBadge extends StatelessWidget {
  final String text;
  const RangeBadge({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(99),
        color: AppTokens.accent.withValues(alpha: 0.12),
      ),
      child: Text(
        text,
        style: const TextStyle(color: AppTokens.accent, fontSize: 11),
      ),
    );
  }
}

class ResultCard extends StatefulWidget {
  final SearchApi api;
  final SearchResult result;
  final bool active;
  final VoidCallback onTap;
  const ResultCard({
    super.key,
    required this.api,
    required this.result,
    required this.active,
    required this.onTap,
  });

  @override
  State<ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<ResultCard> {
  bool _why = false;

  String _whyText() {
    final r = widget.result;
    final pct = (r.score * 100).round();
    final v = r.vecRank;
    final f = r.ftsRank;
    if (v == null && f == null) return 'Meaning $pct%';
    if (f != null && f >= 0) {
      final kw = 'keyword rank #${f + 1}';
      return v != null ? 'Meaning rank #${v + 1} ($pct%) · $kw' : '$kw · meaning $pct%';
    }
    return 'Meaning $pct% · no exact words matched';
  }

  @override
  Widget build(BuildContext context) {
    final result = widget.result;
    final pct = (result.score * 100).round();
    final date = relativeDate(result.mtime);
    final split = splitSnippet(result.snippet);
    final isMedia = result.kind == 'audio' || result.kind == 'video';
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTokens.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.active ? AppTokens.accent : AppTokens.lineMed,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                KindTile(api: widget.api, result: result),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        result.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [result.kind, if (date.isNotEmpty) 'edited $date']
                            .join(' · '),
                        style: const TextStyle(
                          color: AppTokens.textFaint,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Semantics(
                  label: '$pct percent match',
                  child: Text(
                    '$pct%',
                    style: const TextStyle(color: AppTokens.accent, fontSize: 12),
                  ),
                ),
              ],
            ),
            if (split.badge != null) ...[
              const SizedBox(height: 8),
              RangeBadge(text: split.badge!),
            ] else if (!isMedia && result.snippet.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                result.snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: AppTokens.textDim, fontSize: 13),
              ),
            ],
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: LinearProgressIndicator(
                value: result.score.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: AppTokens.elevated,
                valueColor: const AlwaysStoppedAnimation(AppTokens.accent),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                style: TextButton.styleFrom(
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.only(top: 6),
                  foregroundColor: AppTokens.textFaint,
                  textStyle: const TextStyle(fontSize: 11),
                ),
                onPressed: () => setState(() => _why = !_why),
                child: Text(_why ? 'Hide why' : 'Why this matched'),
              ),
            ),
            if (_why)
              Text(
                _whyText(),
                style: const TextStyle(
                  color: AppTokens.textDim,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 3-column photo grid shown above the list when an answer holds
/// 2+ image hits. Everything else renders as [ResultCard]s.
class PhotoGrid extends StatelessWidget {
  final SearchApi api;
  final List<SearchResult> images;
  final SearchResult? selected;
  final ValueChanged<SearchResult> onOpen;
  final KeyFor keyFor;
  const PhotoGrid({
    super.key,
    required this.api,
    required this.images,
    required this.selected,
    required this.onOpen,
    required this.keyFor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: GridView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemCount: images.length,
        itemBuilder: (_, i) {
          final r = images[i];
          final pct = (r.score * 100).round();
          return InkWell(
            key: keyFor(r),
            onTap: () => onOpen(r),
            borderRadius: BorderRadius.circular(12),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: r == selected ? AppTokens.accent : AppTokens.lineMed,
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      api.fileUrl(r.path),
                      fit: BoxFit.cover,
                      cacheWidth: 300,
                      errorBuilder: (_, __, ___) => Container(
                        color: AppTokens.elevated,
                        child: const Icon(
                          Icons.image_outlined,
                          color: AppTokens.textDim,
                        ),
                      ),
                    ),
                    Positioned(
                      right: 6,
                      bottom: 6,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(99),
                          color: Colors.black.withValues(alpha: 0.65),
                        ),
                        child: Text(
                          '$pct%',
                          style: const TextStyle(
                            color: AppTokens.accent,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
