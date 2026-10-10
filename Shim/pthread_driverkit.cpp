//
//  pthread_driverkit.cpp
//  RTL-SDR
//
//  POSIX threads (the subset declared in include/pthread.h) on top of
//  DriverKit:
//    * mutexes are IOLocks, recursive ones IORecursiveLocks,
//    * a thread is a block on its own IODispatchQueue,
//    * condition variables and pthread_join() poll with IOSleep(1). librtlsdr
//      only waits on them in its software AGC worker, which is off unless
//      enabled through rtlsdr_set_opt_string().
//

#include <stdint.h>
#include <stddef.h>

#include <DriverKit/IOLib.h>
#include <DriverKit/IODispatchQueue.h>

#include "include/errno.h"
#include "include/pthread.h"

struct rtlsdr_shim_thread {
    IODispatchQueue *queue;
    void            *(*start)(void *);
    void            *arg;
    void            *result;
    bool             finished;          /* atomic */
};

struct rtlsdr_shim_cond {
    uint64_t         signals;           /* atomic */
};

/* ===========================================================================
 * MARK: - Mutexes
 * ======================================================================== */

int pthread_mutexattr_init(pthread_mutexattr_t *attr)
{
    attr->type = PTHREAD_MUTEX_DEFAULT;
    return 0;
}

int pthread_mutexattr_destroy(pthread_mutexattr_t *attr)
{
    (void)attr;
    return 0;
}

int pthread_mutexattr_settype(pthread_mutexattr_t *attr, int type)
{
    if (type != PTHREAD_MUTEX_NORMAL && type != PTHREAD_MUTEX_RECURSIVE)
        return EINVAL;
    attr->type = type;
    return 0;
}

int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr)
{
    mutex->type = attr ? attr->type : PTHREAD_MUTEX_DEFAULT;
    if (mutex->type == PTHREAD_MUTEX_RECURSIVE)
        mutex->lock = IORecursiveLockAlloc();
    else
        mutex->lock = IOLockAlloc();
    return mutex->lock ? 0 : ENOMEM;
}

int pthread_mutex_destroy(pthread_mutex_t *mutex)
{
    if (!mutex->lock)
        return EINVAL;
    if (mutex->type == PTHREAD_MUTEX_RECURSIVE)
        IORecursiveLockFree((IORecursiveLock *)mutex->lock);
    else
        IOLockFree((IOLock *)mutex->lock);
    mutex->lock = nullptr;
    return 0;
}

int pthread_mutex_lock(pthread_mutex_t *mutex)
{
    if (!mutex->lock)
        return EINVAL;
    if (mutex->type == PTHREAD_MUTEX_RECURSIVE)
        IORecursiveLockLock((IORecursiveLock *)mutex->lock);
    else
        IOLockLock((IOLock *)mutex->lock);
    return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *mutex)
{
    if (!mutex->lock)
        return EINVAL;
    if (mutex->type == PTHREAD_MUTEX_RECURSIVE)
        IORecursiveLockUnlock((IORecursiveLock *)mutex->lock);
    else
        IOLockUnlock((IOLock *)mutex->lock);
    return 0;
}

/* ===========================================================================
 * MARK: - Condition variables
 * ======================================================================== */

int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr)
{
    (void)attr;
    cond->impl = IONewZero(rtlsdr_shim_cond, 1);
    return cond->impl ? 0 : ENOMEM;
}

int pthread_cond_destroy(pthread_cond_t *cond)
{
    rtlsdr_shim_cond *c = (rtlsdr_shim_cond *)cond->impl;
    IOSafeDeleteNULL(c, rtlsdr_shim_cond, 1);
    cond->impl = nullptr;
    return 0;
}

/* Waits until the signal count moves past the value seen while `mutex` was
 * still held, so a signal sent under the same mutex is never lost. */
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex)
{
    rtlsdr_shim_cond *c = (rtlsdr_shim_cond *)cond->impl;
    if (!c)
        return EINVAL;

    uint64_t seen = __atomic_load_n(&c->signals, __ATOMIC_ACQUIRE);
    pthread_mutex_unlock(mutex);
    while (__atomic_load_n(&c->signals, __ATOMIC_ACQUIRE) == seen)
        IOSleep(1);
    pthread_mutex_lock(mutex);
    return 0;
}

/* Wakes all waiters, which POSIX allows. */
int pthread_cond_signal(pthread_cond_t *cond)
{
    rtlsdr_shim_cond *c = (rtlsdr_shim_cond *)cond->impl;
    if (!c)
        return EINVAL;
    __atomic_fetch_add(&c->signals, 1ull, __ATOMIC_RELEASE);
    return 0;
}

/* ===========================================================================
 * MARK: - Threads
 * ======================================================================== */

int pthread_attr_init(pthread_attr_t *attr)
{
    attr->detachstate = PTHREAD_CREATE_JOINABLE;
    return 0;
}

int pthread_attr_destroy(pthread_attr_t *attr)
{
    (void)attr;
    return 0;
}

int pthread_attr_setdetachstate(pthread_attr_t *attr, int detachstate)
{
    if (detachstate != PTHREAD_CREATE_JOINABLE)
        return EINVAL;                  /* every thread must be joined */
    attr->detachstate = detachstate;
    return 0;
}

int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
                   void *(*start_routine)(void *), void *arg)
{
    (void)attr;
    rtlsdr_shim_thread *th = IONewZero(rtlsdr_shim_thread, 1);
    if (!th)
        return EAGAIN;

    kern_return_t ret = IODispatchQueue::Create("pthread", 0, 0, &th->queue);
    if (ret != kIOReturnSuccess || !th->queue) {
        IOSafeDeleteNULL(th, rtlsdr_shim_thread, 1);
        return EAGAIN;
    }
    th->start = start_routine;
    th->arg   = arg;
    th->queue->DispatchAsync(^{
        th->result = th->start(th->arg);
        __atomic_store_n(&th->finished, true, __ATOMIC_RELEASE);
    });
    *thread = th;
    return 0;
}

int pthread_join(pthread_t thread, void **value_ptr)
{
    if (!thread)
        return EINVAL;
    while (!__atomic_load_n(&thread->finished, __ATOMIC_ACQUIRE))
        IOSleep(1);
    if (value_ptr)
        *value_ptr = thread->result;
    OSSafeReleaseNULL(thread->queue);
    IOSafeDeleteNULL(thread, rtlsdr_shim_thread, 1);
    return 0;
}
