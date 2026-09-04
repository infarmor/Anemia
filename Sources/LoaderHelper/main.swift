import Foundation
import LoaderShared

/// Entry point for the privileged helper daemon. Advertises the XPC mach
/// service and serves a single shared ``HelperService`` to connecting clients.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let service = HelperService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection conn: NSXPCConnection) -> Bool {
        // Only the genuine signed Loader app may drive the helper.
        guard ClientVerifier.isValid(conn) else {
            FileHandle.standardError.write(Data("[helper] rejected unverified client\n".utf8))
            return false
        }
        conn.exportedInterface = NSXPCInterface(with: LoaderHelperProtocol.self)
        conn.exportedObject = service
        conn.resume()
        return true
    }
}

let delegate = ListenerDelegate()
let listener = NSXPCListener(machServiceName: LoaderIdentifiers.helperMachService)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
