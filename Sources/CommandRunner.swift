import Foundation
import Darwin

struct CommandResult {
    let status: Int32
    let output: Data
    let diagnosticMessage: LocalizedMessage?
    var diagnostic: String? { diagnosticMessage?.value }
}

enum CommandRunner {
    /// Drain both pipes while the command runs. No blocking EOF reads or main-queue work.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 3) -> CommandResult {
        let process = Process()
        let stdout = Pipe(), stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        _ = fcntl(outFD, F_SETFL, O_NONBLOCK)
        _ = fcntl(errFD, F_SETFL, O_NONBLOCK)
        defer {
            try? stdout.fileHandleForReading.close()
            try? stderr.fileHandleForReading.close()
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { return CommandResult(status: -1, output: Data(), diagnosticMessage: LocalizedMessage("无法启动 \(URL(fileURLWithPath: executable).lastPathComponent)：\(error.localizedDescription)", "Unable to start \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)")) }
        var output = Data(), errors = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var failure: LocalizedMessage?
        let limit = 8 * 1024 * 1024
        func drain(_ descriptor: Int32, into data: inout Data) {
            var buffer = [UInt8](repeating: 0, count: 16384)
            while data.count <= limit {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 { data.append(contentsOf: buffer.prefix(count)) }
                else if count < 0 && errno == EINTR { continue }
                else { break }
            }
        }
        while true {
            drain(outFD, into: &output)
            drain(errFD, into: &errors)
            if output.count > limit || errors.count > limit { failure = LocalizedMessage("采样输出超过容量限制", "Sample output exceeded the size limit"); break }
            if !process.isRunning {
                drain(outFD, into: &output)
                drain(errFD, into: &errors)
                break
            }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = LocalizedMessage("\(URL(fileURLWithPath: executable).lastPathComponent) 采样超时（\(Int(timeout)) 秒）", "\(URL(fileURLWithPath: executable).lastPathComponent) timed out after \(timeout) seconds"); break }
            var descriptors = [pollfd(fd: outFD, events: Int16(POLLIN), revents: 0),
                               pollfd(fd: errFD, events: Int16(POLLIN), revents: 0)]
            _ = poll(&descriptors, nfds_t(descriptors.count), 10)
        }
        if failure != nil {
            if process.isRunning { process.terminate() }
            let grace = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { usleep(10000) }
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
            return CommandResult(status: -1, output: Data(), diagnosticMessage: failure)
        }
        let error = String(decoding: errors.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(status: process.terminationStatus, output: output,
                             diagnosticMessage: error.isEmpty ? nil : LocalizedMessage(error, error))
    }
}
