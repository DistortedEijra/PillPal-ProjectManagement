#include <SoftwareSerial.h>

// HC-05 wiring:
// - HC-05 TX -> Arduino D2
// - HC-05 RX <- Arduino D3 (via divider ~3.3V), common GND
// - HC-05 STATE -> Arduino D4 (add 10k pulldown from D4 to GND)
// LEDs: A..F -> pins 13,12,11,10,9,8 (each with ~220Ω to GND)
SoftwareSerial hc05(2, 3); // RX, TX

// Slot LEDs: A..F => 13,12,11,10,9,8
const int slotPins[6] = {13, 12, 11, 10, 9, 8};

// Connection indicator
const int connLedPin = 7;  // LED on D7 (ON when connected)
const int btStatePin = 4;  // HC-05 STATE pin -> D4 (HIGH when connected)

// Blink timing
const unsigned long BLINK_INTERVAL = 500;    // ms
const unsigned long BLINK_DURATION = 60000;  // ms per blink command (1 minute)

// Connection stability
const unsigned long STATE_STABLE_MS = 200;   // debounce window for STATE
const unsigned long RX_TIMEOUT_MS   = 3000;  // no RX for 3s => allow disconnect if STATE low

struct SlotState {
  bool steadyOn;
  bool blinking;
  bool currentOn;
  unsigned long blinkStopAt;
  unsigned long lastToggleAt;
} slots[6];

unsigned long lastRxAt = 0;
bool isConnected = false;

int idxFromChar(char c) {
  if (c >= 'A' && c <= 'F') return c - 'A';
  if (c >= 'a' && c <= 'f') return c - 'a';
  return -1;
}

void setAllOff() {
  for (int i = 0; i < 6; i++) {
    slots[i] = SlotState{false, false, false, 0, 0};
    digitalWrite(slotPins[i], LOW);
  }
}

void beginBlink(int i, unsigned long now) {
  slots[i].steadyOn = false;
  slots[i].blinking = true;
  slots[i].currentOn = true;
  slots[i].blinkStopAt = now + BLINK_DURATION;
  slots[i].lastToggleAt = now;
  digitalWrite(slotPins[i], HIGH);
}

void stopAllBlink() {
  for (int i = 0; i < 6; i++) {
    if (slots[i].blinking) {
      slots[i].blinking = false;
      slots[i].currentOn = false;
      digitalWrite(slotPins[i], LOW);
    }
  }
}

void sendLine(const String& s) {
  Serial.println(s);
  hc05.println(s);
}

// Debounce HC-05 STATE pin; returns true if stably HIGH for STATE_STABLE_MS
bool readStateStable() {
  unsigned long t0 = millis();
  int first = digitalRead(btStatePin);
  while (millis() - t0 < STATE_STABLE_MS) {
    if (digitalRead(btStatePin) != first) return false; // bouncing / unstable
  }
  return first == HIGH; // HC-05 STATE HIGH when connected
}

void setup() {
  Serial.begin(9600);
  hc05.begin(9600); // If your module uses 38400, change this to 38400

  // LED pins
  for (int i = 0; i < 6; i++) pinMode(slotPins[i], OUTPUT);
  setAllOff();

  // Connection indicator
  pinMode(connLedPin, OUTPUT);
  digitalWrite(connLedPin, LOW);
  pinMode(btStatePin, INPUT); // add 10k pulldown to GND to avoid floating when disconnected

  lastRxAt = millis();
  sendLine("READY PillPalBox v2");
}

void loop() {
  unsigned long now = millis();

  // Connection evaluation
  bool hwConnected = readStateStable();
  bool rxFresh = (now - lastRxAt) <= RX_TIMEOUT_MS;

  // Only let RX freshness extend an already-connected session.
  // If Bluetooth is turned off (STATE low), we will drop once timeout passes.
  bool newIsConnected = hwConnected || (isConnected && rxFresh);

  if (newIsConnected != isConnected) {
    isConnected = newIsConnected;
    digitalWrite(connLedPin, isConnected ? HIGH : LOW);
    if (!isConnected) {
      stopAllBlink();
      setAllOff();
    }
  }

  // Hard guard: if STATE is LOW and inactivity exceeded, force LEDs off
  if (!hwConnected && (now - lastRxAt > RX_TIMEOUT_MS)) {
    if (isConnected) {
      isConnected = false;
      digitalWrite(connLedPin, LOW);
    }
    stopAllBlink();
    setAllOff();
  }

  // Process incoming Bluetooth data
  while (hc05.available()) {
    char ch = (char)hc05.read();
    lastRxAt = now; // refresh RX timestamp

    if (!isConnected) {
      // Ignore commands if not connected
      continue;
    }

    // Blink A..F
    if (ch >= 'A' && ch <= 'F') {
      int i = idxFromChar(ch);
      if (i >= 0) {
        beginBlink(i, now);
        sendLine("ACK BLINK " + String(ch));
      }
      continue;
    }

    // Steady a..f
    if (ch >= 'a' && ch <= 'f') {
      int i = idxFromChar(ch);
      if (i >= 0) {
        slots[i].blinking = false;
        slots[i].steadyOn = true;
        slots[i].currentOn = true;
        digitalWrite(slotPins[i], HIGH);
        sendLine("ACK STEADY " + String((char)toupper(ch)));
      }
      continue;
    }

    if (ch == '0') {
      setAllOff();
      sendLine("ACK ALLOFF");
      continue;
    }

    if (ch == '!') {
      stopAllBlink();
      sendLine("ACK STOP");
      continue;
    }

    if (ch == '?') {
      String s = "STATUS ";
      // Show which slots are blinking
      for (int i = 0; i < 6; i++) s += slots[i].blinking ? (char)('A' + i) : '-';
      s += " LEDS:";
      for (int i = 0; i < 6; i++) s += (digitalRead(slotPins[i]) ? '1' : '0');
      sendLine(s);
      continue;
    }
  }

  // Blink maintenance for all slots
  for (int i = 0; i < 6; i++) {
    if (slots[i].blinking) {
      if (now >= slots[i].blinkStopAt) {
        slots[i].blinking = false;
        slots[i].currentOn = false;
        digitalWrite(slotPins[i], LOW);
      } else if (now - slots[i].lastToggleAt >= BLINK_INTERVAL) {
        slots[i].lastToggleAt = now;
        slots[i].currentOn = !slots[i].currentOn;
        digitalWrite(slotPins[i], slots[i].currentOn ? HIGH : LOW);
      }
    }
  }
}