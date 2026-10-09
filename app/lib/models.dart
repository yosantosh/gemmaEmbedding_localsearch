/// Wire models. Mirrors backend/app/models.py — keep in sync.
class SearchResult {
  final String path;
  final String kind;
  final String snippet;
  final double score;
  final double mtime;
  final int? vecRank; // 0-based meaning rank; null from old backends
  final int? ftsRank; // 0-based keyword rank; -1 = no exact words matched
  const SearchResult({
    required this.path,
    required this.kind,
    required this.snippet,
    required this.score,
    this.mtime = 0,
    this.vecRank,
    this.ftsRank,
  });

  String get name => path.split('/').last.split('\\').last;

  factory SearchResult.fromJson(Map<String, dynamic> j) => SearchResult(
        path: j['path'] as String? ?? '',
        kind: j['kind'] as String? ?? 'text',
        snippet: j['snippet'] as String? ?? '',
        score: (j['score'] as num? ?? 0).toDouble(),
        mtime: (j['mtime'] as num? ?? 0).toDouble(),
        vecRank: j['vec_rank'] as int?,
        ftsRank: j['fts_rank'] as int?,
      );
}

sealed class ChatEntry {
  const ChatEntry();
}

/// Index stats. Mirrors backend IndexStatus — keep in sync.
class IndexStats {
  final int files;
  final int chunks;
  final bool running;
  final List<String> roots;
  final bool rebuilt;
  const IndexStats({this.files = 0, this.chunks = 0, this.running = false, this.roots = const [], this.rebuilt = false});

  factory IndexStats.fromJson(Map<String, dynamic> j) => IndexStats(
        files: (j['files'] as num? ?? 0).toInt(),
        chunks: (j['chunks'] as num? ?? 0).toInt(),
        running: j['running'] as bool? ?? false,
        roots: ((j['roots'] as List?) ?? []).map((e) => '$e').toList(),
        rebuilt: j['rebuilt'] as bool? ?? false,
      );
}

class UserQuery extends ChatEntry {
  final String text;
  const UserQuery(this.text);
}

/// Index progress. Mirrors backend IndexProgress — keep in sync.
class IndexProgress {
  final bool running;
  final int done;
  final int total;
  final String current;
  final bool rebuilt;
  final String error;
  const IndexProgress({
    this.running = false,
    this.done = 0,
    this.total = 0,
    this.current = '',
    this.rebuilt = false,
    this.error = '',
  });

  factory IndexProgress.fromJson(Map<String, dynamic> j) => IndexProgress(
        running: j['running'] as bool? ?? false,
        done: (j['done'] as num? ?? 0).toInt(),
        total: (j['total'] as num? ?? 0).toInt(),
        current: j['current'] as String? ?? '',
        rebuilt: j['rebuilt'] as bool? ?? false,
        error: j['error'] as String? ?? '',
      );
}

class Answer extends ChatEntry {
  final String query;
  final List<SearchResult> results;
  final bool searching;
  final String? error;
  final bool stopped;
  const Answer({
    required this.query,
    this.results = const [],
    this.searching = false,
    this.error,
    this.stopped = false,
  });
}
