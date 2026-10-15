#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "_cgo_export.h"

static JavaVM *vm;
static pthread_mutex_t callback_lock = PTHREAD_MUTEX_INITIALIZER;
static jobject protector;
static jmethodID protect_method;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *machine, void *reserved) {
    (void)reserved;
    vm = machine;
    return JNI_VERSION_1_6;
}

static void clear_protector(JNIEnv *env) {
    pthread_mutex_lock(&callback_lock);
    if (protector) (*env)->DeleteGlobalRef(env, protector);
    protector = NULL;
    protect_method = NULL;
    pthread_mutex_unlock(&callback_lock);
}

int native_protect(int fd) {
    JNIEnv *env = NULL;
    int attached = 0;
    jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return 0;
        attached = 1;
    } else if (status != JNI_OK) return 0;
    pthread_mutex_lock(&callback_lock);
    // A local ref keeps the callback alive if stop deletes the global ref mid-call.
    jobject local = protector ? (*env)->NewLocalRef(env, protector) : NULL;
    jmethodID method = protect_method;
    pthread_mutex_unlock(&callback_lock);
    jboolean accepted = JNI_FALSE;
    if (local && method) accepted = (*env)->CallBooleanMethod(env, local, method, fd);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        accepted = JNI_FALSE;
    }
    if (local) (*env)->DeleteLocalRef(env, local);
    if (attached) (*vm)->DetachCurrentThread(vm);
    return accepted == JNI_TRUE;
}

// Go returns standard UTF-8; NewStringUTF expects JNI modified UTF-8 instead.
static jstring take_result(JNIEnv *env, char *text) {
    const char *value = text ? text : "native allocation failed";
    jsize length = (jsize)strlen(value);
    jbyteArray bytes = (*env)->NewByteArray(env, length);
    if (!bytes) { free(text); return NULL; }
    (*env)->SetByteArrayRegion(env, bytes, 0, length, (const jbyte *)value);
    free(text);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->DeleteLocalRef(env, bytes);
        return NULL;
    }
    jclass cls = (*env)->FindClass(env, "java/lang/String");
    if (!cls) { (*env)->DeleteLocalRef(env, bytes); return NULL; }
    jmethodID constructor = (*env)->GetMethodID(env, cls, "<init>", "([BLjava/lang/String;)V");
    if (!constructor) {
        (*env)->DeleteLocalRef(env, bytes);
        (*env)->DeleteLocalRef(env, cls);
        return NULL;
    }
    jstring encoding = (*env)->NewStringUTF(env, "UTF-8");
    jstring result = NULL;
    if (constructor && encoding && !(*env)->ExceptionCheck(env)) {
        result = (*env)->NewObject(env, cls, constructor, bytes, encoding);
    }
    if (encoding) (*env)->DeleteLocalRef(env, encoding);
    (*env)->DeleteLocalRef(env, bytes);
    (*env)->DeleteLocalRef(env, cls);
    return result;
}

#define METHOD(name) Java_io_github_monadboxlab_clashpseudo_nativecore_NativeCore_##name

JNIEXPORT jstring JNICALL METHOD(version)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreVersion());
}

JNIEXPORT jstring JNICALL METHOD(prepare)(JNIEnv *env, jclass cls, jstring home, jbyteArray body, jstring mode, jobject callback, jbyteArray choices) {
    (void)cls;
    jclass callback_class = (*env)->GetObjectClass(env, callback);
    if (!callback_class) return NULL;
    jmethodID method = (*env)->GetMethodID(env, callback_class, "protectSocket", "(I)Z");
    (*env)->DeleteLocalRef(env, callback_class);
    if (!method) return NULL;
    const char *home_chars = (*env)->GetStringUTFChars(env, home, NULL);
    if (!home_chars) return NULL;
    const char *mode_chars = (*env)->GetStringUTFChars(env, mode, NULL);
    if (!mode_chars) {
        (*env)->ReleaseStringUTFChars(env, home, home_chars);
        return NULL;
    }
    jsize body_length = (*env)->GetArrayLength(env, body);
    jbyte *body_chars = (*env)->GetByteArrayElements(env, body, NULL);
    if (!body_chars) {
        (*env)->ReleaseStringUTFChars(env, mode, mode_chars);
        (*env)->ReleaseStringUTFChars(env, home, home_chars);
        return NULL;
    }
    jsize choices_length = (*env)->GetArrayLength(env, choices);
    jbyte *choices_chars = (*env)->GetByteArrayElements(env, choices, NULL);
    if (!choices_chars) {
        (*env)->ReleaseStringUTFChars(env, mode, mode_chars);
        (*env)->ReleaseStringUTFChars(env, home, home_chars);
        (*env)->ReleaseByteArrayElements(env, body, body_chars, JNI_ABORT);
        return NULL;
    }
    pthread_mutex_lock(&callback_lock);
    if (protector) {
        pthread_mutex_unlock(&callback_lock);
        (*env)->ReleaseByteArrayElements(env, choices, choices_chars, JNI_ABORT);
        (*env)->ReleaseStringUTFChars(env, mode, mode_chars);
        (*env)->ReleaseStringUTFChars(env, home, home_chars);
        (*env)->ReleaseByteArrayElements(env, body, body_chars, JNI_ABORT);
        return (*env)->NewStringUTF(env, "native protector is already in use");
    }
    protector = (*env)->NewGlobalRef(env, callback);
    protect_method = method;
    int ready = protector != NULL;
    pthread_mutex_unlock(&callback_lock);
    char *error = ready ? CorePrepare((char *)home_chars, (char *)body_chars, body_length,
                                      (char *)mode_chars, (char *)choices_chars, choices_length) : NULL;
    (*env)->ReleaseByteArrayElements(env, choices, choices_chars, JNI_ABORT);
    (*env)->ReleaseStringUTFChars(env, mode, mode_chars);
    (*env)->ReleaseStringUTFChars(env, home, home_chars);
    (*env)->ReleaseByteArrayElements(env, body, body_chars, JNI_ABORT);
    if (!ready) return NULL;
    if (error && error[0]) clear_protector(env);
    return take_result(env, error);
}

JNIEXPORT jstring JNICALL METHOD(strategies)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreStrategies());
}

JNIEXPORT jstring JNICALL METHOD(setStrategy)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    jsize length = (*env)->GetArrayLength(env, request);
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *error = CoreSetStrategy((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, error);
}

JNIEXPORT jstring JNICALL METHOD(mode)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreMode());
}

JNIEXPORT jstring JNICALL METHOD(setMode)(JNIEnv *env, jclass cls, jstring mode) {
    (void)cls;
    const char *chars = (*env)->GetStringUTFChars(env, mode, NULL);
    if (!chars) return NULL;
    char *error = CoreSetMode((char *)chars);
    (*env)->ReleaseStringUTFChars(env, mode, chars);
    return take_result(env, error);
}

JNIEXPORT jstring JNICALL METHOD(attach)(JNIEnv *env, jclass cls, jint fd, jint mtu, jstring address, jint prefix_length) {
    (void)cls;
    const char *address_chars = (*env)->GetStringUTFChars(env, address, NULL);
    if (!address_chars) {
        // Kotlin has already detached fd; even a JNI allocation failure owns it here.
        if (fd >= 0) close(fd);
        return NULL;
    }
    char *error = CoreAttach(fd, mtu, (char *)address_chars, prefix_length);
    (*env)->ReleaseStringUTFChars(env, address, address_chars);
    return take_result(env, error);
}

JNIEXPORT void JNICALL METHOD(cancel)(JNIEnv *env, jclass cls) {
    (void)env; (void)cls;
    CoreCancel();
}

JNIEXPORT jstring JNICALL METHOD(stop)(JNIEnv *env, jclass cls) {
    (void)cls;
    char *error = CoreStop();
    clear_protector(env);
    return take_result(env, error);
}

JNIEXPORT jstring JNICALL METHOD(snapshot)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreSnapshot());
}
