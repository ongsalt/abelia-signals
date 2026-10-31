// The same cases as Sources/Benchmarks/main.swift, against alien-signals.
import { signal, computed, effect, effectScope } from "alien-signals";

let sink = 0;

function bench(name, make, opsPerRun = 1) {
  const [run, teardown] = make();
  let iters = 1;
  while (true) {
    const t0 = performance.now();
    for (let i = 0; i < iters; i++) run();
    if (performance.now() - t0 >= 100 || iters >= 2 ** 30) break;
    iters *= 2;
  }
  const samples = [];
  for (let k = 0; k < 5; k++) {
    const t0 = performance.now();
    for (let i = 0; i < iters; i++) run();
    samples.push(((performance.now() - t0) * 1e6) / (iters * opsPerRun));
  }
  teardown();
  samples.sort((a, b) => a - b);
  console.log(`${name}\t${samples[2]}`);
}

for (const w of [1, 10, 100]) {
  for (const h of [1, 10, 100]) {
    bench(`propagate ${w}x${h}`, () => {
      const src = signal(1);
      const dispose = effectScope(() => {
        for (let i = 0; i < w; i++) {
          let last = computed(() => src());
          for (let j = 1; j < h; j++) {
            const prev = last;
            last = computed(() => prev() + 1);
          }
          const tail = last;
          effect(() => { sink += tail(); });
        }
      });
      return [() => src(src() + 1), dispose];
    });
  }
}

bench("create signal+computed+effect (x1000)", () => [() => {
  const dispose = effectScope(() => {
    for (let i = 0; i < 1000; i++) {
      const s = signal(i);
      const c = computed(() => s() * 2);
      effect(() => { sink += c(); });
    }
  });
  dispose();
}, () => {}], 1000);

bench("dynamic deps: swap 50 of 100", () => {
  const sources = Array.from({ length: 100 }, (_, i) => signal(i));
  const which = signal(0);
  const dispose = effectScope(() => {
    effect(() => {
      const w = which();
      let sum = 0;
      for (let i = w; i < 100; i += 2) sum += sources[i]();
      sink += sum;
    });
  });
  return [() => which(1 - which()), dispose];
});

bench("read cached computed (x1000)", () => {
  const s = signal(1);
  const c = computed(() => s() * 2);
  return [() => { for (let i = 0; i < 1000; i++) sink += c(); }, () => {}];
}, 1000);

console.log(`sink\t${sink}`);
