# App 審核資訊（App Review Information）

貼到 App Store Connect 的「App 審核資訊 › 備註」。示範影片（實機錄影加英文字幕，不放進版控）用 `asc review attachments-upload` 附在審核資訊。

---

Presence Remote is the companion app for Presence, a free, open-source Mac app distributed outside the Mac App Store with Developer ID signing and Apple notarization: https://github.com/chung223/Presence/releases

The app has no account or server. It talks to Presence on a paired Mac directly over Bluetooth LE, so it needs a Mac to do anything beyond showing the pairing screen.

How to test:
1. On a Mac with macOS 26 or later, download the latest Presence zip (0.1.1 or later) from the link above, move Presence to Applications, and open it. Allow Bluetooth when asked.
2. In Presence, open "iPhone & Watch" (手機與手錶) and click "Pair New iPhone…". A QR code appears.
3. In Presence Remote on the iPhone, tap "Scan QR Code" and scan it. The Mac shows "Paired".
4. Tap "Lock Mac Now" to lock the Mac, or pause and resume automatic locking (pause and resume require the iPhone to be unlocked).
5. The Control Center control, Home Screen and Lock Screen widgets, and the Apple Watch app use the same pairing.

Demo video: attached to this review (recorded on a real iPhone paired with a Mac; English captions).

Background mode "Uses Bluetooth LE accessories" is used to keep the connection to the Mac, so the app can receive lock notifications and answer the Mac's encrypted presence confirmation while in the background.

Encryption: commands between the iPhone and the Mac are encrypted with AES-GCM using Apple's CryptoKit, only to protect communication between the user's own devices.
