import Foundation
import ScreenBridgeMacCore

// Claude Desktop launches this over stdio. Nothing but JSON-RPC may go to stdout.
MCPServer.runStdio()
