# PillPalBox: HC-05 setup

Arduino Uno + HC-05 Bluetooth module + 6 slot LEDs (A–F) + 1 "connected" LED. No speaker.
Optional: DS3231 clock module (recommended, see below).

**Sketch v3: the box remembers the reminders.** Each time PillPal connects (and whenever you change a schedule or a slot), the app sends the box the current time and the list of reminders. The box saves the list (it survives power-off) and blinks the slot by itself at the right time for 5 minutes, **even if the phone is not connected**. When the phone is connected, the app also sends `A`–`F` at the due time like before (1-minute blink).

## 1. Wiring

| HC-05 pin | Arduino Uno |
|---|---|
| VCC | 5V |
| GND | GND |
| TXD | D2 |
| RXD | D3 **through a voltage divider**: D3 → 1kΩ → HC-05 RXD, and HC-05 RXD → 2kΩ → GND |
| STATE | D4, plus a **10kΩ resistor from D4 to GND** |
| EN | not connected |

The HC-05 RXD pin runs at 3.3V, so the divider protects it.
**STATE is required:** the sketch ignores letters until STATE goes HIGH (phone connected). Without the 10kΩ pull-down, the pin floats and connection detection gets flaky.

| LED (long leg +) | Arduino pin | Resistor |
|---|---|---|
| Slot A | D13 | 220Ω to GND |
| Slot B | D12 | 220Ω to GND |
| Slot C | D11 | 220Ω to GND |
| Slot D | D10 | 220Ω to GND |
| Slot E | D9 | 220Ω to GND |
| Slot F | D8 | 220Ω to GND |
| Connected | D7 | 220Ω to GND |

### Optional: DS3231 clock module (recommended)

Without it, the box keeps time with the Arduino's own timer. That timer **drifts a few minutes a day** and **forgets the time when the power is cut** (for example when the power bank switches off). The saved reminders stay, but they wait until the phone connects once to set the time again.

A DS3231 module (with its coin battery) keeps the exact time, even unplugged.

| DS3231 | Arduino Uno |
|---|---|
| VCC | 5V |
| GND | GND |
| SDA | A4 |
| SCL | A5 |

The DS3231 Mini works too: **+** → 5V, **D** → A4, **C** → A5, **–** → GND (NC not connected).

The sketch uses the DS3231 by default (`#define USE_DS3231 1`), so install the library once: Arduino IDE → **Sketch → Include Library → Manage Libraries →** search **RTClib** (by Adafruit) → Install (accept its dependencies). If the module isn't connected, the box falls back to its own timer. (Set it to `0` only if you don't want to install RTClib.)

## 2. Upload the sketch

1. Open `pillpalbox.ino` in Arduino IDE.
2. Tools → Board → **Arduino Uno**, then Tools → Port → your Uno's COM port.
3. Upload. The HC-05 can stay wired because it uses D2/D3, not 0/1.
4. Serial Monitor (9600 baud) shows `READY PillPalBox v3.1, N reminders saved`. A fast-blinking LED on the HC-05 means it's waiting to pair.

If nothing ever arrives, your HC-05 may be set to 38400 baud. Change `hc05.begin(9600)` to `hc05.begin(38400)`.

### Test the saved reminders without the phone

Serial Monitor (9600 baud, "Newline" line ending), type these one by one:

```
#T,2026,10,25,20,40,0
#C
#S,A,127,20,41
#E
#Q
```

That sets the clock to 8:40 PM, saves one reminder (slot A, every day, 8:41 PM) and prints it. About a minute later LED A blinks and the monitor shows `REMINDER A`. (`127` = every day; Mon=1, Tue=2, Wed=4, Thu=8, Fri=16, Sat=32, Sun=64, add them up.) Type `?` any time to see the clock and how many reminders are saved.

## 3. Pair the phone

1. Phone **Settings → Bluetooth** → tap **HC-05**.
2. Enter PIN **1234**. If it's refused, try **0000**.

## 4. Connect in PillPal

1. In PillPal, tap the **PillPalBox button** (bottom left), then tap **⋯**.
2. If asked, allow **Nearby devices**.
3. Tap **Scan for Devices**, then tap **HC-05**. The **D7 LED turns on** (connected).
4. Under **Assign Medicine**, pick each slot's medicine from the dropdown (it lists the medicines in your schedules). Then tap **Save**.

## 5. Test

Add a schedule 1–2 minutes from now. Keep PillPal open, or tap the reminder when it pops up. The slot's LED blinks for 1 minute, and the box replies `ACK BLINK A`.

**v3.1: over Bluetooth the box only accepts whole lines that start with `#`.** The app blinks a slot with `#B,A` (not a bare `A` like before), so the app and the sketch must both be the latest version. Loose letters are ignored, so a byte lost while the app sends the list can't light a slot any more.

Bluetooth commands: `#B,A`…`#B,F` blink a slot, `#0` all LEDs off, `#!` stop blinking, `#?` status. In the USB Serial Monitor the single characters still work for testing: `A`–`F` blink, `a`–`f` steady on, `0`, `!`, `?`.

## Troubleshooting

- **HC-05 isn't in the list:** pair it in the phone's Bluetooth settings first, then scan again.
- **D7 LED never turns on:** check STATE → D4 and the 10kΩ pull-down. Some HC-05 boards leave the STATE pin unconnected; on those, the sketch never sees a connection.
- **Connected, but the slot LED doesn't light:** check that TXD → D2 and RXD ← D3 aren't swapped. Also check the baud rate (9600 vs 38400).
- **Wrong LED, or no LED for a medicine:** check which slot that medicine is assigned to in Assign Medicine.
- **Box doesn't light by itself:** open PillPal once near the box so it connects (that sends the time and the list). Type `?` in the Serial Monitor: it should show `CLOCK ...` (not "not set") and `SCHED` more than 0. After a power cut without a DS3231, the clock needs the phone again.
- **Box lights a few minutes early/late:** the Arduino timer drifts; connect the phone to re-sync, or add a DS3231.
- **Only medicines with a slot** are saved in the box (max 40 reminder times).
- **A slot lights up when you only changed the slots or a schedule:** update to sketch v3.1 and the latest app. Older versions could turn a letter from the reminder list (for example the `B` in `#S,B,...`) into a blink, and re-blinked a slot whose dose was due that same minute every time the app re-sent the list.
- **A slot LED stays on and won't stop:** send `#0` (or unplug the box for a second; the steady state isn't saved).
- **The app's blink does nothing but the box answers `ERR ?`:** the sketch is older than the app. Upload `pillpalbox.ino` v3.1.
