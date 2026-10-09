import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_filex/open_filex.dart';

import '../api.dart';
import '../models.dart';
import '../theme.dart';

String _mmss(Duration d) =>
    '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Start seconds parsed from "[MM:SS-…]" window snippets. Null when absent.
double? rangeStartSec(String snippet) {
  final m = RegExp(r'^\[(\d+):(\d+)-').firstMatch(snippet);
  if (m == null) return null;
  return double.parse(m.group(1)!) * 60 + double.parse(m.group(2)!);
}

class Preview extends StatelessWidget {
  final SearchApi api;
  final SearchResult result;
  final VoidCallback onClose;
  const Preview({
    super.key,
    required this.api,
    required this.result,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  result.name,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                color: AppTokens.textDim,
                tooltip: 'Close preview',
                onPressed: onClose,
              ),
            ],
          ),
          Text(
            result.path,
            style: const TextStyle(color: AppTokens.textFaint, fontSize: 11),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: AppTokens.lineMed),
            ),
            child: Text(
              '${result.kind} · ${(result.score * 100).round()}% match',
              style: const TextStyle(fontSize: 11, color: AppTokens.textDim),
            ),
          ),
          if (result.kind == 'image') ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                api.fileUrl(result.path),
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox(
                  height: 48,
                  child: Center(
                    child: Text(
                      'Preview unavailable',
                      style: TextStyle(
                        color: AppTokens.textFaint,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (result.kind == 'audio') ...[
            const SizedBox(height: 12),
            RangePlayer(
              url: api.fileUrl(result.path),
              startSec: rangeStartSec(result.snippet) ?? 0,
            ),
          ],
          if (result.kind == 'video') ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                api.posterUrl(result.path),
                height: 180,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  height: 96,
                  color: AppTokens.elevated,
                  child: const Center(
                    child: Icon(
                      Icons.movie_outlined,
                      color: AppTokens.textDim,
                      size: 32,
                    ),
                  ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                result.snippet.isEmpty ? 'No text preview.' : result.snippet,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.black,
                    backgroundColor: AppTokens.accent,
                    side: BorderSide.none,
                  ),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  label: const Text('Open'),
                  onPressed: () => OpenFilex.open(result.path),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.outlined(
                style: IconButton.styleFrom(
                  foregroundColor: AppTokens.textDim,
                  side: const BorderSide(color: AppTokens.lineMed),
                ),
                tooltip: 'Copy path',
                icon: const Icon(Icons.copy, size: 16),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: result.path));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Path copied')),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Streams the file from the backend; first play seeks to the matched
/// window start. Player is released with the widget.
class RangePlayer extends StatefulWidget {
  final String url;
  final double startSec;
  const RangePlayer({super.key, required this.url, required this.startSec});

  @override
  State<RangePlayer> createState() => _RangePlayerState();
}

class _RangePlayerState extends State<RangePlayer> {
  late final AudioPlayer _player;
  StreamSubscription? _stateSub;
  StreamSubscription? _posSub;
  StreamSubscription? _durSub;
  bool _playing = false;
  bool _sought = false;
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _stateSub = _player.onPlayerStateChanged.listen((s) {
      if (mounted) setState(() => _playing = s == PlayerState.playing);
    });
    _posSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _pos = p);
    });
    _durSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _dur = d);
    });
  }

  @override
  void dispose() {
    _stateSub?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    if (_playing) {
      await _player.pause();
      return;
    }
    if (!_sought) {
      await _player.setSource(UrlSource(widget.url));
      if (widget.startSec > 0) {
        await _player.seek(Duration(seconds: widget.startSec.round()));
      }
      _sought = true;
    }
    await _player.resume();
  }

  @override
  Widget build(BuildContext context) {
    final max = _dur.inSeconds.toDouble();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppTokens.elevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTokens.lineSoft),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              _playing ? Icons.pause : Icons.play_arrow,
              color: AppTokens.accent,
            ),
            tooltip: _playing ? 'Pause' : 'Play from matched part',
            onPressed: _toggle,
          ),
          Text(_mmss(_pos), style: _t),
          Expanded(
            child: Slider(
              min: 0,
              max: max > 0 ? max : 1,
              value: _pos.inSeconds.toDouble().clamp(0, max > 0 ? max : 1),
              activeColor: AppTokens.accent,
              inactiveColor: AppTokens.lineMed,
              onChanged: max > 0
                  ? (v) => _player.seek(Duration(seconds: v.round()))
                  : null,
            ),
          ),
          Text(_mmss(_dur), style: _t),
        ],
      ),
    );
  }
}

const _t = TextStyle(color: AppTokens.textDim, fontSize: 11);
