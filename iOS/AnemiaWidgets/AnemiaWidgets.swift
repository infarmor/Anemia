import SwiftUI
import WidgetKit

@main
struct AnemiaWidgets: WidgetBundle {
    var body: some Widget {
        TunnelLiveActivity()
        StatusWidget()
        if #available(iOS 18.0, *) {
            VPNControl()
        }
    }
}
