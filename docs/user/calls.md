# Calls, chat and tab sharing

Airc keeps a call available when you switch tabs. The call's own page can move
into the call window; Back to Tab returns the same live page.

On supported Google Meet pages, **Chat** in the call window or sidebar media tray
opens or closes Meet's own chat panel. A badge shows the unread count exposed by
the page. Airc doesn't read message contents or send messages. If Meet changes its
controls or uses unsupported labels, the shortcut disappears; use the site's chat
button instead. Other providers can add an adapter without changing the call UI.

While a Chromium call shares a browser tab, switch to another tab in the same
profile and choose **Share This Tab Instead**. Airc uses the existing capture
session, so it doesn't ask you to pick a source again. The sharing indicator moves
only when Chromium confirms the new source. **Stop Sharing** ends the capture.
The call itself continues.

Private tabs and tabs from other profiles cannot be replacement targets. Calls
with multiple simultaneous shares, sites that disable source switching, and
policy-blocked targets don't offer the replacement action. Screen/window capture
and the WebKit development engine don't offer tab replacement through this API.
Use the provider's Share control to select a different type of source.

Closing or ending the call clears its chat and sharing controls. Synthetic chat
and Chromium capture-frame checks pass; real-provider compatibility still needs
an attended call. See the parity audit's M05 entry.
