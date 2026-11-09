// node --expose-gc bench.ts [filter]   (Node ≥ 22.18 / 23.6 strips types natively)
// bun bench.ts [filter]
//   no arg   → checks + all benchmarks
//   check    → correctness checks only
//   <filter> → benchmarks whose name contains <filter>

import { runBenchmarks } from "./harness.ts"
import { registerPrimitives } from "./primitives.ts"
import { registerShapes } from "./shapes.ts"
import { runChecks } from "./correctness.ts"

const filter = process.argv[2]

if (filter === undefined || filter === "check") runChecks()

if (filter !== "check") {
  registerPrimitives()
  registerShapes()
  runBenchmarks(filter)
}
