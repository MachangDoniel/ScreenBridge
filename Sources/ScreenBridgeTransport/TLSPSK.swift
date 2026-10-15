#if !SCREENBRIDGE_STRIPPED
import Foundation
import Network
import Security

/// TLS 1.2 with a pre-shared key (RFC 4279, `TLS_PSK_WITH_AES_128_GCM_SHA256`).
///
/// Both sides prove knowledge of the same 32-byte key during the handshake, so the
/// channel is mutually authenticated and encrypted without certificates or ATS
/// exceptions. The PSK identity is the credential ID, which lets the receiver hold
/// many credentials and drop revoked ones.
public enum TLSPSK {
    public struct Credential: Sendable, Equatable {
        public var identity: String
        public var key: Data

        public init(identity: String, key: Data) {
            self.identity = identity
            self.key = key
        }
    }

    public static func clientParameters(_ credential: Credential) -> NWParameters {
        parameters(credentials: [credential])
    }

    /// Server parameters. An empty credential list installs a random throwaway key so
    /// the listener can start but every handshake fails.
    public static func serverParameters(_ credentials: [Credential]) -> NWParameters {
        let effective = credentials.isEmpty
            ? [Credential(identity: "none-\(UUID().uuidString)", key: randomKey())]
            : credentials
        return parameters(credentials: effective)
    }

    public static func randomKey(byteCount: Int = 32) -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    private static func parameters(credentials: [Credential]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        for c in credentials {
            let key = c.key.withUnsafeBytes { DispatchData(bytes: $0) }
            let identity = Data(c.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(sec, key as __DispatchData, identity as __DispatchData)
        }
        // tls_ciphersuite_t has no named PSK case; the raw IANA value is the documented approach.
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 30
        tcp.connectionTimeout = 10
        let params = NWParameters(tls: tls, tcp: tcp)
        params.includePeerToPeer = false
        return params
    }
}
#endif
