# Binkies 3D viewer in an iOS app (Swift / SwiftUI)

This is the Swift counterpart of [`kotlin-example-master`](../../../Downloads/kotlin-example-master): the same
product screen, putting the Binkies 3D viewer on a `WKWebView`. The app and the page talk to each other
through a small bridge:

- The app tells the page what to show, e.g. which product (`window.binkies.setSettings(...)`).
- The page asks the app for these settings when it starts, tells it whether the product has a 3D model,
  and reports its errors (`window.webkit.messageHandlers.BinkiesNative.postMessage(...)`).

<img src="docs/screenshot.png" alt="The example app with the Mint variant selected: the 3D viewer with its action bar and thumbnails on top, the color selector below" width="300">

| File                                                         | What it is                                                                                              |
| ------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| [`BinkiesViewer.swift`](SwiftExample/BinkiesViewer.swift)   | The reusable part: the `BinkiesViewer` view, `BinkiesSettings` and the bridge. Copy this file to your app. |
| [`ContentView.swift`](SwiftExample/ContentView.swift)       | Only the demo around it: `ContentView` and `ColorSelector`.                                             |

## Run the example

1. Open `SwiftExample.xcodeproj` in Xcode (26 or newer).
2. Run the `SwiftExample` scheme on a simulator or device (iOS 16+).
3. Pick a color: Cream and Mint have a 3D model and the viewer slides open. Pink has no model, so the
   viewer stays collapsed and the label shows "(no 3D)".

## Add it to your app

1. No extra dependency and no `Info.plist` permission to add: `WebKit` is a system framework, and
   HTTPS requests work out of the box under App Transport Security.

2. Copy `BinkiesViewer.swift`, and set `viewerURL` to the viewer page you got from Binkies.

3. Use it on your product screen:

   ```swift
   // nil until the page answers, then true (has 3D) or false (no 3D)
   @State private var visible: Bool?

   var body: some View {
       BinkiesViewer(
           settings: BinkiesSettings(product: productId), // Binkies content id of the selected variant
           visible: visible == true,
           onVisibilityChange: { visible = $0 },
           onError: { message in /* optional, e.g. forward to your crash reporting */ }
       )
   }
   ```

   When the settings change (e.g. another `productId`), the viewer updates without reloading the page.
   Keep `visible` in your screen state if other UI depends on it, e.g. a "3D" badge.

   That's all. You don't need to wait for the page or keep track of what it already got: `BinkiesViewer`
   sends the settings when the page asks for them, and again whenever they change.

   `BinkiesViewer` takes the full width it's offered and animates its own height between `0` and its
   viewer size, so you don't need a container or a `GeometryReader` around it.

## How it works

```
App                                              Page (WKWebView)
 │  load(VIEWER_URL)                                │
 │ ──────────────────────────────────────────────▶  │
 │                  {"type":"setSettings"}           │  window.binkies is ready
 │ ◀──────────────────────────────────────────────  │
 │  window.binkies.setSettings({all settings})      │
 │ ──────────────────────────────────────────────▶  │  starts loading the product
 │                  {"type":"show"} or "hide"        │
 │ ◀──────────────────────────────────────────────  │
 │  window.binkies.setSettings({all settings})      │  user picks another variant
 │ ──────────────────────────────────────────────▶  │
 │                  {"type":"show"} or "hide"        │  only if it changed
 │ ◀──────────────────────────────────────────────  │
 │                {"type":"error", ...}              │  whenever the page logs an error
 │ ◀──────────────────────────────────────────────  │
```

### Messages from the page

The page calls `window.webkit.messageHandlers.BinkiesNative.postMessage(json)`. The app registers that
handler with `WKUserContentController.add(_:name:)` **before** `load()`, because the page posts as soon
as it starts (it asks for its settings right away).

| Message                                          | Meaning                                                                                                                                                                             | What the app does                                                                             |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `{"type":"setSettings"}`                         | The page is ready for its settings. Sent once per page load, as soon as the page starts.                                                                                         | Sends the current settings.                                                                   |
| `{"type":"show"}`                                | The selected product's 3D model has loaded.                                                                                                                                         | Expands the viewer.                                                                           |
| `{"type":"hide"}`                                | The selected product has no 3D model, or the device can't render 3D (no WebGL2).                                                                                                    | Collapses the viewer.                                                                         |
| `{"type":"error","message":"...","stack":"..."}` | The page logged an error: `console.error`, an uncaught error, an unhandled promise rejection or a failed script/image load. `stack` is only there when there was an `Error` object. | Logs it with `print` under the `[Binkies]` tag, and calls `onError`.  |

`show` and `hide` are only sent when the visibility changes. Switching from Cream to Mint sends nothing, because both have 3D.
The page remembers the answer per product, so switching back to a product answers right away.

### Settings sent to the page

`BinkiesViewer` always sends all settings, never only the changed ones: when the page asks for them
(`setSettings`), and whenever `settings` changes. It doesn't need to know whether the page is loaded: until
the page is ready, `window.binkies` doesn't exist and the call (`window.binkies?.setSettings(...)`) does
nothing. The page then asks for the current settings. If the page reloads, it asks again.

| `BinkiesSettings`        | Page setting                       | Type                                         | Default                     | Description                                |
| ------------------------- | ---------------------------------- | -------------------------------------------- | --------------------------- | ------------------------------------------- |
| `product`                 | `product`                          | `String`                                     | required                    | Binkies content id of the product to show. |
| `thumbnailsPlacement`     | `gallery.thumbnails.placement`     | `ThumbnailsPlacement`: `.bottom`, `.left`, `.right` | `.bottom`             | Where the thumbnail strip is placed.       |
| `thumbnailsSelectedColor` | `gallery.thumbnails.selectedColor` | SwiftUI `Color`                              | `#262626`                   | Border color of the selected thumbnail.    |

`BinkiesSettings` is `Equatable`, so only real changes are sent. Because of the enum and the `Color`
type, the app can't send an invalid placement or color. To use a new setting of the page, add a property
with a default value to `BinkiesSettings` and put it into `toJSON()`.

The page still validates the settings strictly. Unknown keys (typos) and invalid values are rejected, and the
previous settings stay in place. `evaluateJavaScript`'s completion handler isn't used here, so `setSettings`
catches JS errors and logs them with `console.error`. The page sends that back as an `error` message, which
ends up in the console under the `[Binkies]` tag and in `onError`.

## Things to keep in mind

- **Never give the WKWebView a zero/collapsed size directly.** A WKWebView laid out at zero height pauses
  the page's rendering, so the next model never finishes loading and `show` never arrives. `BinkiesViewer`
  instead keeps the WKWebView at its full `viewerHeight` (width × 1.2, pinned to the top) and animates the
  height of a clipping frame around it, exactly like the Kotlin example's clipping `Box`. Don't wrap it in
  `if visible { ... }` either: pass `visible` and let it collapse itself.
- **The page is loaded once.** `BinkiesViewer` is a `UIViewRepresentable`; SwiftUI keeps the same
  `WKWebView` instance (and the page's JS state) alive across re-renders of `ContentView`, and only
  `updateUIView` runs on settings changes.
- **No Android-style `onPause`/`onResume`.** WKWebView doesn't expose an equivalent API; iOS suspends the
  app process (and with it the page's JS timers/rendering) automatically when it's backgrounded.
- **Viewer size.** The example uses the full width and a 5:6 aspect ratio (`width * 1.2`), which fits the
  model with the thumbnails below it. Change `viewerHeight` in `BinkiesViewer` to fit your layout.

## Debugging

- With the simulator or a device connected and Web Inspector enabled (Settings → Safari → Advanced, on
  device), open Safari's Develop menu on the Mac to get DevTools for the page.
- Bridge messages and page errors are logged with `print`, tagged `[Binkies]`, visible in Xcode's console.
- On the page you can call `window.binkies.setSettings({...})` from DevTools and read the current settings
  from `window.binkies.settings`.
