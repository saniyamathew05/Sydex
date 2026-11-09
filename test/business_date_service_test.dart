import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sydex/services/business_date_service.dart';

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await BusinessDateService.load();
  });

  test('starts a session on the device-local date without restoring yesterday', () {
    final now = DateTime.now();
    expect(BusinessDateService.isManual.value, isFalse);
    expect(BusinessDateService.selectedDate.value, DateTime(now.year, now.month, now.day));
  });

  test('manual business date is explicit and Today clears it', () async {
    final manual = DateTime(2024, 1, 15);
    await BusinessDateService.setDate(manual);
    expect(BusinessDateService.isManual.value, isTrue);
    expect(BusinessDateService.selectedDate.value, manual);

    await BusinessDateService.useToday();
    expect(BusinessDateService.isManual.value, isFalse);
    final now = DateTime.now();
    expect(BusinessDateService.selectedDate.value, DateTime(now.year, now.month, now.day));
  });
}
