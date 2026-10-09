import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../api.dart';
import '../backend_start.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/chat_stream.dart';
import '../widgets/index_dialog.dart';
import '../widgets/preview_pane.dart';
import '../widgets/result_cards.dart';

/// Chat-first search shell: history rail | stream (760px) | preview pane.
/// Rail collapses to a drawer and preview to a sheet on narrow screens.
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final _api = SearchApi();
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final List<ChatEntry> _thread = [];
  final List<String> _history = [];
  final Map<String, GlobalKey> _keys = {};
  SearchResult? _selected;
  bool _online = true;
  bool _starting = false;
  bool _busy = false;
  int _searchToken = 0;
  int _indexGen = 0;
  bool _showRebuilt = false;
  List<String> _kinds = const [];
  IndexStats? _stats;
  bool _indexing = false;
  int _indexSecs = 0;
  IndexProgress? _progress;
  Timer? _indexTimer;

  static const _filters = <String, List<String>>{
    'All': [],
    'Images': ['image'],
    'Videos': ['video'],
    'Docs': ['text', 'pdf'],
    'Audio': ['audio'],
  };

  @override
  void initState() {
    super.initState();
    _checkBackend();
  }

  Future<void> _checkBackend() async {
    if (_starting) return;
    if (await _api.healthy()) {
      if (!mounted) return;
      setState(() => _online = true);
      _refreshStats();
      return;
    }
    if (!mounted) return;
    setState(() {
      _starting = true;
      _online = false;
    });
    final ok = await BackendStart.ensureRunning(_api);
    if (!mounted) return;
    setState(() {
      _starting = false;
      _online = ok;
    });
    if (ok) _refreshStats();
  }

  void _noteOffline(Object e) {
    if (e is SocketException ||
        e is HttpException ||
        e is TimeoutException ||
        e is http.ClientException) {
      setState(() => _online = false);
    }
  }

  @override
  void dispose() {
    _indexTimer?.cancel();
    _api.dispose();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _ask([String? preset, bool echo = true]) async {
    final q = (preset ?? _input.text).trim();
    if (q.isEmpty || _busy) return;
    if ((_stats?.files ?? -1) == 0) {
      _manageIndex(); // nothing searchable yet — guide to indexing
      return;
    }
    final token = ++_searchToken;
    setState(() {
      _busy = true;
      if (echo) _thread.add(UserQuery(q));
      _thread.add(Answer(query: q, searching: true));
      if (!_history.contains(q)) _history.insert(0, q);
      if (_history.length > 50) {
        _history.removeRange(50, _history.length);
      }
    });
    _input.clear();
    _jumpToEnd();
    try {
      final results = await _api.search(q, kinds: _kinds);
      if (!mounted || token != _searchToken) return; // stopped meanwhile
      _replaceAnswer(Answer(query: q, results: results));
      if (results.isNotEmpty) {
        setState(() => _selected = results.first);
      }
    } catch (e) {
      if (!mounted || token != _searchToken) return;
      _noteOffline(e);
      _replaceAnswer(Answer(query: q, error: e.toString()));
    } finally {
      if (mounted && token == _searchToken) {
        setState(() => _busy = false);
      }
    }
    _jumpToEnd();
  }

  /// Abandons the in-flight search. The backend has no query cancel;
  /// the late response is discarded by token instead.
  void _stopSearch() {
    _searchToken++;
    final i = _thread.lastIndexWhere((e) => e is Answer);
    setState(() {
      _busy = false;
      if (i >= 0) {
        _thread[i] = Answer(query: (_thread[i] as Answer).query, stopped: true);
      }
    });
  }

  void _pick(String q) {
    if (_busy) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Wait for the current search…')),
      );
      return;
    }
    _ask(q);
  }

  void _retry(String query) {
    final i = _thread.lastIndexWhere(
      (e) =>
          e is Answer &&
          e.query == query &&
          (e.error != null || e.stopped),
    );
    if (i >= 0) setState(() => _thread.removeAt(i));
    _ask(query, false);
  }

  GlobalKey _keyFor(SearchResult r) =>
      _keys.putIfAbsent(r.path, () => GlobalKey());

  /// Latest answer's hits in visual order (grid first, then cards).
  List<SearchResult> _visibleResults() {
    for (var i = _thread.length - 1; i >= 0; i--) {
      final e = _thread[i];
      if (e is Answer && e.results.isNotEmpty) return visibleOrder(e.results);
    }
    return const [];
  }

  void _stepSelection(int dir) {
    final list = _visibleResults();
    if (list.isEmpty) return;
    var i = list.indexWhere((r) => r.path == _selected?.path);
    i = (i + dir).clamp(0, list.length - 1);
    setState(() => _selected = list[i]);
    final ctx = _keys[list[i].path]?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 180),
      );
    }
  }

  void _openSelected() {
    final s = _selected;
    if (s != null) _openPreview(s);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _focus.hasFocus) {
      return KeyEventResult.ignored; // composer keeps arrows/enter
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _stepSelection(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _stepSelection(-1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter) {
      _openSelected();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _refreshStats() async {
    try {
      final s = await _api.stats();
      if (mounted) setState(() => _stats = s);
    } catch (_) {}
  }

  Future<void> _manageIndex() async {
    final roots = await showDialog<List<String>>(
      context: context,
      builder: (_) => IndexDialog(initial: _stats?.roots ?? const []),
    );
    if (roots == null || !mounted) return;
    setState(() {
      _indexing = true;
      _indexSecs = 0;
      _progress = null;
      _showRebuilt = false;
    });
    _indexTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _indexSecs++);
    });
    try {
      await _api.startIndex(roots);
      await _pollProgress();
      if (!mounted) return;
      if ((_progress?.error ?? '').isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Index failed: ${_progress!.error}')),
        );
      } else {
        await _refreshStats();
        if (_progress?.rebuilt ?? _stats?.rebuilt ?? false) {
          setState(() => _showRebuilt = true);
        }
      }
    } catch (e) {
      if (mounted) {
        _noteOffline(e);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Index failed: $e')));
      }
    } finally {
      _indexTimer?.cancel();
      if (mounted) setState(() => _indexing = false);
    }
  }

  /// Asks the worker to stop after the current file. The poll loop
  /// below notices via its generation token and winds down.
  Future<void> _stopIndex() async {
    _indexGen++;
    try {
      await _api.cancelIndex();
    } catch (_) {}
  }

  /// Polls until the background worker finishes. Bounded: 30 minutes,
  /// then hands control back (the worker keeps going; Stop stays available).
  Future<void> _pollProgress() async {
    final gen = _indexGen;
    var n = 0;
    while (mounted && gen == _indexGen && n++ < 1800) {
      try {
        final p = await _api.indexProgress();
        if (!mounted || gen != _indexGen) return;
        setState(() => _progress = p);
        if (!p.running) return;
      } catch (e) {
        _noteOffline(e);
        return; // backend went away; stats refresh will surface it
      }
      await Future.delayed(const Duration(seconds: 1));
    }
  }

  void _replaceAnswer(Answer a) {
    if (!mounted) return;
    setState(() {
      final i = _thread.lastIndexWhere((e) => e is Answer);
      if (i >= 0) _thread[i] = a;
    });
  }

  void _jumpToEnd() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
  });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 1100;
    final rail = Rail(
      history: _history,
      onPick: _pick,
      onClear: () => setState(_history.clear),
      stats: _stats,
      indexing: _indexing,
      indexSecs: _indexSecs,
      progress: _progress,
      onManage: _manageIndex,
      onStop: _stopIndex,
    );
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () =>
            _focus.requestFocus(),
        const SingleActivator(LogicalKeyboardKey.keyK, meta: true): () =>
            _focus.requestFocus(),
      },
      child: Focus(
        onKeyEvent: _onKey,
        child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'LocalSearch',
            style: TextStyle(fontWeight: FontWeight.w600),
          ),
          actions: [
            if (!wide)
              IconButton(
                icon: _indexing
                    ? const Icon(Icons.stop, size: 20)
                    : const Icon(Icons.folder_open, size: 20),
                color: _indexing ? AppTokens.danger : AppTokens.textDim,
                tooltip: _indexing ? 'Stop indexing' : 'Manage index',
                onPressed: _indexing ? _stopIndex : _manageIndex,
              ),
            _StatusDot(online: _online),
            const SizedBox(width: 16),
          ],
        ),
        drawer: wide
            ? null
            : Drawer(backgroundColor: AppTokens.base, child: SafeArea(child: rail)),
        body: Column(
          children: [
            if (!_online && _starting)
              _Banner(
                text: 'Starting backend…',
                action: null,
                onAction: () {},
              ),
            if (!_online && !_starting)
              _Banner(
                text: 'Backend not running. Start it, then try again.',
                action: 'Retry',
                onAction: _checkBackend,
              ),
            if (_online && _showRebuilt)
              _Banner(
                text: 'Index rebuilt for the updated model.',
                action: 'Dismiss',
                onAction: () => setState(() => _showRebuilt = false),
              ),
            Expanded(
              child: Row(
                children: [
                  if (wide) rail,
                  Expanded(child: _stream()),
                  if (wide && _selected != null)
                    Container(
                      width: 360,
                      decoration: const BoxDecoration(
                        border: Border(
                          left: BorderSide(color: AppTokens.lineSoft),
                        ),
                      ),
                      child: Preview(
                        api: _api,
                        result: _selected!,
                        onClose: () => setState(() => _selected = null),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
    );
  }

  Widget _stream() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          children: [
            Expanded(
              child: _thread.isEmpty
                  ? Empty(
                      onPick: _pick,
                      offline: !_online,
                      needsIndex:
                          _online && (_stats == null || _stats!.files == 0),
                      onRetry: _checkBackend,
                      onAddFolder: _manageIndex,
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      itemCount: _thread.length,
                      itemBuilder: (_, i) => switch (_thread[i]) {
                        UserQuery(:final text) => UserBubble(text: text),
                        Answer(:final query) => AnswerBlock(
                          api: _api,
                          answer: _thread[i] as Answer,
                          selected: _selected,
                          onOpen: (r) => _openPreview(r),
                          onRetry: () => _retry(query),
                          keyFor: _keyFor,
                        ),
                      },
                    ),
            ),
            FilterRow(
              filters: _filters,
              active: _kinds,
              onPick: (k) => setState(() => _kinds = k),
            ),
            Composer(
              controller: _input,
              focusNode: _focus,
              busy: _busy,
              onSend: () => _ask(),
              onStop: _stopSearch,
            ),
          ],
        ),
      ),
    );
  }

  void _openPreview(SearchResult r) {
    if (MediaQuery.sizeOf(context).width >= 1100) {
      setState(() => _selected = r);
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: AppTokens.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => SizedBox(
          height: 500,
          child: Preview(api: _api, result: r, onClose: () {}),
        ),
      );
    }
  }
}

class _Banner extends StatelessWidget {
  final String text;
  final String? action;
  final VoidCallback onAction;
  const _Banner({
    required this.text,
    required this.action,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final action = this.action;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        color: AppTokens.surface,
        border: Border(bottom: BorderSide(color: AppTokens.lineSoft)),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(
                    color: AppTokens.textDim,
                    fontSize: 12,
                  ),
                ),
              ),
              if (action != null)
                TextButton(onPressed: onAction, child: Text(action)),
            ],
          ),
        ),
      ),
    );
  }
}

class Rail extends StatelessWidget {
  final List<String> history;
  final ValueChanged<String> onPick;
  final VoidCallback onClear;
  final IndexStats? stats;
  final bool indexing;
  final int indexSecs;
  final IndexProgress? progress;
  final VoidCallback onManage;
  final VoidCallback onStop;
  const Rail({
    super.key,
    required this.history,
    required this.onPick,
    required this.onClear,
    required this.stats,
    required this.indexing,
    required this.indexSecs,
    required this.progress,
    required this.onManage,
    required this.onStop,
  });

  @override
  Widget build(BuildContext context) {
    final s = stats;
    final p = progress;
    final determinate = indexing && p != null && p.total > 0;
    return Container(
      width: 240,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: AppTokens.lineSoft)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 4, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'RECENT',
                    style: TextStyle(
                      color: AppTokens.textFaint,
                      fontSize: 11,
                    ),
                  ),
                ),
                if (history.isNotEmpty)
                  TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                    ),
                    onPressed: onClear,
                    child: const Text(
                      'Clear',
                      style: TextStyle(
                        color: AppTokens.textFaint,
                        fontSize: 11,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                for (final h in history)
                  ListTile(
                    dense: true,
                    title: Text(
                      h,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    onTap: () => onPick(h),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  indexing
                      ? determinate
                            ? '${p.done}/${p.total}${p.current.isNotEmpty ? ' · ${p.current}' : ''}'
                            : 'Indexing… ${indexSecs}s'
                      : s == null
                      ? '● local · offline'
                      : '● ${s.files} files · ${s.chunks} chunks',
                  style: const TextStyle(
                    color: AppTokens.textDim,
                    fontSize: 11,
                  ),
                ),
                if (determinate) ...[
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: p.done / p.total,
                      minHeight: 3,
                      backgroundColor: AppTokens.elevated,
                      valueColor: const AlwaysStoppedAnimation(
                        AppTokens.accent,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: indexing
                        ? AppTokens.danger
                        : AppTokens.text,
                    side: BorderSide(
                      color: indexing
                          ? AppTokens.danger
                          : AppTokens.lineMed,
                    ),
                    minimumSize: const Size.fromHeight(36),
                  ),
                  onPressed: indexing ? onStop : onManage,
                  child: Text(
                    indexing ? 'Stop indexing' : 'Manage index',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final bool online;
  const _StatusDot({required this.online});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: online ? AppTokens.accent : AppTokens.danger,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          online ? 'local' : 'offline',
          style: const TextStyle(color: AppTokens.textDim, fontSize: 12),
        ),
      ],
    );
  }
}
