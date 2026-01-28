#ifndef CTSC_h
#define CTSC_h

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Read TSC using RDTSC instruction
static inline uint64_t c_rdtsc(void) {
#if defined(__x86_64__) || defined(__i386__)
  uint32_t lo, hi;
  __asm__ __volatile__ ("rdtsc" : "=a"(lo), "=d"(hi));
  return ((uint64_t)hi << 32) | lo;
#else
  return 0;
#endif
}

/// Read TSC with CPU ID using RDTSCP instruction
static inline uint64_t c_rdtscp(uint32_t *cpu_id) {
#if defined(__x86_64__) || defined(__i386__)
  uint32_t lo, hi;
  __asm__ __volatile__ ("rdtscp" : "=a"(lo), "=d"(hi), "=c"(*cpu_id));
  return ((uint64_t)hi << 32) | lo;
#else
  *cpu_id = 0;
  return 0;
#endif
}

/// Check if CPU supports invariant TSC via CPUID
static inline bool c_has_invariant_tsc(void) {
#if defined(__x86_64__) || defined(__i386__)
  uint32_t eax, ebx, ecx, edx;
  
  // Check if extended CPUID is available
  __asm__ __volatile__ (
                        "cpuid"
                        : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                        : "a"(0x80000000)
                        );
  
  if (eax < 0x80000007) {
    return false;
  }
  
  // CPUID.80000007H:EDX[8] indicates invariant TSC
  __asm__ __volatile__ (
                        "cpuid"
                        : "=a"(eax), "=b"(ebx), "=c"(ecx), "=d"(edx)
                        : "a"(0x80000007)
                        );
  
  return (edx & (1 << 8)) != 0;
#else
  return false;
#endif
}

#ifdef __cplusplus
}
#endif

#endif
