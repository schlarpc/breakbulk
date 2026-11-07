use criterion::{Criterion, black_box, criterion_group, criterion_main};

fn bench_fib(c: &mut Criterion) {
    c.bench_function("fib 15", |b| b.iter(|| bencher::fib(black_box(15))));
}

criterion_group!(benches, bench_fib);
criterion_main!(benches);
