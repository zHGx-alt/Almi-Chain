// Stand-in for MHeironimus's Joystick: keeps the last state and counts the reports sent.
#pragma once
#define JOYSTICK_DEFAULT_REPORT_ID 3
#define JOYSTICK_TYPE_JOYSTICK 4
struct Joystick_ {
  int x = 512, y = 512;
  bool button[32] = {};
  int reports = 0;
  Joystick_(int, int, int, int, bool, bool, bool, bool, bool, bool, bool, bool, bool, bool, bool) {}
  void setXAxisRange(int, int) {}
  void setYAxisRange(int, int) {}
  void begin(bool) {}
  void setXAxis(int v) { x = v; }
  void setYAxis(int v) { y = v; }
  void setButton(int b, bool v) { button[b] = v; }
  void sendState() { reports++; }
};
