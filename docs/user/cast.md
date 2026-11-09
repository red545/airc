# Cast and AirPlay

On a Chromium page, choose **View › Cast…**, or type **Cast** in the Command Bar.
Pick a Chromecast or Google TV on the same local network. A site's Cast button
(Presentation API or Remote Playback) opens the same native picker; the site's
request takes priority over tab mirroring. Airc does not offer desktop capture.

Allow **Local Network** access when macOS asks. If access is denied, open
**System Settings › Privacy & Security › Local Network**, enable Airc, and choose
**Try Again**. macOS may require restarting Airc after changing this permission.
An empty list means no compatible device was discovered; it does not prove that
permission was denied. Check the TV's power, Wi-Fi and guest-network isolation.

The tab's icon and Site Controls indicate an active cast. The sidebar tray shows
the receiver for the current profile. **Stop** in the tray or **Stop casting** in
Site Controls ends the session. Closing the picker leaves it running. Use the
site's playback controls for a site-initiated session. Reopen Cast to reconnect;
Airc never starts casting automatically after a disconnect.

Safari-engine pages, including protected-media fallback pages, cannot use this
Chromium Cast route. Their picker explains this limitation. Use **AirPlay** in
WebKit's native video controls when the video and receiver support it.

The automated qualification uses an isolated fake Chromium receiver. It does not
verify Chromecast discovery, audio/video delivery, DRM playback, or macOS's actual
Local Network permission transition. Those require a real receiver and owner
qualification. Cast support must not be interpreted as a protected-media promise.
