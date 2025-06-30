int hashValues(
  Object? arg1,
  Object? arg2, [
  Object? arg3,
  Object? arg4,
  Object? arg5,
  Object? arg6,
  Object? arg7,
  Object? arg8,
  Object? arg9,
]) {
  final List<Object?> values = [
    arg1,
    arg2,
    arg3,
    arg4,
    arg5,
    arg6,
    arg7,
    arg8,
    arg9,
  ];
  return values
      .where((e) => e != null)
      .fold(0, (prev, element) => prev ^ element.hashCode);
}
