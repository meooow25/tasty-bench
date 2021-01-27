{- |
Module:      Test.Tasty.Bench
Copyright:   (c) 2021 Andrew Lelechenko
Licence:     MIT

Featherlight benchmark framework (only one file!) for performance measurement with API mimicking [@criterion@](http://hackage.haskell.org/package/criterion) and [@gauge@](http://hackage.haskell.org/package/gauge).

=== How lightweight is it?

There is only one source file "Test.Tasty.Bench" and no external dependencies
except [@tasty@](http://hackage.haskell.org/package/tasty).
So if you already depend on @tasty@ for a test suite, there
is nothing else to install.

Compare this to @criterion@ (10+ modules, 50+ dependencies) and @gauge@ (40+ modules, depends on @basement@ and @vector@).

=== How is it possible?

Our benchmarks are literally regular @tasty@ tests, so we can leverage all existing
machinery for command-line options, resource management, structuring,
listing and filtering benchmarks, running and reporting results. It also means
that @tasty-bench@ can be used in conjunction with other @tasty@ ingredients.

Unlike @criterion@ and @gauge@ we use a very simple statistical model described below.
This is arguably a questionable choice, but it works pretty well in practice.
A rare developer is sufficiently well-versed in probability theory
to make sense and use of all numbers generated by @criterion@.

=== How to switch?

[Cabal mixins](https://cabal.readthedocs.io/en/3.4/cabal-package.html#pkg-field-mixins)
allow to taste @tasty-bench@ instead of @criterion@ or @gauge@
without changing a single line of code:

@
cabal-version: 2.0

benchmark foo
  ...
  build-depends:
    tasty-bench
  mixins:
    tasty-bench (Test.Tasty.Bench as Criterion)
@

This works vice versa as well: if you use @tasty-bench@, but at some point
need a more comprehensive statistical analysis,
it is easy to switch temporarily back to @criterion@.

=== How to write a benchmark?

@
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
@

Since @tasty-bench@ provides an API compatible with @criterion@,
one can refer to [its documentation](http://www.serpentine.com/criterion/tutorial.html#how-to-write-a-benchmark-suite) for more examples.

=== How to read results?

Running the example above results in the following output:

@
All
  fibonacci numbers
    fifth:     OK (2.13s)
       63 ns ± 3.4 ns
    tenth:     OK (1.71s)
      809 ns ±  73 ns
    twentieth: OK (3.39s)
      104 μs ± 4.9 μs

All 3 tests passed (7.25s)
@

The output says that, for instance, the first benchmark
was repeatedly executed for 2.13 seconds (wall time),
its mean time was 63 nanoseconds and with 95% probability
execution time should not diverge from the mean
further than ±3.4 nanoseconds (double standard deviation).

=== Statistical model

Here is a procedure, used by @tasty-bench@ to measure execution time:

1. Set \( n \leftarrow 1 \).
2. Measure execution time \( t_n \)  of \( n \) iterations
   and execution time \( t_{2n} \) of \( 2n \) iterations.
3. Find \( t \) which minimizes deviation of \( (nt, 2nt) \) from \( (t_n, t_{2n}) \).
4. If deviation is small enough, return \( t \) as a mean execution time.
5. Otherwise set \( n \leftarrow 2n \) and jump back to Step 2.

This is roughly similar to the linear regression approach which @criterion@ takes,
but we fit only two last points. This allows us to simplify away all heavy-weight
statistical analysis. More importantly, earlier measurements,
which are presumably shorter and noisier, do not affect overall result.
This is in contrast to @criterion@, which fits all measurements and
is biased to use more data points corresponding to shorter runs
(it employs \( n \leftarrow 1.05n \) progression).

=== Tip

Passing @+RTS@ @-T@ (via @cabal@ @bench@ @--benchmark-options@ @'+RTS@ @-T'@
or @stack@ @bench@ @--ba@ @'+RTS@ @-T'@) enables @tasty-bench@ to estimate and report
memory usage such as allocated and copied bytes.

=== Command-line options

Use @--help@ to list command-line options.

[@-p@, @--pattern@]:
  This is a standard @tasty@ option, which allows filtering benchmarks
  by a pattern or @awk@ expression. Please refer
  to [@tasty@ documentation](https://github.com/feuerbach/tasty#patterns)
  for details.

[@--csv@]:
  File to write results in CSV format. If specified, suppresses console output.

[@-t@, @--timeout@]:
  This is a standard @tasty@ option, setting timeout for individual benchmarks
  in seconds. Use it when benchmarks tend to take too long: @tasty-bench@ will make
  an effort to report results (even if of subpar quality) before timeout. Setting
  timeout too tight (insufficient for at least three iterations of benchmark)
  will result in a benchmark failure. Do not use @--timeout@ without a reason:
  it forks an additional thread and thus affects reliability of measurements.

[@--stdev@]:
  Target relative standard deviation of measurements in percents (5% by default).
  Large values correspond to fast and loose benchmarks, and small ones to long and precise.
  If it takes far too long, consider setting @--timeout@,
  which will interrupt benchmarks, potentially before reaching the target deviation.

-}

{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}

module Test.Tasty.Bench
  (
  -- * Running 'Benchmark'
    defaultMain
  , Benchmark
  , bench
  , bgroup
  -- * Creating 'Benchmarkable'
  , Benchmarkable
  , nf
  , whnf
  , nfIO
  , whnfIO
  , nfAppIO
  , whnfAppIO
  -- * CSV ingredient
  , csvReporter
  ) where

import Control.Applicative
import Control.DeepSeq
import Control.Exception
import Control.Monad
import Data.Data (Typeable)
import Data.Int
import Data.List (intercalate)
import Data.Proxy
#if MIN_VERSION_base(4,6,0)
import GHC.Stats
#endif
import System.CPUTime
import System.Mem
import Test.Tasty hiding (defaultMain)
import qualified Test.Tasty
import Test.Tasty.Options
import Test.Tasty.Providers
import Text.Printf
import Test.Tasty.Runners
import Test.Tasty.Ingredients
import Test.Tasty.Ingredients.ConsoleReporter
import System.IO

newtype RelStDev = RelStDev { unRelStDev :: Double }
  deriving (Eq, Ord, Show, Typeable)

instance IsOption RelStDev where
  defaultValue = RelStDev 5
  parseValue = fmap RelStDev . safeRead
  optionName = pure "stdev"
  optionHelp = pure "Target relative standard deviation of measurements in percents (5 by default). Large values correspond to fast and loose benchmarks, and small ones to long and precise. If it takes far too long, consider setting --timeout, which will interrupt benchmarks, potentially before reaching the target deviation."

-- | Something that can be benchmarked.
--
-- Drop-in replacement for 'Criterion.Benchmarkable' and 'Gauge.Benchmarkable'.
--
newtype Benchmarkable = Benchmarkable { _unBenchmarkable :: Int64 -> IO () }
  deriving (Typeable)

showPicos :: Integer -> String
showPicos i
  | a == 0    = "0"
  | a < 995   = printf "%3.0f ps" t
  | a < 995e1 = printf "%3.1f ns" (t / 1e3)
  | a < 995e3 = printf "%3.0f ns" (t / 1e3)
  | a < 995e4 = printf "%3.1f μs" (t / 1e6)
  | a < 995e6 = printf "%3.0f μs" (t / 1e6)
  | a < 995e7 = printf "%3.1f ms" (t / 1e9)
  | a < 995e9 = printf "%3.0f ms" (t / 1e9)
  | otherwise = printf "%.1f s"   (t / 1e12)
  where
    t, a :: Double
    t = fromInteger i
    a = abs t

showBytes :: Integer -> String
showBytes i
  | a < 1000          = printf "%3.0f B " t
  | a < 10189         = printf "%3.1f KB" (t / 1024)
  | a < 1023488       = printf "%3.0f KB" (t / 1024)
  | a < 10433332      = printf "%3.1f MB" (t / 1048576)
  | a < 1048051712    = printf "%3.0f MB" (t / 1048576)
  | a < 10683731149   = printf "%3.1f GB" (t / 1073741824)
  | a < 1073204953088 = printf "%3.0f GB" (t / 1073741824)
  | otherwise         = printf "%.1f TB"  (t / 1099511627776)
  where
    t, a :: Double
    t = fromInteger i
    a = abs t

data Measurement = Measurement
  { measTime   :: !Integer -- ^ time in picoseconds
  , measAllocs :: !Integer -- ^ allocations in bytes
  , measCopied :: !Integer -- ^ copied bytes
  }

data Estimate = Estimate
  { estMean  :: !Measurement
  , estSigma :: !Integer  -- ^ stdev in picoseconds
  }

prettyEstimate :: Estimate -> String
prettyEstimate (Estimate m sigma) =
  -- Two sigmas correspond to 95% probability,
  showPicos (measTime m) ++ " ± " ++ showPicos (2 * sigma)

prettyEstimateWithGC :: Estimate -> String
prettyEstimateWithGC (Estimate m sigma) =
  -- Two sigmas correspond to 95% probability,
  showPicos (measTime m) ++ " ± " ++ showPicos (2 * sigma)
  ++ ", " ++ showBytes (measAllocs m) ++ " allocated, "
  ++ showBytes (measCopied m) ++ " copied"

csvEstimate :: Estimate -> String
csvEstimate (Estimate m sigma) = show (measTime m) ++ "," ++ show sigma

csvEstimateWithGC :: Estimate -> String
csvEstimateWithGC (Estimate m sigma) = show (measTime m) ++ "," ++ show sigma
  ++ "," ++ show (measAllocs m) ++ "," ++ show (measCopied m)

predict
  :: Measurement -- ^ time for one run
  -> Measurement -- ^ time for two runs
  -> Estimate
predict (Measurement t1 a1 c1) (Measurement t2 a2 c2) = Estimate
  { estMean  = Measurement t a c
  , estSigma = truncate (sqrt (fromInteger d) :: Double)
  }
  where
    sqr x = x * x
    d = sqr (t1 - t) + sqr (t2 - 2 * t)
    t = (t1 + 2 * t2) `quot` 5
    a = (a1 + 2 * a2) `quot` 5
    c = (c1 + 2 * c2) `quot` 5

predictPerturbed :: Measurement -> Measurement -> Estimate
predictPerturbed t1 t2 = Estimate
  { estMean = estMean (predict t1 t2)
  , estSigma = max
    (estSigma (predict (lo t1) (hi t2)))
    (estSigma (predict (hi t1) (lo t2)))
  }
  where
    prec = max cpuTimePrecision 1000000000 -- 1 ms
    hi meas = meas { measTime = measTime meas + prec }
    lo meas = meas { measTime = measTime meas - prec }

#if !MIN_VERSION_base(4,10,0)
getRTSStatsEnabled :: IO Bool
#if MIN_VERSION_base(4,6,0)
getRTSStatsEnabled = getGCStatsEnabled
#else
getRTSStatsEnabled = pure False
#endif
#endif

getAllocsAndCopied :: IO (Integer, Integer)
getAllocsAndCopied = do
  enabled <- getRTSStatsEnabled
  if not enabled then pure (0, 0) else
#if MIN_VERSION_base(4,10,0)
    (\s -> (toInteger $ allocated_bytes s, toInteger $ copied_bytes s)) <$> getRTSStats
#elif MIN_VERSION_base(4,6,0)
    (\s -> (toInteger $ bytesAllocated s, toInteger $ bytesCopied s)) <$> getGCStats
#else
    pure (0, 0)
#endif

measureTime :: Int64 -> Benchmarkable -> IO Measurement
measureTime n (Benchmarkable act) = do
  performGC
  startTime <- getCPUTime
  (startAllocs, startCopied) <- getAllocsAndCopied
  act n
  endTime <- getCPUTime
  (endAllocs, endCopied) <- getAllocsAndCopied
  pure $ Measurement
    { measTime   = endTime - startTime
    , measAllocs = endAllocs - startAllocs
    , measCopied = endCopied - startCopied
    }

measureTimeUntil :: Maybe Integer -> Double -> Benchmarkable -> IO Estimate
measureTimeUntil timeout targetRelStDev b = do
  t1 <- measureTime 1 b
  go 1 t1 0
  where
    go :: Int64 -> Measurement -> Integer -> IO Estimate
    go n t1 sumOfTs = do
      t2 <- measureTime (2 * n) b

      let Estimate (Measurement meanN allocN copiedN) sigmaN = predictPerturbed t1 t2
          isTimeoutSoon = case timeout of
            Nothing -> False
            -- multiplying by 1.2 helps to avoid accidental timeouts
            Just tmt  -> (sumOfTs + measTime t1 + 3 * measTime t2) * 12 >= tmt * 10
          isStDevInTargetRange = sigmaN < truncate (targetRelStDev * fromInteger meanN)
          scale = (`quot` toInteger n)

      if isStDevInTargetRange || isTimeoutSoon
        then pure $ Estimate (Measurement (scale meanN) (scale allocN) (scale copiedN)) (scale sigmaN)
        else go (2 * n) t2 (sumOfTs + measTime t1)

instance IsTest Benchmarkable where
  testOptions = pure [Option (Proxy :: Proxy RelStDev), Option (Proxy :: Proxy (Maybe CsvPath))]
  run opts b = const $ case getNumThreads (lookupOption opts) of
    1 -> do
      let targetRelStDev = unRelStDev (lookupOption opts) / 100
          timeout = case lookupOption opts of
            NoTimeout -> Nothing
            Timeout micros _ -> Just $ micros * 1000000
      hasGCStats <- getRTSStatsEnabled

      est <- measureTimeUntil timeout targetRelStDev b
      pure $ testPassed $ case lookupOption opts of
        Nothing        -> (if hasGCStats then prettyEstimateWithGC else prettyEstimate) est
        Just CsvPath{} -> (if hasGCStats then csvEstimateWithGC    else csvEstimate)    est
    _ -> pure $ testFailed "Benchmarks should be run in a single-threaded mode (--jobs 1)"

-- | Attach a name to 'Benchmarkable'.
--
-- This is actually a synonym of 'Test.Tasty.Providers.singleTest'
-- to provide an interface compatible with 'Criterion.bench' and 'Gauge.bench'.
--
bench :: String -> Benchmarkable -> Benchmark
bench = singleTest

-- | Attach a name to a group of 'Benchmark'.
--
-- This is actually a synonym of 'Test.Tasty.testGroup'
-- to provide an interface compatible with 'Criterion.bgroup'
-- and 'Gauge.bgroup'.
--
bgroup :: String -> [Benchmark] -> Benchmark
bgroup = testGroup

-- | Benchmarks are actually just a regular 'Test.Tasty.TestTree' in disguise.
--
-- This is a drop-in replacement for 'Criterion.Benchmark' and 'Gauge.Benchmark'.
--
type Benchmark = TestTree

-- | Run benchmarks and report results.
--
-- Wrapper around 'Test.Tasty.defaultMain' (+ 'csvReporter')
-- to provide an interface compatible with 'Criterion.defaultMain'
-- and 'Gauge.defaultMain'.
--
defaultMain :: [Benchmark] -> IO ()
defaultMain = Test.Tasty.defaultMainWithIngredients ingredients . testGroup "All"
  where
    ingredients = [listingTests, csvReporter, consoleTestReporter]


funcToBench :: (b -> c) -> (a -> b) -> a -> Benchmarkable
funcToBench frc = (Benchmarkable .) . go
  where
    go f x n
      | n <= 0    = pure ()
      | otherwise = do
        _ <- evaluate (frc (f x))
        go f x (n - 1)
{-# INLINE funcToBench #-}

-- | 'nf' @f@ @x@ measures time to compute
-- a normal form (by means of 'rnf') of @f@ @x@.
--
-- Note that forcing a normal form requires an additional
-- traverse of the structure. In certain scenarios (imagine benchmarking 'tail'),
-- especially when 'NFData' instance is badly written,
-- this traversal may take non-negligible time and affect results.
--
-- Drop-in replacement for 'Criterion.nf' and 'Gauge.nf'.
--
nf :: NFData b => (a -> b) -> a -> Benchmarkable
nf = funcToBench rnf
{-# INLINE nf #-}

-- | 'whnf' @f@ @x@ measures time to compute
-- a weak head normal form of @f@ @x@.
--
-- Computing only a weak head normal form is
-- rarely what intuitively is meant by "evaluation".
-- Unless you understand precisely, what is measured,
-- it is recommended to use 'nf' instead.
--
-- Drop-in replacement for 'Criterion.whnf' and 'Gauge.whnf'.
--
whnf :: (a -> b) -> a -> Benchmarkable
whnf = funcToBench id
{-# INLINE whnf #-}

ioToBench :: (b -> c) -> IO b -> Benchmarkable
ioToBench frc act = Benchmarkable go
  where
    go n
      | n <= 0    = pure ()
      | otherwise = do
        val <- act
        _ <- evaluate (frc val)
        go (n - 1)
{-# INLINE ioToBench #-}

-- | 'nfIO' @x@ measures time to evaluate side-effects of @x@
-- and compute its normal form (by means of 'rnf').
--
-- Pure subexpression of an effectful computation @x@
-- may be evaluated only once and get cached; use 'nfAppIO'
-- to avoid this.
--
-- Note that forcing a normal form requires an additional
-- traverse of the structure. In certain scenarios,
-- especially when 'NFData' instance is badly written,
-- this traversal may take non-negligible time and affect results.
--
-- Drop-in replacement for 'Criterion.nfIO' and 'Gauge.nfIO'.
--
nfIO :: NFData a => IO a -> Benchmarkable
nfIO = ioToBench rnf
{-# INLINE nfIO #-}

-- | 'whnfIO' @x@ measures time to evaluate side-effects of @x@
-- and compute its weak head normal form.
--
-- Pure subexpression of an effectful computation @x@
-- may be evaluated only once and get cached; use 'whnfAppIO'
-- to avoid this.
--
-- Computing only a weak head normal form is
-- rarely what intuitively is meant by "evaluation".
-- Unless you understand precisely, what is measured,
-- it is recommended to use 'nfIO' instead.
--
-- Drop-in replacement for 'Criterion.whnfIO' and 'Gauge.whnfIO'.
--
whnfIO :: NFData a => IO a -> Benchmarkable
whnfIO = ioToBench id
{-# INLINE whnfIO #-}

ioFuncToBench :: (b -> c) -> (a -> IO b) -> a -> Benchmarkable
ioFuncToBench frc = (Benchmarkable .) . go
  where
    go f x n
      | n <= 0    = pure ()
      | otherwise = do
        val <- f x
        _ <- evaluate (frc val)
        go f x (n - 1)
{-# INLINE ioFuncToBench #-}

-- | 'nfAppIO' @f@ @x@ measures time to evaluate side-effects of @f@ @x@
-- and compute its normal form (by means of 'rnf').
--
-- Note that forcing a normal form requires an additional
-- traverse of the structure. In certain scenarios,
-- especially when 'NFData' instance is badly written,
-- this traversal may take non-negligible time and affect results.
--
-- Drop-in replacement for 'Criterion.nfAppIO' and 'Gauge.nfAppIO'.
--
nfAppIO :: NFData b => (a -> IO b) -> a -> Benchmarkable
nfAppIO = ioFuncToBench rnf
{-# INLINE nfAppIO #-}

-- | 'whnfAppIO' @f@ @x@ measures time to evaluate side-effects of @f@ @x@
-- and compute its weak head normal form.
--
-- Computing only a weak head normal form is
-- rarely what intuitively is meant by "evaluation".
-- Unless you understand precisely, what is measured,
-- it is recommended to use 'nfAppIO' instead.
--
-- Drop-in replacement for 'Criterion.whnfAppIO' and 'Gauge.whnfAppIO'.
--
whnfAppIO :: (a -> IO b) -> a -> Benchmarkable
whnfAppIO = ioFuncToBench id
{-# INLINE whnfAppIO #-}

newtype CsvPath = CsvPath { _unCsvPath :: FilePath }
  deriving (Typeable)

instance IsOption (Maybe CsvPath) where
  defaultValue = Nothing
  parseValue = Just . Just . CsvPath
  optionName = pure "csv"
  optionHelp = pure "File to write results in CSV format. If specified, suppresses console output"

-- | Add this ingredient to run benchmarks and save results in CSV format.
-- It activates when @--csv@ @FILE@ command line option is specified.
--
-- @
-- defaultMainWithIngredients [listingTests, csvReporter, consoleTestReporter] benchmarks
-- @
--
-- Remember that successful activation of an ingredient suppresses all subsequent
-- ingredients. If you wish to produce CSV in addition to other reports,
-- use 'composeReporters':
--
-- @
-- defaultMainWithIngredients [listingTests, composeReporters csvReporter consoleTestReporter] benchmarks
-- @
--
csvReporter :: Ingredient
csvReporter = TestReporter [Option (Proxy :: Proxy (Maybe CsvPath))] $
  \opts tree -> do
    CsvPath path <- lookupOption opts
    pure $ \smap -> do
      bracket
        (do
          h <- openFile path WriteMode
          hSetBuffering h LineBuffering
          hasGCStats <- getRTSStatsEnabled
          hPutStrLn h $ "Name,Mean (ps),Stdev (ps)" ++
            (if hasGCStats then ",Allocated,Copied" else "")
          pure h
        )
        hClose
        (\h -> csvOutput (buildCsvOutput h opts tree) smap)
      pure $ const ((== 0) . statFailures <$> computeStatistics smap)

buildCsvOutput :: Handle -> OptionSet -> TestTree -> TestOutput
buildCsvOutput h = ((($ []) . getApp) .) . foldTestTree
  trivialFold { foldSingle = const runSingleTest, foldGroup =
#if MIN_VERSION_tasty(1,4,0)
    const runGroup
#else
    runGroup
#endif
  }
  where
    runSingleTest name = const $ Ap $ \prefix -> PrintTest name
      (hPutStr h $ encodeCsv (intercalate "." (reverse (name : prefix))) ++ ",")
      (hPutStrLn h <=< formatMessage . resultDescription)

    runGroup name (Ap grp) = Ap $ \prefix -> grp (name : prefix)

csvOutput :: TestOutput -> StatusMap -> IO ()
csvOutput = (getTraversal .) . foldTestOutput (const foldTest) (const (const id))
  where
    foldTest printName getResult printResult =
      Traversal $ printName >> getResult >>= printResult

encodeCsv :: String -> String
encodeCsv xs
  | any (`elem` xs) ",\"\n\r"
  = '"' : concatMap (\x -> if x == '"' then "\"\"" else [x]) xs ++ "\""
  | otherwise = xs
