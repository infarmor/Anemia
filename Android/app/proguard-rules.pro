# Экспорты JNI связаны с именами классов и методов: `Java_<пакет>_<класс>_<метод>`.
# R8, не зная про эти строки, переименовывает класс, и `System.loadLibrary`
# отрабатывает, а `nativeStartXray` падает с UnsatisfiedLinkError — приложение
# тогда показывает «Движок не загружен» вместо ошибки сборки.
-keepclasseswithmembernames class app.anemia.vpn.Engine {
    native <methods>;
}
