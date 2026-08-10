import Foundation
import Hummingbird
import RepoPromptServiceProtocol

enum HTTPResponses {
    static func json(_ value: some Encodable, status: HTTPResponse.Status = .ok) throws -> Response {
        let data = try JSONEncoder.serviceEncoder.encode(value)
        var headers = HTTPFields()
        headers[.contentType] = "application/json; charset=utf-8"
        headers[.cacheControl] = "no-store"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: ByteBuffer(bytes: data)))
    }

    static func error(_ error: Error) -> Response {
        let apiError = error as? ServiceAPIError ?? ServiceAPIError(code: .dependencyUnavailable, message: "Internal dependency failed", retryable: true)
        let status: HTTPResponse.Status = switch apiError.code {
        case .invalidRequest: .badRequest
        case .internalAuthFailed: .unauthorized
        case .authorizationDecisionRejected: .forbidden
        case .notFound: .notFound
        case .staleRevision, .controllerChanged, .interactionSettled, .idempotencyConflict, .runAlreadyActive: .conflict
        case .cursorExpired, .resourceDeleted: .gone
        case .rateLimited: .tooManyRequests
        case .dependencyUnavailable, .quiescing, .persistenceUnavailable: .serviceUnavailable
        default: .unprocessableContent
        }
        return (try? json(apiError, status: status)) ?? Response(status: .internalServerError)
    }
}
