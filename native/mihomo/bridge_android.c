#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "_cgo_export.h"
#include "application_contract.h"

static JavaVM *vm;
static pthread_mutex_t callback_lock = PTHREAD_MUTEX_INITIALIZER;
static jobject protector;
static jmethodID protect_method;
static jmethodID protect_network_method;
static jmethodID seed_method;
static jmethodID specification_method;

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
    protect_network_method = NULL;
    seed_method = NULL;
    specification_method = NULL;
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

static JNIEnv *callback_env(int *attached) {
    JNIEnv *env = NULL;
    *attached = 0;
    jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return NULL;
        *attached = 1;
    } else if (status != JNI_OK) return NULL;
    return env;
}

int native_protect_network(int fd, char *handle) {
    int attached;
    JNIEnv *env = callback_env(&attached);
    if (!env) return 0;
    pthread_mutex_lock(&callback_lock);
    jobject local = protector ? (*env)->NewLocalRef(env, protector) : NULL;
    jmethodID method = protect_network_method;
    pthread_mutex_unlock(&callback_lock);
    jstring network = (*env)->NewStringUTF(env, handle);
    jboolean accepted = JNI_FALSE;
    if (local && method && network && !(*env)->ExceptionCheck(env))
        accepted = (*env)->CallBooleanMethod(env, local, method, fd, network);
    if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); accepted = JNI_FALSE; }
    if (network) (*env)->DeleteLocalRef(env, network);
    if (local) (*env)->DeleteLocalRef(env, local);
    if (attached) (*vm)->DetachCurrentThread(vm);
    return accepted == JNI_TRUE;
}

int native_seed_geo_available(void) {
    pthread_mutex_lock(&callback_lock);
    int available = protector != NULL && seed_method != NULL;
    pthread_mutex_unlock(&callback_lock);
    return available;
}

char *native_seed_geo(char *request) {
    int attached;
    JNIEnv *env = callback_env(&attached);
    if (!env) return strdup("bundled Geo callback thread is unavailable");
    pthread_mutex_lock(&callback_lock);
    jobject local = protector ? (*env)->NewLocalRef(env, protector) : NULL;
    jmethodID method = seed_method;
    pthread_mutex_unlock(&callback_lock);
    jstring input = take_result(env, strdup(request));
    jstring response = NULL;
    if (local && method && input && !(*env)->ExceptionCheck(env))
        response = (*env)->CallObjectMethod(env, local, method, input);
    char *result = NULL;
    if (!(*env)->ExceptionCheck(env) && response) {
        const char *text = (*env)->GetStringUTFChars(env, response, NULL);
        if (text) { result = strdup(text); (*env)->ReleaseStringUTFChars(env, response, text); }
    }
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (!result) result = strdup("bundled Geo installation failed or was cancelled");
    if (input) (*env)->DeleteLocalRef(env, input);
    if (response) (*env)->DeleteLocalRef(env, response);
    if (local) (*env)->DeleteLocalRef(env, local);
    if (attached) (*vm)->DetachCurrentThread(vm);
    return result;
}

void native_specification_changed(long long generation, char *composition, long long revision, int needed) {
    int attached;
    JNIEnv *env = callback_env(&attached);
    if (!env) return;
    pthread_mutex_lock(&callback_lock);
    jobject local = protector ? (*env)->NewLocalRef(env, protector) : NULL;
    jmethodID method = specification_method;
    pthread_mutex_unlock(&callback_lock);
    jstring value = take_result(env, strdup(composition));
    if (local && method && value && !(*env)->ExceptionCheck(env))
        (*env)->CallVoidMethod(env, local, method, (jlong)generation, value, (jlong)revision, needed ? JNI_TRUE : JNI_FALSE);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (value) (*env)->DeleteLocalRef(env, value);
    if (local) (*env)->DeleteLocalRef(env, local);
    if (attached) (*vm)->DetachCurrentThread(vm);
}

#define METHOD(name) Java_io_github_monadboxlab_clashpseudo_nativecore_NativeCore_##name
#define MAX_PREPARATION_OPTIONS_BYTES APP_CONFIGURATION_PREPARATION_OPTIONS_BYTES

// Rejections must still be valid JSON; a null return would crash Kotlin callers.
static jstring reject(JNIEnv *env, const char *json) {
    char *copy = malloc(strlen(json) + 1);
    if (!copy) return take_result(env, NULL);
    memcpy(copy, json, strlen(json) + 1);
    return take_result(env, copy);
}

JNIEXPORT jstring JNICALL METHOD(initializeTrust)(JNIEnv *env, jclass cls, jbyteArray material) {
    (void)cls;
    if (!material || (*env)->GetArrayLength(env, material) > (4 << 20)) return reject(env, "invalid trust material");
    jsize length = (*env)->GetArrayLength(env, material);
    jbyte *bytes = (*env)->GetByteArrayElements(env, material, NULL);
    if (!bytes) return NULL;
    char *error = CoreInitializeTrust((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, material, bytes, JNI_ABORT);
    return take_result(env, error);
}

JNIEXPORT jstring JNICALL METHOD(vpnSpec)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreVpnSpec());
}

JNIEXPORT jstring JNICALL METHOD(updateNetwork)(JNIEnv *env, jclass cls, jbyteArray snapshot) {
    (void)cls;
    if (!snapshot || (*env)->GetArrayLength(env, snapshot) > 65536) return reject(env, "{\"error\":\"invalid network snapshot\"}");
    jsize length = (*env)->GetArrayLength(env, snapshot);
    jbyte *bytes = (*env)->GetByteArrayElements(env, snapshot, NULL);
    if (!bytes) return NULL;
    char *result = CoreUpdateNetwork((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, snapshot, bytes, JNI_ABORT);
    return take_result(env, result);
}

JNIEXPORT jstring JNICALL METHOD(version)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreVersion());
}

JNIEXPORT jstring JNICALL METHOD(prepare)(JNIEnv *env, jclass cls, jstring home, jbyteArray body, jstring mode, jobject callback, jbyteArray choices, jbyteArray overrides, jbyteArray options) {
    (void)cls;
    if (!home || !mode || !callback || !body || !choices || !overrides || !options ||
        (*env)->GetArrayLength(env, body) > APP_CONFIGURATION_TEXT_BYTES ||
        (*env)->GetArrayLength(env, choices) > (1 << 20) ||
        (*env)->GetArrayLength(env, overrides) > APP_CONFIGURATION_OVERRIDE_JSON_BYTES)
        return reject(env, "configuration input exceeds limit");
    const jsize options_length = (*env)->GetArrayLength(env, options);
    if (options_length <= 0 || options_length > MAX_PREPARATION_OPTIONS_BYTES)
        return reject(env, "invalid native preparation options");
    jclass callback_class = (*env)->GetObjectClass(env, callback);
    if (!callback_class) return NULL;
    jmethodID method = (*env)->GetMethodID(env, callback_class, "protectSocket", "(I)Z");
    (*env)->DeleteLocalRef(env, callback_class);
    if (!method) return NULL;
    jmethodID seed = NULL, specification = NULL, network_protect = NULL;
    jclass callbacks = (*env)->FindClass(env, "io/github/monadboxlab/clashpseudo/nativecore/NativeCore$PreparationCallbacks");
    if (!callbacks) return NULL;
    if ((*env)->IsInstanceOf(env, callback, callbacks)) {
        network_protect = (*env)->GetMethodID(env, callbacks, "protectSocketOnNetwork", "(ILjava/lang/String;)Z");
        seed = (*env)->GetMethodID(env, callbacks, "seedGeo", "(Ljava/lang/String;)Ljava/lang/String;");
        specification = (*env)->GetMethodID(env, callbacks, "specificationChanged", "(JLjava/lang/String;JZ)V");
    }
    (*env)->DeleteLocalRef(env, callbacks);
    if ((*env)->ExceptionCheck(env)) return NULL;
    const char *home_chars = NULL, *mode_chars = NULL;
    jbyte *body_chars = NULL, *choices_chars = NULL, *overrides_chars = NULL, *options_chars = NULL;
    char *error = NULL;
    int installed = 0;
    home_chars = (*env)->GetStringUTFChars(env, home, NULL);
    if (!home_chars) goto cleanup;
    mode_chars = (*env)->GetStringUTFChars(env, mode, NULL);
    if (!mode_chars) goto cleanup;
    body_chars = (*env)->GetByteArrayElements(env, body, NULL);
    if (!body_chars) goto cleanup;
    choices_chars = (*env)->GetByteArrayElements(env, choices, NULL);
    if (!choices_chars) goto cleanup;
    overrides_chars = (*env)->GetByteArrayElements(env, overrides, NULL);
    if (!overrides_chars) goto cleanup;
    options_chars = (*env)->GetByteArrayElements(env, options, NULL);
    if (!options_chars) goto cleanup;
    pthread_mutex_lock(&callback_lock);
    if (protector) {
        pthread_mutex_unlock(&callback_lock);
        error = strdup("native protector is already in use");
        goto cleanup;
    }
    protector = (*env)->NewGlobalRef(env, callback);
    if (protector) {
        protect_method = method;
        protect_network_method = network_protect;
        seed_method = seed;
        specification_method = specification;
        installed = 1;
    }
    pthread_mutex_unlock(&callback_lock);
    if (!installed) goto cleanup;
    error = CorePrepare((char *)home_chars, (char *)body_chars, (*env)->GetArrayLength(env, body),
                        (char *)mode_chars, (char *)choices_chars, (*env)->GetArrayLength(env, choices),
                        (char *)overrides_chars, (*env)->GetArrayLength(env, overrides),
                        (char *)options_chars, options_length);
cleanup:
    if (options_chars) (*env)->ReleaseByteArrayElements(env, options, options_chars, JNI_ABORT);
    if (overrides_chars) (*env)->ReleaseByteArrayElements(env, overrides, overrides_chars, JNI_ABORT);
    if (choices_chars) (*env)->ReleaseByteArrayElements(env, choices, choices_chars, JNI_ABORT);
    if (body_chars) (*env)->ReleaseByteArrayElements(env, body, body_chars, JNI_ABORT);
    if (mode_chars) (*env)->ReleaseStringUTFChars(env, mode, mode_chars);
    if (home_chars) (*env)->ReleaseStringUTFChars(env, home, home_chars);
    if (installed && (!error || error[0])) clear_protector(env);
    if ((*env)->ExceptionCheck(env)) { free(error); return NULL; }
    return take_result(env, error);
}

JNIEXPORT jstring JNICALL METHOD(strategies)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreStrategies());
}

JNIEXPORT jstring JNICALL METHOD(runtimeConfig)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreRuntimeConfig());
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

JNIEXPORT jstring JNICALL METHOD(attach)(JNIEnv *env, jclass cls, jobject descriptor, jlong revision) {
    (void)cls;
    if (!descriptor || revision <= 0) return reject(env, "invalid TUN attachment arguments");
    jclass descriptor_class = (*env)->FindClass(env, "android/os/ParcelFileDescriptor");
    if (!descriptor_class) return NULL;
    if (!(*env)->IsInstanceOf(env, descriptor, descriptor_class)) {
        (*env)->DeleteLocalRef(env, descriptor_class);
        return reject(env, "invalid TUN descriptor object");
    }
    jmethodID detach = (*env)->GetMethodID(env, descriptor_class, "detachFd", "()I");
    (*env)->DeleteLocalRef(env, descriptor_class);
    if (!detach) return NULL;
    char *error = CoreCanAttach((long long)revision);
    if (!error || error[0]) return take_result(env, error);
    free(error);
    // Kotlin owns the descriptor until this call succeeds. Transfer directly from
    // detach to Go's consuming contract, including fd=0 and cancelled sessions.
    jint fd = (*env)->CallIntMethod(env, descriptor, detach);
    if ((*env)->ExceptionCheck(env)) return NULL;
    return take_result(env, CoreAttach(fd, (long long)revision));
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

JNIEXPORT jstring JNICALL METHOD(nodes)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"invalid node query\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length > 65536) return reject(env, "{\"error\":\"invalid node query\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreNodes((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT jstring JNICALL METHOD(rules)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"invalid rule query\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length > 65536) return reject(env, "{\"error\":\"invalid rule query\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreRules((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT jstring JNICALL METHOD(logs)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"invalidLogQuery\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length > 4096) return reject(env, "{\"error\":\"invalidLogQuery\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreLogs((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT jstring JNICALL METHOD(resources)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreResources());
}

JNIEXPORT jstring JNICALL METHOD(updateResource)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"invalidUpdate\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length <= 0 || length > 4096) return reject(env, "{\"error\":\"invalidUpdate\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreUpdateResource((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT jstring JNICALL METHOD(startDelayTest)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"invalidDelayRequest\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length <= 0 || length > 65536) return reject(env, "{\"error\":\"invalidDelayRequest\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreStartDelayTest((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT jstring JNICALL METHOD(delayTest)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"delayUnavailable\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length <= 0 || length > 512) return reject(env, "{\"error\":\"delayUnavailable\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreDelayTest((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT void JNICALL METHOD(cancelDelayTest)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return;
    jsize length = (*env)->GetArrayLength(env, request);
    if (length <= 0 || length > 512) return;
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return;
    CoreCancelDelayTest((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
}

JNIEXPORT jstring JNICALL METHOD(connections)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"invalid connection query\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length > APP_CONNECTION_REQUEST_BYTES) return reject(env, "{\"error\":\"invalid connection query\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreConnections((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT jstring JNICALL METHOD(closeConnection)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request || (*env)->GetArrayLength(env, request) != 36)
        return reject(env, "{\"status\":\"failed\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreCloseConnection((char *)bytes, 36);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT jstring JNICALL METHOD(processMemory)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreProcessMemory());
}

JNIEXPORT jstring JNICALL METHOD(dnsQuery)(JNIEnv *env, jclass cls, jbyteArray request) {
    (void)cls;
    if (!request) return reject(env, "{\"error\":\"invalidRequest\"}");
    jsize length = (*env)->GetArrayLength(env, request);
    if (length <= 0 || length > APP_DNS_REQUEST_BYTES) return reject(env, "{\"error\":\"invalidRequest\"}");
    jbyte *bytes = (*env)->GetByteArrayElements(env, request, NULL);
    if (!bytes) return NULL;
    char *value = CoreDNSQuery((char *)bytes, length);
    (*env)->ReleaseByteArrayElements(env, request, bytes, JNI_ABORT);
    return take_result(env, value);
}

JNIEXPORT void JNICALL METHOD(cancelDnsQuery)(JNIEnv *env, jclass cls, jlong request_id) {
    (void)env; (void)cls;
    CoreCancelDNSQuery((long long)request_id);
}

JNIEXPORT jstring JNICALL METHOD(clearDnsCache)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreClearDNSCache());
}

JNIEXPORT jstring JNICALL METHOD(flushFakeIp)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreFlushFakeIP());
}

JNIEXPORT jstring JNICALL METHOD(snapshot)(JNIEnv *env, jclass cls) {
    (void)cls;
    return take_result(env, CoreSnapshot());
}
