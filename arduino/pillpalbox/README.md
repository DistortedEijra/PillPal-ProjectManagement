# PillPalBox: HC-05 setup

Arduino Uno + HC-05 Bluetooth module + 6 slot LEDs (A–F) + 1 "connected" LED. No speaker.
When a dose is due, the PillPal app sends one capital letter (`A`–`F`). The matching LED blinks for 1 minute.

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

## 2. Upload the sketch

1. Open `pillpalbox.ino` in Arduino IDE.
2. Tools → Board → **Arduino Uno**, then Tools → Port → your Uno's COM port.
3. Upload. The HC-05 can stay wired because it uses D2/D3, not 0/1.
4. Serial Monitor (9600 baud) shows `READY PillPalBox v2`. A fast-blinking LED on the HC-05 means it's waiting to pair.

If nothing ever arrives, your HC-05 may be set to 38400 baud. Change `hc05.begin(9600)` to `hc05.begin(38400)`.

## 3. Pair the phone

1. Phone **Settings → Bluetooth** → tap **HC-05**.
2. Enter PIN **1234**. If it's refused, try **0000**.

## 4. Connect in PillPal

1. In PillPal, tap the **PillPalBox button** (bottom left), then tap **⋯**.
2. If asked, allow **Nearby devices**.
3. Tap **Scan for Devices**, then tap **HC-05**. The **D7 LED turns on** (connected).
4. Under **Assign Medicine**, type each medicine name **exactly as it appears in your schedule**, in its slot (A, B, …). Then tap **Save**.

## 5. Test

Add a schedule 1–2 minutes from now. Keep PillPal open, or tap the reminder when it pops up. The slot's LED blinks for 1 minute, and the box replies `ACK BLINK A`.

Other commands, for testing from a Bluetooth terminal app: `a`–`f` turns a slot on steady, `0` turns all off, `!` stops blinking, and `?` returns the status.

## Troubleshooting

- **HC-05 isn't in the list:** pair it in the phone's Bluetooth settings first, then scan again.
- **D7 LED never turns on:** check STATE → D4 and the 10kΩ pull-down. Some HC-05 boards leave the STATE pin unconnected; on those, the sketch never sees a connection.
- **Connected, but the slot LED doesn't light:** check that TXD → D2 and RXD ← D3 aren't swapped. Also check the baud rate (9600 vs 38400).
- **Wrong LED, or no LED for a medicine:** the slot name has to match the schedule name.
- **LED only lights with the app open:** this is expected. When the app is closed, tap the reminder notification to send the signal.
