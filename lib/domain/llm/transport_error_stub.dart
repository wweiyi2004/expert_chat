bool isTransportFailure(Object? error) => false;
String underlyingTransportDetails(Object? error) =>
    error == null ? '底层异常：未提供' : '底层异常：${error.runtimeType}';
