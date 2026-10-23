/*
  PillPalBox - Arduino Uno + HC-05 + 6 LEDs (slots A-F). No speaker.

  The PillPal app sends ONE capital letter over Bluetooth when a dose is due:
    'A' = slot A, 'B' = slot B ... 'F' = slot F
  The matching LED blinks for 2 minutes so the user knows which compartment
  to open. A new letter switches to that slot (several can blink at once).

  Wiring (see README in this folder):
    HC-05 VCC -> 5V       HC-05 GND -> GND
    HC-05 TXD -> pin 10   (Arduino receives)
    HC-05 RXD <- pin 11   through a voltage divider (1k + 2k) -> 3.3V level
    LED A..F  -> pins 2..7, each with a 220 ohm resistor to GND

  HC-05 defaults: name "HC-05", PIN 1234 (sometimes 0000), 9600 baud.
*/

#include <SoftwareSerial.h>

SoftwareSerial bt(10, 11);  // RX, TX  (pins 0/1 stay free for USB upload)

const int NUM_SLOTS = 6;
const int ledPins[NUM_SLOTS] = {2, 3, 4, 5, 6, 7};  // A B C D E F

const unsigned long BLINK_FOR_MS = 120000UL;  // keep blinking 2 minutes
const unsigned long BLINK_STEP_MS = 400UL;    // on/off speed

unsigned long activeUntil[NUM_SLOTS];  // 0 = slot not active

void setup() {
  Serial.begin(9600);  // USB serial monitor, for testing
  bt.begin(9600);      // HC-05 default data-mode speed
  for (int i = 0; i < NUM_SLOTS; i++) {
    pinMode(ledPins[i], OUTPUT);
    digitalWrite(ledPins[i], LOW);
    activeUntil[i] = 0;
  }
  // Quick self-test: light each LED once on power-up.
  for (int i = 0; i < NUM_SLOTS; i++) {
    digitalWrite(ledPins[i], HIGH);
    delay(150);
    digitalWrite(ledPins[i], LOW);
  }
  Serial.println(F("PillPalBox ready"));
}

void handleSignal(char c) {
  if (c >= 'a' && c <= 'f') c = c - 'a' + 'A';  // accept lowercase too
  if (c < 'A' || c > 'F') return;               // ignore newlines/others
  int slot = c - 'A';
  activeUntil[slot] = millis() + BLINK_FOR_MS;
  bt.print(F("OK:"));  // short reply the app can read (optional)
  bt.println(c);
  Serial.print(F("Slot "));
  Serial.println(c);
}

void loop() {
  while (bt.available()) handleSignal((char)bt.read());
  while (Serial.available()) handleSignal((char)Serial.read());  // test from PC

  unsigned long now = millis();
  bool blinkOn = (now / BLINK_STEP_MS) % 2 == 0;
  for (int i = 0; i < NUM_SLOTS; i++) {
    bool active = activeUntil[i] != 0 && (long)(activeUntil[i] - now) > 0;
    if (!active) activeUntil[i] = 0;
    digitalWrite(ledPins[i], active && blinkOn ? HIGH : LOW);
  }
}
