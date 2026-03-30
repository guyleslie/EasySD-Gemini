#ifndef _CARTINTERFACE_

#define _CARTINTERFACE_
#include "Arduino.h"
#include "HardwareSerial.h"
#include "EasySD.h"
#include <ByteQueue.h>

#define PORT_MANIPULATION
#define OPENCOLLECTORSTYLE

#define IO2 3    // D3 → C64 /IO2 (INPUT, INT1, $DF00-$DFFF trigger detect)
#define EXROM 2  // D2 → C64 /EXROM (OUTPUT, controls ROM visibility)
#define NMI 8
#define RESET 9
#define SEL A6         // A6 — analog-only pin, MENU/RESET button; 10k pull-up to +5V, switch to GND
#define STATUS_LED 21  // A7 — NC on PCB (LED is hardware-driven from cartridge 5V rail, not Arduino)
// A5 = IRQ input from C64 cartridge port (future use — not yet read in firmware)
// A4 = PHI2 input from C64 cartridge port (future use — not yet read in firmware)

// A6 is analog-only: no digitalRead/INPUT_PULLUP support.
// Returns true when button is released (high), false when pressed (low).
inline bool selRead() { return analogRead(SEL) >= 512; }

#define PRE_WAIT 3
#define INITIAL_WAIT 17
#define INTER_WAIT 11
#define FINAL_WAIT 23
#define SINGLE_WAIT 35


#define ONE 1
#define ZERO 0
#define BIT_WAITING  0
#define BIT_STARTED 1
#define BIT_ZERO_END 2
#define BIT_ONE_END 3

#define IDENTIFIER_1 0x64
#define IDENTIFIER_2 0x46
#define IDENTIFIER_3 0x17

#define IDLE 0
#define IDENTIFIER_1_OK 1
#define IDENTIFIER_2_OK 2
#define IDENTIFIER_3_OK 3
#define GOT_COMMAND_BYTE 4
#define IN_TRANSMISSION 5



class CartInterface {

 protected:
  //static ByteQueue readQueue;
  unsigned int transferIndex;
  unsigned int blockIndex;
  //unsigned char transferBufferIndex;
  //static const unsigned char bytesPerNMI = 1;   

 
  void SetAddressPinsOutput();
  void IOSetup();
 private : 
  static void ReceiveInterrupt();
  
 public :
  static const uint8_t TransferMode = 0;
  void Init();  
  void SetPage(unsigned char value);   
  uint8_t ReadIO();
  void SetIO(unsigned char value);    
  unsigned int GetTransferIndex();
  unsigned int GetBlockIndex();
  void ResetC64();
  void TransmitByteSlow(unsigned char val);
  void TransmitByteBlockEnd(unsigned char val) ;
  void ResetIndex();
  void EnableCartridge();
  void DisableCartridge();
  void ResetLow();
  void ResetHigh();
  void NmiLow();
  void NmiHigh();  
  void TransmitByteFast(unsigned char val);
  void StreamByteSlow(unsigned char value);
  void TransmitByteFastStd(unsigned char val);
  void TransmitByteFastMK3(unsigned char val);  // 35µs delay: 22133 Hz > C64 21894 Hz
  void StreamByte(unsigned char value);
  void InitTransfer();
  void HandleReceive();
  void ResetReceive();
  void ResetReceiveNoStateChange();
  void StartListening();
  void EndListening();

  void SoftStartListening();
  void SoftEndListening();
 
  uint16_t Read();  
  uint8_t ReceiveHandler();    
};

#endif

