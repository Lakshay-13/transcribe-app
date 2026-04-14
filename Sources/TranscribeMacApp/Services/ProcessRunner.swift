import Darwin
import Foundation

struct ProcessOutput: Sendable {
    let exitCode: Int32
    let standardOutput: String
    let standardError: String
}

struct ProcessRunner: Sendable {
    func run(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        onStandardOutput: (@Sendable (String) -> Void)? = nil,
        onStandardError: (@Sendable (String) -> Void)? = nil,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        process.standardInput = stdinHandle

        let stdoutBuffer = LockedDataBuffer()
        let stderrBuffer = LockedDataBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }

            stdoutBuffer.append(data)
            onStandardOutput?(String(decoding: data, as: UTF8.self))
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }

            stderrBuffer.append(data)
            onStandardError?(String(decoding: data, as: UTF8.self))
        }

        do {
            try process.run()
        } catch {
            throw TranscriptionError.commandLaunchFailed(command: "\(executablePath) \(arguments.joined(separator: " "))", underlying: error.localizedDescription)
        }

        var cancelled = false
        while process.isRunning {
            if isCancelled?() == true {
                cancelled = true
                process.terminate()
                break
            }
            Thread.sleep(forTimeInterval: 0.08)
        }

        process.waitUntilExit()

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStdout.isEmpty {
            stdoutBuffer.append(remainingStdout)
            onStandardOutput?(String(decoding: remainingStdout, as: UTF8.self))
        }

        let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrBuffer.append(remainingStderr)
            onStandardError?(String(decoding: remainingStderr, as: UTF8.self))
        }

        stdinHandle.closeFile()
        stdoutPipe.fileHandleForReading.closeFile()
        stderrPipe.fileHandleForReading.closeFile()

        let stdout = stdoutBuffer.stringValue
        let stderr = stderrBuffer.stringValue

        if cancelled {
            throw TranscriptionError.cancelled("Transcription stopped.")
        }

        return ProcessOutput(exitCode: process.terminationStatus, standardOutput: stdout, standardError: stderr)
    }

    func runCancellable(
        executablePath: String,
        arguments: [String],
        workingDirectory: URL? = nil,
        onStandardOutput: (@Sendable (String) -> Void)? = nil,
        onStandardError: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessOutput {
        try Task.checkCancellation()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/null"))
        process.standardInput = stdinHandle

        let stdoutBuffer = LockedDataBuffer()
        let stderrBuffer = LockedDataBuffer()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }

            stdoutBuffer.append(data)
            onStandardOutput?(String(decoding: data, as: UTF8.self))
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }

            stderrBuffer.append(data)
            onStandardError?(String(decoding: data, as: UTF8.self))
        }

        let terminator = ProcessTerminator(process: process)

        let output = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessOutput, Error>) in
                process.terminationHandler = { _ in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil

                    let remainingStdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingStdout.isEmpty {
                        stdoutBuffer.append(remainingStdout)
                        onStandardOutput?(String(decoding: remainingStdout, as: UTF8.self))
                    }

                    let remainingStderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                    if !remainingStderr.isEmpty {
                        stderrBuffer.append(remainingStderr)
                        onStandardError?(String(decoding: remainingStderr, as: UTF8.self))
                    }

                    stdinHandle.closeFile()
                    stdoutPipe.fileHandleForReading.closeFile()
                    stderrPipe.fileHandleForReading.closeFile()

                    continuation.resume(
                        returning: ProcessOutput(
                            exitCode: process.terminationStatus,
                            standardOutput: stdoutBuffer.stringValue,
                            standardError: stderrBuffer.stringValue
                        )
                    )
                }

                do {
                    try process.run()
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                    stdinHandle.closeFile()
                    stdoutPipe.fileHandleForReading.closeFile()
                    stderrPipe.fileHandleForReading.closeFile()

                    continuation.resume(
                        throwing: TranscriptionError.commandLaunchFailed(
                            command: "\(executablePath) \(arguments.joined(separator: " "))",
                            underlying: error.localizedDescription
                        )
                    )
                }
            }
        }, onCancel: {
            terminator.requestTermination()
        })

        try Task.checkCancellation()
        return output
    }
}

private final class ProcessTerminator: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    func requestTermination() {
        lock.lock()
        defer { lock.unlock() }

        guard process.isRunning else { return }
        process.terminate()

        let pid = process.processIdentifier
        guard pid > 0 else { return }

        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.2) {
            kill(pid_t(pid), SIGKILL)
        }
    }
}

private final class LockedDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    var stringValue: String {
        lock.lock()
        let output = String(decoding: data, as: UTF8.self)
        lock.unlock()
        return output
    }
}
