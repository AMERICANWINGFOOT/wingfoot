/*======================================================================
  loadtest.h  -  CPU load generator for QB64-PE (Linux, pthreads)

  QB64 is single-threaded, so the real work happens here: one worker
  thread per requested CPU, each spinning a floating-point loop
  (sin / cos / sqrt) until told to stop.

  LT_CPUCount()   online logical CPUs (threads) reported by the OS
  LT_Start(n)     start n worker threads, returns how many started
  LT_Stop()       signal workers to stop and wait for them to exit
  LT_Running()    -1 while workers are running, 0 otherwise
======================================================================*/
#include <pthread.h>
#include <unistd.h>
#include <stdint.h>
#include <math.h>

#define LT_MAXTHREADS 256

static pthread_t lt_thr[LT_MAXTHREADS];
static volatile int lt_run = 0;
static int lt_count = 0;
static volatile double lt_sink[LT_MAXTHREADS];

static void *lt_worker(void *arg)
{
    intptr_t id = (intptr_t)arg;
    double x = 0.5 + (double)id * 0.01;
    double y = 1.0;
    long i;
    while (lt_run) {
        /* ~10 ms of math per pass, so Stop takes effect almost at once */
        for (i = 0; i < 200000; i++) {
            x = sin(x) + cos(y);
            y = sqrt(x * x + 1.0);
        }
        lt_sink[id] = x + y;   /* keeps the optimizer from deleting the loop */
    }
    return NULL;
}

int LT_CPUCount(void)
{
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) n = 1;
    if (n > LT_MAXTHREADS) n = LT_MAXTHREADS;
    return (int)n;
}

int LT_Start(int n)
{
    int i;
    if (lt_run) return 0;
    if (n < 1) n = 1;
    if (n > LT_MAXTHREADS) n = LT_MAXTHREADS;
    lt_run = 1;
    lt_count = 0;
    for (i = 0; i < n; i++) {
        if (pthread_create(&lt_thr[i], NULL, lt_worker, (void *)(intptr_t)i) != 0) break;
        lt_count++;
    }
    if (lt_count == 0) lt_run = 0;
    return lt_count;
}

void LT_Stop(void)
{
    int i;
    lt_run = 0;
    for (i = 0; i < lt_count; i++) pthread_join(lt_thr[i], NULL);
    lt_count = 0;
}

int LT_Running(void)
{
    return lt_run ? -1 : 0;
}
