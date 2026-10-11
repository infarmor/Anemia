import Compression
import CoreImage.CIFilterBuiltins
import LoaderCore
import SwiftUI
import UniformTypeIdentifiers

// Moving servers and settings to another device and back — the Mac app
// reads and writes the same bundle (LoaderCore/SyncBundle.swift).

extension UTType {
    /// `.anemia` files, declared in Config/Anemia-Info.plist.
    static let anemiaBundle = UTType(exportedAs: "app.anemia.sync")
}

/// The bundle as a file for the share sheet; written when a target is picked.
struct SyncFile: Transferable {
    let bundle: SyncBundle

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .anemiaBundle) { file in
            // Каждый перенос — свой файл. Под одним и тем же именем второй
            // «Поделиться» писал поверх уже уходящего bundle'а, а первый
            // `SentTransferredFile` удалял файл на выходе, и второй адресат
            // получал пустой или чужой файл.
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Anemia-\(UUID().uuidString).\(SyncBundle.fileExtension)")
            try file.bundle.fileData().write(to: url, options: .atomic)
            return SentTransferredFile(url)
        }
    }
}

enum QRCode {
    /// A crisp QR image of `text`; nil when it doesn't fit in a QR code.
    static func image(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 12, y: 12)),
              let image = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: image)
    }
}

/// Settings → "Перенос на другое устройство".
struct TransferSection: View {
    @Environment(ServerStore.self) private var store
    @State private var showingQR = false

    var body: some View {
        Section {
            ShareLink(item: SyncFile(bundle: store.syncBundle()),
                      preview: SharePreview("Серверы и настройки Anemia", image: Image(systemName: "shield.lefthalf.filled"))) {
                Label("Отправить файлом", systemImage: "square.and.arrow.up")
            }
            Button("Показать QR-код", systemImage: "qrcode") { showingQR = true }
        } header: {
            Text("Перенос на другое устройство")
        } footer: {
            Text("Серверы, подписки и настройки — для Anemia на Mac или другом iPhone. Файл можно отправить через AirDrop, сохранить в «Файлы» или переслать; QR-код сканируется в Anemia: «Серверы → + → Сканировать QR». В файле ключи серверов: не публикуйте его.")
        }
        .listRowBackground(Theme.card)
        .sheet(isPresented: $showingQR) {
            TransferQRSheet(bundle: store.syncBundle())
        }
    }
}

private struct TransferQRSheet: View {
    let bundle: SyncBundle
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let link = try? bundle.link(), let image = QRCode.image(link) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .frame(maxWidth: 320)
                    Text("Откройте Anemia на другом устройстве: «Серверы → + → Сканировать QR».")
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                        .multilineTextAlignment(.center)
                } else {
                    ContentUnavailableView(
                        "Не помещается в QR-код",
                        systemImage: "qrcode",
                        description: Text("Серверов слишком много. Отправьте их файлом — через AirDrop или «Файлы».")
                    )
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.ground)
            .navigationTitle("QR-код")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private var summary: String {
        let servers = bundle.servers.count
        let subscriptions = bundle.subscriptions.count
        return "\(servers) \(WorldMap.plural(servers, "сервер", "сервера", "серверов")) · "
            + "\(subscriptions) \(WorldMap.plural(subscriptions, "подписка", "подписки", "подписок")) · настройки"
    }
}

/// What a received bundle would add, and the button that adds it.
struct SyncImportSheet: View {
    let bundle: SyncBundle
    @Environment(ServerStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var applySettings = true
    @State private var working = false
    /// Задача импорта — чтобы «Отмена» её снимала, а не только закрывала шторку.
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        // `preview` — это диф всего хранилища против бандла, а тело читает его
        // пять раз за проход: каждое обращение пересчитывало его заново, и если
        // `store.state` менялся между этими чтениями, «Новых серверов» и
        // «Новых подписок» на одном экране могли считаться с разных снимков.
        let preview = self.preview
        NavigationStack {
            List {
                Section {
                    LabeledContent("Откуда", value: bundle.device)
                    LabeledContent("Когда", value: bundle.exportedAt.formatted(.relative(presentation: .named)
                        .locale(Locale(identifier: "ru_RU"))))
                }
                .listRowBackground(Theme.card)

                Section {
                    row("Новых серверов", preview.addedServers, known: preview.knownServers)
                    row("Новых подписок", preview.newSubscriptions.count, known: preview.knownSubscriptions)
                    // Подписка — это не список серверов, а адрес, на который
                    // телефон потом ходит сам. Присланный бандл мог назначить его
                    // целиком, и до этого окна пользователь видел только «+1».
                    ForEach(preview.newSubscriptions.prefix(5), id: \.url) { entry in
                        Text(entry.url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.inkSoft)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    // И то, что «Взять настройки» снижает защиту, должно быть
                    // видно до нажатия, а не после.
                    if applySettings, let kill = bundle.settings?.killSwitchEnabled,
                       kill != store.killSwitch {
                        Text(kill ? "«Только через VPN» включится"
                                  : "«Только через VPN» выключится")
                            .font(.caption)
                            .foregroundStyle(Theme.accent)
                    }
                    if bundle.settings != nil {
                        Toggle(isOn: $applySettings) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Взять настройки")
                                Text("Маскировка, kill switch, «Мимо VPN», подобранная маскировка, «обновлять подписки сами»")
                                    .font(.caption)
                                    .foregroundStyle(Theme.inkSoft)
                            }
                        }
                    }
                } footer: {
                    Text("Серверы, которые уже есть (тот же адрес и ключ), не дублируются. Подписки загрузятся заново на этом устройстве.")
                }
                .listRowBackground(Theme.card)
            }
            .anemiaList()
            .navigationTitle("Перенос")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") {
                        // Отмена во время спиннера: задача импорта снимается, и
                        // `importSync` смотрит на это перед тем, как менять
                        // сохранённое состояние.
                        importTask?.cancel()
                        importTask = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Добавить") {
                            let task = Task {
                                working = true
                                await store.importSync(bundle, applySettings: applySettings)
                                // A cancelled import leaves the sheet already
                                // dismissed by the Cancel button — no second one.
                                if !Task.isCancelled {
                                    working = false
                                    dismiss()
                                }
                            }
                            importTask = task
                        }
                        .disabled(preview.addsNothing)
                    }
                }
            }
            .onDisappear { importTask?.cancel() }
        }
    }

    private var preview: SyncBundle.Summary {
        bundle.preview(against: store.state, applySettings: applySettings && bundle.settings != nil)
    }

    private func row(_ title: String, _ count: Int, known: Int) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(count)")
                    .font(.body.monospacedDigit().weight(.semibold))
                    .foregroundStyle(count > 0 ? Theme.accent : Theme.inkSoft)
                if known > 0 {
                    Text("уже есть: \(known)")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                }
            }
        }
    }
}

/// A bundle handed to the app — a link, a scanned code or a file — waiting
/// for the preview sheet.
struct IncomingBundle: Identifiable {
    let id = UUID()
    let bundle: SyncBundle

    /// From a link or pasted text; nil when it isn't a bundle at all.
    /// Throws when it looks like one but can't be read.
    init?(text: String) throws {
        guard SyncBundle.looksLikeBundle(text) else { return nil }
        // Размер проверяется ДО разбора: тело `anemia://sync/…` — zlib-поток,
        // а `SyncBundle.decode` раскручивает его целиком в памяти, и из
        // чужого QR или чужого файла можно принести пару сотен килобайт,
        // которые станут сотнями мегабайт.
        let data = Data(text.utf8)
        guard data.count <= Self.maxTextPayload else {
            throw Failure(message: "Ссылка слишком большая (\(Bytes.text(Int64(data.count)))) — "
                                 + "перешлите файл вместо ссылки")
        }
        // Ссылка раскручивается сама: `SyncBundle.decode` видит префикс и
        // разжимает zlib без потолка, так что размер входа ещё ничего не
        // гарантирует (256 КиБ зловредного.deflate — это и сотни мегабайт JSON).
        // Поэтому разжатие здесь идёт через буфер с жёстким пределом, а дальше
        // обычный путь получает уже готовый JSON.
        bundle = try Self.read(text.starts(with: SyncBundle.linkPrefix)
                               ? Self.inflatedLinkJSON(text) : data)
        try Self.checkCounts(bundle)
    }

    /// From a file iOS opened the app with.
    init(fileURL: URL) throws {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        // Сначала объявленный размер: 2 ГБ в «Файлах» нужно успеть отклонить до
        // того, как они легут в память целиком. Но и он не отсечка — провайдер
        // может не ответить, — поэтому само чтение идёт через `FileHandle` с
        // потолком: лишнего файл не дочитывает.
        let declared = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        if let declared, declared > Self.maxFilePayload {
            throw Failure(message: "Файл слишком большой (\(Bytes.text(Int64(declared))))")
        }
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw Failure(message: "Не удалось открыть файл")
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxFilePayload + 1),
              data.count <= Self.maxFilePayload else {
            throw Failure(message: "Файл слишком большой (больше \(Bytes.text(Int64(Self.maxFilePayload))))")
        }
        bundle = try Self.read(data)
        try Self.checkCounts(bundle)
    }

    /// Тот же файл, но чтение и разбор — не на главном актёре. `.anemia` в
    /// iCloud Drive может лежать выгруженным: `Data(contentsOf:)` добывает его
    /// синхронно, а следом декодируется весь JSON бандла — в `.onOpenURL` это
    /// стояло бы всем интерфейсом, а на телефоне длинный главный цикл ещё и
    /// заканчивается смертью процесса.
    /// Тот же разбор текста, но вне главного актёра: чужая ссылка или чужой QR
    /// приходят из `.onOpenURL`, вставки и снимка, а разжимание и декодирование
    /// мегибайтного JSON на главном потоке — это зависший интерфейс и смерть
    /// процесса по сматровому таймауту.
    static func load(text: String) async throws -> IncomingBundle? {
        let payload = text
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IncomingBundle?, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try IncomingBundle(text: payload)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// base64url → zlib с потолком. Алфавит и обрамление совпадают с
    /// `SyncBundle.link()`; `linkPrefix` открытый, так что формат здесь не
    /// угадывается, а только разжимание ограничено с этой стороны.
    private static func inflatedLinkJSON(_ text: String) throws -> Data {
        var body = String(text.dropFirst(SyncBundle.linkPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        body += String(repeating: "=", count: (4 - body.count % 4) % 4)
        guard let packed = Data(base64Encoded: body) else {
            throw Failure(message: "Не удалось прочитать данные: файл или QR-код повреждён.")
        }
        return try packed.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else {
                throw Failure(message: "Не удалось прочитать данные: файл или QR-код повреждён.")
            }
            let cap = Self.maxInflatedJSON
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(dst, cap, src, packed.count, nil, COMPRESSION_ZLIB)
            guard written > 0 else {
                throw Failure(message: "Не удалось прочитать данные: файл или QR-код повреждён.")
            }
            guard written < cap else {
                throw Failure(message: "Данных слишком много (больше "
                                     + "\(Bytes.text(Int64(cap)))) — перешлите файлом")
            }
            return Data(bytes: dst, count: written)
        }
    }

    /// Предел развёрнутого JSON. Настоящий перенос на 2000 серверов — сотни
    /// килобайт; 32 МБ хватает с запасом, но не дают чужой ссылке занять память
    /// целым приложением.
    static let maxInflatedJSON = 32 * 1024 * 1024

    static func load(fileURL: URL) async throws -> IncomingBundle {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<IncomingBundle, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try IncomingBundle(fileURL: fileURL)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Потолок тела из QR/ссылки и из файла: файл в 25 МБ — это уже не бандл
    /// настроек, а текст ссылки не бывает таким по построению.
    /// Ссылка `anemia://sync/` — это base64 от zlib всего бандла: измерено, что
    /// 300 серверов дают ~43 КиБ, 500 — ~71 КиБ, 2000 (потолок `checkCounts`) —
    /// около 280 КиБ, поэтому 512 КиБ хватает настоящему переносу с запасом.
    /// Размер входа о памяти ничего не говорит — удерживает её `maxInflatedJSON`
    /// ниже: разжатие идёт в буфер с жёстким пределом, потому что
    /// `SyncBundle.decode` разжимает без оного (в `ShareLinkParser` предел задан
    /// — 16 МБ). Файл держит 16 МБ — тот же, что у inflate `ShareLinkParser`;
    /// строка в 4 МБ отрезала ~1750 строк AmneziaWG, которые `checkCounts`
    /// как раз и разрешает.
    static let maxTextPayload = 512 * 1024
    static let maxFilePayload = 16 * 1024 * 1024

    /// Числа после разбора: список серверов, подписок и выученных маскировок
    /// выбирает приславшее устройство, и без потолка один бандл заполняет
    /// хранилище так, что каждое сохранение `state.json` становится работой на
    /// десятки мегабайт на главном потоке.
    static func checkCounts(_ bundle: SyncBundle) throws {
        guard bundle.servers.count <= 2000, bundle.subscriptions.count <= 50 else {
            throw Failure(message: "В переносе слишком много серверов или подписок "
                                 + "(\(bundle.servers.count) и \(bundle.subscriptions.count))")
        }
    }

    private static func read(_ data: Data) throws -> SyncBundle {
        do {
            return try SyncBundle.decode(data)
        } catch SyncBundle.DecodeError.newerVersion {
            throw Failure(message: "Данные из более новой версии Anemia — обновите приложение.")
        } catch {
            throw Failure(message: "Не удалось прочитать данные: файл или QR-код повреждён.")
        }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
