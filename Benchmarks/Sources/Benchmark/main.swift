// swift run -c release Benchmark            → all benchmarks
// swift run -c release Benchmark <filter>   → benchmarks whose name contains <filter>
// correctness checks are tests now: `swift test` in the root package

let filter = CommandLine.arguments.dropFirst().first

registerPrimitives()
registerShapes()
runBenchmarks(filter: filter)
