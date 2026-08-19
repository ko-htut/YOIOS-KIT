import Foundation
import Darwin

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    let stdoutData: Data
    let stderrData: Data
    let timedOut: Bool
}

enum ProcessRunner {
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 15
    ) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let semaphore = DispatchSemaphore(value: 0)
        let readGroup = DispatchGroup()
        var stdoutData = Data()
        var stderrData = Data()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ToolchainExecutionEnvironment.sanitized()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { _ in semaphore.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                stdoutData: Data(),
                stderrData: Data(error.localizedDescription.utf8),
                timedOut: false
            )
        }

        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            readGroup.leave()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        let timedOut = waitResult == .timedOut
        if timedOut {
            if process.isRunning {
                process.terminate()
                _ = semaphore.wait(timeout: .now() + 1)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 1)
            }

        }

        if readGroup.wait(timeout: .now() + 2) == .timedOut {
            try? stdoutPipe.fileHandleForReading.close()
            try? stderrPipe.fileHandleForReading.close()
            readGroup.wait()
        }

        let capturedStdout = stdoutData
        let capturedStderr = stderrData
        let out = String(data: capturedStdout, encoding: .utf8) ?? ""
        let err = String(data: capturedStderr, encoding: .utf8) ?? ""

        return CommandResult(
            exitCode: timedOut ? -2 : process.terminationStatus,
            stdout: out,
            stderr: err,
            stdoutData: capturedStdout,
            stderrData: capturedStderr,
            timedOut: timedOut
        )
    }

    @discardableResult
    static func stream(
        _ executable: String,
        _ arguments: [String],
        onLine: @escaping (String) -> Void,
        onExit: @escaping (Int32, String?) -> Void
    ) -> Process? {
        let process = Process()
        let pipe = Pipe()
        let readQueue = DispatchQueue(
            label: "local.minthanhtut.SE2RecoveryAssistant.stream",
            qos: .userInitiated
        )

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ToolchainExecutionEnvironment.sanitized()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            readQueue.async {
                var pending = Data()

                func emit(_ lineData: Data) {
                    var line = String(decoding: lineData, as: UTF8.self)
                    line = line.replacingOccurrences(of: "\r", with: "")
                    if !line.isEmpty { onLine(line) }
                }

                while true {
                    let chunk: Data
                    do {
                        chunk = try pipe.fileHandleForReading.read(upToCount: 16_384) ?? Data()
                    } catch {
                        break
                    }
                    if chunk.isEmpty { break }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        emit(pending.prefix(upTo: newline))
                        pending.removeSubrange(...newline)
                    }
                }

                if !pending.isEmpty { emit(pending) }
                process.waitUntilExit()
                onExit(process.terminationStatus, nil)
            }
            return process
        } catch {
            onExit(-1, error.localizedDescription)
            return nil
        }
    }
}
