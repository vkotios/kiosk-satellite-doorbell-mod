# Doorbell

Kiosk Satellite can open a doorbell app when the doorbell rings. The kiosk wakes the screen, opens the live view of the camera that rang over the dashboard, and brings itself back after a while, all without a touch. The Eufy Security app is one tap away; any other doorbell app is learned from its ring notification.

## Turning It On

The page lives under **Settings, Doorbell**.

| Setting | What it does |
| --- | --- |
| Open the doorbell app on a ring | The master switch, off by default. While it is off, rings are ignored and no notification is read. |
| Return after a ring (seconds) | The time without a touch before the kiosk comes back, 75 by default and at least 10. |
| Doorbells | The saved doorbells. The row opens a dialog that lists them, each with a remove button, next to an **Add Eufy Security** button and a **Capture a doorbell** button. |

**Add Eufy Security** saves the Eufy Security app in one tap. **Capture a doorbell** learns any other app from the ring notification it posts; see [Capturing a Doorbell](#capturing-a-doorbell).

The feature needs **Notification access**, the same grant as the Media Player's [Local Media Session](sendspin.md#local-media-session). A **Required system permissions** section on the page shows the grant while the switch is on. Without the grant a ring is never seen.

## Capturing a Doorbell

With the switch on, **Capture a doorbell** starts a capture. The dialog says **Press your doorbell now.** and waits up to 60 seconds. While it waits, Kiosk Satellite reads notifications from other apps and reports the first new one: the app it came from, its title and its channel. After it catches one, you name the doorbell and **Save**, or **Try again**, or **Cancel**. Closing the dialog ends a capture. Notifications from Kiosk Satellite itself, ongoing ones such as a music player, and group summaries are skipped.

Only what you save is kept: the name you typed, the app's package and the channel prefix the ring arrived on. Nothing else is stored.

## What Happens on a Ring

When an app on the list posts a notification on a matching channel:

1. The kiosk wakes the screen.
2. It opens the notification's own tap action, the live view of the camera that rang. With two doorbells the right one opens, because each ring carries its own tap action.
3. It comes back after the **Return after a ring** time without a touch.

The return works through the App Launcher's return, which needs the **Display over other apps** grant. The App Launcher's own switches are not needed. See [Kiosk Mode](kiosk.md#staying-in-front).

The same ring seen twice within 20 seconds is opened once.

## Home Assistant and Android

A ring also fires the `esphome.kiosk_satellite_doorbell` event on the Home Assistant bus and sends the `DOORBELL_RINGING` Android broadcast, whether the tap action opened or not. The fields are the same on both:

| Field | What it holds |
| --- | --- |
| `event_type` | `ringing`. Home Assistant only: the broadcast action name carries it. |
| `doorbell` | The title of the ring notification. |
| `label` | The name you saved the doorbell under, or the title when it cannot be told. |
| `opened` | True or false: whether the tap action opened. |

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

## Privacy

Kiosk Satellite looks at the app and channel of each notification to see whether it belongs to a saved doorbell. It reads a notification's title only when it does, or while a capture waits. Every other notification is dropped without its content being read, stored or reported. With the switch off no doorbell is matched, so no title is read.

What is kept is what you saved: the name, the app's package and the channel prefix. A ring itself is told to Home Assistant and, through the broadcast, to any app on the device that listens for it, with the ring's title, the saved name and whether it opened.

## If a Ring Does Not Open

- **Notification access** is not granted. Without it a ring is never seen.
- The switch is off. Rings are ignored while it is.
- The ring arrived on a channel the saved doorbell does not match. Capture the doorbell again.
- The ring notification has no tap action, so there is nothing to open.
