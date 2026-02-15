#include "StringPrint.h"

#if ARDUINO >= 100
size_t StringPrint::write(uint8_t c) {
#else
void StringPrint::write(uint8_t c) {
#endif
      // FIXED: buffer is 32 bytes, so max index is 30 (leaving room for null terminator at 31)
      if (index < 31) {
        value[index] = c;
        value[index+1] = 0x00;
        index++;
      }
#if ARDUINO >= 100
  return 1;
#endif
}

void StringPrint::ResetIndex(void) {
  
	index = 0;
}

void StringPrint::Copy(char * str) {
  strncpy(value, str, 31);  // Max 31 chars + null terminator (buffer size = 32)
  value[31] = '\0';          // Ensure null termination
  index = strlen(value);
}

