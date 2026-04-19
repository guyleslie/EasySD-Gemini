#ifndef _BYTE_QUEUE_
#define _BYTE_QUEUE_

#include <Arduino.h>

// 31 entries is sufficient: the modulated C64→Arduino receive protocol
// delivers bytes one at a time and the main loop drains them promptly.
// Reducing from 63 saves 32 bytes of scarce ATmega328P SRAM.
#define QUEUE_MAX_SIZE 31

class ByteQueue{
    private:
        uint8_t item[QUEUE_MAX_SIZE];
        volatile int8_t head;
        volatile int8_t tail;
    public:
        ByteQueue();
		void Reset();
        void Enqueue(uint8_t);
        uint8_t Dequeue();
        int8_t Size();
        bool IsEmpty();
		bool IsAvailable();
        bool IsFull();
};

#endif 