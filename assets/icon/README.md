# App Icon Setup

To set up the app icon:

1. Place your app icon image in this directory as `app_icon.png`
2. The icon should be:
   - **1024x1024 pixels** (square)
   - **PNG format**
   - **Transparent background** (if needed)
   - The icon should show:
     - ॐ (Om symbol) at the top
     - धर्म (Dharma) text below
     - Orange background (#FF6B35 or similar)

3. After placing the icon, run:
   ```bash
   flutter pub get
   flutter pub run flutter_launcher_icons
   ```

4. Rebuild the app:
   ```bash
   flutter clean
   flutter run
   ```

The `flutter_launcher_icons` package will automatically generate all required icon sizes for both Android and iOS.

