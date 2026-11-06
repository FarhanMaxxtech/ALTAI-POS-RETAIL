# Features

Each feature has the same three layers. Code only calls **downward**:

```
presentation/  screens + widgets         → may use domain/ and data/
domain/        plain Dart classes/rules   → uses nothing from Flutter or HTTP
data/          API calls, JSON ↔ domain   → uses core/ (API client)
```

- `auth/`: login, current user, token storage
- `catalog/`: product/variant lookup by SKU, barcode or RFID tag
- `cart/`: lines, quantities, discounts
- `checkout/`: the basket of tagged pieces and recording the sale (payment stays on StoreHub, see docs/api/checkout.md)

Shared building blocks go in `lib/core/` (API client, config, errors) and `lib/shared/` (widgets, money formatting).
