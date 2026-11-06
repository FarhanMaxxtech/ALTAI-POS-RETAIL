# Altai POS Retail (tablet)

The Android checkout app for RFID-tagged stores. Staff scan items with an RFID reader, the app checks every
tag with the Altai team API (`altairfid.com/rest`) and records the sale; payment is taken on StoreHub (iPad)
as usual. The tablet calls the Altai API directly: there's no backend of ours in between.

> **Careful:** `Stock/Checkout` and returns change **live stock** in Altai. Test on a test merchant or with
> test items, and return anything you "sold" while testing.

## What you need

- **Flutter 3.41** (Dart 3.11) and **Android Studio** (or the Android SDK + `adb`).
- An Android tablet (developed on a Samsung Galaxy Tab S9 FE+, SM-X610) with **USB debugging** on.
- The **Altai team API key** (ask the team; never commit it).
- The **Silion desktop RFID reader** (USB). The app also opens without it, it just can't scan.

## First-time setup

1. Clone the repo and open the folder in Android Studio (or VS Code).
2. Copy `altai.example.json` to `altai.json` in the same folder and paste the API key into it.
   `altai.json` is in `.gitignore`: **never commit it**.
3. `flutter pub get`

Without `altai.json` the app opens but every server call says it has no API key.

## Run it on the tablet

Every build and run **must** pass the key file:

```bash
flutter run --dart-define-from-file=altai.json
```

In Android Studio: **Run ▸ Edit Configurations ▸ main.dart ▸ Additional run args** →
`--dart-define-from-file=altai.json`.

To build and install an APK instead:

```bash
flutter build apk --debug --dart-define-from-file=altai.json
```

```bash
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

### When the reader is plugged into the tablet

The tablet has one USB port, so once the reader is in it, use **Wi-Fi debugging**. With the tablet still on
the cable once:

```bash
adb tcpip 5555
```

```bash
adb connect <tablet-ip>:5555
```

Then unplug the cable, plug in the reader, and `adb install` / `flutter run` work over Wi-Fi.

## The RFID reader

- The **Silion desktop reader** (USB `2E88:4605`) must be in **Passive mode**: set it once in Silion's
  *ReaderManager* (Windows) under **Auto Mode ▸ Revert to passive**. In its other (keyboard / active) mode
  it ignores the app.
- Plugging it into the tablet asks *"Open Altai POS?"*: tick **Always**. The app then drives it itself
  (`android/.../SilionReader.kt`): press **Scan**, it reads until **Stop scanning**.
- Tags with **no product** in Altai are ignored. EPC numbers are never shown, only product names.

## How it works (for the cashier)

1. **Log in** with the Altai account; the tablet's store (location) is set once and remembered.
2. **Start page:** *Scan for Checkout* or *Return / Refund*.
3. **Scan page:** Scan → the reader keeps reading → Stop scanning. Scan again adds more; Remove all clears.
4. **Checkout:** every tag is checked with the server (in this store, not sold, not held by a transfer or
   count). Enter the **StoreHub receipt no.** (16 digits, or the last 4 + *Find*), then **Confirm & submit**.
5. **Return / Refund** puts items back into stock; **Exchange** = a return, then a sale on the same receipt.
6. **StoreHub orders** (receipt icon): scan the items of a sale paid on StoreHub. *Demo data for now*: the
   Altai server doesn't send StoreHub sales to the tablet yet.

## Code map

| Folder | What's there |
| --- | --- |
| `lib/main.dart` | Start-up: login → start page |
| `lib/core/` | `api_client.dart` (headers, session, errors), `config.dart` (API URL and key from `altai.json`) |
| `lib/features/auth/` | Login, store (location) choice, remembered session |
| `lib/features/home/` | The start page |
| `lib/features/checkout/` | Scan page, basket rules, receipt check, store tag list, checkout screens |
| `lib/features/returns/` | Return / refund and exchange |
| `lib/features/orders/` | StoreHub orders (demo data source in `orders_api.dart`) |
| `lib/shared/` | Theme, shared widgets, beeper, `rfid_reader.dart` (Flutter side of the reader) |
| `android/.../SilionReader.kt` | The USB reader driver (Silion command protocol over USB HID) |
| `test/` | Widget and unit tests: `flutter test` (all must pass) |

## Team API calls used

| Step | Call |
| --- | --- |
| Log in | `POST Merchant/Login` (session in the `session` response header) |
| Stores | `GET Stock/StoreList` |
| Store tag list (names shown at once) | `POST Stock/EpcList` by store, page by page, every 10 min |
| Check scanned tags | `POST Stock/EpcList` (one call) + `POST Stock/TagLookup` (per tag, 5 at a time) |
| Prices and pictures | `POST Product/List` |
| Record a sale | `POST Stock/Checkout` `{ storeId, trxDate, remark, epcs }` → `trxId` |
| After no answer, before sending again | `GET Stock/CheckoutList` (finds the basket's ref in the remark) |
| Returns | `POST Stock/Adjustment` (stock in) + `Stock/AdjustmentApproveNoScan` |

Headers: `APIKEY` always, `SESSION` + `MERCHANTID` after login. A `440` answer logs in again once and
repeats the call.

## Before you push

```bash
flutter analyze
```

```bash
flutter test
```

Never commit `altai.json`, `build/` or any key.
