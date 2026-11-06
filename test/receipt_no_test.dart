import 'package:altai_pos/features/checkout/domain/receipt_no.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 20 Jul 2026, 3:00 pm: the day the two sample receipts were printed.
  final now = DateTime(2026, 7, 20, 15);

  test('a real StoreHub receipt no. of today passes', () {
    expect(checkReceiptNo('0022607201446208', now), (error: null, warning: null));
    expect(checkReceiptNo('002 2607 2014 4950 9', now), (error: null, warning: null)); // spaces are fine
    expect(receiptTime('0022607201446208'), DateTime(2026, 7, 20, 14, 46, 20));
  });

  test('empty: nothing to say yet', () {
    expect(checkReceiptNo('  ', now), (error: null, warning: null));
  });

  test('wrong length or letters: an error', () {
    expect(checkReceiptNo('6208', now).error, 'A StoreHub receipt no. has 16 digits (this has 4).');
    expect(checkReceiptNo('00226072014462081', now).error, 'A StoreHub receipt no. has 16 digits (this has 17).');
    expect(checkReceiptNo('SH-0012', now).error, 'A StoreHub receipt no. has only digits.');
  });

  test('no real date or time in it: an error', () {
    expect(checkReceiptNo('0022602301446208', now).error, isNotNull); // 30 Feb
    expect(checkReceiptNo('0022607202546208', now).error, isNotNull); // 25 o'clock
    expect(checkReceiptNo('0022607201460208', now).error, isNotNull); // minute 60
  });

  test('from the future: an error; a few minutes of clock difference is fine', () {
    expect(checkReceiptNo('0022607211446208', now).error, contains('future')); // tomorrow
    expect(checkReceiptNo('0022607201505008', now).error, isNull); // 3:05 pm, 5 min ahead
  });

  test('not today: only a warning', () {
    final r = checkReceiptNo('0022607191446208', now);
    expect(r.error, isNull);
    expect(r.warning, 'This receipt is from 19 Jul 2026, not today.');
  });
}
