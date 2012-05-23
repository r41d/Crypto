/*
 * Copyright (C) 2012 Southern Storm Software, Pty Ltd.
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 * OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */

// include the library code:
#include <FreetronicsLCD.h>
#include <Form.h>
#include <Field.h>
#include <BoolField.h>
#include <IntField.h>
#include <SoftI2C.h>
#include <DS1307RTC.h>
#include <Melody.h>
#include <PowerSave.h>
#include <avr/power.h>
#include "FrontScreen.h"
#include "SetAlarm.h"
#include "SetTime.h"
#include "SetDate.h"
#include "LowPowerMelody.h"

// I/O pins that are used by this sketch.
#define BUZZER                  12
#define SENSE_BATTERY           A1
#define RTC_DATA                A4
#define RTC_CLOCK               A5
#define RTC_ONE_HZ              A3

// Value to adjust for the voltage drop on D2.
#define VOLTAGE_DROP_ADJUST     70  // 0.7 volts

// Offsets of settings in the realtime clock's NVRAM.
#define SETTING_24HOUR          0   // 0: 12 hour, 1: 24 hour
#define SETTING_ALARM_TIMEOUT   1   // Timeout in minutes for the alarm
#define SETTING_SNOOZE          2   // 0: no snooze, 1: snooze

// Initialize the LCD
FreetronicsLCD lcd;

// Activate the realtime clock chip.
SoftI2C bus(RTC_DATA, RTC_CLOCK);
DS1307RTC rtc(bus, RTC_ONE_HZ);

// Melody to play when the alarm sounds.
int alarmNotes[] = {NOTE_C6, NOTE_C6, NOTE_C6, NOTE_C6, NOTE_REST};
byte alarmLengths[] = {8, 8, 8, 8, 2};
LowPowerMelody alarmMelody(BUZZER);

uint8_t prevHour = 24;
bool is24HourClock = false;
RTCAlarm nextAlarm;

// Create the main form and its fields.
Form mainForm(lcd);
FrontScreenField frontScreen(mainForm);
SetAlarm alarm1(mainForm, "Alarm 1", 0);
SetAlarm alarm2(mainForm, "Alarm 2", 1);
SetAlarm alarm3(mainForm, "Alarm 3", 2);
SetAlarm alarm4(mainForm, "Alarm 4", 3);
IntField alarmTimeout(mainForm, "Alarm timeout", 2, 10, 1, 2, " minutes");
BoolField snooze(mainForm, "Snooze alarm", "On", "Off", false);
SetTime setTime(mainForm, "Set current time");
SetDate setDate(mainForm, "Set current date");
BoolField hourMode(mainForm, "Hour display", "24 hour clock", "12 hour clock", false);

void setup() {
    // Reduce power consumption on I/O pins we don't need.
#ifndef USE_VOLTAGE_MONITOR
    unusedPin(A1);
#endif
    unusedPin(A2);
    unusedPin(0);
    unusedPin(1);
    unusedPin(2);
    unusedPin(10);
    unusedPin(11);
    unusedPin(13);

    // Turn off peripherals we don't need.
    power_spi_disable();
    power_usart0_disable();
    power_twi_disable();
    power_timer1_disable();

    // Enable the screen saver.
    lcd.setScreenSaverMode(FreetronicsLCD::BacklightOnSelect);
    lcd.enableScreenSaver(3);

    // Initialize the alarm melody.
    alarmMelody.setMelody(alarmNotes, alarmLengths, sizeof(alarmLengths));
    alarmMelody.stop();     // Force Timer2 to be disabled.

    // Read the clock settings from the realtime clock's NVRAM.
    is24HourClock = rtc.readByte(SETTING_24HOUR) != 0;
    hourMode.setValue(is24HourClock);
    frontScreen.set24HourMode(is24HourClock);
    alarmTimeout.setValue(rtc.readByte(SETTING_ALARM_TIMEOUT));
    alarmMelody.setLoopDuration(60000UL * alarmTimeout.value());
    snooze.setValue(rtc.readByte(SETTING_SNOOZE) != 0);

    // Set the initial time and date and find the next alarm to be triggered.
    RTCTime time;
    RTCDate date;
    rtc.readTime(&time);
    rtc.readDate(&date);
    frontScreen.setTime(time);
    frontScreen.setDate(date);
    findNextAlarm();

    // Show the main form for the first time.
    mainForm.show();
}

void loop() {
    // Update the time and date every second based on the 1 Hz RTC output.
    if (rtc.hasUpdates() || prevHour >= 24) {
        RTCTime time;
        rtc.readTime(&time);
        frontScreen.setTime(time);
        if (time.hour < prevHour) {
            // Time has wrapped around, or date update has been forced.
            RTCDate date;
            rtc.readDate(&date);
            frontScreen.setDate(date);
            setDate.updateCurrentDate();
        }
        prevHour = time.hour;
        setTime.updateCurrentTime();

#ifdef USE_VOLTAGE_MONITOR
        // Update the battery status once a second also.
        int status = analogRead(SENSE_BATTERY);
        int voltage = (int)((status * 500L) / 1024L);   // e.g. 2.81V = 281
        voltage += VOLTAGE_DROP_ADJUST;
        if (voltage > 500)
            voltage = 500;
        frontScreen.setVoltage(voltage);
#endif

        // Trigger an alarm if necessary.
        if (time.second == 0 && nextAlarm.flags && !alarmMelody.isPlaying()) {
            if (time.hour == nextAlarm.hour && time.minute == nextAlarm.minute) {
                findNextAlarm();
                alarmMelody.play();
            }
        }
    }

    // Dispatch button events to the main form.
    int event = lcd.getButton();
    if (mainForm.dispatch(event) == FORM_CHANGED) {
        if (hourMode.isCurrent()) {
            is24HourClock = hourMode.value();
            frontScreen.set24HourMode(is24HourClock);
            rtc.writeByte(SETTING_24HOUR, (byte)is24HourClock);
        } else if (alarmTimeout.isCurrent()) {
            rtc.writeByte(SETTING_ALARM_TIMEOUT, (byte)alarmTimeout.value());
            alarmMelody.setLoopDuration(60000UL * alarmTimeout.value());
        } else if (snooze.isCurrent()) {
            rtc.writeByte(SETTING_SNOOZE, (byte)snooze.value());
        }
        prevHour = 24;      // Force an update of the main screen.
        findNextAlarm();    // Update the time of the next alarm event.
    }

    // If the alarm is playing and a button was pressed, then turn it off.
    if (alarmMelody.isPlaying()) {
        if (event > 0)
            alarmMelody.stop();
        alarmMelody.run();
    } else {
        // No alarm playing, so put the device to sleep to save power.
        sleepFor(SLEEP_15_MS);
    }
}

inline int timeToAlarm(const RTCTime &currentTime, const RTCAlarm &alarm)
{
    int mins1 = currentTime.hour * 60 + currentTime.minute;
    int mins2 = alarm.hour * 60 + alarm.minute;
    if (mins1 <= mins2)
        return mins2 - mins1;
    else
        return 24 * 60 + mins2 - mins1;
}

// Add 9 minutes to an alarm to get its snooze time.
RTCAlarm adjustForSnooze(const RTCAlarm &alarm)
{
    if (!alarm.flags)
        return alarm;
    RTCAlarm snooze;
    snooze.hour = alarm.hour;
    snooze.minute = alarm.minute + 9;
    if (snooze.minute >= 60) {
        snooze.hour = (snooze.hour + 1) % 24;
        snooze.minute %= 60;
    }
    snooze.flags = alarm.flags;
    return snooze;
}

// Find the time of the next alarm to be triggered.
void findNextAlarm()
{
    // Get the current time plus 1 minute, to avoid repeating the same alarm.
    RTCTime currentTime = frontScreen.time();
    if (++(currentTime.minute) >= 60) {
        currentTime.minute = 0;
        currentTime.hour = (currentTime.hour + 1) % 24;
    }

    // Process each of the alarms to find the closest.
    nextAlarm.hour = 0;
    nextAlarm.minute = 0;
    nextAlarm.flags = 0;
    findNextAlarm(currentTime, alarm1.alarmValue());
    findNextAlarm(currentTime, alarm2.alarmValue());
    findNextAlarm(currentTime, alarm3.alarmValue());
    findNextAlarm(currentTime, alarm4.alarmValue());
    if (snooze.value()) {
        findNextAlarm(currentTime, adjustForSnooze(alarm1.alarmValue()));
        findNextAlarm(currentTime, adjustForSnooze(alarm2.alarmValue()));
        findNextAlarm(currentTime, adjustForSnooze(alarm3.alarmValue()));
        findNextAlarm(currentTime, adjustForSnooze(alarm4.alarmValue()));
    }

    // Set the alarm indicator on the front screen.
    if (nextAlarm.flags) {
        if (snooze.value())
            frontScreen.setAlarmMode(FrontScreenField::Snooze);
        else
            frontScreen.setAlarmMode(FrontScreenField::AlarmOn);
    } else {
        frontScreen.setAlarmMode(FrontScreenField::AlarmOff);
    }
}
void findNextAlarm(const RTCTime &currentTime, const RTCAlarm &alarm)
{
    if (!alarm.flags)
        return;     // Alarm is disabled.
    if (!nextAlarm.flags) {
        // First valid alarm.
        nextAlarm = alarm;
        return;
    }
    if (timeToAlarm(currentTime, nextAlarm) >
            timeToAlarm(currentTime, alarm)) {
        // Found an alarm that is closer in time.
        nextAlarm = alarm;
    }
}
