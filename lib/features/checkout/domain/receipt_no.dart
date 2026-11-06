/// Checks a StoreHub receipt number as typed by the cashier.
///
/// A StoreHub receipt no. is 16 digits: register (3) + date (yymmdd) + time (hhmmss) + 1 more digit,
/// e.g. 002 260720 144620 8 = register 002, 20 Jul 2026, 2:46:20 pm.
///
/// [error] stops Submit (it can't be a StoreHub receipt). [warning] only asks the cashier to look
/// again (an old receipt can be right, e.g. more items for yesterday's sale).
({String? error, String? warning}) checkReceiptNo(String typed, DateTime now) {
  final no = typed.replaceAll(RegExp(r'[\s·-]'), '');
  if (no.isEmpty) return (error: null, warning: null);
  if (!RegExp(r'^\d+$').hasMatch(no)) {
    return (error: 'A StoreHub receipt no. has only digits.', warning: null);
  }
  if (no.length != 16) {
    return (error: 'A StoreHub receipt no. has 16 digits (this has ${no.length}).', warning: null);
  }
  final paid = receiptTime(no);
  if (paid == null) {
    return (error: 'This number has no valid date and time in it. Check it on the iPad.', warning: null);
  }
  // A few minutes of slack: the iPad's and the tablet's clocks may differ a little.
  if (paid.isAfter(now.add(const Duration(minutes: 10)))) {
    return (error: 'The date in this receipt no. is in the future. Check it on the iPad.', warning: null);
  }
  if (paid.year != now.year || paid.month != now.month || paid.day != now.day) {
    return (error: null, warning: 'This receipt is from ${_day(paid)}, not today.');
  }
  return (error: null, warning: null);
}

/// When the sale was paid, read from the receipt no. Null when the digits aren't a real date and time.
DateTime? receiptTime(String no) {
  if (!RegExp(r'^\d{16}$').hasMatch(no)) return null;
  int at(int i) => int.parse(no.substring(i, i + 2));
  final (y, mo, d, h, mi, s) = (2000 + at(3), at(5), at(7), at(9), at(11), at(13));
  final t = DateTime(y, mo, d, h, mi, s);
  // DateTime rolls 31 Feb over into March: a real date comes back unchanged.
  final real = t.year == y && t.month == mo && t.day == d && t.hour == h && t.minute == mi && t.second == s;
  return real ? t : null;
}

const _months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

String _day(DateTime t) => '${t.day} ${_months[t.month - 1]} ${t.year}';
