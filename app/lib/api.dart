import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';

/// Minimal localhost client for the FastAPI sidecar.
class SearchApi {
  final String base;
  final http.Client _client;
  SearchApi({this.base = 'http://127.0.0.1:39281', http.Client? client})
      : _client = client ?? http.Client();

  Future<bool> healthy() async {
    try {
      final r = await _client
          .get(Uri.parse('$base/health'))
          .timeout(const Duration(seconds: 10));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<List<SearchResult>> search(String query, {int topK = 10, List<String>? kinds}) async {
    final r = await _client
        .post(
          Uri.parse('$base/search'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'query': query, 'top_k': topK, 'kinds': kinds ?? []}),
        )
        .timeout(const Duration(seconds: 90));
    if (r.statusCode != 200) throw Exception('search ${r.statusCode}');
    final j = jsonDecode(r.body) as Map<String, dynamic>;
    return ((j['results'] as List?) ?? [])
        .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<IndexStats> stats() async {
    final r = await _client
        .get(Uri.parse('$base/stats'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('stats ${r.statusCode}');
    return IndexStats.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  Future<IndexStats> index(List<String> roots) async {
    final r = await _client
        .post(
          Uri.parse('$base/index'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'roots': roots, 'reset': true}),
        )
        .timeout(const Duration(minutes: 10));
    if (r.statusCode != 200) throw Exception('index ${r.statusCode}: ${r.body}');
    return IndexStats.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Starts indexing without waiting. Poll [indexProgress] until
  /// `running` is false, then read [stats] (and its `rebuilt` flag).
  Future<void> startIndex(List<String> roots) async {
    final r = await _client
        .post(
          Uri.parse('$base/index'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'roots': roots, 'reset': true, 'background': true}),
        )
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) throw Exception('index ${r.statusCode}: ${r.body}');
  }

  /// Asks the worker to stop after the current file. Progress reports
  /// `error: "cancelled by user"` when it lands.
  Future<void> cancelIndex() async {
    await _client
        .post(Uri.parse('$base/index/cancel'))
        .timeout(const Duration(seconds: 10));
  }

  Future<IndexProgress> indexProgress() async {
    final r = await _client
        .get(Uri.parse('$base/index/progress'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('progress ${r.statusCode}');
    return IndexProgress.fromJson(jsonDecode(r.body) as Map<String, dynamic>);
  }

  /// Direct bytes URL for thumbnails/previews. Backend guards roots (403).
  String fileUrl(String path) => '$base/file?path=${Uri.encodeComponent(path)}';

  /// First-frame JPEG for videos. 404 when none was captured.
  String posterUrl(String path) =>
      '$base/poster?path=${Uri.encodeComponent(path)}';

  void dispose() => _client.close();
}
