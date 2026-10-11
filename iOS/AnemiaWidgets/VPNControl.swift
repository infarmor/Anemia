import AppIntents
import SwiftUI
import WidgetKit

/// The VPN switch for Control Center, the Lock Screen and the Action button.
@available(iOS 18.0, *)
struct VPNControl: ControlWidget {
    static let kind = WidgetKinds.control

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind, provider: Provider()) { isOn in
            ControlWidgetToggle("Anemia", isOn: isOn, action: ToggleVPNIntent()) { on in
                Label(on ? "Включён" : "Выключен", systemImage: on ? "lock.shield.fill" : "shield.slash")
            }
            .tint(Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255))
        }
        .displayName("Anemia VPN")
        .description("Включает и выключает VPN Anemia.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: Bool { false }

        func currentValue() async throws -> Bool {
            await VPNProbe.isOn()
        }
    }
}
