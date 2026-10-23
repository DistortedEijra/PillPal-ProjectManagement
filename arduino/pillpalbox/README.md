# PillPalBox: HC-05 setup

Arduino Uno + HC-05 Bluetooth module + 6 LEDs (slots A–F). No speaker.
The PillPal app sends one capital letter (`A`–`F`) when a dose is due; the matching LED blinks for 2 minutes.

## 1. Wiring

| HC-05 pin | Arduino Uno |
|---|---|
| VCC | 5V |
| GND | GND |
| TXD | pin 10 |
| RXD | pin 11 **through a voltage divider**: pin 11 → 1kΩ → HC-05 RXD, and HC-05 RXD → 2kΩ → GND |
| STATE, EN | not connected |

The HC-05 RXD pin works at 3.3V, so don't connect it straight to pin 11. The divider protects it.

| LED (long leg +) | Arduino pin | Resistor |
|---|---|---|
| Slot A | 2 | 220Ω to GND |
| Slot B | 3 | 220Ω to GND |
| Slot C | 4 | 220Ω to GND |
| Slot D | 5 | 220Ω to GND |
| Slot E | 6 | 220Ω to GND |
| Slot F | 7 | 220Ω to GND |

## 2. Upload the sketch

1. Open `pillpalbox.ino` in Arduino IDE.
2. Tools → Board → **Arduino Uno**, Tools → Port → your Uno's COM port.
3. Upload. The HC-05 can stay connected (it uses pins 10/11, not 0/1).
4. On power-up every LED flashes once (self-test). The HC-05 LED blinks fast = waiting to pair.

Test without the phone: Tools → Serial Monitor, 9600 baud, type `A` and press Send. LED A should blink.

## 3. Pair the phone

1. Phone **Settings → Bluetooth** → turn on → tap **HC-05**.
2. PIN: **1234** (if refused, try **0000**).

## 4. Connect in PillPal

1. Open PillPal → tap the **PillPalBox button** (bottom left) → **⋯** next to the box name.
2. Allow **Nearby devices** / Bluetooth permission if asked.
3. Tap **Scan for Devices** → tap **HC-05**. The box should show as connected. The HC-05 LED changes to a slow double-blink.
4. In **Assign Medicine**, type each medicine **exactly as it's named in your schedule** in its slot (A, B, …) → **Save**.

## 5. Test

Add a schedule for that medicine 1–2 minutes from now and keep PillPal open (or tap the reminder when it pops up). The matching LED blinks.

## Troubleshooting

- **HC-05 not in the list:** pair it first in phone Bluetooth settings, then scan again. Make sure the HC-05 LED is blinking (powered).
- **Connects but no LED:** check TXD → pin 10, RXD ← pin 11 (not swapped); test with Serial Monitor; check the LED's long leg goes to the pin.
- **Wrong LED / no LED for a medicine:** the slot name must match the schedule name.
- **Light only when the app is open:** expected; when the app is closed, tap the reminder notification to send the signal.
