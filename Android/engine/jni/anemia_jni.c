// JNI-мост между Kotlin и C-экспортами Go-библиотеки.
//
// Go отдаёт чистые C-функции (`AnemiaStartXray` и т. д.), а JVM из Kotlin умеет
// вызывать только `Java_<пакет>_<класс>_<метод>`. Отсюда этот тонкий слой:
// он находит символы в соседней `libanemia.so` (та же директория APK),
// превращает строки JVM в UTF-8 и — обязательно — освобождает то, что вернул
// движок: `AnemiaStatus` и компания отдают память, живущую в C, и без
// `AnemiaFree` она бы копилась в процессе туннеля бесконечно.
//
// Дескриптор туннеля дублирует сам движок (`dupNonblocking` в engine.go),
// поэтому здесь fd только передаётся числом и ничей.

#include <jni.h>
#include <dlfcn.h>
#include <stddef.h>
#include <string.h>

typedef char *(*start_fn)(const char *, int);
typedef char *(*void_fn)(void);
typedef char *(*str_fn)(const char *);
typedef void (*free_fn)(char *);
typedef void (*stop_fn)(void);
typedef void (*limit_fn)(long long);
typedef long long (*active_fn)(const char *, int);
typedef char *(*fetch_fn)(const char *, int, int);

static void *lib;
static start_fn c_start_xray;
static start_fn c_start_awg;
static stop_fn c_stop;
static stop_fn c_network_changed;
static void_fn c_status;
static void_fn c_version;
static limit_fn c_set_memory_limit;
static str_fn c_set_log_directory;
static free_fn c_free;
static active_fn c_check_active;
static fetch_fn c_fetch;

/**
 * Поднято ли всё: и библиотека, и каждый нужный символ. Отдельного флага тут
 * быть не могло — `if (lib != NULL) return 1` возвращал успех и тогда, когда
 * dlopen сработал, а dlsym не нашёл половину имён (старая `libanemia.so`), и
 * следующий вызов прыгал бы в NULL. Вызывается из `loadLibrary`, который Kotlin
 * делает под `lazy` (он потокобезопасен), и только после этого — остальные.
 */
static int resolved;

static int resolve_symbols(void) {
    if (resolved) return 1;
    if (lib == NULL) {
        lib = dlopen("libanemia.so", RTLD_NOW | RTLD_LOCAL);
        if (lib == NULL) return 0;
    }
    c_start_xray = (start_fn)dlsym(lib, "AnemiaStartXray");
    c_start_awg = (start_fn)dlsym(lib, "AnemiaStartAWG");
    c_stop = (stop_fn)dlsym(lib, "AnemiaStop");
    c_network_changed = (stop_fn)dlsym(lib, "AnemiaNetworkChanged");
    c_status = (void_fn)dlsym(lib, "AnemiaStatus");
    c_version = (void_fn)dlsym(lib, "AnemiaVersion");
    c_set_memory_limit = (limit_fn)dlsym(lib, "AnemiaSetMemoryLimit");
    c_set_log_directory = (str_fn)dlsym(lib, "AnemiaSetLogDirectory");
    c_free = (free_fn)dlsym(lib, "AnemiaFree");
    // Намеренно вне `resolved`: `libanemia.so` без этого экспорта обязана
    // оставлять туннель рабочим — тогда просто не будет сигнала здоровья, а не
    // «движок не загружен».
    c_check_active = (active_fn)dlsym(lib, "AnemiaCheckActive");
    // Тоже вне `resolved`: без `AnemiaFetch` живёт туннель и проверка
    // скорости, а утечки просто скажут «адрес выхода не измерен».
    c_fetch = (fetch_fn)dlsym(lib, "AnemiaFetch");
    resolved = c_start_xray && c_start_awg && c_stop && c_network_changed && c_status &&
               c_version && c_set_memory_limit && c_set_log_directory && c_free;
    return resolved;
}

/**
 * Копирует ответ движка в строку JVM и отпускает его память. NULL из Go —
 * это «ошибки нет», то есть null и в Kotlin.
 */
static jstring take(JNIEnv *env, char *raw) {
    jstring out = NULL;
    if (raw != NULL) {
        out = (*env)->NewStringUTF(env, raw);
        // `NewStringUTF` бросает OutOfMemoryError (и не переносит байты,
        // которые не влезают в Modified UTF-8). Не снятое здесь исключение
        // уехало бы в следующий нативный вызов — то есть упало бы не там,
        // где случилось.
        if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
            // Но NULL здесь — это не «ошибки нет»: Kotlin читает пустой ответ
            // как принятый движком конфиг, и сорванный запуск превращался бы в
            // «подключено» над мёртвым выходом. 4-байтные последовательности
            // Modified UTF-8 не перевозит, а имена серверов у нас — флаги-
            // эмодзи, которые Go возвращает в цепочках ошибок. Поэтому факт
            // отказа доезжает до JVM хотя бы текстом.
            out = (*env)->NewStringUTF(env, "текст ошибки движка не передался");
        }
        c_free(raw);
    }
    return out;
}

/**
 * UTF-8 строки JVM на время вызова; освобождать должен вызывающий. NULL —
 * строки нет либо память кончилась (`GetStringUTFChars` возвращает NULL и
 * оставляет висящий OutOfMemoryError): вызывать Go с NULL нельзя.
 */
static const char *pin(JNIEnv *env, jstring text, jboolean *copy) {
    if (text == NULL) return NULL;
    const char *chars = (*env)->GetStringUTFChars(env, text, copy);
    if (chars == NULL && (*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
    return chars;
}

static void unpin(JNIEnv *env, jstring text, const char *chars) {
    if (text != NULL && chars != NULL) (*env)->ReleaseStringUTFChars(env, text, chars);
}

JNIEXPORT jboolean JNICALL
Java_app_anemia_vpn_Engine_loadLibrary(JNIEnv *env, jclass klass) {
    (void)env;
    (void)klass;
    return resolve_symbols() ? JNI_TRUE : JNI_FALSE;
}

/** NULL, если движок принял аргумент; иначе — текст ошибки. */
JNIEXPORT jstring JNICALL
Java_app_anemia_vpn_Engine_nativeStartXray(JNIEnv *env, jclass klass, jstring config, jint fd) {
    (void)klass;
    if (!resolve_symbols()) return (*env)->NewStringUTF(env, "libanemia.so не загружена");
    jboolean copy = JNI_FALSE;
    const char *chars = pin(env, config, &copy);
    if (chars == NULL) return (*env)->NewStringUTF(env, "конфиг не передался в движок");
    char *raw = c_start_xray(chars, (int)fd);
    unpin(env, config, chars);
    return take(env, raw);
}

JNIEXPORT jstring JNICALL
Java_app_anemia_vpn_Engine_nativeStartAwg(JNIEnv *env, jclass klass, jstring uapi, jint fd) {
    (void)klass;
    if (!resolve_symbols()) return (*env)->NewStringUTF(env, "libanemia.so не загружена");
    jboolean copy = JNI_FALSE;
    const char *chars = pin(env, uapi, &copy);
    if (chars == NULL) return (*env)->NewStringUTF(env, "UAPI-скрипт не передался в движок");
    char *raw = c_start_awg(chars, (int)fd);
    unpin(env, uapi, chars);
    return take(env, raw);
}

JNIEXPORT void JNICALL Java_app_anemia_vpn_Engine_nativeStop(JNIEnv *env, jclass klass) {
    (void)env;
    (void)klass;
    if (resolve_symbols()) c_stop();
}

JNIEXPORT void JNICALL Java_app_anemia_vpn_Engine_nativeNetworkChanged(JNIEnv *env, jclass klass) {
    (void)env;
    (void)klass;
    if (resolve_symbols()) c_network_changed();
}

JNIEXPORT jstring JNICALL Java_app_anemia_vpn_Engine_nativeStatus(JNIEnv *env, jclass klass) {
    (void)klass;
    if (!resolve_symbols()) return NULL;
    return take(env, c_status());
}

JNIEXPORT jstring JNICALL Java_app_anemia_vpn_Engine_nativeVersion(JNIEnv *env, jclass klass) {
    (void)klass;
    if (!resolve_symbols()) return NULL;
    return take(env, c_version());
}

JNIEXPORT void JNICALL Java_app_anemia_vpn_Engine_nativeSetMemoryLimit(JNIEnv *env, jclass klass, jlong bytes) {
    (void)env;
    (void)klass;
    if (resolve_symbols()) c_set_memory_limit((long long)bytes);
}

JNIEXPORT jstring JNICALL
Java_app_anemia_vpn_Engine_nativeSetLogDirectory(JNIEnv *env, jclass klass, jstring directory) {
    (void)klass;
    if (!resolve_symbols()) return (*env)->NewStringUTF(env, "libanemia.so не загружена");
    jboolean copy = JNI_FALSE;
    const char *chars = pin(env, directory, &copy);
    if (chars == NULL) return (*env)->NewStringUTF(env, "каталог логов не передался");
    char *raw = c_set_log_directory(chars);
    unpin(env, directory, chars);
    return take(env, raw);
}

/**
 * Один GET через живой туннель с ответом: JSON `{"ms":…,"bytes":…,"body":…}`,
 * `{"error":…}` при отказе и пустая строка, когда туннель не поднят. Нужен
 * потому, что само приложение из своего VPN вынесено, и посмотреть «что видят
 * сайты» его сокетом нельзя — только со стороны движка.
 */
JNIEXPORT jstring JNICALL
Java_app_anemia_vpn_Engine_nativeFetch(JNIEnv *env, jclass klass, jstring url,
                                       jint timeoutMs, jint maxBytes) {
    (void)klass;
    // Пустой ответ = «туннеля нет или символ старой сборки». Но NULL и для
    // неотданной строки был бы ложью того же рода: экран прочитал бы «символа
    // нет» и послал бы человека пересобирать движок, когда сломан переход
    // аргумента. Здесь отказ приходит текстом, как его отдаёт сам Go.
    if (!resolve_symbols() || c_fetch == NULL) return NULL;
    jboolean copy = JNI_FALSE;
    const char *chars = pin(env, url, &copy);
    if (chars == NULL) return (*env)->NewStringUTF(env, "{\"error\":\"URL не передался в движок\"}");
    char *raw = c_fetch(chars, (int)timeoutMs, (int)maxBytes);
    unpin(env, url, chars);
    return take(env, raw);
}

/**
 * Один GET через живое соединение: milliseconds, -1 — запрос не прошёл,
 * -2 — Xray не запущен, -3 — вызвать не удалось (нет символа `AnemiaCheckActive`
 * в `libanemia.so`), -4 — строка цели не передалась через JNI. Разные -3 и -4
 * затем, чтобы единственная диагностическая строчка в Kotlin не отправляла
 * человека проверять сборку движка, когда сломан переход аргумента.
 */
JNIEXPORT jlong JNICALL
Java_app_anemia_vpn_Engine_nativeCheckActive(JNIEnv *env, jclass klass, jstring target, jint timeoutMs) {
    (void)klass;
    if (!resolve_symbols() || c_check_active == NULL) return -3;
    jboolean copy = JNI_FALSE;
    const char *chars = pin(env, target, &copy);
    if (chars == NULL) return -4;
    long long ms = c_check_active(chars, (int)timeoutMs);
    unpin(env, target, chars);
    return (jlong)ms;
}
