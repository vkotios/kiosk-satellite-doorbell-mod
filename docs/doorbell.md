# Doorbell

Kiosk Satellite can open a doorbell app when the doorbell rings. The kiosk wakes the screen, opens the live view of the camera that rang over the dashboard, and brings itself back after a while, all without a touch.

A doorbell rings in two ways: its app posts a ring notification, which needs **Notification access**, or a Home Assistant sensor turns on, a binary_sensor that is on while the doorbell rings. It opens in two ways: by tapping the notification, or by tapping the camera's card in the doorbell app, which needs **Doorbell click access**, an Android Accessibility service. A notification doorbell whose tap fails falls back to the card when it has one taught.

The Eufy Security app is one tap away; any other doorbell app is learned from its ring notification, or taught its camera card.

## Turning It On

The page lives under **Settings, Doorbell**.

| Setting | What it does |
| --- | --- |
| Open the doorbell app on a ring | The master switch, off by default. While it is off, rings are ignored and no notification title is read. |
| Return after a ring (seconds) | The time without a touch before the kiosk comes back, 75 by default and at least 10. |
| Wait before tapping (seconds) | How long the kiosk waits after the doorbell app opens before it taps the camera card, 8 by default and at least 0. A slow tablet or a slow app needs longer. |
| Doorbells | The saved doorbells. The row opens a dialog that lists them, each with a test button when it has a card taught and a remove button, next to an **Add Eufy Security** button, an **Add a camera doorbell** button and a **Capture a doorbell** button. |

**Add Eufy Security** saves the Eufy Security app in one tap. **Capture a doorbell** learns any other app from the ring notification it posts; see [Capturing a Doorbell](#capturing-a-doorbell).

A doorbell that rings by its app's notification needs **Notification access**, the same grant as the Media Player's [Local Media Session](sendspin.md#local-media-session); without the grant a notification ring is never seen. A doorbell that opens by its camera card needs **Doorbell click access**, an Android Accessibility service; without it the card is never tapped. A **Required system permissions** section on the page shows both grants while the switch is on. See [Permissions](permissions.md).

## Capturing a Doorbell

With the switch on, **Capture a doorbell** starts a capture. The dialog says **Press your doorbell now.** and waits up to 60 seconds. While it waits, Kiosk Satellite reads notifications from other apps and reports the first new one: the app it came from, its title and its channel. After it catches one, you name the doorbell and **Save**, or **Try again**, or **Cancel**. Closing the dialog ends a capture. Notifications from Kiosk Satellite itself, ongoing ones such as a music player, and group summaries are skipped.

Only what you save is kept: the name you typed, the app's package and the channel prefix the ring arrived on. Nothing else is stored.

## Adding a Camera Doorbell

With the switch on, **Add a camera doorbell**, in the doorbells dialog, starts a wizard on the tablet that saves a doorbell its Home Assistant sensor rings and the kiosk opens by its card. Five steps:

1. Which app the doorbell is in: tap **Eufy Security**, or type the app's Android package.
2. Turn on **Doorbell click access**: the wizard checks whether the service runs, and its **Open Accessibility settings** button takes you to Android's Accessibility settings, where you find Kiosk Satellite and turn it on. Come back and check again.
3. Teach the camera: tap **Open the app and wait**, then tap the camera of this doorbell in the app. The wizard waits up to 90 seconds, shows the label of the card you tapped and lets you correct it.
4. Name the doorbell and pick its ringing sensor, a binary_sensor that is on while the doorbell rings.
5. Read the summary, **Save**, then **Test open** to open the doorbell the way a ring will.

Each doorbell has its own sensor and its own card. The remote admin can edit, test and remove a doorbell and add one by hand, but only the tablet can teach a card.

## What Happens on a Ring

When a doorbell rings, by a notification on a matching channel or by its sensor turning on:

1. The kiosk wakes the screen.
2. It opens the camera that rang. A notification ring opens the notification's own tap action, the live view of the camera that rang; with two doorbells the right one opens, because each ring carries its own tap action. A sensor ring opens the doorbell by its card, and so does a notification ring saved to open by click.
3. It comes back after the **Return after a ring** time without a touch.

The return works through the App Launcher's return, which needs the **Display over other apps** grant. The App Launcher's own switches are not needed. See [Kiosk Mode](kiosk.md#staying-in-front).

The same ring seen twice within 20 seconds is opened once.

A ring that arrives before Kiosk Satellite has started is dropped, and nothing is logged for it. While Lockdown Mode holds, a ring opens nothing: Home Assistant still gets the event, with opened set to false.

## Timing of a Ring

A ring that opens by the card runs on a clock:

1. The kiosk wakes the screen and opens the doorbell app fresh, at its home screen.
2. It waits the **Wait before tapping** time for the app to load.
3. It looks for the card for 15 seconds and taps it once found.
4. It comes back after the **Return after a ring** time, never sooner than the wait plus 25 seconds, so it never returns while the search is still running.

A doorbell a sensor rings ignores a second ring within a window after it opened: never shorter than 20 seconds, and the wait plus 20 seconds when that is longer. The doorbell app's own notification counts as a ring too, so one that follows its sensor's ring is ignored. A ring that arrives while you are teaching a camera is ignored.

## Home Assistant and Android

A ring also fires the `esphome.kiosk_satellite_doorbell` event on the Home Assistant bus and sends the `DOORBELL_RINGING` Android broadcast, whether the camera opened or not. A ring that opens by the card and cannot tap it follows up with `click_failed`, as the `DOORBELL_CLICK_FAILED` broadcast. The Home Assistant event goes out over the ESPHome connection, so turn on Settings > ESPHome first, as for the other [Home Assistant Events](events.md). The fields are the same on both:

| Field | What it holds |
| --- | --- |
| `event_type` | `ringing`, or `click_failed` when a card was not tapped. Home Assistant only: the broadcast action name carries it. |
| `doorbell` | On `ringing`, the title of the ring notification, or the name you saved the doorbell under when a sensor rang it. On `click_failed`, the name you saved the doorbell under, or the card's label when it cannot be told. |
| `label` | The name you saved the doorbell under, or the title when it cannot be told. On `click_failed`, the card's label the kiosk looked for. |
| `opened` | True or false: whether the ring opened. `ringing` only. |
| `trigger` | What rang: `notification` or `entity`. `ringing` only. |
| `open` | How the ring opens: `tap` or `click`. `ringing` only. |
| `reason` | Why the card was not tapped: `not_found`, `wrong_app` or `service_off`. `click_failed` only. |

`ringing` goes out when the open has started. `click_failed` follows a `ringing` only when the card was not tapped.

The broadcast's full name is `me.jxl.kiosk_satellite.event.DOORBELL_RINGING`. See [Android Broadcasts](android-broadcasts.md#doorbell) for receiving it and [Home Assistant Events](events.md#doorbell) for the event.

```yaml
# Turn the porch light on when the doorbell rings.
triggers:
  - trigger: event
    event_type: esphome.kiosk_satellite_doorbell
    event_data:
      event_type: ringing
actions:
  - action: light.turn_on
    target:
      entity_id: light.porch
```

## Remote Admin

The Doorbell tab of the Remote Admin UI turns the feature on, sets the return time and the wait, and lists, tests, edits and removes saved doorbells. It adds the Eufy Security preset in one tap and adds a camera doorbell by hand, with the name, the sensor, the card and how it opens. Teaching a card needs the kiosk's own screen, and the Remote Admin UI and the API refuse to start it, as they refuse a capture.

## Privacy

Kiosk Satellite looks at the app and channel of each notification to see whether it belongs to a saved doorbell. It reads a notification's title only when it does, or while a capture waits. Every other notification is dropped without its content being read, stored or reported. With the switch off no doorbell is matched, so no title is read.

The Doorbell click service listens only to the saved doorbell apps. It reads the app's screen only while it looks for the card, and only while you teach one. It never reads, stores or sends anything but the card's label that you saved, and it does nothing in other apps. The click service acts only in the apps of saved doorbells and only on the card label saved with each; the remote API cannot start a teach or call openAppAndClick directly, but whoever holds the remote admin token can save a doorbell, so keep that token as private as the kiosk's other admin rights.

What is kept is what you saved: the name, the app's package, the channel prefix, the ringing sensor and the card's label. A ring itself is told to Home Assistant and, through the broadcast, to any app on the device that listens for it, with the ring's title, the saved name, whether it opened, what rang it and how it opens.

## If a Ring Does Not Open

- **Notification access** is not granted. Without it a notification ring is never seen.
- The switch is off. Rings are ignored while it is.
- The ring arrived on a channel the saved doorbell does not match. Capture the doorbell again.
- The ring notification has no tap action, so there is nothing to open.
- **Doorbell click access** is off. The doorbell app opens but no card is tapped, and the ring reports `click_failed` with reason `service_off`.
- The card's label was not found: the app opened, but the card was not on the screen in time, for instance when the doorbell app is signed out. The ring reports `click_failed` with reason `not_found`.
- A different screen was showing: the doorbell app never came to the front during the search. The ring reports `click_failed` with reason `wrong_app`.
- The screen stayed off, so the camera opens on a dark panel.
- **Display over other apps** is not granted, so the kiosk cannot come back after the ring.
- The kiosk was behind another app: the return only comes when the kiosk itself was in front when the ring opened the doorbell app.

A sensor ring has two more gaps. A ring that happens while Home Assistant is disconnected, or while the kiosk reconnects to it, is not seen, and a sensor that is already on when the kiosk connects does not ring: only the sensor turning on rings.
