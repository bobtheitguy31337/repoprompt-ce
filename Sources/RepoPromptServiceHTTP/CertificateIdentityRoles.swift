import Foundation
import Hummingbird
import NIOCore
import NIOSSL
import RepoPromptServiceProtocol
import X509

public struct RepoPromptRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    let channel: any Channel

    public init(source: ApplicationRequestContextSource) {
        coreContext = .init(source: source)
        channel = source.channel
    }
}

public struct CertificateIdentityRoleResolver: Sendable {
    private let identities: [String: InternalRouteRole]

    public init(identities: [String: InternalRouteRole]) {
        self.identities = identities
    }

    public static func environment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        func required(_ name: String) throws -> String {
            guard let value = environment[name], !value.isEmpty else { throw ConfigurationError.missing(name) }
            return value.lowercased()
        }
        let app = try required("REPOPROMPT_GOBLIN_APP_CERT_IDENTITY")
        let sync = try required("REPOPROMPT_GOBLIN_SYNC_CERT_IDENTITY")
        let operatorIdentity = try required("REPOPROMPT_OPERATOR_CERT_IDENTITY")
        guard Set([app, sync, operatorIdentity]).count == 3 else {
            throw ConfigurationError.invalid("Client certificate identities must be unique across roles")
        }
        return Self(identities: [
            app: .goblinApp,
            sync: .goblinSync,
            operatorIdentity: .operatorRole
        ])
    }

    public func role(certificate: NIOSSLCertificate) throws -> InternalRouteRole {
        let parsed = try Certificate(derEncoded: certificate.toDERBytes())
        guard let usage = try parsed.extensions.extendedKeyUsage, usage.contains(.clientAuth) else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Client certificate is missing clientAuth EKU")
        }
        let names = try parsed.extensions.subjectAlternativeNames ?? SubjectAlternativeNames()
        let asserted = names.compactMap { name -> String? in
            switch name {
            case let .dnsName(value), let .uniformResourceIdentifier(value), let .rfc822Name(value): value.lowercased()
            default: nil
            }
        }
        let roles = Set(asserted.compactMap { identities[$0] })
        guard roles.count == 1, let role = roles.first else {
            throw ServiceAPIError(code: .internalAuthFailed, message: "Client certificate identity does not map to exactly one route role")
        }
        return role
    }
}
