/// The team's API (altairfid). The tablet calls it directly, like the rfid_counter app.
///
/// The values come from altai.json (not in git), passed when the app starts:
///   flutter run --dart-define-from-file=altai.json
/// Android Studio does this for you with the "Altai POS" run configuration. See README.md.
const teamApiBaseUrl = String.fromEnvironment(
  'ALTAI_API_BASE_URL',
  defaultValue: 'https://altairfid.com/rest',
);

/// Empty when altai.json wasn't passed: the app then says so instead of calling the API.
const teamApiKey = String.fromEnvironment('ALTAI_API_KEY');
