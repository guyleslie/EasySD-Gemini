#include <Arduino.h>
#include <ByteQueue.h>
#include "CartInterface.h"
#include "EasySD.h"

volatile ByteQueue readQueue;
volatile uint8_t bitState = BIT_STARTED;
volatile int receiveState = IDLE;

volatile uint8_t currentByte = 0;
volatile uint8_t bitMask = 1;
volatile unsigned long lastInterruptTime = 0;
volatile unsigned long timeDifference = 0;
volatile unsigned long interruptTime = 0;
//volatile uint8_t toggle = 1;

namespace {

constexpr unsigned long PHI2_SYNC_TIMEOUT_US = 2000UL;

inline bool phi2ReadFast() {
  #ifdef __AVR__
  return (PINC & _BV(PC4)) != 0;
  #else
  return phi2Read();
  #endif
}

bool waitForPhi2Level(bool targetLevel, unsigned long timeoutUs) {
  unsigned long start = micros();
  while (phi2ReadFast() != targetLevel) {
    if ((unsigned long)(micros() - start) > timeoutUs) {
      return false;
    }
  }
  return true;
}

void syncBusChangeToPhi2Low() {
  // Cartridge visibility and bus-driving changes should happen while PHI2 is low,
  // i.e. outside the CPU-owned half-cycle, to avoid mid-read mapping glitches.
  if (phi2ReadFast()) {
    if (!waitForPhi2Level(false, PHI2_SYNC_TIMEOUT_US)) {
      return;
    }
  }

  delayMicroseconds(1);
}

}

static void CartInterface::ReceiveInterrupt() {
    lastInterruptTime = interruptTime;
    interruptTime = micros();
    timeDifference = interruptTime - lastInterruptTime;

    switch(bitState) {
    case BIT_STARTED :
      if (timeDifference<350 || timeDifference>1000) {
        bitState = BIT_STARTED;
        currentByte = 0;
        bitMask = 1;
      } else {
        if (timeDifference<450) {
          bitState = BIT_ZERO_END;
        } else if (timeDifference>700) {
          bitState = BIT_ONE_END;
        } else {
          bitState = BIT_STARTED;
          currentByte = 0;
          bitMask = 1;          
        }     
      }
    break;
    case BIT_ZERO_END :
      bitState = BIT_STARTED;
      return;
    break;
    case BIT_ONE_END :
      bitState = BIT_STARTED;
      return;
    break;
  }

  if (receiveState == IN_TRANSMISSION) {
    if (bitState > BIT_STARTED) {
      if (bitState == BIT_ONE_END) {
        currentByte = currentByte | bitMask;      
      }  
    
      bitMask<<=1;
      
      if (bitMask == 0) {      
        if (!readQueue.IsFull()) {
          readQueue.Enqueue(currentByte);
        }                  
        
        bitMask = 1;
        currentByte = 0;      
      }      
    }
  }
  
}

uint8_t CartInterface::ReceiveHandler() {
    if (receiveState == IN_TRANSMISSION) {
        return receiveState;
    }
    if (bitState < BIT_ZERO_END) {
      return receiveState;
    }

    // A bit transfer has been finished.

    if (bitState == BIT_ONE_END) {
      currentByte = currentByte | bitMask;      
    }
  
    bitMask<<=1;
    
    if (bitMask == 0) {
      switch(receiveState) {
        case IDLE : 
        if (currentByte == IDENTIFIER_1) {
          receiveState = IDENTIFIER_1_OK;
        }
        break;
        
        case IDENTIFIER_1_OK : 
        if (currentByte == IDENTIFIER_2) {
          receiveState = IDENTIFIER_2_OK;
        }
        break;

        case IDENTIFIER_2_OK :
        if (currentByte == IDENTIFIER_3) {
          receiveState = IDENTIFIER_3_OK;
        }
        break;
        
        case IDENTIFIER_3_OK :                    
          if (!readQueue.IsFull()) {
            readQueue.Enqueue(currentByte);
          }          
          receiveState = IN_TRANSMISSION;      
          EnableCartridge(); 
        break;         

        case IN_TRANSMISSION : break;     
          if (!readQueue.IsFull()) {
            readQueue.Enqueue(currentByte);
            //Serial.println(currentByte);
          }          
      }
      
      bitMask = 1;
      currentByte = 0;      
    }

    // Preserve the original edge-to-edge synchronization, but do not wedge the
    // whole main loop forever if the C64 disappears or aborts mid-byte.
    unsigned long waitStart = micros();
    while(bitState >= BIT_ZERO_END) {
      if (receiveState == IN_TRANSMISSION) break;
      if ((unsigned long)(micros() - waitStart) > 2000UL) {
        bitState = BIT_STARTED;
        bitMask = 1;
        currentByte = 0;
        receiveState = IDLE;
        break;
      }
    }

    return receiveState;
}

void CartInterface::SetAddressPinsOutput() {
  #ifdef __AVR__
    #ifdef PORT_MANIPULATION  
    DDRD = DDRD | B11110000; // Set Pin 4..7 as outputs. A12, A13, A14, A15
    DDRC = DDRC | B00001111; // Set Analog pin 0..3 as outputs A8, A9, A10, A11
    #else
    for (int i=0;i<8;i++) {
      pinMode(dataPins[i], OUTPUT);
    }  
    #endif
  #endif
}


uint16_t CartInterface::Read() {
  if (readQueue.IsAvailable()) {
    uint8_t val = readQueue.Dequeue();
    uint16_t intVal = val;
    return val;    
  } else {      
      return -1;
  }
}

void CartInterface::IOSetup() {
  // BASIC-first boot: do NOT pull /RESET LOW. The C64 boots normally to BASIC.
  // EXROM stays HIGH (cartridge hidden). Data bus stays INPUT (tristate).
  // The menu is loaded later when the user presses SEL, which calls
  // TransferMenu() — that does EnableExromOnly() + ResetC64() to warm-reset
  // the C64 into the cartridge menu.
  #ifdef OPENCOLLECTORSTYLE
    ResetHigh();
    NmiHigh();
  #else
    pinMode(RESET, OUTPUT);
    digitalWrite(RESET, HIGH);

    pinMode(NMI, OUTPUT);
    digitalWrite(NMI, HIGH);
  #endif

  pinMode(IO2, INPUT);
  pinMode(PHI2, INPUT);
  // Set EXROM HIGH before enabling output — avoids a ~1-2µs LOW glitch.
  PORTD |= _BV(PD2);   // latch HIGH first
  DDRD  |= _BV(PD2);   // then enable output — pin starts HIGH, no glitch
  // SEL is on A6 (analog-only): no pinMode/pullup needed, external 10k pullup used
}


void CartInterface::ResetReceive() {
  bitState = BIT_STARTED;
  receiveState = IDLE;
  bitMask = 1;  
  //Discard any received items that are not consumed.
  readQueue.Reset(); 
}

void CartInterface::ResetReceiveNoStateChange() {
  bitState = BIT_STARTED;
  bitMask = 1;  
  //Discard any received items that are not consumed.
  readQueue.Reset(); 
}

void CartInterface::StartListening() {
  ResetReceive();
  attachInterrupt(digitalPinToInterrupt(IO2), CartInterface::ReceiveInterrupt, FALLING);      
}

void CartInterface::EndListening() {
  detachInterrupt(digitalPinToInterrupt(IO2));
  ResetReceive();
  DisableCartridge();
}

void CartInterface::SoftStartListening() {
  ResetReceiveNoStateChange();
  attachInterrupt(digitalPinToInterrupt(IO2), CartInterface::ReceiveInterrupt, FALLING);      
}

void CartInterface::SoftEndListening() {
  detachInterrupt(digitalPinToInterrupt(IO2));
  ResetReceiveNoStateChange();
}


void CartInterface::Init() {
  IOSetup();
  // IOSetup() leaves /RESET HIGH (not driven) and EXROM HIGH (cartridge hidden).
  // C64 boots normally to BASIC. Data bus pins start as INPUT (tristate).
  // SetAddressPinsOutput() must NOT be called here to avoid bus contention.
  StartListening();
}


unsigned int CartInterface::GetTransferIndex() {
  return transferIndex;
}

unsigned int CartInterface::GetBlockIndex() {
  return blockIndex;
}


void CartInterface::SetPage(unsigned char value) {
  #ifdef PORT_MANIPULATION
  // FIX: Read PORT registers (output state), not PIN registers (external signals)
  PORTD = (PORTD & 0x0F) | (value & 0xF0);
  PORTC = (PORTC & 0xF0) | (value & 0x0F);
  #else
  unsigned char mask = 1;
  for (int i=0;i<8;i++) {
    digitalWrite(dataPins[i], value & mask);
    mask = mask<<1;
  }    
  #endif   
}

void CartInterface::ResetC64() {
  //Serial.println(F("Resetting"));
  ResetLow();
  delayMicroseconds(1000);  
  ResetHigh();
  //Serial.println(F("Reset"));  
}

void CartInterface::TransmitByteSlow(unsigned char val) {
  SetPage(val);
  NmiLow();
  delayMicroseconds(10); //Wait for interrupt to trigger
  NmiHigh();    
  delayMicroseconds(75);  //Wait for interrupt to finish it's job 
}

void CartInterface::TransmitByteBlockEnd(unsigned char val) {
  SetPage(val);
  NmiLow();
  delayMicroseconds(6); //Wait for interrupt to trigger
  NmiHigh(); 
  delayMicroseconds(100);  //Wait for interrupt to finish it's job
}

void CartInterface::ResetIndex() {
  transferIndex = 0;
  blockIndex = 0;
  //transferBufferIndex=0;
}

void CartInterface::EnableCartridge() {
  #ifdef EASYSD_DEBUG_SERIAL
  Serial.println(F("AVR Enabling Cartridge"));
  #endif
  syncBusChangeToPhi2Low();
  DDRD |= 0xF0;          // D4-D7: OUTPUT (drive data bus)
  DDRC |= 0x0F;          // A0-A3: OUTPUT (drive data bus)
  PORTD &= ~_BV (PD2);  // EXROM LOW — cartridge visible to C64
}

void CartInterface::EnableExromOnly() {
  // EXROM LOW — cartridge ROML chip (AT28C64B / M27C64A) becomes visible to
  // C64 at $8000-$9FFF (ROML active).
  // Data bus pins intentionally left as INPUT (tristate) so the cartridge ROML
  // chip can drive the data bus undisturbed. Required for the CBM80 check at
  // $8004-$8008: if data pins were OUTPUT(0x00) here, ATmega's 40mA sink would
  // override the chip's 4mA source and CBM80 detection would fail even with
  // the chip installed.
  syncBusChangeToPhi2Low();
  PORTD &= ~_BV (PD2);
}

void CartInterface::EnableDataBus() {
  // Switch data bus pins to OUTPUT — call after delay(300) CBM80 window,
  // immediately before NMI data transfers begin (SendHeader / TransmitByte*).
  syncBusChangeToPhi2Low();
  DDRD |= 0xF0;   // D4-D7: OUTPUT
  DDRC |= 0x0F;   // A0-A3: OUTPUT
}



void CartInterface::DisableCartridge() {
  syncBusChangeToPhi2Low();
  PORTD |= _BV (PD2);   // EXROM HIGH — cartridge hidden from C64
  DDRD &= ~0xF0;         // D4-D7: INPUT (tristate — stop driving data bus)
  DDRC &= ~0x0F;         // A0-A3: INPUT (tristate — stop driving data bus)
}

void CartInterface::ResetLow() {
  #ifdef OPENCOLLECTORSTYLE
   PORTB &= ~_BV(PB1); // turn off internal resistor 
   DDRB |= _BV(PB1); // set to output       
  #else
    PORTB &= ~_BV (PB1);
  #endif  
}

void CartInterface::ResetHigh() {
  #ifdef OPENCOLLECTORSTYLE
    DDRB &= ~_BV(PB1); //switch to input while port is low. 
    PORTB |= _BV(PB1); //turn on internal resistor to Vcc 
  #else
    PORTB |= _BV (PB1);
  #endif 
}

void CartInterface::NmiLow() {
  #ifdef OPENCOLLECTORSTYLE
   PORTB &= ~_BV(PB0); // turn off internal resistor 
   DDRB |= _BV(PB0); // set to output       
  #else
    PORTB &= ~_BV (PB0);
  #endif
}

void CartInterface::NmiHigh() {
  #ifdef OPENCOLLECTORSTYLE
    DDRB &= ~_BV(PB0); //switch to input while port is low. 
    PORTB |= _BV(PB0); //turn on internal resistor to Vcc 
  #else      
    PORTB |= _BV (PB0);
  #endif
}

void CartInterface::TransmitByteFast(unsigned char val)
{
   SetPage(val);
   if (transferIndex==255) {
      NmiLow();
      delayMicroseconds(10); // FIX: Increased from 7µs (hardware detection minimum)
      NmiHigh();
      delayMicroseconds(80);  // Wait for interrupt to finish its job
      transferIndex = 0;
      blockIndex++;
   } else {
      NmiLow();
      delayMicroseconds(10); // FIX: Increased from 6µs (was too short!)
      NmiHigh();
      delayMicroseconds(50);  // FIX: Increased from 31µs (handler execution time)
      transferIndex++;
   }
}


void CartInterface::TransmitByteFastStd(unsigned char val)
{
   SetPage(val);
   if (transferIndex==255) {
      NmiLow();
      delayMicroseconds(10); // FIX: Increased from 7µs (hardware detection minimum)
      NmiHigh();
      delayMicroseconds(80);  // Wait for interrupt to finish its job
      transferIndex = 0;
      blockIndex++;
   } else {
      NmiLow();
      delayMicroseconds(10); // FIX: Increased from 7µs
      NmiHigh();
      delayMicroseconds(50);  // FIX: Increased from 40µs (safer handler execution time)
      transferIndex++;
   }
}

// MK3 audio path: 35µs inter-byte delay → ~22133 Hz fill rate.
// Must exceed C64 CIA1 rate (21894 Hz) so the ISR never laps the NMI fill.
// Block-end delay kept at 80µs (same as FastStd) for safe page-boundary handling.
void CartInterface::TransmitByteFastMK3(unsigned char val)
{
   SetPage(val);
   if (transferIndex==255) {
      NmiLow();
      delayMicroseconds(10);
      NmiHigh();
      delayMicroseconds(80);  // block-end: extra margin at 256-byte boundary
      transferIndex = 0;
      blockIndex++;
   } else {
      NmiLow();
      delayMicroseconds(10);
      NmiHigh();
      delayMicroseconds(35);  // 35µs → 45µs/byte → 22222 Hz (avg 22133 Hz with block-end)
      transferIndex++;
   }
}

void CartInterface::StreamByte(unsigned char value)
{
    SetPage(value);

    NmiLow();
    delayMicroseconds(10); // FIX: Increased from 5µs (was too short!)
    NmiHigh();

    // Note: No delay after NmiHigh() - streaming relies on external sync
}

void CartInterface::InitTransfer()  {
  /* Cart software waits for data while page is negative */
  SetPage(0x80);    
  /* Enable cartridge so on restart rom code is executed */    
  EnableCartridge();
  /* Reset C64 */        
  ResetC64();   
}



