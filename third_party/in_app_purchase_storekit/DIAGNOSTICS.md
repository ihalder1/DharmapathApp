# Local diagnostic patch

This is the `in_app_purchase_storekit` 0.4.8+1 package source pinned by the
project lockfile, with diagnostic-only StoreKit 2 source events added for the
iOS purchase investigation. Purchase requests, results, transaction delivery,
restoration, verification, and finishing behavior are unchanged.

The `STOREKIT_DIAGNOSTICS` Dart define enables the app-side diagnostic log in a
Release build. Keep it disabled in ordinary production builds.
