import Foundation

@main
enum Entry {
    static func main() {
        if CommandLine.arguments.contains("--cli") {
            Task {
                let code = await CLI.run(CommandLine.arguments)
                exit(code)
            }
            dispatchMain()
        }
        ClaudeHelperApp.main()
    }
}
