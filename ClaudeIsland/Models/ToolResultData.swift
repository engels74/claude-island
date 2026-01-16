//
//  ToolResultData.swift
//  ClaudeIsland
//
//  Structured models for all Claude Code tool results
//

import Foundation

// MARK: - ToolResultData

/// Structured tool result data - parsed from JSONL tool_result blocks
enum ToolResultData: Equatable, Sendable {
    case read(ReadResult)
    case edit(EditResult)
    case write(WriteResult)
    case bash(BashResult)
    case grep(GrepResult)
    case glob(GlobResult)
    case todoWrite(TodoWriteResult)
    case task(TaskResult)
    case webFetch(WebFetchResult)
    case webSearch(WebSearchResult)
    case askUserQuestion(AskUserQuestionResult)
    case bashOutput(BashOutputResult)
    case killShell(KillShellResult)
    case exitPlanMode(ExitPlanModeResult)
    case mcp(MCPResult)
    case generic(GenericResult)
}

// MARK: - ReadResult

struct ReadResult: Equatable, Sendable {
    let filePath: String
    let content: String
    let numLines: Int
    let startLine: Int
    let totalLines: Int

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - EditResult

struct EditResult: Equatable, Sendable {
    let filePath: String
    let oldString: String
    let newString: String
    let replaceAll: Bool
    let userModified: Bool
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - PatchHunk

struct PatchHunk: Equatable, Sendable {
    let oldStart: Int
    let oldLines: Int
    let newStart: Int
    let newLines: Int
    let lines: [String]
}

// MARK: - WriteResult

struct WriteResult: Equatable, Sendable {
    enum WriteType: String, Equatable, Sendable {
        case create
        case overwrite
    }

    let type: WriteType
    let filePath: String
    let content: String
    let structuredPatch: [PatchHunk]?

    var filename: String {
        URL(fileURLWithPath: filePath).lastPathComponent
    }
}

// MARK: - BashResult

struct BashResult: Equatable, Sendable {
    let stdout: String
    let stderr: String
    let interrupted: Bool
    let isImage: Bool
    let returnCodeInterpretation: String?
    let backgroundTaskID: String?

    var hasOutput: Bool {
        !stdout.isEmpty || !stderr.isEmpty
    }

    var displayOutput: String {
        if !stdout.isEmpty {
            return stdout
        }
        if !stderr.isEmpty {
            return stderr
        }
        return "(No content)"
    }
}

// MARK: - GrepResult

struct GrepResult: Equatable, Sendable {
    enum Mode: String, Equatable, Sendable {
        case filesWithMatches = "files_with_matches"
        case content
        case count
    }

    let mode: Mode
    let filenames: [String]
    let numFiles: Int
    let content: String?
    let numLines: Int?
    let appliedLimit: Int?
}

// MARK: - GlobResult

struct GlobResult: Equatable, Sendable {
    let filenames: [String]
    let durationMs: Int
    let numFiles: Int
    let truncated: Bool
}

// MARK: - TodoWriteResult

struct TodoWriteResult: Equatable, Sendable {
    let oldTodos: [TodoItem]
    let newTodos: [TodoItem]
}

// MARK: - TodoItem

struct TodoItem: Equatable, Sendable {
    let content: String
    let status: String // "pending", "in_progress", "completed"
    let activeForm: String?
}

// MARK: - TaskResult

struct TaskResult: Equatable, Sendable {
    let agentID: String
    let status: String
    let content: String
    let prompt: String?
    let totalDurationMs: Int?
    let totalTokens: Int?
    let totalToolUseCount: Int?
}

// MARK: - WebFetchResult

struct WebFetchResult: Equatable, Sendable {
    let url: String
    let code: Int
    let codeText: String
    let bytes: Int
    let durationMs: Int
    let result: String
}

// MARK: - WebSearchResult

struct WebSearchResult: Equatable, Sendable {
    let query: String
    let durationSeconds: Double
    let results: [SearchResultItem]
}

// MARK: - SearchResultItem

struct SearchResultItem: Equatable, Sendable {
    let title: String
    let url: String
    let snippet: String
}

// MARK: - AskUserQuestionResult

struct AskUserQuestionResult: Equatable, Sendable {
    let questions: [QuestionItem]
    let answers: [String: String]
}

// MARK: - QuestionItem

struct QuestionItem: Equatable, Sendable {
    let question: String
    let header: String?
    let options: [QuestionOption]
}

// MARK: - QuestionOption

struct QuestionOption: Equatable, Sendable {
    let label: String
    let description: String?
}

// MARK: - BashOutputResult

struct BashOutputResult: Equatable, Sendable {
    let shellID: String
    let status: String
    let stdout: String
    let stderr: String
    let stdoutLines: Int
    let stderrLines: Int
    let exitCode: Int?
    let command: String?
    let timestamp: String?
}

// MARK: - KillShellResult

struct KillShellResult: Equatable, Sendable {
    let shellID: String
    let message: String
}

// MARK: - ExitPlanModeResult

struct ExitPlanModeResult: Equatable, Sendable {
    let filePath: String?
    let plan: String?
    let isAgent: Bool
}

// MARK: - MCPResult

struct MCPResult: Equatable, @unchecked Sendable {
    let serverName: String
    let toolName: String
    let rawResult: [String: Any]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.serverName == rhs.serverName &&
            lhs.toolName == rhs.toolName &&
            NSDictionary(dictionary: lhs.rawResult).isEqual(to: rhs.rawResult)
    }
}

// MARK: - GenericResult

struct GenericResult: Equatable, @unchecked Sendable {
    let rawContent: String?
    let rawData: [String: Any]?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.rawContent == rhs.rawContent
    }
}

// MARK: - ToolStatusDisplay

struct ToolStatusDisplay {
    let text: String
    let isRunning: Bool

    /// Get running status text for a tool
    static func running(for toolName: String, input: [String: String]) -> Self {
        switch toolName {
        case "Read":
            return Self(text: "Reading...", isRunning: true)
        case "Edit":
            return Self(text: "Editing...", isRunning: true)
        case "Write":
            return Self(text: "Writing...", isRunning: true)
        case "Bash":
            if let desc = input["description"], !desc.isEmpty {
                return Self(text: desc, isRunning: true)
            }
            return Self(text: "Running...", isRunning: true)
        case "Grep",
             "Glob":
            if let pattern = input["pattern"] {
                return Self(text: "Searching: \(pattern)", isRunning: true)
            }
            return Self(text: "Searching...", isRunning: true)
        case "WebSearch":
            if let query = input["query"] {
                return Self(text: "Searching: \(query)", isRunning: true)
            }
            return Self(text: "Searching...", isRunning: true)
        case "WebFetch":
            return Self(text: "Fetching...", isRunning: true)
        case "Task":
            if let desc = input["description"], !desc.isEmpty {
                return Self(text: desc, isRunning: true)
            }
            return Self(text: "Running agent...", isRunning: true)
        case "TodoWrite":
            return Self(text: "Updating todos...", isRunning: true)
        case "EnterPlanMode":
            return Self(text: "Entering plan mode...", isRunning: true)
        case "ExitPlanMode":
            return Self(text: "Exiting plan mode...", isRunning: true)
        default:
            return Self(text: "Running...", isRunning: true)
        }
    }

    /// Get completed status text for a tool result
    static func completed(for toolName: String, result: ToolResultData?) -> Self {
        guard let result else {
            return Self(text: "Completed", isRunning: false)
        }

        switch result {
        case let .read(readResult):
            let lineText = readResult.totalLines > readResult.numLines ? "\(readResult.numLines)+ lines" : "\(readResult.numLines) lines"
            return Self(text: "Read \(readResult.filename) (\(lineText))", isRunning: false)

        case let .edit(editResult):
            return Self(text: "Edited \(editResult.filename)", isRunning: false)

        case let .write(writeResult):
            let action = writeResult.type == .create ? "Created" : "Wrote"
            return Self(text: "\(action) \(writeResult.filename)", isRunning: false)

        case let .bash(bashResult):
            if let bgID = bashResult.backgroundTaskID {
                return Self(text: "Running in background (\(bgID))", isRunning: false)
            }
            if let interpretation = bashResult.returnCodeInterpretation {
                return Self(text: interpretation, isRunning: false)
            }
            return Self(text: "Completed", isRunning: false)

        case let .grep(grepResult):
            let fileWord = grepResult.numFiles == 1 ? "file" : "files"
            return Self(text: "Found \(grepResult.numFiles) \(fileWord)", isRunning: false)

        case let .glob(globResult):
            let fileWord = globResult.numFiles == 1 ? "file" : "files"
            if globResult.numFiles == 0 {
                return Self(text: "No files found", isRunning: false)
            }
            return Self(text: "Found \(globResult.numFiles) \(fileWord)", isRunning: false)

        case .todoWrite:
            return Self(text: "Updated todos", isRunning: false)

        case let .task(taskResult):
            return Self(text: taskResult.status.capitalized, isRunning: false)

        case let .webFetch(fetchResult):
            return Self(text: "\(fetchResult.code) \(fetchResult.codeText)", isRunning: false)

        case let .webSearch(searchResult):
            let time = searchResult.durationSeconds >= 1 ?
                "\(Int(searchResult.durationSeconds))s" :
                "\(Int(searchResult.durationSeconds * 1000))ms"
            let searchWord = searchResult.results.count == 1 ? "search" : "searches"
            return Self(text: "Did 1 \(searchWord) in \(time)", isRunning: false)

        case .askUserQuestion:
            return Self(text: "Answered", isRunning: false)

        case let .bashOutput(outputResult):
            return Self(text: "Status: \(outputResult.status)", isRunning: false)

        case .killShell:
            return Self(text: "Terminated", isRunning: false)

        case .exitPlanMode:
            return Self(text: "Plan ready", isRunning: false)

        case .mcp:
            return Self(text: "Completed", isRunning: false)

        case .generic:
            return Self(text: "Completed", isRunning: false)
        }
    }
}
