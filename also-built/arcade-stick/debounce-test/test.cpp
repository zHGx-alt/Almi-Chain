// Host test of the firmware's debounce (no board needed): compiles the real .ino with
// Arduino stand-ins, simulates bouncing pins and checks what reaches the PC over HID.
#include "../arcade_stick/arcade_stick.ino"

unsigned long sim_millis = 0;
int sim_pin[32];
SerialSim Serial;
EEPROMSim EEPROM;

static int failures = 0;
static void check(bool ok, const char *what) {
  printf("%s  %s\n", ok ? "OK  " : "FAIL", what);
  if (!ok) failures++;
}

// Advances time 1 ms at a time, running loop() (the real loop runs much faster).
static void run_for(unsigned long ms) {
  for (unsigned long i = 0; i < ms; i++) { loop(); sim_millis++; }
}

// Counts how often HID button b goes from released to pressed while time passes.
static int hidPresses(int b, const char *pattern) {
  int n = 0; bool before = Joystick.button[b];
  for (const char *c = pattern; *c; c++) {
    sim_pin[2] = (*c == '1') ? LOW : HIGH;  // '1' = contact closed during that ms
    loop(); sim_millis++;
    if (Joystick.button[b] && !before) n++;
    before = Joystick.button[b];
  }
  return n;
}

int main() {
  for (int &p : sim_pin) p = HIGH;  // INPUT_PULLUP: released
  setup();
  run_for(20);
  check(Joystick.x == 512 && Joystick.y == 512 && !Joystick.button[0], "at rest: lever centred and buttons released");

  // A press with typical microswitch bounce: 3 ms of chatter when closing and when opening
  const char *bouncy = "1010110111111111111111111111110101001000000000000000";
  check(hidPresses(0, bouncy) == 1, "press with 3 ms bounce on close and open: counts 1, not 5");
  check(!Joystick.button[0], "after a bouncy release, the button is released");

  // Isolated 1-2 ms glitches (interference): must not reach the PC
  check(hidPresses(0, "0001000000110000000000") == 0, "1 and 2 ms noise spikes: no press");

  // Latency: the change arrives DEBOUNCE_MS after the reading settles
  sim_pin[2] = LOW;
  int ms = 0;
  while (!Joystick.button[0] && ms < 50) { loop(); sim_millis++; ms++; }
  printf("      measured latency of a clean press: %d ms (with the old delay(10): up to 10 ms)\n", ms);
  check(ms >= DEBOUNCE_MS && ms <= DEBOUNCE_MS + 1, "a clean press arrives in 5-6 ms");
  sim_pin[2] = HIGH; run_for(20);

  // Lever: bounce on up
  const char *lever = "10110111111111";
  int timesUp = 0; int yBefore = Joystick.y;
  for (const char *c = lever; *c; c++) {
    sim_pin[A5] = (*c == '1') ? LOW : HIGH; loop(); sim_millis++;
    if (Joystick.y == 0 && yBefore != 0) timesUp++;
    yBefore = Joystick.y;
  }
  check(timesUp == 1 && Joystick.y == 0, "lever up with bounce: Y = 0 exactly once");
  sim_pin[A5] = HIGH; run_for(20);
  check(Joystick.y == 512, "releasing the lever re-centres it");

  // Remap: MAP 1 2 with button 1 held moves the press to HID 2 without leaving HID 1 stuck
  sim_pin[2] = LOW; run_for(20);
  cfg.map[0] = 1; run_for(2);
  check(!Joystick.button[0] && Joystick.button[1], "remap with the button held: HID 1 released and HID 2 pressed");
  cfg.map[0] = 0; sim_pin[2] = HIGH; run_for(20);

  // With no changes, one report every 100 ms
  int before = Joystick.reports; run_for(1000);
  int reports = Joystick.reports - before;
  printf("      USB reports in 1 s untouched: %d (with the old delay(10): about 100)\n", reports);
  check(reports >= 9 && reports <= 11, "at rest, one report every 100 ms");

  printf("\n%s: %d failures\n", failures ? "FAILURES" : "All OK", failures);
  return failures ? 1 : 0;
}
