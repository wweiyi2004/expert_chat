/// Composer "联网" switch. [off] never searches; [auto] lets the model (or the
/// planner, for tool-less models) decide per question; [always] forces a
/// search tool call this turn (tool-less models still pre-search).
enum SearchMode { off, auto, always }

extension SearchModeInfo on SearchMode {
  SearchMode get next => switch (this) {
    SearchMode.off => SearchMode.auto,
    SearchMode.auto => SearchMode.always,
    SearchMode.always => SearchMode.off,
  };

  String get composerLabel => switch (this) {
    SearchMode.off => '联网',
    SearchMode.auto => '联网·自动',
    SearchMode.always => '联网·强制',
  };

  String get wire => name;

  static SearchMode fromWire(String? value) => SearchMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => SearchMode.auto,
  );
}

/// Composer "配图" switch for **dialogue** image generation (not pure 生图 mode).
///
/// - [off]: model cannot generate images in chat
/// - [auto]: tool-capable models may call `generate_image` at most once / turn
/// - [always]: force `generate_image` this turn (tool-less models still pre-gen)
enum ImageGenMode { off, auto, always }

extension ImageGenModeInfo on ImageGenMode {
  ImageGenMode get next => switch (this) {
    ImageGenMode.off => ImageGenMode.auto,
    ImageGenMode.auto => ImageGenMode.always,
    ImageGenMode.always => ImageGenMode.off,
  };

  String get composerLabel => switch (this) {
    ImageGenMode.off => '配图',
    ImageGenMode.auto => '配图·自动',
    ImageGenMode.always => '配图·强制',
  };

  String get wire => name;

  static ImageGenMode fromWire(String? value) => ImageGenMode.values.firstWhere(
    (mode) => mode.name == value,
    orElse: () => ImageGenMode.auto,
  );
}
