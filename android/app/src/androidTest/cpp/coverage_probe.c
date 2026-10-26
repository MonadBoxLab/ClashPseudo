#include <jni.h>

int __llvm_profile_write_file(void);
void __llvm_profile_set_filename(const char *filename);

// Known test-only outcomes for validating the installed Clang collector.
// Two distinct entries deliberately share one source line.
int validation_same_line_a(void) { return 1; } int validation_same_line_b(void) { return 2; }

int validation_coverage_probe(int first, int second) {
    if (first && second) return validation_same_line_a();
    return 0;
}

int validation_coverage_never_called(void) { return 99; }

JNIEXPORT jint JNICALL Java_io_github_monadboxlab_clashpseudo_debug_NativeCoverage_probe(
        JNIEnv *env, jclass cls, jboolean first, jboolean second) {
    (void)env; (void)cls;
    return validation_coverage_probe(first == JNI_TRUE, second == JNI_TRUE);
}

JNIEXPORT jint JNICALL Java_io_github_monadboxlab_clashpseudo_debug_NativeCoverage_write(
        JNIEnv *env, jclass cls, jstring path) {
    (void)cls;
    if (!path) return -1;
    const char *filename = (*env)->GetStringUTFChars(env, path, NULL);
    if (!filename) return -1;
    __llvm_profile_set_filename(filename);
    int result = __llvm_profile_write_file();
    (*env)->ReleaseStringUTFChars(env, path, filename);
    return result;
}
