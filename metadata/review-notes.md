# App 審核資訊（App Review Information）

貼到 App Store Connect 的「App 審核資訊 › 備註」。示範影片（實機錄影加英文字幕，不放進版控）用 `asc review attachments-upload` 附在審核資訊。

---

Presence Remote is the companion app for Presence, a free, open-source Mac app distributed outside the Mac App Store with Developer ID signing and Apple notarization: https://github.com/chung223/Presence/releases

The app has no account or server. It talks to Presence on a paired Mac directly over Bluetooth LE, so it needs a Mac to do anything beyond showing the pairing screen.

How to test:
1. On a Mac with macOS 26 or later, download the latest Presence zip (0.2.0 or later) from the link above, move Presence to Applications, and open it. Allow Bluetooth when asked.
2. In Presence, open "iPhone & Watch" (手機與手錶) and click "Pair New iPhone…". A QR code appears.
3. In Presence Remote on the iPhone, tap "Scan QR Code" and scan it. The Mac shows "Paired".
4. Tap "Lock Mac Now" to lock the Mac, or pause and resume automatic locking (pause and resume require the iPhone to be unlocked).
5. The Control Center control, Home Screen and Lock Screen widgets, and the Apple Watch app use the same pairing.

Presence Pro (in-app purchases):
- Presenter Remote is the only paid feature. Locking, pausing, notifications, and widgets stay free, and the Mac app is free and open source.
- Products: monthly subscription, yearly subscription (both in the "Presence Pro" group, each with a 7-day free trial), and a one-time lifetime purchase. All three have Family Sharing turned on.
- Tap the "Presenter Remote" (簡報遙控) card on the home screen, or Settings > Upgrade to Presence Pro, to open the purchase screen. It shows the price, period, and auto-renewal terms above the purchase button, with Restore Purchases, Terms of Use (Apple's standard EULA), and Privacy Policy links. Settings also has Restore Purchases and Manage Subscription.
- To try Presenter Remote after purchasing: in Presence on the Mac, turn on "Allow Presenter Remote" under iPhone & Watch (and grant Accessibility, which Presence already uses for unlocking). Open a slideshow in Keynote or a PDF, then tap Presenter Remote in the app. Tapping the big orange button sends the Right Arrow key to the frontmost app on the Mac; the Lock Screen Live Activity and the Apple Watch app have the same next/previous buttons.
- The presenter screen keeps the Mac from auto-locking while you present, and resumes auto-lock when you close it.

Demo video: attached to this review (recorded on a real iPhone paired with a Mac; English captions).

Background mode "Uses Bluetooth LE accessories" is used to keep the connection to the Mac, so the app can receive lock notifications and answer the Mac's encrypted presence confirmation while in the background. It also lets the Lock Screen slide buttons reach the Mac while the iPhone is locked during a presentation.

Encryption: commands between the iPhone and the Mac are encrypted with AES-GCM using Apple's CryptoKit, only to protect communication between the user's own devices.
