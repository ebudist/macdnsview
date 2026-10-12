import Foundation
import MacDNSViewCore

let result = await CLI.run(Array(CommandLine.arguments.dropFirst())) {
    // Only read a pipe or file; an interactive terminal means no input was meant.
    guard isatty(STDIN_FILENO) == 0 else { return nil }
    return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
}
FileHandle.standardOutput.write(Data(result.stdout.utf8))
FileHandle.standardError.write(Data(result.stderr.utf8))
exit(result.status)
