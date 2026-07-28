/// POSIX-style single-quote escaping for untrusted shell arguments
/// (e.g. tmux session names). Never interpolate raw user input into shell.
String shellSingleQuote(String value) {
  // 'foo'bar' → 'foo'"'"'bar'
  return "'${value.replaceAll("'", "'\"'\"'")}'";
}
