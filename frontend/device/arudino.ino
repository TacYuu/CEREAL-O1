// Core libraries
#include <Wire.h>
#include <LiquidCrystal_I2C.h>
#include <SPI.h>
#include <MFRC522.h>

// NOTE: Removed SerialESP8266wifi include (unused)

#define LCD_ADDRESS 0x27
#define LCD_COLUMNS 19
#define LCD_ROWS 4

// RFID (adjust pins for board)
#define SS_PIN 10 // uno
#define RST_PIN 9 // uno

//#define SS_PIN 53 // mega
//#define RST_PIN 49 // mega

// (WiFi credentials were unused; remove or repurpose later)
// const char* ssid = "yuwen";
// const char* password = "yeojachingu";

#define ULTRASONIC_1_TRIG_PIN 2   // DIGITAL PINS
#define ULTRASONIC_1_ECHO_PIN 3
#define ULTRASONIC_2_TRIG_PIN 4
#define ULTRASONIC_2_ECHO_PIN 5

#define INFRARED_1_PIN A0   // ANALOG PINS
#define INFRARED_2_PIN A1

#define RELAY_1_PIN 6    // DIGITAL PINS
#define RELAY_2_PIN 7
#define RELAY_3_PIN 8

MFRC522 mfrc522(SS_PIN, RST_PIN);
LiquidCrystal_I2C lcd(LCD_ADDRESS, LCD_COLUMNS, LCD_ROWS);

const int pointsThreshold = 10; // Initial points threshold

struct User {
  String rfid;
  String username;
  int points;
};

User users[] = {
  {"f382825", "Rein Moratalla", pointsThreshold},
  {"f3dddf19", "Asley Masujer", pointsThreshold},
  {"235bf519", "Danah Camba", pointsThreshold},
  // Add more users here
};

String rfid_address;

// !! SYSTEM SETUP !! ///////////////////////////////////////////////////////////////////////////////

// --- Detection & Debounce Configuration ---
const int presenceDistanceOnCm = 15;   // distance <= this -> PRESENT
const int presenceDistanceOffCm = 20;  // distance >= this -> ABSENT (hysteresis)
const unsigned long presenceMinIntervalMs = 1500; // min time between repeated events
int lastPresenceState = -1; // -1 unknown, 0 ABSENT, 1 PRESENT
unsigned long lastPresenceEventMs = 0;

// Heartbeat
const unsigned long heartbeatIntervalMs = 30000;
unsigned long lastHeartbeatMs = 0;

// RFID
const unsigned long rfidPollIntervalMs = 100; // poll interval
const unsigned long rfidScanTimeoutMs = 8000;  // user has 8s to scan
unsigned long rfidSessionStartMs = 0;
bool awaitingRFID = true; // Start by asking for RFID
int currentUserIndex = -1;

// Forward declarations
String readRFIDNonBlocking();
int findUserIndex(const String &rfid);
void emitPresenceEvent(int state, int distance1, int distance2);
void printUserTable();
void resetWelcome();

void setup() {
  Serial.begin(115200);
  // Initialize LCD Display
  lcd.begin();
  lcd.backlight();

  // Initialize RFID
  SPI.begin();
  mfrc522.PCD_Init();
  mfrc522.PCD_DumpVersionToSerial();
  //Serial.println(F("RFID Scanner Initiated \n"));

  lcd.setCursor(0, 0); // (start column, row)
  lcd.print("Initializing . . .");

  delay(1500);
  lcd.clear();

  pinMode(ULTRASONIC_1_TRIG_PIN, OUTPUT);
  pinMode(ULTRASONIC_1_ECHO_PIN, INPUT);
  pinMode(ULTRASONIC_2_TRIG_PIN, OUTPUT);
  pinMode(ULTRASONIC_2_ECHO_PIN, INPUT);
  pinMode(INFRARED_1_PIN, INPUT);
  pinMode(INFRARED_2_PIN, INPUT);
  pinMode(RELAY_1_PIN, OUTPUT);
  pinMode(RELAY_2_PIN, OUTPUT);
  pinMode(RELAY_3_PIN, OUTPUT);

  delay(1000);

  lcd.clear();
  lcd.setCursor(0, 0);
  lcd.print("Welcome to CEREAL");
  lcd.setCursor(2, 1);
  lcd.print("Creative Real-time");
  lcd.setCursor(2, 2);
  lcd.print("Initiating Waste");
  lcd.setCursor(2, 3);
  lcd.print("Bin");

  Serial.println("INFO System: Welcome to CEREAL, Creative Real-time Initiating Waste Bin");
  resetWelcome();
  rfidSessionStartMs = millis();
}

// !! MAIN FUNCTION ON LOOP !! /////////////////////////////////////////////////////////////////////////////

void loop() {
  unsigned long nowMs = millis();

  // Heartbeat
  if (nowMs - lastHeartbeatMs > heartbeatIntervalMs) {
    lastHeartbeatMs = nowMs;
    Serial.println("PING");
  }

  // RFID phase
  if (awaitingRFID) {
    String tag = readRFIDNonBlocking();
    if (tag.length()) {
      int idx = findUserIndex(tag);
      if (idx < 0) {
        lcd.clear();
        lcd.setCursor(0, 0);
        lcd.print("No User Found");
        Serial.println("RFID UID=" + tag); // Still emit for Pi if needed
        Serial.println("WARN UnknownRFID:" + tag);
        delay(1500);
        resetWelcome();
        rfidSessionStartMs = nowMs; // restart waiting window
      } else {
        currentUserIndex = idx;
        awaitingRFID = false;
        User &u = users[currentUserIndex];
        Serial.println("RFID UID=" + tag);
        Serial.println(String("INFO UserAuthenticated:") + u.username);
        lcd.clear();
        lcd.setCursor(0,0); lcd.print("Welcome ");
        lcd.setCursor(8,0); lcd.print(u.username.substring(0,10));
        lcd.setCursor(0,1); lcd.print("Points:");
        lcd.setCursor(8,1); lcd.print(u.points);
        delay(1200);
        DetectNotification();
      }
    } else if (nowMs - rfidSessionStartMs > rfidScanTimeoutMs) {
      // Timeout - re-prompt
      lcd.clear();
      lcd.setCursor(0,0); lcd.print("Scan RFID Card");
      rfidSessionStartMs = nowMs;
    }
  } else {
    // Detection phase (after RFID authenticated)
    int dist1, dist2;
    bool detected = Detect(dist1, dist2);
    int presenceState = detected ? 1 : 0;
    bool stateChanged = (presenceState != lastPresenceState);
    bool intervalOk = (nowMs - lastPresenceEventMs) > presenceMinIntervalMs;
    if (stateChanged || intervalOk) {
      if (presenceState != lastPresenceState) {
        lastPresenceState = presenceState;
      }
      lastPresenceEventMs = nowMs;
      emitPresenceEvent(presenceState, dist1, dist2);
    }

    if (detected) {
      ClassifyNotification();
      bool correct = Classify();
      if (correct) {
        correctNotif();
        MotorForward();
        delay(2000);
        MotorOff();
        if (currentUserIndex >= 0) {
          users[currentUserIndex].points++;
          Serial.println("CLASS RESULT=CORRECT user=" + users[currentUserIndex].username + " points=" + String(users[currentUserIndex].points));
        }
      } else {
        incorrectNotif();
        MotorBackward();
        delay(2000);
        MotorOff();
        if (currentUserIndex >= 0) {
          users[currentUserIndex].points--;
          Serial.println("CLASS RESULT=INCORRECT user=" + users[currentUserIndex].username + " points=" + String(users[currentUserIndex].points));
        }
      }
      // After classification cycle, return to RFID stage
      awaitingRFID = true;
      currentUserIndex = -1;
      resetWelcome();
      printUserTable();
      rfidSessionStartMs = nowMs;
    }
  }
}

// !!  SUB FUNCTIONS  !! /////////////////////////////////////////////////////////////////////////////////////

String readRFIDNonBlocking() {
  // Non-blocking check
  if (!mfrc522.PICC_IsNewCardPresent()) return "";
  if (!mfrc522.PICC_ReadCardSerial()) return "";
  String addr = "";
  for (byte i = 0; i < mfrc522.uid.size; i++) {
    addr += String(mfrc522.uid.uidByte[i], HEX);
  }
  mfrc522.PICC_HaltA();
  return addr;
}

int findUserIndex(const String &rfid) {
  for (int i = 0; i < (int)(sizeof(users) / sizeof(users[0])); i++) {
    if (users[i].rfid == rfid) return i;
  }
  return -1;
}

void printUserTable() {
  Serial.println("INFO UserTable: username rfid points");
  for (int i = 0; i < (int)(sizeof(users) / sizeof(users[0])); i++) {
    Serial.print(users[i].username); Serial.print(" ");
    Serial.print(users[i].rfid); Serial.print(" ");
    Serial.println(users[i].points);
  }
}

void resetWelcome() {
  lcd.clear();
  lcd.setCursor(0,0); lcd.print("Scan RFID Card");
  lcd.setCursor(0,1); lcd.print("CEREAL System");
}

// Legacy findUser removed; using findUserIndex instead

bool measureUltrasonicPair(int &distance1, int &distance2) {
  // Sensor 1
  digitalWrite(ULTRASONIC_1_TRIG_PIN, LOW); delayMicroseconds(2);
  digitalWrite(ULTRASONIC_1_TRIG_PIN, HIGH); delayMicroseconds(10);
  digitalWrite(ULTRASONIC_1_TRIG_PIN, LOW);
  long duration1 = pulseIn(ULTRASONIC_1_ECHO_PIN, HIGH, 30000UL);
  distance1 = (duration1 > 0) ? (int)(duration1 * 0.034 / 2) : 999;
  // Sensor 2
  digitalWrite(ULTRASONIC_2_TRIG_PIN, LOW); delayMicroseconds(2);
  digitalWrite(ULTRASONIC_2_TRIG_PIN, HIGH); delayMicroseconds(10);
  digitalWrite(ULTRASONIC_2_TRIG_PIN, LOW);
  long duration2 = pulseIn(ULTRASONIC_2_ECHO_PIN, HIGH, 30000UL);
  distance2 = (duration2 > 0) ? (int)(duration2 * 0.034 / 2) : 999;
  return true;
}

bool Detect(int &distance1, int &distance2) {
  measureUltrasonicPair(distance1, distance2);
  // Determine presence using either sensor
  bool present = (distance1 <= presenceDistanceOnCm) || (distance2 <= presenceDistanceOnCm);
  // Provide some debug optionally
  // Serial.println(String("DEBUG distances=") + distance1 + "," + distance2);
  return present;
}

void emitPresenceEvent(int state, int distance1, int distance2) {
  // state: 1 PRESENT, 0 ABSENT
  String stateStr = state == 1 ? "PRESENT" : "ABSENT";
  int primaryDist = distance1 <= 800 ? distance1 : distance2; // pick a plausible one
  Serial.print("ULTRA EVENT state=");
  Serial.print(stateStr);
  Serial.print(" dist1_cm="); Serial.print(distance1);
  Serial.print(" dist2_cm="); Serial.print(distance2);
  Serial.print(" primary_cm="); Serial.println(primaryDist);
}

bool Classify(){
  delay(1000); // brief stabilization
  int irValue1 = analogRead(INFRARED_1_PIN);
  int irValue2 = analogRead(INFRARED_2_PIN);
  // Example thresholds (adjust empirically)
  bool cond1 = irValue1 < 500; // considered correct indicator
  bool cond2 = irValue2 < 200; // secondary condition
  bool result = cond1 || cond2; // simple OR logic
  Serial.print("INFO IR values: ");
  Serial.print(irValue1); Serial.print(","); Serial.println(irValue2);
  return result;
}

void MotorForward(){
  Serial.println("\n Motor Forward");
  digitalWrite(RELAY_1_PIN, HIGH);
}

void MotorBackward(){
  Serial.println("\n Motor Backwards");
  digitalWrite(RELAY_2_PIN, HIGH);
  digitalWrite(RELAY_3_PIN, HIGH);
  delay(500);
  digitalWrite(RELAY_1_PIN, HIGH);

}

void MotorOff(){
  Serial.println("\n Turning Off Motor");
  digitalWrite(RELAY_1_PIN, LOW);
  digitalWrite(RELAY_2_PIN, LOW);
  digitalWrite(RELAY_3_PIN, LOW);
}

// Removed AddPoints / DeductPoints (logic integrated in loop with persistent array updates)

void DetectNotification(){
  lcd.clear();
  lcd.setCursor(2, 0);
  lcd.print("Detecting");
  lcd.setCursor(3, 1);
  lcd.print("Waste");
  lcd.setCursor(4, 2);
  lcd.print("Presence !");
  
  Serial.println("INFO DetectingWastePresence");
}

void ClassifyNotification(){
  lcd.clear();
  lcd.setCursor(1, 0);
  lcd.print("Checking");
  lcd.setCursor(2, 1);
  lcd.print("Waste");
  lcd.setCursor(3, 2);
  lcd.print("Classification");
  Serial.println("INFO ClassifyingWaste");
}

void correctNotif(){
  lcd.clear();
  lcd.setCursor(1, 0);
  lcd.print("Correct");
  lcd.setCursor(2, 1);
  lcd.print("Classification");
  Serial.println("INFO CorrectClassification");
}

void incorrectNotif(){
  lcd.clear();
  lcd.setCursor(1, 0);
  lcd.print("Sorry, Incorrect");
  lcd.setCursor(2, 1);
  lcd.print("Classification");
  Serial.println("INFO IncorrectClassification");
}