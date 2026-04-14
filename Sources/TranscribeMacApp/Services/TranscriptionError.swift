import Foundation

enum TranscriptionError: LocalizedError {
    case validation(String)
    case commandLaunchFailed(command: String, underlying: String)
    case commandFailed(command: String, exitCode: Int32, message: String)
    case outputNotFound(String)
    case fileOperation(String)
    case apiFailure(statusCode: Int, message: String)
    case cancelled(String)

    var errorDescription: String? {
        switch self {
        case let .validation(message):
            return message
        case let .commandLaunchFailed(command, underlying):
            return "Could not run command '\(command)': \(underlying)"
        case let .commandFailed(command, exitCode, message):
            return "Command '\(command)' failed (code \(exitCode)). \(message)"
        case let .outputNotFound(message):
            return message
        case let .fileOperation(message):
            return message
        case let .apiFailure(statusCode, message):
            return "OpenAI API request failed (HTTP \(statusCode)). \(message)"
        case let .cancelled(message):
            return message
        }
    }
}
