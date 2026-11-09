/// Loads a complete, consistently ordered PostgREST result in bounded pages.
/// Callers must apply a stable order before `range` to avoid skipped rows.
class SupabasePagination {
  SupabasePagination._();

  static const pageSize = 500;

  static Future<List<Map<String, dynamic>>> loadAll(
    Future<List<Map<String, dynamic>>> Function(int from, int to) loadPage,
  ) async {
    final result = <Map<String, dynamic>>[];
    for (var from = 0; ; from += pageSize) {
      final page = await loadPage(from, from + pageSize - 1);
      result.addAll(page);
      if (page.length < pageSize) return result;
    }
  }
}
