//
//  pthread.h
//  RTL-SDR
//
//  The part of the POSIX threads API that librtlsdr uses, implemented on top
//  of DriverKit locks and dispatch queues in ../pthread_driverkit.cpp.
//
//  librtlsdr uses a recursive mutex around I2C register sequences and, only
//  when its software AGC is enabled, a worker thread with a condition
//  variable.
//

#ifndef RTLSDR_SHIM_PTHREAD_H
#define RTLSDR_SHIM_PTHREAD_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct rtlsdr_shim_thread *pthread_t;

typedef struct {
	int type;
} pthread_mutexattr_t;

typedef struct {
	void *lock;     /* IOLock or IORecursiveLock */
	int   type;
} pthread_mutex_t;

typedef struct {
	void *impl;
} pthread_cond_t;

typedef struct {
	int detachstate;
} pthread_attr_t;

typedef struct {
	int unused;
} pthread_condattr_t;

#define PTHREAD_MUTEX_NORMAL     0
#define PTHREAD_MUTEX_RECURSIVE  2
#define PTHREAD_MUTEX_DEFAULT    PTHREAD_MUTEX_NORMAL

#define PTHREAD_CREATE_JOINABLE  1
#define PTHREAD_CREATE_DETACHED  2

int pthread_mutexattr_init(pthread_mutexattr_t *attr);
int pthread_mutexattr_destroy(pthread_mutexattr_t *attr);
int pthread_mutexattr_settype(pthread_mutexattr_t *attr, int type);

int pthread_mutex_init(pthread_mutex_t *mutex, const pthread_mutexattr_t *attr);
int pthread_mutex_destroy(pthread_mutex_t *mutex);
int pthread_mutex_lock(pthread_mutex_t *mutex);
int pthread_mutex_unlock(pthread_mutex_t *mutex);

int pthread_cond_init(pthread_cond_t *cond, const pthread_condattr_t *attr);
int pthread_cond_destroy(pthread_cond_t *cond);
int pthread_cond_wait(pthread_cond_t *cond, pthread_mutex_t *mutex);
int pthread_cond_signal(pthread_cond_t *cond);

int pthread_attr_init(pthread_attr_t *attr);
int pthread_attr_destroy(pthread_attr_t *attr);
int pthread_attr_setdetachstate(pthread_attr_t *attr, int detachstate);

/* Each thread runs on its own IODispatchQueue. */
int pthread_create(pthread_t *thread, const pthread_attr_t *attr,
	void *(*start_routine)(void *), void *arg);
int pthread_join(pthread_t thread, void **value_ptr);

/* A dispatch block cannot be left from inside a nested call. librtlsdr calls
 * pthread_exit() only directly in its thread function, where returning the
 * value is equivalent. */
#define pthread_exit(value_ptr) return (value_ptr)

#ifdef __cplusplus
}
#endif

#endif /* RTLSDR_SHIM_PTHREAD_H */
