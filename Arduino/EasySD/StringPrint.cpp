#include "StringPrint.h"

#if ARDUINO >= 100
size_t StringPrint::write(uint8_t c) {
#else
void StringPrint::write(uint8_t c) {
#endif
      // buffer is 64 bytes, so max index is 62 (leaving room for null terminator at 63)
      if (index < 63) {
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
  strncpy(value, str, 63);  // Max 63 chars + null terminator (buffer size = 64)
  value[63] = '\0';          // Ensure null termination
  index = strlen(value);
}

