/// Tracks which document the live blob object URL serves, so repeated
/// launches of the same document reuse one URL instead of minting +
/// auto-revoking a fresh URL per click, and the URL is only revoked when
/// this window unloads — a fixed timer could fire before a background tab
/// lazily loads the preview.
///
/// Pure Dart (no browser APIs) so the reuse/revoke policy is unit-testable;
/// the browser glue lives in [html_preview_launcher_web.dart].
class PreviewUrlPolicy {
  /// The document the current object URL was created for, or null when no URL
  /// is live (first launch, or after [revoke]).
  String? document;

  /// The live object URL for [document], or null after [revoke].
  String? url;

  /// A fresh object URL must be minted for [html] unless the current one was
  /// created for exactly the same document and hasn't been revoked.
  bool needsNewUrlFor(String html) => url == null || document != html;

  void register(String html, String url) {
    document = html;
    this.url = url;
  }

  /// Drops the live URL (window unload / explicit revoke). The next launch
  /// then mints a fresh one.
  void revoke() {
    document = null;
    url = null;
  }
}

/// Process-wide policy instance. One per page load — a reload starts a fresh
/// JS world, so the next launch rebuilds the URL instead of reusing a
/// revoked one.
final PreviewUrlPolicy previewUrlPolicy = PreviewUrlPolicy();
