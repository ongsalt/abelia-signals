// swift run -c release Benchmark            → checks + all benchmarks
// swift run -c release Benchmark check      → correctness checks only
// swift run -c release Benchmark <filter>   → benchmarks whose name contains <filter>

let filter = CommandLine.arguments.dropFirst().first

if filter == nil || filter == "check" {
    runChecks()
}

if filter != "check" {
    registerPrimitives()
    registerShapes()
    runBenchmarks(filter: filter)
}
