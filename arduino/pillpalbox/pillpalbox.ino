/*
  PillPalBox v3 - Arduino Uno + HC-05 + 6 slot LEDs (+ optional DS3231 clock)

  NEW in v3: the box remembers the reminders. The PillPal app sends the
  current time and the list of reminders whenever it connects (and whenever
  a schedule or slot changes). The box saves the list in EEPROM and lights the
  slot by itself at the right time, even when the phone is not connected.

  Without a DS3231 the box keeps time with millis(): it can drift a few
  minutes a day and forgets the time when power is cut, so open PillPal near
  the box now and then (it re-syncs the time on every connection). With a
  DS3231 module the time is kept accurately, even when unplugged.

  Wiring (same as v2):
    HC-05 TX  -> D2          HC-05 RX <- D3 (through divider, ~3.3V)
    HC-05 STATE -> D4 (+10k pull-down from D4 to GND)
    Slot LEDs A..F -> D13, D12, D11, D10, D9, D8 (each with 220 ohm to GND)
    Connection LED -> D7
    Optional DS3231: SDA -> A4, SCL -> A5, VCC -> 5V, GND -> GND

  Commands from the app (single characters, as before):
    A..F blink slot   a..f steady   0 all off   ! stop blinking   ? status
  Line commands (start with '#', end with newline):
    #T,YYYY,MM,DD,hh,mm,ss    set the clock (phone's local time)
    #C                        start a new reminder list
    #S,<slot>,<days>,hh,mm    add a reminder; days = bits Mon=1,Tue=2,...,Sun=64
    #E                        save the list (EEPROM) and use it
    #Q                        print the saved reminders and the clock
  The same commands can be typed in the Serial Monitor (9600 baud) for testing.
*/

#include <SoftwareSerial.h>
#include <EEPROM.h>

// 1 = DS3231 clock module connected and the "RTClib" library (Adafruit) installed.
#define USE_DS3231 0

#if USE_DS3231
#include <RTClib.h>
RTC_DS3231 rtc;
bool rtcOk = false;
#endif

SoftwareSerial hc05(2, 3);  // RX, TX

const int slotPins[6] = {13, 12, 11, 10, 9, 8};  // A..F
const int connLedPin = 7;                          // ON when connected
const int btStatePin = 4;                          // HC-05 STATE (HIGH when connected)

const unsigned long BLINK_INTERVAL = 500;              // ms
const unsigned long BLINK_DURATION = 60000UL;          // blink sent by the app: 1 minute
const unsigned long SCHEDULE_BLINK_DURATION = 300000UL; // box's own reminder: 5 minutes
const unsigned long STATE_STABLE_MS = 200;             // STATE debounce
const unsigned long RX_TIMEOUT_MS = 3000;

struct SlotState {
  bool steadyOn;
  bool blinking;
  bool currentOn;
  bool fromSchedule;  // started by the box's own reminder (kept when Bluetooth drops)
  unsigned long blinkStopAt;
  unsigned long lastToggleAt;
} slots[6];

// ---------- saved reminders ----------
struct Entry {
  uint8_t slot;    // 0..5 = A..F
  uint8_t days;    // bit 0 = Mon ... bit 6 = Sun
  uint8_t hour;    // 0..23
  uint8_t minute;  // 0..59
};
const uint8_t MAX_ENTRIES = 40;
Entry entries[MAX_ENTRIES];
uint8_t entryCount = 0;
Entry pending[MAX_ENTRIES];  // list being received
uint8_t pendingCount = 0;

const uint8_t EE_MAGIC = 0x50;  // 'P'
const uint8_t EE_VERSION = 1;
const int EE_START = 3;  // [0]=magic [1]=version [2]=count, then 4 bytes per entry

// ---------- clock ----------
bool clockSet = false;
unsigned long syncMillis = 0;
unsigned long syncWeekSeconds = 0;  // seconds since Monday 00:00 when the time was set
long lastMinuteChecked = -1;

// ---------- connection ----------
unsigned long lastRxAt = 0;
bool isConnected = false;
int lastStateRaw = LOW;
unsigned long stateChangedAt = 0;
bool stateHigh = false;

// ---------- line input (Bluetooth and USB) ----------
struct LineReader {
  char buf[40];
  uint8_t len;
  bool active;
};
LineReader btLine = {{0}, 0, false};
LineReader usbLine = {{0}, 0, false};

// =====================================================================

void sendLine(const String& s) {
  Serial.println(s);
  hc05.println(s);
}

void setAllOff() {
  for (int i = 0; i < 6; i++) {
    slots[i] = SlotState{false, false, false, false, 0, 0};
    digitalWrite(slotPins[i], LOW);
  }
}

void beginBlink(int i, unsigned long now, unsigned long duration, bool fromSchedule) {
  slots[i].steadyOn = false;
  slots[i].blinking = true;
  slots[i].currentOn = true;
  slots[i].fromSchedule = fromSchedule;
  slots[i].blinkStopAt = now + duration;
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

// When Bluetooth drops, turn off what the app turned on, but keep the
// box's own reminders blinking.
void stopAppLeds() {
  for (int i = 0; i < 6; i++) {
    if (!slots[i].fromSchedule) {
      slots[i] = SlotState{false, false, false, false, 0, 0};
      digitalWrite(slotPins[i], LOW);
    }
  }
}

// ---------- EEPROM ----------
void saveSchedule() {
  EEPROM.update(0, EE_MAGIC);
  EEPROM.update(1, EE_VERSION);
  EEPROM.update(2, entryCount);
  for (uint8_t i = 0; i < entryCount; i++) {
    int a = EE_START + i * 4;
    EEPROM.update(a, entries[i].slot);
    EEPROM.update(a + 1, entries[i].days);
    EEPROM.update(a + 2, entries[i].hour);
    EEPROM.update(a + 3, entries[i].minute);
  }
}

void loadSchedule() {
  entryCount = 0;
  if (EEPROM.read(0) != EE_MAGIC || EEPROM.read(1) != EE_VERSION) return;
  uint8_t n = EEPROM.read(2);
  if (n > MAX_ENTRIES) n = MAX_ENTRIES;
  for (uint8_t i = 0; i < n; i++) {
    int a = EE_START + i * 4;
    Entry e = {EEPROM.read(a), EEPROM.read(a + 1), EEPROM.read(a + 2), EEPROM.read(a + 3)};
    if (e.slot < 6 && e.days > 0 && e.days < 128 && e.hour < 24 && e.minute < 60) {
      entries[entryCount++] = e;
    }
  }
}

// ---------- clock ----------
// Day of week for a date, Monday = 0 ... Sunday = 6.
uint8_t mondayBasedDow(int y, int m, int d) {
  static const int t[] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4};
  if (m < 3) y -= 1;
  int sundayBased = (y + y / 4 - y / 100 + y / 400 + t[m - 1] + d) % 7;  // 0 = Sunday
  return (sundayBased + 6) % 7;
}

bool clockValid() {
#if USE_DS3231
  if (rtcOk && !rtc.lostPower()) return true;
#endif
  return clockSet;
}

unsigned long weekSecondsNow() {
#if USE_DS3231
  if (rtcOk && !rtc.lostPower()) {
    DateTime n = rtc.now();
    uint8_t day = (n.dayOfTheWeek() + 6) % 7;  // RTClib: 0 = Sunday
    return day * 86400UL + n.hour() * 3600UL + n.minute() * 60UL + n.second();
  }
#endif
  return (syncWeekSeconds + (millis() - syncMillis) / 1000UL) % 604800UL;
}

void setClock(int y, int mo, int d, int h, int mi, int s) {
  syncWeekSeconds = mondayBasedDow(y, mo, d) * 86400UL + h * 3600UL + mi * 60UL + s;
  syncMillis = millis();
  clockSet = true;
#if USE_DS3231
  if (rtcOk) rtc.adjust(DateTime(y, mo, d, h, mi, s));
#endif
  // Don't fire again for a minute that was just handled.
  lastMinuteChecked = (long)(weekSecondsNow() / 60UL);
}

String clockText() {
  if (!clockValid()) return "CLOCK not set";
  static const char* names[] = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};
  unsigned long ws = weekSecondsNow();
  unsigned long m = (ws / 60UL) % 1440UL;
  String hh = String(m / 60);
  String mm = String(m % 60);
  if (hh.length() < 2) hh = "0" + hh;
  if (mm.length() < 2) mm = "0" + mm;
  return String("CLOCK ") + names[ws / 86400UL] + " " + hh + ":" + mm;
}

// Lights the slot of every reminder due this minute (works offline).
void checkSchedule(unsigned long now) {
  if (entryCount == 0 || !clockValid()) return;
  long minuteOfWeek = (long)(weekSecondsNow() / 60UL);
  if (minuteOfWeek == lastMinuteChecked) return;
  lastMinuteChecked = minuteOfWeek;

  uint8_t day = minuteOfWeek / 1440;
  int mod = minuteOfWeek % 1440;
  uint8_t h = mod / 60;
  uint8_t m = mod % 60;
  for (uint8_t i = 0; i < entryCount; i++) {
    const Entry& e = entries[i];
    if (((e.days >> day) & 1) && e.hour == h && e.minute == m) {
      beginBlink(e.slot, now, SCHEDULE_BLINK_DURATION, true);
      sendLine(String("REMINDER ") + (char)('A' + e.slot));
    }
  }
}

// ---------- commands ----------
void printSchedule() {
  sendLine(clockText());
  sendLine(String("SCHED ") + entryCount);
  for (uint8_t i = 0; i < entryCount; i++) {
    String s = String((char)('A' + entries[i].slot)) + " days=" + entries[i].days + " " +
               entries[i].hour + ":" + (entries[i].minute < 10 ? "0" : "") + entries[i].minute;
    sendLine(s);
  }
}

void handleLine(const char* s) {
  int y, mo, d, h, mi, se, days;
  char slot;
  switch (s[0]) {
    case 'T':
      if (sscanf(s + 1, ",%d,%d,%d,%d,%d,%d", &y, &mo, &d, &h, &mi, &se) == 6 && mo >= 1 && mo <= 12 &&
          d >= 1 && d <= 31 && h >= 0 && h < 24 && mi >= 0 && mi < 60 && se >= 0 && se < 60) {
        setClock(y, mo, d, h, mi, se);
        sendLine("ACK " + clockText());
      } else {
        sendLine("ERR T");
      }
      break;
    case 'C':
      pendingCount = 0;
      sendLine("ACK CLEAR");
      break;
    case 'S':
      if (sscanf(s + 1, ",%c,%d,%d,%d", &slot, &days, &h, &mi) == 4) {
        int idx = slot >= 'a' ? slot - 'a' : slot - 'A';
        if (idx >= 0 && idx < 6 && days > 0 && days < 128 && h >= 0 && h < 24 && mi >= 0 && mi < 60 &&
            pendingCount < MAX_ENTRIES) {
          pending[pendingCount++] = {(uint8_t)idx, (uint8_t)days, (uint8_t)h, (uint8_t)mi};
          break;
        }
      }
      sendLine("ERR S");
      break;
    case 'E':
      for (uint8_t i = 0; i < pendingCount; i++) entries[i] = pending[i];
      entryCount = pendingCount;
      saveSchedule();
      sendLine(String("ACK SCHED ") + entryCount);
      break;
    case 'Q':
      printSchedule();
      break;
    default:
      sendLine("ERR ?");
  }
}

// Single-character commands (unchanged from v2).
void handleChar(char ch, unsigned long now) {
  if (ch >= 'A' && ch <= 'F') {
    beginBlink(ch - 'A', now, BLINK_DURATION, false);
    sendLine("ACK BLINK " + String(ch));
  } else if (ch >= 'a' && ch <= 'f') {
    int i = ch - 'a';
    slots[i].blinking = false;
    slots[i].steadyOn = true;
    slots[i].currentOn = true;
    slots[i].fromSchedule = false;
    digitalWrite(slotPins[i], HIGH);
    sendLine("ACK STEADY " + String((char)toupper(ch)));
  } else if (ch == '0') {
    setAllOff();
    sendLine("ACK ALLOFF");
  } else if (ch == '!') {
    stopAllBlink();
    sendLine("ACK STOP");
  } else if (ch == '?') {
    String s = "STATUS ";
    for (int i = 0; i < 6; i++) s += slots[i].blinking ? (char)('A' + i) : '-';
    s += " LEDS:";
    for (int i = 0; i < 6; i++) s += (digitalRead(slotPins[i]) ? '1' : '0');
    sendLine(s);
    sendLine(clockText());
    sendLine(String("SCHED ") + entryCount);
  }
}

// Returns true if the character was part of a '#' line.
bool feedLine(LineReader& r, char ch) {
  if (r.active) {
    if (ch == '\n' || ch == '\r') {
      r.buf[r.len] = 0;
      r.active = false;
      if (r.len > 0) handleLine(r.buf);
    } else if (r.len < sizeof(r.buf) - 1) {
      r.buf[r.len++] = ch;
    }
    return true;
  }
  if (ch == '#') {
    r.active = true;
    r.len = 0;
    return true;
  }
  return false;
}

// Non-blocking debounce of the HC-05 STATE pin.
void updateState(unsigned long now) {
  int raw = digitalRead(btStatePin);
  if (raw != lastStateRaw) {
    lastStateRaw = raw;
    stateChangedAt = now;
  }
  if (now - stateChangedAt >= STATE_STABLE_MS) stateHigh = (raw == HIGH);
}

// =====================================================================

void setup() {
  Serial.begin(9600);
  hc05.begin(9600);  // if your module uses 38400, change this to 38400

  for (int i = 0; i < 6; i++) pinMode(slotPins[i], OUTPUT);
  setAllOff();
  pinMode(connLedPin, OUTPUT);
  digitalWrite(connLedPin, LOW);
  pinMode(btStatePin, INPUT);  // add 10k pull-down to GND

#if USE_DS3231
  rtcOk = rtc.begin();
#endif

  loadSchedule();
  lastRxAt = millis();
  sendLine(String("READY PillPalBox v3, ") + entryCount + " reminders saved");
  sendLine(clockText());
}

void loop() {
  unsigned long now = millis();

  // Connection state
  updateState(now);
  bool rxFresh = (now - lastRxAt) <= RX_TIMEOUT_MS;
  bool newIsConnected = stateHigh || (isConnected && rxFresh);
  if (newIsConnected != isConnected) {
    isConnected = newIsConnected;
    digitalWrite(connLedPin, isConnected ? HIGH : LOW);
    if (!isConnected) stopAppLeds();
  }

  // Bluetooth input
  while (hc05.available()) {
    char ch = (char)hc05.read();
    lastRxAt = now;
    if (feedLine(btLine, ch)) continue;  // '#' lines are always accepted
    if (!isConnected) continue;          // ignore stray characters when not connected
    handleChar(ch, now);
  }

  // USB Serial Monitor input (for testing)
  while (Serial.available()) {
    char ch = (char)Serial.read();
    if (feedLine(usbLine, ch)) continue;
    handleChar(ch, now);
  }

  // The box's own reminders (work without the phone)
  checkSchedule(now);

  // Blink maintenance
  for (int i = 0; i < 6; i++) {
    if (slots[i].blinking) {
      if ((long)(now - slots[i].blinkStopAt) >= 0) {
        slots[i].blinking = false;
        slots[i].currentOn = false;
        slots[i].fromSchedule = false;
        digitalWrite(slotPins[i], LOW);
      } else if (now - slots[i].lastToggleAt >= BLINK_INTERVAL) {
        slots[i].lastToggleAt = now;
        slots[i].currentOn = !slots[i].currentOn;
        digitalWrite(slotPins[i], slots[i].currentOn ? HIGH : LOW);
      }
    }
  }
}
