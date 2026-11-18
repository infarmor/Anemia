plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "app.anemia"
    compileSdk = 36
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "app.anemia"
        minSdk = 28
        targetSdk = 36
        versionCode = 1
        versionName = "0.1"
        // Движок собирается Scripts/build-engine.sh; лишние ABI только
        // раздувают APK. `-PanemiaAbi=arm64-v8a` оставляет в APK одно ABI —
        // так `build-apk.sh` делает сборку на ~40 МБ вместо ~100 МБ на три.
        val abis = providers.gradleProperty("anemiaAbi").orNull
            ?.takeIf { it.isNotBlank() }
            ?.split(',', ' ')
            ?.filter { it in setOf("arm64-v8a", "armeabi-v7a", "x86_64") }
            ?: listOf("arm64-v8a", "armeabi-v7a", "x86_64")
        require(abis.isNotEmpty()) { "anemiaAbi не назвал ни одного известного ABI" }
        ndk { abiFilters += abis }
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            // Без keep-правил R8 переименует `app.anemia.vpn.Engine`, а JNI
            // ищет `Java_app_anemia_vpn_Engine_*` по имени: библиотека
            // перестанет находиться молча, и релизный APK останется без
            // движка. См. proguard-rules.pro.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlin { compilerOptions { jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17) } }

    buildFeatures { compose = true }

    // Движок — 33 МБ на ABI, то есть 93 % APK. С `-PanemiaCompressLibs=1`
    // нативные библиотеки ложатся в APK сжатыми: скачивать в 2,5 раза меньше
    // ценой того, что при установке они распаковываются в /data (плюс ~33 МБ
    // на телефоне). APK'ом раздают руками и по мобильному, поэтому для
    // релизной сборки скрипт включает это по умолчанию; отладочной и эмулятору
    // это не нужно — там файл никуда не качается, а mmap прямо из архива быстрее
    // стартует.
    packaging {
        jniLibs {
            useLegacyPackaging = providers.gradleProperty("anemiaCompressLibs").orNull == "1"
        }
    }
}

dependencies {
    implementation(project(":core"))
    implementation("androidx.activity:activity-compose:1.9.3")
    implementation("androidx.compose.material3:material3:1.3.1")
    // Генератор QR-кода для переноса (`data/Qr.kt`). Чистый Java-артефакт без
    // Android-зависимостей и без своих разрешений: он нужен только чтобы
    // нарисовать матрицу, которую читает `LoaderTool sync-read` на другой
    // стороне. glance/datastore/security-crypto сюда не вернутся — кода,
    // который их использует, по-прежнему нет.
    implementation("com.google.zxing:core:3.5.3")
    testImplementation("junit:junit:4.13.2")
    // В unit-тестах `org.json` из Android-фреймворка — заглушка, бросающая
    // «not mocked». Ряд замеров читает и пишет именно его (`ProbeHistory`),
    // поэтому на время тестов в класс-пат кладётся эталонная реализация той же
    // библиотеки, из которой Android-овый `org.json` и вырос.
    testImplementation("org.json:json:20240303")
}
