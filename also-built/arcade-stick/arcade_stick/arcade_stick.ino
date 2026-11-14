// Arcade stick for a Keyestudio Leonardo (KS0248, ATmega32U4).
// It connects over USB as a standard HID joystick, and the mapping is changed over the serial port.
//
// Wiring (diagram in ../wiring.svg):
//   Buttons 1-4: red wire -> pins 2..5, black wire -> common GND (breadboard "-" row)
//   Arcade lever (Sanwa, Zippy...: 4 microswitches):
//     left -> A2, right -> A3, down -> A4, up -> A5, common (white wire) -> GND
//
// Needs MHeironimus's Joystick library:
// https://github.com/MHeironimus/ArduinoJoystickLibrary

#include <Arduino.h>
#include <EEPROM.h>
#include <Joystick.h>

// With INPUT_PULLUP, with no lever the pins read HIGH (released) and the axes stay centred.
// Pins follow the lever's real wiring: on this connector the colours are not in
// up/down/left/right order, so it is fixed here instead of rewiring.
const int PIN_UP = A5;
const int PIN_DOWN = A4;
const int PIN_LEFT = A2;
const int PIN_RIGHT = A3;

// Buttons 1-4 in diagram order: red, blue, red, blue.
// Do not use pins 0 and 1 (RX/TX).
const int BUTTON_PINS[] = {2, 3, 4, 5};
const uint8_t NUM_BUTTONS = sizeof(BUTTON_PINS) / sizeof(BUTTON_PINS[0]);

const uint16_t MAGIC = 0xA5C1;
const uint8_t CONFIG_VERSION = 4;  // 3: 8 buttons and lever type; 4: 4 buttons and digital lever only
const int EEPROM_ADDRESS = 0;

// What is stored in EEPROM. If the structure changes, bump CONFIG_VERSION.
struct Config {
  uint16_t magic;
  uint8_t version;
  uint8_t map[NUM_BUTTONS];  // physical button -> HID button (0..NUM_BUTTONS-1)
  uint8_t invertX;
  uint8_t invertY;
  uint8_t checksum;
};

Config cfg;

// 4 buttons, no hat switches, X and Y axes only
Joystick_ Joystick(JOYSTICK_DEFAULT_REPORT_ID, JOYSTICK_TYPE_JOYSTICK, NUM_BUTTONS, 0,
                   true, true, false, false, false, false, false, false, false, false, false);

char line[32];
uint8_t lineLength = 0;

uint8_t computeChecksum(const Config &c) {
  const uint8_t *p = (const uint8_t *)&c;
  uint8_t sum = 0;
  for (size_t i = 0; i < sizeof(Config) - 1; i++) sum += p[i];
  return sum;
}

void defaultConfig() {
  cfg.magic = MAGIC;
  cfg.version = CONFIG_VERSION;
  for (uint8_t i = 0; i < NUM_BUTTONS; i++) cfg.map[i] = i;
  cfg.invertX = 0;
  cfg.invertY = 0;
}

bool loadConfig() {
  Config stored;
  EEPROM.get(EEPROM_ADDRESS, stored);
  if (stored.magic != MAGIC || stored.version != CONFIG_VERSION ||
      stored.checksum != computeChecksum(stored)) {
    return false;
  }
  for (uint8_t i = 0; i < NUM_BUTTONS; i++) {
    if (stored.map[i] >= NUM_BUTTONS) return false;
  }
  cfg = stored;
  return true;
}

void saveConfig() {
  cfg.checksum = computeChecksum(cfg);
  EEPROM.put(EEPROM_ADDRESS, cfg);  // put only writes the bytes that changed
}

void showConfig() {
  Serial.println(F("--- Configuration (numbered from 1) ---"));
  for (uint8_t i = 0; i < NUM_BUTTONS; i++) {
    Serial.print(F("Physical button "));
    Serial.print(i + 1);
    Serial.print(F(" (pin "));
    Serial.print(BUTTON_PINS[i]);
    Serial.print(F(") -> HID "));
    Serial.println(cfg.map[i] + 1);
  }
  Serial.print(F("Invert X: "));
  Serial.println(cfg.invertX ? F("yes") : F("no"));
  Serial.print(F("Invert Y: "));
  Serial.println(cfg.invertY ? F("yes") : F("no"));
}

void showHelp() {
  Serial.println(F("Commands:"));
  Serial.println(F("  SHOW                     shows the configuration"));
  Serial.println(F("  MAP <physical> <hid>     maps a physical button to an HID button (1-4)"));
  Serial.println(F("  INV X|Y                  inverts an axis"));
  Serial.println(F("  SAVE                     saves to EEPROM"));
  Serial.println(F("  LOAD                     discards changes and reloads from EEPROM"));
  Serial.println(F("  RESET                    default values (not saved)"));
}

void processCommand(char *cmd) {
  for (char *c = cmd; *c; c++) *c = toupper(*c);
  char *command = strtok(cmd, " ");
  char *arg1 = strtok(NULL, " ");
  char *arg2 = strtok(NULL, " ");
  if (!command) return;

  if (!strcmp(command, "SHOW")) {
    showConfig();
  } else if (!strcmp(command, "MAP") && arg1 && arg2) {
    int physical = atoi(arg1);
    int hid = atoi(arg2);
    if (physical < 1 || physical > NUM_BUTTONS || hid < 1 || hid > NUM_BUTTONS) {
      Serial.println(F("ERROR: out of range"));
      return;
    }
    cfg.map[physical - 1] = hid - 1;
    Serial.println(F("OK"));
  } else if (!strcmp(command, "INV") && arg1 && (!strcmp(arg1, "X") || !strcmp(arg1, "Y"))) {
    uint8_t &axis = (arg1[0] == 'X') ? cfg.invertX : cfg.invertY;
    axis = !axis;
    Serial.println(axis ? F("OK: inverted") : F("OK: normal"));
  } else if (!strcmp(command, "SAVE")) {
    saveConfig();
    Serial.println(F("OK: saved"));
  } else if (!strcmp(command, "LOAD")) {
    if (!loadConfig()) defaultConfig();
    Serial.println(F("OK: reloaded"));
  } else if (!strcmp(command, "RESET")) {
    defaultConfig();
    Serial.println(F("OK: defaults (use SAVE to keep them)"));
  } else {
    showHelp();
  }
}

void readSerial() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      if (lineLength > 0) {
        line[lineLength] = '\0';
        processCommand(line);
        lineLength = 0;
      }
    } else if (lineLength < sizeof(line) - 1) {
      line[lineLength++] = c;
    }
  }
}

// Debounce. When pressed or released, the metal contact vibrates for a few milliseconds and
// the pin reads LOW and HIGH in turn; unfiltered, one press could count as several.
// Each input (4 buttons and 4 directions) only changes state once the raw reading has been
// steady for DEBOUNCE_MS in a row. No delay(): the loop reads continuously.
const uint8_t DEBOUNCE_MS = 5;
const uint8_t NUM_INPUTS = NUM_BUTTONS + 4;
enum { IN_UP = NUM_BUTTONS, IN_DOWN, IN_LEFT, IN_RIGHT };
int inputPins[NUM_INPUTS];
bool stable[NUM_INPUTS];            // filtered state (true = pressed)
bool lastRaw[NUM_INPUTS];           // last unfiltered reading
unsigned long since[NUM_INPUTS];    // millis() of the raw reading's last change

void initInputs() {
  for (uint8_t i = 0; i < NUM_BUTTONS; i++) inputPins[i] = BUTTON_PINS[i];
  inputPins[IN_UP] = PIN_UP;
  inputPins[IN_DOWN] = PIN_DOWN;
  inputPins[IN_LEFT] = PIN_LEFT;
  inputPins[IN_RIGHT] = PIN_RIGHT;
  unsigned long now = millis();
  for (uint8_t i = 0; i < NUM_INPUTS; i++) {
    pinMode(inputPins[i], INPUT_PULLUP);
    lastRaw[i] = stable[i] = false;
    since[i] = now;
  }
}

// Returns true if any filtered input changed in this pass.
bool updateInputs() {
  bool changed = false;
  unsigned long now = millis();
  for (uint8_t i = 0; i < NUM_INPUTS; i++) {
    bool raw = digitalRead(inputPins[i]) == LOW;  // microswitch: pressed = LOW
    if (raw != lastRaw[i]) {
      lastRaw[i] = raw;  // still bouncing: start counting again from now
      since[i] = now;
    } else if (raw != stable[i] && now - since[i] >= DEBOUNCE_MS) {
      stable[i] = raw;
      changed = true;
    }
  }
  return changed;
}

// If both directions are pressed at once (should not happen), centre.
// In HID, X = 0 is left and Y = 0 is up.
int readAxis(uint8_t inputMinus, uint8_t inputPlus, bool invert) {
  bool minus = stable[inputMinus];
  bool plus = stable[inputPlus];
  if (invert) {
    bool t = minus;
    minus = plus;
    plus = t;
  }
  if (minus && !plus) return 0;
  if (plus && !minus) return 1023;
  return 512;
}

// Computes the full HID state and sends it. Every HID button is recomputed so none
// is left stuck pressed after a remap.
void sendState() {
  Joystick.setXAxis(readAxis(IN_LEFT, IN_RIGHT, cfg.invertX));
  Joystick.setYAxis(readAxis(IN_UP, IN_DOWN, cfg.invertY));
  bool pressed[NUM_BUTTONS] = {false};
  for (uint8_t i = 0; i < NUM_BUTTONS; i++) {
    if (stable[i]) pressed[cfg.map[i]] = true;
  }
  for (uint8_t b = 0; b < NUM_BUTTONS; b++) Joystick.setButton(b, pressed[b]);
  Joystick.sendState();
}

void setup() {
  initInputs();
  if (!loadConfig()) defaultConfig();

  Serial.begin(9600);
  Joystick.setXAxisRange(0, 1023);
  Joystick.setYAxisRange(0, 1023);
  Joystick.begin(false);  // the state is sent by hand once per pass
}

void loop() {
  readSerial();

  // Only send over USB when something changes (or every 100 ms, in case the PC missed a report).
  // No delay(10) needed, which used to hold back every press by up to 10 ms.
  static unsigned long lastSend = 0;
  static uint8_t lastMap[NUM_BUTTONS];
  static uint8_t lastInvX = 255, lastInvY = 255;
  bool changed = updateInputs();
  if (memcmp(lastMap, cfg.map, NUM_BUTTONS) != 0 ||
      lastInvX != cfg.invertX || lastInvY != cfg.invertY) {
    memcpy(lastMap, cfg.map, NUM_BUTTONS);  // MAP, INV, LOAD or RESET over the serial port
    lastInvX = cfg.invertX;
    lastInvY = cfg.invertY;
    changed = true;
  }
  if (changed || millis() - lastSend >= 100) {
    sendState();
    lastSend = millis();
  }
}
