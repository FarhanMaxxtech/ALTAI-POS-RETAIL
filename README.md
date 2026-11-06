# Altai POS (tablet)

The Android checkout app. It calls the team's API (altairfid.com) directly, like the rfid_counter app.
There's no backend in between.

## Run it in Android Studio

1. Copy `altai.example.json` to `altai.json` (same folder) and put the team API key in it.
   `altai.json` is in `.gitignore`: never commit it.
2. Open the `pos-app` folder in Android Studio and plug in the tablet (USB debugging on).
3. Pick the **Altai POS** run configuration at the top, then press Run.
   It passes `--dart-define-from-file=altai.json` for you.

Without `altai.json` the app opens but says it has no API key.

From a terminal instead:

```bash
flutter run --dart-define-from-file=altai.json
```

## What checkout calls

| Step | Team API call |
| --- | --- |
| Log in | `POST Merchant/Login` (session comes back in the `session` header) |
| Pick store | `GET Stock/StoreList` |
| Check scanned tags | `POST Stock/EpcList` (one call) + `POST Stock/TagLookup` (per tag, 5 at a time) |
| Record the sale | `POST Stock/Checkout` `{ storeId, trxDate, remark, epcs }` → `trxId` |
| After no answer, before sending again | `GET Stock/CheckoutList` (looks for the basket's ref in the remark) |

A 440 answer logs in again once and repeats the call. `Stock/Checkout` changes live stock, so only test
it on a test merchant.
