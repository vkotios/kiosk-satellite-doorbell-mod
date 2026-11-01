# Home Assistant Events

Kiosk Satellite fires an event on the Home Assistant bus whenever a voice turn, a timer, an intercom call, an alarm, a doorbell, the screensaver or the screen changes. Automations can trigger on them with an event trigger. They go out over the ESPHome connection, so turn on **Settings > ESPHome** and add the kiosk to Home Assistant first. **Expose kiosk entities** is not needed.

Home Assistant only fires device events under `esphome.`, hence the prefix. Every event carries `event_type` with what happened. Home Assistant adds `device_id`, the kiosk's ESPHome device. Use `device_id` to react to one kiosk only. You can find it in the URL of the kiosk's device page.

| Event | What it follows |
| --- | --- |
| [`esphome.kiosk_satellite_voice`](#voice-satellite) | Voice Satellite interactions |
| [`esphome.kiosk_satellite_timer`](#timers) | Voice Satellite timers |
| [`esphome.kiosk_satellite_intercom`](#intercom) | Intercom calls and announcements |
| [`esphome.kiosk_satellite_alarm`](#alarms) | Alarms |
| [`esphome.kiosk_satellite_doorbell`](#doorbell) | A doorbell ring |
| [`esphome.kiosk_satellite_screensaver`](#screensaver) | The screensaver |
| [`esphome.kiosk_satellite_screen`](#screen) | The screen turning on and off |

To watch them arrive, open **Developer tools > Events** in Home Assistant and listen for one of the names above.

Apps on the kiosk itself, like Tasker or MacroDroid, get the same changes as [Android Broadcasts](android-broadcasts.md).

## Voice Satellite

```yaml
event_type: esphome.kiosk_satellite_voice
data:
  device_id: 5f1c...
  event_type: started
  reason: voice
```

| `event_type` | When |
| --- | --- |
| `started` | A voice interaction begins: a turn, an announcement, a `vs_show` prompt, a realtime conversation or a ringing timer. `reason` says which: `voice`, `announcement`, `show`, `conversation` or `timer`. |
| `listening` | The microphone opens for a command. |
| `thinking` | The command is in and the assistant is working on it. |
| `speaking` | The answer starts playing. |
| `announcement` | An announcement starts playing. |
| `ended` | The interaction is over. Audio focus is released and the overlay is gone. |

`ended` fires once per interaction. A follow-up question, an announcement that asks for a reply and a new wake word while the answer is still on screen all stay inside the same interaction. When **Keep the answer on screen** or **Keep results on screen** leaves the answer up, `ended` waits for it to go.

These come from the built-in Voice Satellite. The Voice Satellite integration running in a dashboard does not send them.

```yaml
# Lower the living room speaker while the kitchen kiosk listens.
triggers:
  - trigger: event
    event_type: esphome.kiosk_satellite_voice
    event_data:
      event_type: started
      device_id: 5f1c...
actions:
  - action: media_player.volume_set
    target:
      entity_id: media_player.living_room
    data:
      volume_level: 0.1
```

## Timers

`esphome.kiosk_satellite_timer` fires when a timer starts, changes, is cancelled, finishes or its alert is dismissed. It carries `timer_id`, `name`, `total_seconds`, `seconds_left` and `is_active`. See [Timer events](voice-satellite.md#timer-events) for the fields and an example.

## Intercom

```yaml
event_type: esphome.kiosk_satellite_intercom
data:
  device_id: 5f1c...
  event_type: ringing
  kiosk: Kitchen
```

| `event_type` | When |
| --- | --- |
| `calling` | This kiosk is calling another one. |
| `ringing` | Another kiosk is calling this one. |
| `in_call` | The call connected. |
| `broadcasting` | This kiosk is announcing to all kiosks. |
| `listening` | Another kiosk's announcement is playing here. |
| `missed` | A call rang out with no answer. |
| `ended` | The call, announcement or ring is over. |

`kiosk` is the other kiosk's name, empty when there is none. `ended` fires once at the end of each call, announcement or ring, missed calls included.

## Alarms

`esphome.kiosk_satellite_alarm` fires once per alarm whenever it is created, changed, deleted, starts its sunrise, rings, is snoozed, stopped or silenced. It carries `alarm_id`, `label`, `time`, `days` and `enabled`. See [Alarm events](alarms.md#alarm-events) for the fields and an example.

## Doorbell

```yaml
event_type: esphome.kiosk_satellite_doorbell
data:
  device_id: 5f1c...
  event_type: ringing
  doorbell: Front door
  label: Front door
  opened: true
```

| `event_type` | When |
| --- | --- |
| `ringing` | A saved doorbell app rang. |

`doorbell` is the title of the ring notification, `label` the name you saved the doorbell under (the title when it cannot be told), and `opened` whether the kiosk opened the ring. See [Doorbell](doorbell.md) for the feature.

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

## Screensaver

```yaml
event_type: esphome.kiosk_satellite_screensaver
data:
  device_id: 5f1c...
  event_type: started
```

| `event_type` | When |
| --- | --- |
| `started` | The screensaver started. |
| `stopped` | The screensaver ended. |

## Screen

```yaml
event_type: esphome.kiosk_satellite_screen
data:
  device_id: 5f1c...
  event_type: "off"
  source: system
```

| `event_type` | When |
| --- | --- |
| `on` | The screen turned on. |
| `off` | The screen turned off. |

`source` says who moved it:

- `app`: Kiosk Satellite did. That covers the screensaver turning the screen off, a wake on motion, a face or the wake word and the **Screen** light in Home Assistant.
- `system`: Android did, for example the power button, double tap to wake or the display timeout. Android does not say which. With **Keep screen on** turned on the display timeout never fires, so `system` turning the screen off is almost always the power button.

Quote `"on"` and `"off"` in YAML. Unquoted, Home Assistant reads them as true and false and the trigger never matches.

```yaml
# Keep the kitchen kiosk dark after a power button press: stop motion and
# face detection from waking it until the power button turns it back on.
triggers:
  - trigger: event
    id: "off"
    event_type: esphome.kiosk_satellite_screen
    event_data:
      device_id: 5f1c...
      event_type: "off"
      source: system
  - trigger: event
    id: "on"
    event_type: esphome.kiosk_satellite_screen
    event_data:
      device_id: 5f1c...
      event_type: "on"
      source: system
actions:
  - choose:
      - conditions:
          - condition: trigger
            id: "off"
        sequence:
          - action: switch.turn_off
            target:
              entity_id:
                - switch.kitchen_tablet_screensaver_motion_detection
                - switch.kitchen_tablet_screensaver_face_detection
    default:
      - action: switch.turn_on
        target:
          entity_id:
            - switch.kitchen_tablet_screensaver_motion_detection
            - switch.kitchen_tablet_screensaver_face_detection
```

If you turn the screen back on any other way, such as with the **Screen** light, detection stays off until the next power button press.
