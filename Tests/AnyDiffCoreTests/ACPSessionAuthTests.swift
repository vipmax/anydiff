import XCTest
@testable import AnyDiffCore

final class ACPSessionAuthTests: XCTestCase {

    func testAuthMethodDecoding() throws {
        let json = """
        {
            "id": "google",
            "name": "Sign in with Google",
            "description": "Authenticate using your Google Workspace or Personal account",
            "type": "agent"
        }
        """.data(using: .utf8)!

        let method = try JSONDecoder().decode(ACPAuthMethod.self, from: json)
        XCTAssertEqual(method.id, "google")
        XCTAssertEqual(method.name, "Sign in with Google")
        XCTAssertEqual(method.description, "Authenticate using your Google Workspace or Personal account")
        XCTAssertEqual(method.type, "agent")
    }

    func testInitializeResultWithCamelCaseAuthMethods() throws {
        let json = """
        {
            "protocolVersion": 1,
            "agentInfo": {
                "name": "Antigravity",
                "title": "Google Antigravity"
            },
            "authMethods": [
                {
                    "id": "oauth-google",
                    "name": "Google Login"
                }
            ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: json)
        XCTAssertEqual(result.authMethods?.count, 1)
        XCTAssertEqual(result.authMethods?.first?.id, "oauth-google")
        XCTAssertEqual(result.authMethods?.first?.name, "Google Login")
    }

    func testInitializeResultWithSnakeCaseAuthMethods() throws {
        let json = """
        {
            "protocolVersion": 1,
            "agentInfo": {
                "name": "Antigravity"
            },
            "auth_methods": [
                {
                    "id": "api-key",
                    "name": "API Key Entry"
                }
            ]
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: json)
        XCTAssertEqual(result.authMethods?.count, 1)
        XCTAssertEqual(result.authMethods?.first?.id, "api-key")
        XCTAssertEqual(result.authMethods?.first?.name, "API Key Entry")
    }

    func testAuthenticateParamsEncoding() throws {
        let params = ACPAuthenticateParams(methodId: "google-oauth")
        let data = try JSONEncoder().encode(params)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(json?["methodId"] as? String, "google-oauth")
    }

    func testJSONRPCErrorIsAuthRequired() {
        let authErrorCode = JSONRPCError(code: -32000, message: "Authentication required to access agent")
        XCTAssertTrue(authErrorCode.isAuthRequired)

        let authErrorMessage = JSONRPCError(code: -1, message: "Please complete authentication required for session")
        XCTAssertTrue(authErrorMessage.isAuthRequired)

        let normalError = JSONRPCError(code: -32601, message: "Method not found")
        XCTAssertFalse(normalError.isAuthRequired)

        let genericServerError = JSONRPCError(code: -32000, message: "Internal server error: file not found")
        XCTAssertFalse(genericServerError.isAuthRequired)
    }

    func testACPClientErrorDescriptions() {
        let authErr = ACPClientError.authRequired([
            ACPAuthMethod(id: "google", name: "Google")
        ])
        XCTAssertEqual(authErr.localizedDescription, "Authentication required to use this agent.")

        let failedErr = ACPClientError.authenticationFailed("Invalid credentials")
        XCTAssertEqual(failedErr.localizedDescription, "Authentication failed: Invalid credentials")
    }

    func testJSONRPCErrorDecodingWithStructuredData() throws {
        let json = """
        {
            "code": -32000,
            "message": "Authentication required",
            "data": {
                "message": "No authentication method selected. Either call the `authenticate` method..."
            }
        }
        """.data(using: .utf8)!

        let error = try JSONDecoder().decode(JSONRPCError.self, from: json)
        XCTAssertEqual(error.code, -32000)
        XCTAssertEqual(error.message, "Authentication required")
        XCTAssertEqual(error.data, "No authentication method selected. Either call the `authenticate` method...")
        XCTAssertTrue(error.isAuthRequired)
    }

    func testRawJSONRPCMessageWithStructuredError() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 2,
            "error": {
                "code": -32000,
                "message": "Authentication required",
                "data": {
                    "message": "Please choose auth method"
                }
            }
        }
        """.data(using: .utf8)!

        let raw = try JSONDecoder().decode(RawJSONRPCMessage.self, from: json)
        XCTAssertEqual(raw.error?.code, -32000)
        XCTAssertEqual(raw.error?.message, "Authentication required")
        XCTAssertEqual(raw.error?.data, "Please choose auth method")
        XCTAssertTrue(raw.error?.isAuthRequired == true)
    }

    func testInitializeResultWithStringProtocolVersion() throws {
        let json = """
        {
            "protocolVersion": "1",
            "agentInfo": {
                "name": "Antigravity"
            }
        }
        """.data(using: .utf8)!

        let result = try JSONDecoder().decode(ACPInitializeResult.self, from: json)
        XCTAssertEqual(result.protocolVersion, 1)
        XCTAssertEqual(result.agentInfo?.name, "Antigravity")
    }
}
