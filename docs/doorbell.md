# Doorbell

Kiosk Satellite can open a doorbell app over the dashboard when the doorbell rings: it wakes the screen, opens the camera that rang, and brings itself back after a while, all without a touch. You switch this on in two independent ways, each with its own switch: by the doorbell app's ring notification, or by a Home Assistant sensor with a tap on the camera's card. You can use either or both, for different doorbells.

## The Doorbell Page

The page lives under **Settings > Doorbell** on the tablet, and the admin panel's Doorbell tab has the same structure. It holds two sections, each with its own switch, its own grant, its own settings and its own list of doorbells. A doorbell belongs to exactly one section, and both sections can be on at once, for doorbells with different characteristics. While a section's switch is off, that section's rings are ignored and nothing else of the section is shown.

| | Doorbell video launch by notifications | Doorbell video launch by Home Assistant sensor & tap |
| --- | --- | --- |
| How it rings | The doorbell app posts its ring notification | A Home Assistant binary_sensor turns on while the doorbell rings |
| How it opens | The kiosk taps the ring notification, which opens the camera's live view | The kiosk opens the doorbell app and taps the camera's card |
| What it needs | The **Notification access** grant | The **Doorbell click access** grant, an Android Accessibility service |
| How you add a doorbell | **Eufy Security** in one tap, or learn any app from a real ring | A five-step wizard that teaches the card by tapping it |

## Notification Doorbells

The section's switch is **Doorbell video launch by notifications**, off by default. While it is off, no notification title is read and no ring is answered.

A notification doorbell needs **Notification access**, the same grant as the Media Player's [Local Media Session](sendspin.md#local-media-session); without it a ring is never seen. The section shows the grant while it is on. See [Permissions](permissions.md).

**Return after a ring (seconds)** is the time without a touch before the kiosk comes back, 75 by default and at least 10.

**Add doorbell** offers two ways to save one:

- **Eufy Security** saves the Eufy Security app in one tap.
- **Learn from a ring** learns any other app. Press your doorbell and the kiosk waits up to 60 seconds for its notification, then you name the doorbell and **Save**, or **Try again**, or **Cancel**. Notifications from Kiosk Satellite itself, ongoing ones such as a music player, and group summaries are skipped.

On a ring, the kiosk wakes the screen and taps the ring notification, whose own tap action opens the camera that rang: with two doorbells the right one opens, because each ring carries its own tap action. The kiosk comes back after the **Return after a ring (seconds)** time. The return works through the App Launcher's return, which needs the **Display over other apps** grant; the App Launcher's own switches are not needed. See [Kiosk Mode](kiosk.md#staying-in-front). While Lockdown Mode holds, a ring opens nothing: Home Assistant still gets the event, with `opened` set to false.

The ring fires the `esphome.kiosk_satellite_doorbell` event with `trigger` set to `notification`, `open` set to `tap`, `doorbell` the ring notification's title and `label` the name you saved the doorbell under. See [Home Assistant and Android](#home-assistant-and-android) for all the fields.

## Sensor & Tap Doorbells

The section's switch is **Doorbell video launch by Home Assistant sensor & tap**, off by default. While it is off, no sensor is watched and no card is tapped.

A sensor & tap doorbell needs **Doorbell click access**, an Android Accessibility service. The section's **Doorbell click access** row says whether the service runs, and its **Open** button opens Android's Accessibility settings, where you find Kiosk Satellite and turn it on. See [Permissions](permissions.md).

**Wait before tapping (seconds)** is how long the kiosk waits after the doorbell app opens before it taps the camera card, 8 by default and at least 0; a slow tablet or a slow app needs longer. **Return after a ring (seconds)** is the time without a touch before the kiosk comes back, 75 by default and at least 10.

**Add doorbell** starts a five-step wizard on the tablet:

1. **Choose the doorbell app**: tap **Eufy Security**, or type the app's Android package.
2. **Allow Kiosk Satellite to tap**: turn on Doorbell click access; the step shows whether the service runs and its button opens Android's Accessibility settings.
3. **Show me the camera**: the wizard opens the doorbell app, you tap the camera of this doorbell in the app, and the wizard comes back with the card's name, which you can correct or teach again.
4. **Name it and choose its sensor**: give the doorbell its name and pick the Home Assistant binary_sensor that is on while it rings.
5. **Save and test**: the wizard saves the doorbell and runs the Test open, which takes up to a minute and ends with the doorbell ready or the reason it is not.

When the sensor turns on, the kiosk wakes the screen and opens the doorbell app fresh, at its home screen. It waits the **Wait before tapping (seconds)** time for the app to load, then looks for the card for 15 seconds and taps it once found. It comes back after the **Return after a ring (seconds)** time, never sooner than the wait plus 25 seconds, so it never returns while the search is still running.

A second ring of the same doorbell within a window after it opened is ignored: never shorter than 20 seconds, and the wait plus 20 seconds when that is longer. Rings are also ignored while you teach a camera. While Lockdown Mode holds, a ring opens nothing: Home Assistant still gets the event, with `opened` set to false.

A sensor that is already on when the kiosk connects does not ring: only the sensor turning on rings. A ring that happens while Home Assistant is disconnected, or while the kiosk reconnects to it, is not seen.

## Status and Testing

Each doorbell's row shows a status line, the same text on the tablet and in the admin panel. A notification doorbell starts at `Waiting for the first ring.`, then says `Working. Last ring opened 12:10.` or `Last ring at 12:10 did not open.` A sensor & tap doorbell starts at `Not tested yet. Press Test.`, then says `Ready. Last tested OK 12:10.` or `Ready. Last ring opened 12:10.` when its last test or ring worked, and `Not working: could not find the card "Front Door". 12:10.` when it did not. A doorbell is ready when its last test or ring worked.

**Test**, on a sensor & tap doorbell's row, runs the whole open the way a ring will: it wakes the screen, opens the app fresh, waits and taps the card, and waits up to about a minute for the answer, longer if the **Wait before tapping (seconds)** setting is raised. A notification doorbell has no Test; only a real ring tells whether it works. When the card is not found, Test lists the names of the cards it could see in the doorbell app, so you can pick the right one: tapping a name saves it as the doorbell's card and tests again.

## What You Can Do Where

| Tablet only | Tablet and admin panel |
| --- | --- |
| Grant Notification access | Turn either section on or off, set the return and wait times |
| Grant Doorbell click access | Add the Eufy Security preset in one tap |
| Learn a notification doorbell from a real ring | Test a sensor & tap doorbell |
| Teach a camera card by tapping it | Edit a doorbell's name and ringing sensor |
| | Remove a doorbell |
| | See each doorbell's status |

The admin panel's grant buttons open the grant screens on the tablet and show their status. Its sensor & tap section has no add form: it tells you adding needs the tablet, because the card is taught by tapping it. Its notification section says the same about learning another doorbell from a real ring.

## Home Assistant and Android

A ring also fires the `esphome.kiosk_satellite_doorbell` event on the Home Assistant bus and sends the `DOORBELL_RINGING` Android broadcast, whether the camera opened or not. A ring that opens by the card and cannot tap it follows up with `click_failed`, as the `DOORBELL_CLICK_FAILED` broadcast. The Home Assistant event goes out over the ESPHome connection, so turn on **Settings > ESPHome** first, as for the other [Home Assistant Events](events.md). The fields are the same on both:

| Field | What it holds |
| --- | --- |
| `event_type` | `ringing`, or `click_failed` when a card was not tapped. Home Assistant only: the broadcast action name carries it. |
| `doorbell` | On `ringing`, the title of the ring notification, or the name you saved the doorbell under when a sensor rang it. On `click_failed`, the name you saved the doorbell under, or the card's label when it cannot be told. |
| `label` | The name you saved the doorbell under, or the title when it cannot be told. On `click_failed`, the card's label the kiosk looked for. |
| `opened` | True or false: whether the ring opened. `ringing` only. |
| `trigger` | What rang: `notification` or `entity`. `ringing` only. |
| `open` | How the ring opens: `tap` or `click`. A notification doorbell always opens by the tap, a sensor & tap doorbell always by the click. `ringing` only. |
| `reason` | Why the card was not tapped: `not_found`, `wrong_app` or `service_off`. `click_failed` only. |

`ringing` goes out when the open has started. `click_failed` follows a `ringing` only when the card was not tapped. A Test sends no event: only a real ring does.

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

Kiosk Satellite looks at the app and channel of each notification to see whether it belongs to a saved doorbell of the notifications section. It reads a notification's title only when it does, or while a capture waits. Every other notification is dropped without its content being read, stored or reported. With the section's switch off no doorbell is matched, so no title is read.

The Doorbell click service listens only to the apps of the sensor & tap doorbells you saved. It reads the app's screen only while it looks for the card, and only while you teach a camera. It stores and sends nothing but the card name you saved, and it does nothing in other apps. During a Test you started, when the card is not found the kiosk shows you up to 12 card names it could see in the doorbell app, so you can pick the right one: they are shown on the screen, never stored or logged. Only the tablet can start teaching, and the remote API cannot call openAppAndClick directly, but whoever holds the remote admin token can save a doorbell, so keep that token as private as the kiosk's other admin rights.

What is kept is what you saved: the name and the app's package, plus the channel prefix of a notification doorbell, or the ringing sensor and the card's label of a sensor & tap doorbell. A ring itself is told to Home Assistant and, through the broadcast, to any app on the device that listens for it, with the ring's title, the saved name, whether it opened, what rang it and how it opens.

## If a Ring Does Not Open

A notification ring does not open when:

- **Notification access** is not granted. Without it a ring is never seen.
- The section's switch is off. Rings are ignored while it is.
- The ring arrived on a channel the saved doorbell does not match. Learn the doorbell from a ring again.
- The ring notification has no tap action, so there is nothing to open.
- The kiosk was behind another app: the return only comes when the kiosk itself was in front when the ring opened the doorbell app.

A sensor ring does not open when:

- **Doorbell click access** is off. The doorbell app opens but no card is tapped, and the ring reports `click_failed` with reason `service_off`.
- The card's label was not found: the app opened, but the card was not on the screen in time, for instance when the doorbell app is signed out. The ring reports `click_failed` with reason `not_found`, and the doorbell's status line says so.
- A different screen was showing: the doorbell app never came to the front during the search. The ring reports `click_failed` with reason `wrong_app`.
- The screen stayed off, so the camera opens on a dark panel.
- **Display over other apps** is not granted, so the kiosk cannot come back after the ring.
- The sensor gaps: a ring while Home Assistant is disconnected is not seen, and a sensor that is already on when the kiosk connects does not ring.
