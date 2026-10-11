// Корень проекта. Версии AGP/Kotlin держим здесь, чтобы :app и :core не
// разъезжались; проверены ли они сборкой — см. Android/README.md (пока нет).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "Anemia"

// :core — порт Sources/LoaderCore (разбор ссылок, сборка конфигов, формат
// чисел). Чистый Kotlin + JVM-тесты, без Android-зависимостей: так golden-
// тесты из Tests/LoaderCoreTests гоняются без эмулятора.
include(":core")
include(":app")
