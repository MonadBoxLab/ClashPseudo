#include <errno.h>
#include <jni.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include "_cgo_export.h"
#include "application_contract.h"
#include "native_bridge.h"

static JavaVM *vm;
static pthread_mutex_t callback_lock = PTHREAD_MUTEX_INITIALIZER;
static jobject callbacks;
static jmethodID protect_method, network_method, dns_method, lookup_method;
static jmethodID cancel_dns_method, seed_method, specification_method;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *machine, void *reserved) {
    (void)reserved; vm = machine; return JNI_VERSION_1_6;
}

static JNIEnv *callback_env(int *attached) {
    JNIEnv *env = NULL; *attached = 0;
    jint status = (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6);
    if (status == JNI_EDETACHED) {
        if ((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) != JNI_OK) return NULL;
        *attached = 1;
    } else if (status != JNI_OK) return NULL;
    return env;
}

static jbyteArray bytes(JNIEnv *env, const char *data, jsize size) {
    jbyteArray value = (*env)->NewByteArray(env, size);
    if (value && size) (*env)->SetByteArrayRegion(env, value, 0, size, (const jbyte *)data);
    if ((*env)->ExceptionCheck(env)) { if (value) (*env)->DeleteLocalRef(env, value); return NULL; }
    return value;
}

/* 标准UTF-8不经过JNI modified UTF-8。 */
static jstring utf8_string(JNIEnv *env, const char *data) {
    jbyteArray value = bytes(env, data, (jsize)strlen(data));
    if (!value || (*env)->ExceptionCheck(env)) return NULL;
    jclass cls = (*env)->FindClass(env, "java/lang/String");
    jmethodID constructor = cls ? (*env)->GetMethodID(env, cls, "<init>", "([BLjava/lang/String;)V") : NULL;
    jstring charset = constructor ? (*env)->NewStringUTF(env, "UTF-8") : NULL;
    jstring result = constructor && charset ? (*env)->NewObject(env, cls, constructor, value, charset) : NULL;
    if (charset) (*env)->DeleteLocalRef(env, charset);
    if (cls) (*env)->DeleteLocalRef(env, cls);
    (*env)->DeleteLocalRef(env, value);
    return result;
}
static char *copy_bytes(JNIEnv *env, jbyteArray value, int limit) {
    if (!value || (*env)->ExceptionCheck(env)) return NULL;
    jsize size = (*env)->GetArrayLength(env, value);
    if (size < 0 || size > limit) return NULL;
    char *out = malloc((size_t)size + 1);
    if (!out) return NULL;
    if (size) (*env)->GetByteArrayRegion(env, value, 0, size, (jbyte *)out);
    if ((*env)->ExceptionCheck(env)) { free(out); return NULL; }
    out[size] = 0;
    return out;
}
static char *copy_string(JNIEnv *env, jstring value) {
    if (!value || (*env)->ExceptionCheck(env)) return NULL;
    jclass cls = (*env)->FindClass(env, "java/lang/String");
    jmethodID method = cls ? (*env)->GetMethodID(env, cls, "getBytes", "(Ljava/lang/String;)[B") : NULL;
    jstring charset = method ? (*env)->NewStringUTF(env, "UTF-8") : NULL;
    jbyteArray encoded = method && charset ? (*env)->CallObjectMethod(env, value, method, charset) : NULL;
    char *out = copy_bytes(env, encoded, APP_CORE_IPC_CONTROL_BYTES);
    if (encoded) (*env)->DeleteLocalRef(env, encoded);
    if (charset) (*env)->DeleteLocalRef(env, charset);
    if (cls) (*env)->DeleteLocalRef(env, cls);
    return out;
}
static char *json_error(const char *message) {
    const char *prefix = "{\"accepted\":false,\"exited\":true,\"ok\":false,\"error\":{\"code\":\"callFailed\",\"message\":\"";
    const char *suffix = "\"}}";
    size_t length = strlen(message);
    char *out = malloc(strlen(prefix) + length * 6 + strlen(suffix) + 1);
    if (!out) return NULL;
    char *p = out; memcpy(p, prefix, strlen(prefix)); p += strlen(prefix);
    for (size_t i = 0; i < length; i++) {
        unsigned char c = (unsigned char)message[i];
        if (c == '"' || c == '\\') { *p++ = '\\'; *p++ = (char)c; }
        else if (c < 32) { snprintf(p, 7, "\\u%04x", c); p += 6; }
        else *p++ = (char)c;
    }
    memcpy(p, suffix, strlen(suffix) + 1); return out;
}

/* 原始Java异常的堆栈保留cause及suppressed文字。 */
static char *exception_result(JNIEnv *env) {
    jthrowable failure = (*env)->ExceptionOccurred(env);
    if (!failure) return NULL;
    (*env)->ExceptionClear(env);
    jclass sw_cls = (*env)->FindClass(env, "java/io/StringWriter");
    jclass pw_cls = sw_cls ? (*env)->FindClass(env, "java/io/PrintWriter") : NULL;
    jclass th_cls = pw_cls ? (*env)->FindClass(env, "java/lang/Throwable") : NULL;
    jmethodID sw_init = th_cls ? (*env)->GetMethodID(env, sw_cls, "<init>", "()V") : NULL;
    jmethodID pw_init = sw_init ? (*env)->GetMethodID(env, pw_cls, "<init>", "(Ljava/io/Writer;)V") : NULL;
    jmethodID print = pw_init ? (*env)->GetMethodID(env, th_cls, "printStackTrace", "(Ljava/io/PrintWriter;)V") : NULL;
    jmethodID text = print ? (*env)->GetMethodID(env, sw_cls, "toString", "()Ljava/lang/String;") : NULL;
    jobject sw = text ? (*env)->NewObject(env, sw_cls, sw_init) : NULL;
    jobject pw = pw_init && sw ? (*env)->NewObject(env, pw_cls, pw_init, sw) : NULL;
    if (print && pw) (*env)->CallVoidMethod(env, failure, print, pw);
    jstring trace = text && sw && !(*env)->ExceptionCheck(env) ? (*env)->CallObjectMethod(env, sw, text) : NULL;
    char *detail = trace ? copy_string(env, trace) : NULL;
    char *result = json_error(detail ? detail : "Java callback exception could not be serialized");
    free(detail);
    if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    if (trace) (*env)->DeleteLocalRef(env, trace);
    if (pw) (*env)->DeleteLocalRef(env, pw);
    if (sw) (*env)->DeleteLocalRef(env, sw);
    if (sw_cls) (*env)->DeleteLocalRef(env, sw_cls);
    if (pw_cls) (*env)->DeleteLocalRef(env, pw_cls);
    if (th_cls) (*env)->DeleteLocalRef(env, th_cls);
    (*env)->DeleteLocalRef(env, failure);
    return result;
}

static char *callback_result(JNIEnv *env, jbyteArray value, int limit) {
    char *error = exception_result(env);
    if (error) return error;
    char *result = copy_bytes(env, value, limit);
    error = exception_result(env);
    if (error) { free(result); return error; }
    if (!result) return json_error("Android callback returned no bytes or exceeded its byte limit");
    return result;
}
static jobject local_callbacks(JNIEnv *env) {
    pthread_mutex_lock(&callback_lock);
    jobject local = callbacks ? (*env)->NewLocalRef(env, callbacks) : NULL;
    pthread_mutex_unlock(&callback_lock);
    return local;
}
static void finish_callback(JNIEnv *env, jobject local, int attached) {
    if (local) (*env)->DeleteLocalRef(env, local);
    if (attached) (*vm)->DetachCurrentThread(vm);
}

char *native_protect(int fd) {
    int attached; JNIEnv *env = callback_env(&attached);
    if (!env) return json_error("JNI callback thread is unavailable");
    jobject local = local_callbacks(env);
    jbyteArray value = local ? (*env)->CallObjectMethod(env, local, protect_method, (jint)fd) : NULL;
    char *result = callback_result(env, value, APP_CORE_IPC_CONTROL_BYTES);
    if (value) (*env)->DeleteLocalRef(env, value);
    finish_callback(env, local, attached); return result;
}
char *native_protect_network(int fd, char *handle) {
    int attached; JNIEnv *env = callback_env(&attached);
    if (!env) return json_error("JNI callback thread is unavailable");
    jobject local = local_callbacks(env); jstring network = local ? utf8_string(env, handle) : NULL;
    jbyteArray value = local && network && !(*env)->ExceptionCheck(env) ? (*env)->CallObjectMethod(env, local, network_method, (jint)fd, network) : NULL;
    char *result = callback_result(env, value, APP_CORE_IPC_CONTROL_BYTES);
    if (value) (*env)->DeleteLocalRef(env, value);
    if (network) (*env)->DeleteLocalRef(env, network);
    finish_callback(env, local, attached); return result;
}
char *native_system_dns(long long request_id, char *wire, int size) {
    int attached; JNIEnv *env = callback_env(&attached);
    if (!env) return json_error("JNI callback thread is unavailable");
    jobject local = local_callbacks(env); jbyteArray input = local ? bytes(env, wire, size) : NULL;
    jbyteArray value = local && input && !(*env)->ExceptionCheck(env) ? (*env)->CallObjectMethod(env, local, dns_method, (jlong)request_id, input) : NULL;
    char *result = callback_result(env, value, APP_DNS_RESULT_BYTES);
    if (value) (*env)->DeleteLocalRef(env, value);
    if (input) (*env)->DeleteLocalRef(env, input);
    finish_callback(env, local, attached); return result;
}
char *native_system_lookup(long long request_id, char *host, int family) {
    int attached; JNIEnv *env = callback_env(&attached);
    if (!env) return json_error("JNI callback thread is unavailable");
    jobject local = local_callbacks(env); jstring name = local ? utf8_string(env, host) : NULL;
    jbyteArray value = local && name && !(*env)->ExceptionCheck(env) ? (*env)->CallObjectMethod(env, local, lookup_method, (jlong)request_id, name, (jint)family) : NULL;
    char *result = callback_result(env, value, APP_DNS_RESULT_BYTES);
    if (value) (*env)->DeleteLocalRef(env, value);
    if (name) (*env)->DeleteLocalRef(env, name);
    finish_callback(env, local, attached); return result;
}
char *native_cancel_system_dns(long long request_id) {
    int attached; JNIEnv *env = callback_env(&attached);
    if (!env) return json_error("JNI callback thread is unavailable");
    jobject local = local_callbacks(env);
    jbyteArray value = local ? (*env)->CallObjectMethod(env, local, cancel_dns_method, (jlong)request_id) : NULL;
    char *result = callback_result(env, value, APP_CORE_IPC_CONTROL_BYTES);
    if (value) (*env)->DeleteLocalRef(env, value);
    finish_callback(env, local, attached); return result;
}
char *native_seed_geo(char *request, int size) {
    int attached; JNIEnv *env = callback_env(&attached);
    if (!env) return json_error("JNI callback thread is unavailable");
    jobject local = local_callbacks(env); jbyteArray input = local ? bytes(env, request, size) : NULL;
    jbyteArray value = local && input && !(*env)->ExceptionCheck(env) ? (*env)->CallObjectMethod(env, local, seed_method, input) : NULL;
    char *result = callback_result(env, value, APP_CORE_IPC_CONTROL_BYTES);
    if (value) (*env)->DeleteLocalRef(env, value);
    if (input) (*env)->DeleteLocalRef(env, input);
    finish_callback(env, local, attached); return result;
}
void native_specification_changed(long long revision, int changed) {
    int attached; JNIEnv *env = callback_env(&attached); if (!env) return;
    jobject local = local_callbacks(env);
    if (local) (*env)->CallVoidMethod(env, local, specification_method, (jlong)revision, changed ? JNI_TRUE : JNI_FALSE);
    char *error = exception_result(env);
    if (error) { CoreReportCallbackError(error); free(error); }
    finish_callback(env, local, attached);
}

static int bind_callbacks(JNIEnv *env, jobject object) {
    pthread_mutex_lock(&callback_lock);
    if (callbacks) {
        int same = (*env)->IsSameObject(env, callbacks, object);
        pthread_mutex_unlock(&callback_lock); return same;
    }
    jclass cls = (*env)->GetObjectClass(env, object);
    protect_method = cls ? (*env)->GetMethodID(env, cls, "protect", "(I)[B") : NULL;
    network_method = protect_method ? (*env)->GetMethodID(env, cls, "protectNetwork", "(ILjava/lang/String;)[B") : NULL;
    dns_method = network_method ? (*env)->GetMethodID(env, cls, "systemDns", "(J[B)[B") : NULL;
    lookup_method = dns_method ? (*env)->GetMethodID(env, cls, "systemLookup", "(JLjava/lang/String;I)[B") : NULL;
    cancel_dns_method = lookup_method ? (*env)->GetMethodID(env, cls, "cancelSystemDns", "(J)[B") : NULL;
    seed_method = cancel_dns_method ? (*env)->GetMethodID(env, cls, "seedGeo", "([B)[B") : NULL;
    specification_method = seed_method ? (*env)->GetMethodID(env, cls, "specificationChanged", "(JZ)V") : NULL;
    int ready = protect_method && network_method && dns_method && lookup_method && cancel_dns_method && seed_method && specification_method && !(*env)->ExceptionCheck(env);
    if (ready) callbacks = (*env)->NewGlobalRef(env, object);
    if (cls) (*env)->DeleteLocalRef(env, cls);
    pthread_mutex_unlock(&callback_lock); return ready && callbacks;
}
static jbyteArray take_result(JNIEnv *env, char *text) {
    const char *value = text ? text : "{\"accepted\":false,\"exited\":true,\"error\":{\"code\":\"callFailed\",\"message\":\"native allocation failed\"}}";
    jbyteArray result = bytes(env, value, (jsize)strlen(value)); free(text); return result;
}
static jbyteArray reject(JNIEnv *env, const char *message) {
    char *exception = exception_result(env);
    if (exception) return take_result(env, exception);
    return take_result(env, json_error(message));
}

static jbyteArray reject_handoff(JNIEnv *env, const char *message, int input, int output, int tun) {
    char *original = exception_result(env);
    if (!original) original = json_error(message);
    int descriptors[] = {input, output, tun};
    const char *names[] = {"input", "output", "TUN"};
    char *failures[3] = {NULL, NULL, NULL};
    size_t extra = 0;
    for (int i = 0; i < 3; i++) {
        if (descriptors[i] >= 0 && close(descriptors[i]) != 0) {
            int code = errno;
            char detail[512];
            snprintf(detail, sizeof(detail), "close(%s): errno=%d %s", names[i], code, strerror(code));
            failures[i] = json_error(detail);
            if (failures[i]) extra += strlen(failures[i]) + 1;
        }
    }
    if (original && extra) {
        size_t length = strlen(original);
        char *joined = malloc(length + extra + 24);
        if (joined) {
            memcpy(joined, original, length - 2);
            char *cursor = joined + length - 2;
            memcpy(cursor, ",\"suppressed\":[", 15); cursor += 15;
            int first = 1;
            for (int i = 0; i < 3; i++) {
                if (!failures[i]) continue;
                if (!first) *cursor++ = ',';
                size_t size = strlen(failures[i]);
                memcpy(cursor, failures[i], size); cursor += size; first = 0;
            }
            memcpy(cursor, "]}}", 4);
            free(original); original = joined;
        }
    }
    for (int i = 0; i < 3; i++) free(failures[i]);
    return take_result(env, original);
}

JNIEXPORT jbyteArray JNICALL Java_io_github_monadboxlab_clashpseudo_nativecore_NativeCore_invoke(
        JNIEnv *env, jclass cls, jint operation, jlong request_id,
        jobject input, jobject output, jobject tun, jobject callback) {
    (void)cls;
    if (operation < APP_CORE_OPERATION_PREPARE || operation > APP_CORE_OPERATION_VPN_SPEC || request_id <= 0 || !input || !output || !callback)
        return reject(env, "invalid JNI invocation");
    if ((operation == APP_CORE_OPERATION_ATTACH) != (tun != NULL)) return reject(env, "TUN descriptor must be supplied only for attach");
    jclass pfd = (*env)->FindClass(env, "android/os/ParcelFileDescriptor");
    jmethodID get = pfd ? (*env)->GetMethodID(env, pfd, "getFd", "()I") : NULL;
    jmethodID detach = get ? (*env)->GetMethodID(env, pfd, "detachFd", "()I") : NULL;
    if (!pfd || !get || !detach || !(*env)->IsInstanceOf(env, input, pfd) || !(*env)->IsInstanceOf(env, output, pfd) || (tun && !(*env)->IsInstanceOf(env, tun, pfd))) {
        if (pfd) (*env)->DeleteLocalRef(env, pfd);
        return reject(env, "invalid ParcelFileDescriptor");
    }
    jint in = (*env)->CallIntMethod(env, input, get);
    jint out = !(*env)->ExceptionCheck(env) ? (*env)->CallIntMethod(env, output, get) : -1;
    jint device = tun && !(*env)->ExceptionCheck(env) ? (*env)->CallIntMethod(env, tun, get) : -1;
    if ((*env)->ExceptionCheck(env) || in < 0 || out < 0 || (tun && device <= 0) || in == out || (tun && (device == in || device == out)) || !bind_callbacks(env, callback)) {
        (*env)->DeleteLocalRef(env, pfd); return reject(env, "descriptor or callback identity is invalid");
    }
    in = (*env)->CallIntMethod(env, input, detach);
    if ((*env)->ExceptionCheck(env) || in < 0) { (*env)->DeleteLocalRef(env, pfd); return reject(env, "input descriptor handoff failed"); }
    out = (*env)->CallIntMethod(env, output, detach);
    if ((*env)->ExceptionCheck(env) || out < 0) { (*env)->DeleteLocalRef(env, pfd); return reject_handoff(env, "output descriptor handoff failed", in, -1, -1); }
    device = tun ? (*env)->CallIntMethod(env, tun, detach) : -1;
    if ((*env)->ExceptionCheck(env) || (tun && device <= 0)) { (*env)->DeleteLocalRef(env, pfd); return reject_handoff(env, "TUN descriptor handoff failed", in, out, (*env)->ExceptionCheck(env) ? -1 : device); }
    (*env)->DeleteLocalRef(env, pfd);
    /* 交给Go后，C不再按这些整数关闭任何描述符。 */
    return take_result(env, CoreInvoke(operation, request_id, in, out, device));
}
