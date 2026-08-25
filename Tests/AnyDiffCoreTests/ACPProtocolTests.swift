import XCTest
@testable import AnyDiffCore

final class ACPProtocolTests: XCTestCase {
    func testJSONRPCRequestAndResponseEncoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let req = JSONRPCRequest(id: 42, method: "initialize", params: ACPInitializeParams())
        let reqData = try encoder.encode(req)
        let decodedReq = try decoder.decode(JSONRPCRequest<ACPInitializeParams>.self, from: reqData)

        XCTAssertEqual(decodedReq.id, 42)
        XCTAssertEqual(decodedReq.method, "initialize")
        XCTAssertEqual(decodedReq.jsonrpc, "2.0")
        XCTAssertEqual(decodedReq.params?.protocolVersion, 1)

        let resp = JSONRPCResponse(id: 42, result: ACPInitializeResult(protocolVersion: 1, agentInfo: ACPAgentInfo(name: "codex-acp", version: "0.1.0")))
        let respData = try encoder.encode(resp)
        let decodedResp = try decoder.decode(JSONRPCResponse<ACPInitializeResult>.self, from: respData)

        XCTAssertEqual(decodedResp.id, 42)
        XCTAssertEqual(decodedResp.result?.agentInfo?.name, "codex-acp")
    }

    func testSessionPromptAndCancelEncoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let prompt = ACPSessionPromptParams(sessionId: "sess-123", text: "Explain this diff")
        let data = try encoder.encode(prompt)
        let decoded = try decoder.decode(ACPSessionPromptParams.self, from: data)

        XCTAssertEqual(decoded.sessionId, "sess-123")
        XCTAssertEqual(decoded.prompt.first?.text, "Explain this diff")

        let cancel = ACPSessionCancelParams(sessionId: "sess-123")
        let cancelData = try encoder.encode(cancel)
        let decodedCancel = try decoder.decode(ACPSessionCancelParams.self, from: cancelData)

        XCTAssertEqual(decodedCancel.sessionId, "sess-123")
    }

    func testSessionPromptWithImagesEncoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let dummyImageData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let attachment = AgentImageAttachment(
            data: dummyImageData,
            mimeType: "image/png",
            filename: "screenshot.png",
            width: 800,
            height: 600
        )

        let prompt = ACPSessionPromptParams(sessionId: "sess-img-1", text: "Look at this screenshot", images: [attachment])
        let data = try encoder.encode(prompt)
        let decoded = try decoder.decode(ACPSessionPromptParams.self, from: data)

        XCTAssertEqual(decoded.sessionId, "sess-img-1")
        XCTAssertEqual(decoded.prompt.count, 2)
        XCTAssertEqual(decoded.prompt[0].type, "text")
        XCTAssertEqual(decoded.prompt[0].text, "Look at this screenshot")
        XCTAssertEqual(decoded.prompt[1].type, "image")
        XCTAssertEqual(decoded.prompt[1].mimeType, "image/png")
        XCTAssertEqual(decoded.prompt[1].data, dummyImageData.base64EncodedString())
    }

    func testSessionUpdateStreamingNotifications() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "sess-456",
                "update": {
                    "type": "message_chunk",
                    "delta": "Hello from ACP Agent!"
                }
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let notif = try decoder.decode(JSONRPCNotification<ACPSessionUpdateNotificationParams>.self, from: json)

        XCTAssertEqual(notif.method, "session/update")
        XCTAssertEqual(notif.params?.sessionId, "sess-456")
        XCTAssertEqual(notif.params?.update.type, "message_chunk")
        XCTAssertEqual(notif.params?.update.effectiveChunk, "Hello from ACP Agent!")
    }

    func testFileSystemReadAndWriteModels() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let writeParams = ACPFSWriteTextFileParams(path: "Sources/Foo.swift", content: "let x = 1\n")
        let writeData = try encoder.encode(writeParams)
        let decodedWrite = try decoder.decode(ACPFSWriteTextFileParams.self, from: writeData)

        XCTAssertEqual(decodedWrite.path, "Sources/Foo.swift")
        XCTAssertEqual(decodedWrite.content, "let x = 1\n")

        let readResult = ACPFSReadTextFileResult(content: "print('hello')")
        let readData = try encoder.encode(readResult)
        let decodedRead = try decoder.decode(ACPFSReadTextFileResult.self, from: readData)

        XCTAssertEqual(decodedRead.content, "print('hello')")
    }

    func testPermissionRequestAndResponseEncoding() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "id": 77,
            "method": "session/request_permission",
            "params": {
                "sessionId": "sess-789",
                "toolCall": {
                    "toolCallId": "call-1",
                    "title": "Run Swift tests",
                    "kind": "execute",
                    "status": "pending",
                    "rawInput": {"command": "swift test --filter ACPProtocolTests"}
                },
                "options": [
                    {"optionId": "allow-once", "name": "Allow once", "kind": "allow_once"},
                    {"optionId": "reject-once", "name": "Reject", "kind": "reject_once"}
                ]
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let request = try decoder.decode(JSONRPCRequest<ACPRequestPermissionParams>.self, from: json)

        XCTAssertEqual(request.id, 77)
        XCTAssertEqual(request.method, "session/request_permission")
        XCTAssertEqual(request.params?.sessionId, "sess-789")
        XCTAssertEqual(request.params?.toolCall.toolCallId, "call-1")
        XCTAssertEqual(request.params?.toolCall.rawInput?["command"]?.description, "swift test --filter ACPProtocolTests")
        XCTAssertEqual(request.params?.options.first?.optionId, "allow-once")

        let stringIDJSON = String(data: json, encoding: .utf8)!
            .replacingOccurrences(of: "\"id\": 77", with: "\"id\": \"permission-77\"")
        let stringRequest = try decoder.decode(
            JSONRPCAnyIDRequest<ACPRequestPermissionParams>.self,
            from: stringIDJSON.data(using: .utf8)!
        )
        XCTAssertEqual(stringRequest.id, .string("permission-77"))

        let selectedData = try JSONEncoder().encode(
            JSONRPCResponse(id: 77, result: ACPRequestPermissionResult.selected(optionId: "allow-once"))
        )
        let selected = try decoder.decode(JSONRPCResponse<ACPRequestPermissionResult>.self, from: selectedData)
        XCTAssertEqual(selected.result?.outcome.outcome, "selected")
        XCTAssertEqual(selected.result?.outcome.optionId, "allow-once")

        let cancelledData = try JSONEncoder().encode(
            JSONRPCResponse(id: 77, result: ACPRequestPermissionResult.cancelled)
        )
        let cancelled = try decoder.decode(JSONRPCResponse<ACPRequestPermissionResult>.self, from: cancelledData)
        XCTAssertEqual(cancelled.result?.outcome.outcome, "cancelled")
        XCTAssertNil(cancelled.result?.outcome.optionId)
    }

    func testConfigOptionDecodesSelectAndBooleanValues() throws {
        let decoder = JSONDecoder()
        let select = try decoder.decode(ACPConfigOption.self, from: """
        {
            "id": "mode",
            "name": "Mode",
            "category": "mode",
            "type": "select",
            "currentValue": "agent",
            "options": [
                {"value": "read-only", "name": "Read-only"},
                {"value": "agent", "name": "Agent"}
            ]
        }
        """.data(using: .utf8)!)
        XCTAssertEqual(select.category, "mode")
        XCTAssertEqual(select.options?.count, 2)
        XCTAssertEqual(select.options?.last?.name, "Agent")

        let boolean = try decoder.decode(ACPConfigOption.self, from: """
        {
            "id": "fast-mode",
            "name": "Fast mode",
            "type": "boolean",
            "currentValue": true
        }
        """.data(using: .utf8)!)
        XCTAssertEqual(boolean.currentValue, "true")
        XCTAssertEqual(boolean.type, "boolean")
    }

    func testOpenCodeSessionNewDecoding() throws {
        let opencodeJson = """
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "sessionId": "ses_12345",
                "configOptions": [
                    {
                        "id": "model",
                        "name": "Model",
                        "category": "model",
                        "type": "select",
                        "currentValue": "opencode/big-pickle",
                        "options": [
                            {"value": "opencode/big-pickle", "name": "OpenCode Zen/Big Pickle"},
                            {"value": "anthropic/claude-sonnet-4-5", "name": "Anthropic/claude-sonnet-4-5"}
                        ]
                    },
                    {
                        "id": "mode",
                        "name": "Session Mode",
                        "category": "mode",
                        "type": "select",
                        "currentValue": "build",
                        "options": [
                            {"value": "build", "name": "build", "description": "The default agent."},
                            {"value": "plan", "name": "plan", "description": "Plan mode."}
                        ]
                    }
                ]
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let resp = try decoder.decode(JSONRPCResponse<ACPSessionNewResult>.self, from: opencodeJson)
        XCTAssertEqual(resp.result?.sessionId, "ses_12345")
        XCTAssertEqual(resp.result?.configOptions?.count, 2)
        XCTAssertEqual(resp.result?.configOptions?.first?.id, "model")
        XCTAssertEqual(resp.result?.configOptions?.first?.currentValue, "opencode/big-pickle")
    }

    func testSessionListAndLoadEncoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let listJson = """
        {
            "jsonrpc": "2.0",
            "id": 2,
            "result": {
                "sessions": [
                    {
                        "sessionId": "ses_abc123",
                        "cwd": "/path/to/project",
                        "title": "Fix Parser",
                        "updatedAt": "2026-08-23T20:37:20.688Z"
                    },
                    {
                        "sessionId": "ses_def456",
                        "cwd": "/path/to/project",
                        "title": "Add Unit Tests",
                        "updatedAt": "2026-08-23T20:15:00.000Z"
                    }
                ],
                "nextCursor": "2026-08-23T20:15:00.000Z"
            }
        }
        """.data(using: .utf8)!

        let listResp = try decoder.decode(JSONRPCResponse<ACPSessionListResult>.self, from: listJson)
        XCTAssertEqual(listResp.result?.sessions.count, 2)
        XCTAssertEqual(listResp.result?.sessions[0].displayTitle, "Fix Parser")
        XCTAssertEqual(listResp.result?.sessions[0].sessionId, "ses_abc123")
        XCTAssertEqual(listResp.result?.nextCursor, "2026-08-23T20:15:00.000Z")
        XCTAssertFalse(listResp.result?.sessions[0].formattedDate.isEmpty ?? true)

        let loadParams = ACPSessionLoadParams(sessionId: "ses_abc123", cwd: "/path/to/project")
        let loadData = try encoder.encode(loadParams)
        let decodedLoadParams = try decoder.decode(ACPSessionLoadParams.self, from: loadData)
        XCTAssertEqual(decodedLoadParams.sessionId, "ses_abc123")
        XCTAssertEqual(decodedLoadParams.cwd, "/path/to/project")
    }

    func testSavedSessionsCoordinatorIntegration() async throws {
        let coordinator = AgentSessionCoordinator(isMockAgent: true, autoCreateSession: false)
        let savedSessions = try await coordinator.fetchSavedSessions(for: .mock, workingDirectory: "/test/dir")
        XCTAssertEqual(savedSessions.count, 3)
        XCTAssertEqual(savedSessions.first?.title, "Welcome & Onboarding Tour")

        let resumed = coordinator.resumeSavedSession(savedSession: savedSessions[0], preset: .mock, workingDirectory: "/test/dir")
        XCTAssertEqual(coordinator.sessions.count, 1)
        XCTAssertEqual(coordinator.activeSessionId, resumed.id)
        XCTAssertEqual(resumed.title, "Welcome & Onboarding Tour")
        XCTAssertEqual(coordinator.showStartScreen, false)
    }

    func testCodexEditToolCallStreamingUpdate() throws {
        let json = """
        {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": "01a0315e-4851-76a0-9af0-ffb4df1e355f",
                "update": {
                    "sessionUpdate": "tool_call",
                    "toolCallId": "exec-04740d69-f2e6-4d03-b9ed-1d38d47e2307",
                    "title": "Editing files",
                    "kind": "edit",
                    "status": "in_progress",
                    "content": [
                        {
                            "type": "diff",
                            "oldText": "line 1\\nline 2\\nline 3\\n",
                            "newText": "line 1\\nline 2 modified\\nline 3\\n",
                            "path": "/Users/max/dev/anydiff-swift2/README.md",
                            "_meta": {"kind": "update"}
                        }
                    ]
                }
            }
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let notif = try decoder.decode(JSONRPCNotification<ACPSessionUpdateNotificationParams>.self, from: json)
        let update = try XCTUnwrap(notif.params?.update)

        XCTAssertEqual(update.type, "tool_call")
        XCTAssertEqual(update.kind, "edit")
        XCTAssertEqual(update.title, "Editing files")
        XCTAssertEqual(update.toolCallId, "exec-04740d69-f2e6-4d03-b9ed-1d38d47e2307")

        let toolInput = try XCTUnwrap(update.toolInput)
        XCTAssertEqual(toolInput["path"]?.value as? String, "/Users/max/dev/anydiff-swift2/README.md")
        XCTAssertEqual(toolInput["old_content"]?.value as? String, "line 1\nline 2\nline 3\n")
        XCTAssertEqual(toolInput["new_content"]?.value as? String, "line 1\nline 2 modified\nline 3\n")
    }
}
