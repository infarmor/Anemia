package app.anemia.ui

import android.app.Activity
import android.os.Bundle
import android.widget.Toast
import app.anemia.data.SessionStarter

/**
 * Окно-прослойка для нажатия плитки: поднимает или рвёт соединение и сразу
 * закрывается.
 *
 * Оно существует ровно потому, что с Android 12 foreground-сервис можно
 * стартовать только когда приложение на виду, а системный диалог согласия на
 * VPN вообще нельзя показать без активности. Тема у окна прозрачная, поэтому
 * человек видит не пустой экран, а шторку под ним; итогом служит сама плитка.
 */
class SessionActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (SessionStarter.tunnelUp(this)) {
            SessionStarter.stop(this)
            finishWith("отключено")
            return
        }
        SessionStarter.consent(this)?.let {
            // Согласие выдаётся один раз на приложение: дальше этот путь не
            // повторяется, и плитка работает без всякого окна.
            startActivityForResult(it, REQUEST_CONSENT)
            return
        }
        finishWith(SessionStarter.start(this))
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        if (requestCode != REQUEST_CONSENT) return finishWith(null)
        if (resultCode == RESULT_OK) finishWith(SessionStarter.start(this))
        else finishWith("Разрешение на VPN-подключение не выдано")
    }

    /** null — всё в порядке, показывать нечего; текст — причина отказа. */
    private fun finishWith(reason: String?) {
        reason?.let { Toast.makeText(applicationContext, it, Toast.LENGTH_SHORT).show() }
        finish()
    }

    private companion object {
        const val REQUEST_CONSENT = 1
    }
}
