import Foundation
import Testing
@testable import LoaderCore

/// 3x-ui appends Happ's `?serverDescription=<base64>` to a link's #fragment.
/// Kept verbatim it shows up in the server list as base64; decoded it is the
/// only thing that tells two hosts of one inbound apart (direct vs CDN).
struct LinkNameTests {

    @Test func decodesServerDescriptionIntoTheName() {
        #expect(ShareLinkParser.displayName(fromFragment: "🇫🇷 XHTTP?serverDescription=0J3QsNC/0YDRj9C80YPRjg==")
                == "🇫🇷 XHTTP · Напрямую")
        #expect(ShareLinkParser.displayName(fromFragment: "🇫🇷 XHTTP?serverDescription=Q2xvdWRmbGFyZSBDRE4gwrcg0YDQtdC30LXRgNCy")
                == "🇫🇷 XHTTP · Cloudflare CDN · резерв")
    }

    @Test func keepsANameThatMerelyContainsAQuestionMark() {
        #expect(ShareLinkParser.displayName(fromFragment: "Why? Server") == "Why? Server")
        #expect(ShareLinkParser.displayName(fromFragment: "Plain") == "Plain")
    }

    @Test func dropsAnUnreadableDescription() {
        #expect(ShareLinkParser.displayName(fromFragment: "Node?serverDescription=") == "Node")
        #expect(ShareLinkParser.displayName(fromFragment: "Node?serverDescription=%%%") == "Node")
    }

    @Test func appliesToParsedLinks() throws {
        let link = "vless://11111111-1111-1111-1111-111111111111@example.com:443?type=tcp&security=none"
            + "#%F0%9F%87%AB%F0%9F%87%B7%20XHTTP?serverDescription=0J3QsNC/0YDRj9C80YPRjg=="
        let server = try ShareLinkParser.parse(link)
        #expect(server.name == "🇫🇷 XHTTP · Напрямую")
    }
}
