/*
  Segno console: program the SparkFun Power Delivery Board (STUSB4500, DEV-15801)
  to request 20 V / 5 A from the USB-C PD inlet. See segno_wiring.md section 2.

  Shipped default asks 20 V at 1.0 A (20 W); the console draws ~59 W worst case.

  Upload to an Arduino UNO, wire Qwiic -> UNO (SDA=A4, SCL=A5, GND, 3.3V), open the
  serial monitor at 115200. The sketch writes the NVM once, reads it back and prints
  it. Run it again later only to change settings; the NVM survives power cycles.

    arduino-cli compile --fqbn arduino:avr:uno hardware/console/stusb4500_pdo
    arduino-cli upload  --fqbn arduino:avr:uno -p /dev/cu.usbmodem* hardware/console/stusb4500_pdo
    arduino-cli monitor -p /dev/cu.usbmodem* -c baudrate=115200
*/
#include <Wire.h>
#include <SparkFun_STUSB4500.h>

STUSB4500 usb;

static void printPdo(uint8_t n) {
  Serial.print("PDO"); Serial.print(n);
  Serial.print(": "); Serial.print(usb.getVoltage(n)); Serial.print(" V  ");
  Serial.print(usb.getCurrent(n)); Serial.print(" A  (-");
  Serial.print(usb.getLowerVoltageLimit(n)); Serial.print("% / +");
  Serial.print(usb.getUpperVoltageLimit(n)); Serial.println("%)");
}

static void dump(const char *title) {
  Serial.println(title);
  Serial.print("PDO count (highest priority): "); Serial.println(usb.getPdoNumber());
  printPdo(1); printPdo(2); printPdo(3);
  Serial.print("Flex current: ");        Serial.println(usb.getFlexCurrent());
  Serial.print("External power: ");      Serial.println(usb.getExternalPower());
  Serial.print("USB comm capable: ");    Serial.println(usb.getUsbCommCapable());
  Serial.print("POWER_OK config: ");     Serial.println(usb.getConfigOkGpio());
  Serial.print("GPIO ctrl: ");           Serial.println(usb.getGpioCtrl());
  Serial.print("Power only above 5V: "); Serial.println(usb.getPowerAbove5vOnly());
  Serial.print("Request source current: "); Serial.println(usb.getReqSrcCurrent());
  Serial.println();
}

void setup() {
  Serial.begin(115200);
  Wire.begin();
  delay(500);

  if (!usb.begin()) {               // 0x28, both ADDR jumpers closed (as shipped)
    Serial.println("Cannot connect to STUSB4500 at 0x28. Check Qwiic wiring / 3.3 V.");
    while (1) {}
  }
  Serial.println("Connected to STUSB4500.");
  usb.read();
  dump("Settings BEFORE (as found in NVM):");

  // --- Segno console profile ------------------------------------------------
  usb.setPdoNumber(3);              // negotiate the highest PDO the source can match

  usb.setCurrent(1, 0.5);           // PDO1 is fixed at 5 V by USB PD; never used here

  usb.setVoltage(2, 20.0);          // PDO2: degraded fallback on a 65 W brick
  usb.setCurrent(2, 3.0);           //       (20 V / 3 A = 60 W, still inside the bucks' 8-36 V window)

  usb.setVoltage(3, 20.0);          // PDO3: the real contract, 100 W-class brick
  usb.setCurrent(3, 5.0);           //       20 V / 5 A; T5A slow-blow fuse downstream

  usb.setPowerAbove5vOnly(1);       // VSNK stays OFF on a 5 V-only source: the 8-36 V bucks
                                    // would brown the Pi out on 5 V in, so refuse it outright
  usb.setExternalPower(0);          // no other power source in the console
  usb.setUsbCommCapable(0);         // power only, no USB data through the inlet
  usb.setReqSrcCurrent(0);          // request OUR current (I_SNK_PDO), not the source's max

  usb.write();                      // burn to NVM
  delay(100);
  usb.read();
  dump("Settings AFTER (read back from NVM):");
  Serial.println("Done. Unplug the UNO, plug the PD brick into the board and measure VSNK: expect 20 V.");
}

void loop() {}
