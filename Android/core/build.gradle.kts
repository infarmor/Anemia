// :core — порт `Sources/LoaderCore` (разбор ссылок, сборка конфигов, числа).
// Чистый Kotlin/JVM без Android-зависимостей: так он собирается и здесь, и в
// Scripts/test-core.sh, где golden-сверка с Swift гоняется без эмулятора.
plugins {
    id("org.jetbrains.kotlin.jvm")
}

kotlin {
    compilerOptions {
        // :app компилируется под JVM 17; библиотека не должна быть новее
        // потребителя, иначе AGP не найдёт совместимого варианта.
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

// Golden-проверки в src/test/kotlin — это не JUnit, а `main()` с фикстурами:
// они прогоняются Scripts/test-core.sh (и дважды, под второй локалью). Через
// Gradle здесь только компиляция, чтобы порту не мешал отсутствующий раннер.
tasks.withType<Test>().configureEach { enabled = false }
