import app.anemia.core.AmneziaWg
import app.anemia.core.ShareLinkParser
import java.io.File

/**
 * Tiny CLI: wg-quick конфиг на входе → тот самый UAPI-скрипт, который Android
 * отдаёт движку (`ConfigApplier` → `AmneziaWg.uapiScript`).
 *
 * Нужен одним файлом и одним аргументом, чтобы `verify-awg-kotlin.sh` мог
 * скормить именно Kotlin-вывод настоящему `amneziawg-go`: золотая сверка с
 * Swift отвечает за «мы совпадаем», а этот прогон — за «движок принимает то,
 * что мы собрали, и носит пакеты».
 */
fun main(args: Array<String>) {
    require(args.isNotEmpty()) { "употребление: awg-uapi-kotlin <conf> [<endpoint>]" }
    val server = ShareLinkParser.parseConfigText(File(args[0]).readText())
    print(AmneziaWg.uapiScript(server, args.getOrNull(1)))
}
