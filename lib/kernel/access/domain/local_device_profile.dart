import 'car.dart';

class LocalDeviceProfile {
  const LocalDeviceProfile({
    required this.id,
    required this.displayName,
    required this.cars,
  });
  final String id;
  final String displayName;
  final List<Car> cars;
  String get initials {
    final parts = displayName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '';
    return parts.take(2).map((p) => p.substring(0, 1).toUpperCase()).join();
  }
}
