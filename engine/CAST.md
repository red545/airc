# Native Cast hosting

Chromium's media router is already compiled into the Mac framework. The port's
`airc_cast_dialog.mm` and gated `airc_test_media_route_provider.cc` were present,
but their Views integration seams were unused. Patch 032 connects the controller
without replacing Chromium's discovery, request validation or route provider.

`Airc.h` already exports the needed API:

- `AircTab.showCastDialog` starts discovery for that tab's profile.
- `engine:castDialog:tab:` sends the dialog ID, open flag, header,
  `permissionRejected`, and sinks (opaque ID, name, state, compatible mode bits,
  route ID and issue). States include available, connecting, connected,
  disconnecting and unavailable. Issues carry routing errors.
- `startCasting:sink:mode:` uses presentation mode 1 for a site's pending request,
  otherwise tab mirroring mode 2. No desktop mode is offered by the app.
- `AircProfile.watchCastRoutes` and `engine:castRoutes:profile:` report the
  profile's live routes, including removal when a session ends.
- `stopCasting:route:` stops through an open controller;
  `terminateCastRoute:` works after closing the picker.
- `closeCastDialog:` cancels a pending presentation request and releases its
  fullscreen blocker. It does not terminate an established route.

All callbacks are on Chromium's UI thread. The Swift adapter defers mutations to
the next main-queue turn. Profile keys include the private-session flag; opaque
route IDs never appear in telemetry or screenshots.

Site requests take the base controller's StartPresentationContext path, then the
same hosted MediaRouterUI as the browser command. Chromium drops content
fullscreen before handing its blocker to the host and keeps fullscreen blocked
for the picker's lifetime. Airc-hosted contents do not create a Views Cast/GMC
widget. Closing, navigating or destroying the initiator resets the controller.

`engine/host/tests/cast.mm` checks real host callbacks and the existing fake
provider (`--airc-test=mediaRouteProvider`, unsigned scratch profile and mock
Keychain required; create the scratch `Chromium` directory before launch so the
startup gate can resolve its canonical path). Its fake route does not capture a screen, stream audio or
reach a receiver. `ParityCastCheck` (`--script paritycast`) exercises the app on
both engines, with a separate fake-provider Chromium launch. Permission UI
injection is explicitly synthetic: actual deny/grant and physical-device playback
remain owner qualification. See `docs/user/cast.md`.
