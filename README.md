# tasty-bench [![Hackage](http://img.shields.io/hackage/v/tasty-bench.svg)](https://hackage.haskell.org/package/tasty-bench) [![Stackage Nightly](http://stackage.org/package/tasty-bench/badge/nightly)](http://stackage.org/nightly/package/tasty-bench)

Featherlight benchmark framework (only one file!) for performance measurement
with API mimicking [`criterion`](http://hackage.haskell.org/package/criterion)
and [`gauge`](http://hackage.haskell.org/package/gauge).
A prominent feature is built-in comparison against baseline.

## How lightweight is it?

There is only one source file `Test.Tasty.Bench` and no non-boot dependencies
except [`tasty`](http://hackage.haskell.org/package/tasty).
So if you already depend on `tasty` for a test suite, there
is nothing else to install.

Compare this to `criterion` (10+ modules, 50+ dependencies) and `gauge` (40+ modules, depends on `basement` and `vector`).

## How is it possible?

Our benchmarks are literally regular `tasty` tests, so we can leverage all existing
machinery for command-line options, resource management, structuring,
listing and filtering benchmarks, running and reporting results. It also means
that `tasty-bench` can be used in conjunction with other `tasty` ingredients.

Unlike `criterion` and `gauge` we use a very simple statistical model described below.
This is arguably a questionable choice, but it works pretty well in practice.
A rare developer is sufficiently well-versed in probability theory
to make sense and use of all numbers generated by `criterion`.

## How to switch?

[Cabal mixins](https://cabal.readthedocs.io/en/3.4/cabal-package.html#pkg-field-mixins)
allow to taste `tasty-bench` instead of `criterion` or `gauge`
without changing a single line of code:

```cabal
cabal-version: 2.0

benchmark foo
  ...
  build-depends:
    tasty-bench
  mixins:
    tasty-bench (Test.Tasty.Bench as Criterion, Test.Tasty.Bench as Criterion.Main)
```

This works vice versa as well: if you use `tasty-bench`, but at some point
need a more comprehensive statistical analysis,
it is easy to switch temporarily back to `criterion`.

## How to write a benchmark?

Benchmarks are declared in a separate section of `cabal` file:

```cabal
cabal-version:   2.0
name:            bench-fibo
version:         0.0
build-type:      Simple
synopsis:        Example of a benchmark

benchmark bench-fibo
  main-is:       BenchFibo.hs
  type:          exitcode-stdio-1.0
  build-depends: base, tasty-bench
```

And here is `BenchFibo.hs`:

```haskell
import Test.Tasty.Bench

fibo :: Int -> Integer
fibo n = if n < 2 then toInteger n else fibo (n - 1) + fibo (n - 2)

main :: IO ()
main = defaultMain
  [ bgroup "fibonacci numbers"
    [ bench "fifth"     $ nf fibo  5
    , bench "tenth"     $ nf fibo 10
    , bench "twentieth" $ nf fibo 20
    ]
  ]
```

Since `tasty-bench` provides an API compatible with `criterion`,
one can refer to [its documentation](http://www.serpentine.com/criterion/tutorial.html#how-to-write-a-benchmark-suite) for more examples.

## How to read results?

Running the example above (`cabal bench` or `stack bench`)
results in the following output:

```
All
  fibonacci numbers
    fifth:     OK (2.13s)
       63 ns ± 3.4 ns
    tenth:     OK (1.71s)
      809 ns ±  73 ns
    twentieth: OK (3.39s)
      104 μs ± 4.9 μs

All 3 tests passed (7.25s)
```

The output says that, for instance, the first benchmark
was repeatedly executed for 2.13 seconds (wall time),
its mean time was 63 nanoseconds and,
assuming ideal precision of a system clock,
execution time does not often diverge from the mean
further than ±3.4 nanoseconds
(double standard deviation, which for normal distributions
corresponds to [95%](https://en.wikipedia.org/wiki/68%E2%80%9395%E2%80%9399.7_rule)
probability). Take standard deviation numbers
with a grain of salt; there are lies, damned lies, and statistics.

Note that this data is not directly comparable with `criterion` output:

```
benchmarking fibonacci numbers/fifth
time                 62.78 ns   (61.99 ns .. 63.41 ns)
                     0.999 R²   (0.999 R² .. 1.000 R²)
mean                 62.39 ns   (61.93 ns .. 62.94 ns)
std dev              1.753 ns   (1.427 ns .. 2.258 ns)
```

One might interpret the second line as saying that
95% of measurements fell into 61.99–63.41 ns interval, but this is wrong.
It states that the [OLS regression](https://en.wikipedia.org/wiki/Ordinary_least_squares)
of execution time (which is not exactly the mean time) is most probably
somewhere between 61.99 ns and 63.41 ns,
but does not say a thing about individual measurements.
To understand how far away a typical measurement deviates
you need to add/subtract double standard deviation yourself
(which gives 62.78 ns ± 3.506 ns, similar to `tasty-bench` above).

To add to the confusion, `gauge` in `--small` mode outputs
not the second line of `criterion` report as one might expect,
but a mean value from the penultimate line and a standard deviation:

```
fibonacci numbers/fifth                  mean 62.39 ns  ( +- 1.753 ns  )
```

The interval ±1.753 ns answers
for [68%](https://en.wikipedia.org/wiki/68%E2%80%9395%E2%80%9399.7_rule)
of samples only, double it to estimate the behavior in 95% of cases.

## Statistical model

Here is a procedure used by `tasty-bench` to measure execution time:

1. Set _n_ ← 1.
2. Measure execution time _tₙ_ of _n_ iterations
   and execution time _t₂ₙ_ of _2n_ iterations.
3. Find _t_ which minimizes deviation of (_nt_, _2nt_) from (_tₙ_, _t₂ₙ_).
4. If deviation is small enough (see `--stdev` below),
   return _t_ as a mean execution time.
5. Otherwise set _n_ ← _2n_ and jump back to Step 2.

This is roughly similar to the linear regression approach which `criterion` takes,
but we fit only two last points. This allows us to simplify away all heavy-weight
statistical analysis. More importantly, earlier measurements,
which are presumably shorter and noisier, do not affect overall result.
This is in contrast to `criterion`, which fits all measurements and
is biased to use more data points corresponding to shorter runs
(it employs _n_ ← _1.05n_ progression).

An alert reader could object that we measure standard deviation
for samples with _n_ and _2n_ iterations, but report
it scaled to a single iteration.
Strictly speaking, this is justified only if we assume
that deviating factors are either roughly periodic
(e. g., coarseness of a system clock, garbage collection)
or are likely to affect several successive iterations in the same way
(e. g., slow down by another concurrent process).

Obligatory disclaimer: statistics is a tricky matter, there is no
one-size-fits-all approach.
In the absence of a good theory
simplistic approaches are as (un)sound as obscure ones.
Those who seek statistical soundness should rather collect raw data
and process it themselves using a proper statistical toolbox.
Data reported by `tasty-bench`
is only of indicative and comparative significance.

## Memory usage

Passing `+RTS -T` (via `cabal bench --benchmark-options '+RTS -T'`
or `stack bench --ba '+RTS -T'`) enables `tasty-bench` to estimate and report
memory usage such as allocated and copied bytes:

```
All
  fibonacci numbers
    fifth:     OK (2.13s)
       63 ns ± 3.4 ns, 223 B  allocated,   0 B  copied
    tenth:     OK (1.71s)
      809 ns ±  73 ns, 2.3 KB allocated,   0 B  copied
    twentieth: OK (3.39s)
      104 μs ± 4.9 μs, 277 KB allocated,  59 B  copied

All 3 tests passed (7.25s)
```

## Combining tests and benchmarks

When optimizing an existing function, it is important to check that its
observable behavior remains unchanged. One can rebuild
both tests and benchmarks after each change, but it would be more convenient
to run sanity checks within benchmark itself. Since our benchmarks
are compatible with `tasty` tests, we can easily do so.

Imagine you come up with a faster function `myFibo` to generate Fibonacci numbers:

```haskell
import Test.Tasty.Bench
import Test.Tasty.QuickCheck -- from tasty-quickcheck package

fibo :: Int -> Integer
fibo n = if n < 2 then toInteger n else fibo (n - 1) + fibo (n - 2)

myFibo :: Int -> Integer
myFibo n = if n < 3 then toInteger n else myFibo (n - 1) + myFibo (n - 2)

main :: IO ()
main = Test.Tasty.Bench.defaultMain -- not Test.Tasty.defaultMain
  [ bench "fibo   20" $ nf fibo   20
  , bench "myFibo 20" $ nf myFibo 20
  , testProperty "myFibo = fibo" $ \n -> fibo n === myFibo n
  ]
```

This outputs:

```
All
  fibo   20:     OK (3.02s)
    104 μs ± 4.9 μs
  myFibo 20:     OK (1.99s)
     71 μs ± 5.3 μs
  myFibo = fibo: FAIL
    *** Failed! Falsified (after 5 tests and 1 shrink):
    2
    1 /= 2
    Use --quickcheck-replay=927711 to reproduce.

1 out of 3 tests failed (5.03s)
```

We see that `myFibo` is indeed significantly faster than `fibo`,
but unfortunately does not do the same thing. One should probably
look for another way to speed up generation of Fibonacci numbers.

## Troubleshooting

* If benchmarks take too long, set `--timeout` to limit execution time
  of individual benchmarks, and `tasty-bench` will do its best to fit
  into given timeframe. Without `--timeout` we rerun benchmarks until
  achieving a target precision set by `--stdev`, which in a noisy environment
  of a modern laptop with GUI may take a lot of time.

  While `criterion` runs each benchmark at least for 5 seconds,
  `tasty-bench` is happy to conclude earlier, if it does not compromise
  the quality of results. In our experiments `tasty-bench` suites
  tend to finish earlier, even if some individual benchmarks
  take longer than with `criterion`.

* If benchmark results look malformed like below, make sure that you are
  invoking `Test.Tasty.Bench.defaultMain` and not `Test.Tasty.defaultMain`
  (the difference is `consoleBenchReporter` vs. `consoleTestReporter`):

  ```
  All
    fibo 20:       OK (1.46s)
      Response {respEstimate = Estimate {estMean = Measurement {measTime = 87496728, measAllocs = 0, measCopied = 0}, estStdev = 694487}, respIfSlower = FailIfSlower Infinity, respIfFaster = FailIfFaster Infinity}
  ```

## Comparison against baseline

One can compare benchmark results against an earlier baseline in an automatic way.
To use this feature, first run `tasty-bench` with `--csv FILE` key
to dump results to `FILE` in CSV format
(it could be a good idea to set smaller `--stdev`, if possible):

```
Name,Mean (ps),2*Stdev (ps)
All.fibonacci numbers.fifth,48453,4060
All.fibonacci numbers.tenth,637152,46744
All.fibonacci numbers.twentieth,81369531,3342646
```

Note that columns do not match CSV reports of `criterion` and `gauge`.
If desired, missing columns can be faked with
`awk 'BEGIN {FS=",";OFS=","}; {print $1,$2,$2,$2,$3/2,$3/2,$3/2}'` or similar.

Now modify implementation and rerun benchmarks
with `--baseline FILE` key. This produces a report as follows:

```
All
  fibonacci numbers
    fifth:     OK (0.44s)
       53 ns ± 2.7 ns,  8% slower than baseline
    tenth:     OK (0.33s)
      641 ns ±  59 ns
    twentieth: OK (0.36s)
       77 μs ± 6.4 μs,  5% faster than baseline

All 3 tests passed (1.50s)
```

You can also fail benchmarks, which deviate too far from baseline, using
`--fail-if-slower` and `--fail-if-faster` options. For example, setting both of them
to 6 will fail the first benchmark above (because it is more than 6% slower),
but the last one still succeeds (even while it is measurably faster than baseline,
deviation is less than 6%). Consider also using `--hide-successes` to show
only problematic benchmarks, or even
[`tasty-rerun`](http://hackage.haskell.org/package/tasty-rerun) package
to focus on rerunning failing items only.

## Command-line options

Use `--help` to list command-line options.

* `-p`, `--pattern`

  This is a standard `tasty` option, which allows filtering benchmarks
  by a pattern or `awk` expression. Please refer to
  [`tasty` documentation](https://github.com/feuerbach/tasty#patterns)
  for details.

* `-t`, `--timeout`

  This is a standard `tasty` option, setting timeout for individual benchmarks
  in seconds. Use it when benchmarks tend to take too long: `tasty-bench` will make
  an effort to report results (even if of subpar quality) before timeout. Setting
  timeout too tight (insufficient for at least three iterations)
  will result in a benchmark failure.

* `--stdev`

  Target relative standard deviation of measurements in percents (5% by default).
  Large values correspond to fast and loose benchmarks, and small ones to long and precise.
  If it takes far too long, consider setting `--timeout`,
  which will interrupt benchmarks, potentially before reaching the target deviation.

* `--csv`

  File to write results in CSV format.

* `--baseline`

  File to read baseline results in CSV format (as produced by `--csv`).

* `--fail-if-slower`, `--fail-if-faster`

  Upper bounds of acceptable slow down / speed up in percents. If a benchmark is unacceptably slower / faster than baseline (see `--baseline`),
  it will be reported as failed. Can be used in conjunction with
  a standard `tasty` option `--hide-successes` to show only problematic benchmarks.
