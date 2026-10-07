# bench_instruments

- CPU: Raspberry Pi 5 Model B Rev 1.1 / Cortex-A76 (part 0xd0b)
- timed loops: SCHED_FIFO 70, held only for the loop
- rate 96000 Hz, period 64 frames, budget 667.0 us, 60 s per pool scenario, 5.00 s per patch
- le_synth state: 38568 bytes; default pool 32 voices, 64 fade slots

## patches (8 voices each, one le_synth_render per period)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| piano                              |      7.3 |      7.4 |     24.1 |      7.3 |    1.1% |    1.1% |
| keys                               |      9.6 |      9.7 |     13.0 |      9.6 |    1.4% |    1.5% |
| clav                               |      7.3 |      9.4 |     16.1 |      7.3 |    1.1% |    1.4% |
| organ                              |     11.7 |     13.9 |     17.3 |     11.8 |    1.8% |    2.1% |
| reed                               |     10.4 |     12.6 |     16.4 |     10.5 |    1.6% |    1.9% |
| lead                               |      7.4 |      9.6 |     14.1 |      7.5 |    1.1% |    1.4% |
| pad                                |      7.2 |      7.4 |     14.4 |      7.2 |    1.1% |    1.1% |
| pluck                              |      8.6 |      8.8 |     13.1 |      8.6 |    1.3% |    1.3% |
| bass                               |      7.2 |      7.3 |      9.6 |      7.2 |    1.1% |    1.1% |
| synth-bass                         |      7.2 |      7.3 |      9.4 |      7.2 |    1.1% |    1.1% |
| sub                                |      9.5 |      9.7 |     12.0 |      9.6 |    1.4% |    1.4% |
| strings                            |      7.4 |      7.5 |     10.6 |      7.4 |    1.1% |    1.1% |
| violin                             |      7.2 |      9.4 |     15.6 |      7.3 |    1.1% |    1.4% |
| cello                              |      7.2 |      9.3 |      9.6 |      7.3 |    1.1% |    1.4% |
| drums                              |      7.6 |      9.8 |     10.6 |      7.7 |    1.1% |    1.5% |
| electronic-drums                   |      7.6 |      9.8 |     10.4 |      7.7 |    1.1% |    1.5% |
| marimba                            |      9.6 |     11.8 |     16.7 |      9.7 |    1.4% |    1.8% |
| vibes                              |      9.6 |     11.8 |     16.0 |      9.7 |    1.4% |    1.8% |
| bells                              |     11.8 |     11.9 |     17.1 |     11.8 |    1.8% |    1.8% |

costliest patch: organ

## voices (64-voice pool)

| scenario                           |  p50 us |  p99 us | p99.9 us |  max us | p50/bud | p99/bud | p99.9/bud | late |
|------------------------------------|---------|---------|----------|---------|---------|---------|-----------|------|
| organ x 8                          |     11.7 |     11.8 |     13.3 |     38.1 |    1.8% |    1.8% |    2.0% |     0 |
| organ x 16                         |     22.8 |     23.5 |     27.3 |     37.8 |    3.4% |    3.5% |    4.1% |     0 |
| organ x 32                         |     44.9 |     48.8 |     50.2 |     83.6 |    6.7% |    7.3% |    7.5% |     0 |
| organ x 64                         |     89.4 |     94.3 |     96.7 |    255.1 |   13.4% |   14.1% |   14.5% |     0 |
| mixed set x 8                      |      8.7 |      9.0 |     10.0 |     30.4 |    1.3% |    1.3% |    1.5% |     0 |
| mixed set x 16                     |     16.4 |     16.9 |     19.9 |     71.8 |    2.5% |    2.5% |    3.0% |     0 |
| mixed set x 32                     |     31.8 |     33.0 |     36.3 |     71.9 |    4.8% |    5.0% |    5.4% |     0 |
| mixed set x 64                     |     62.3 |     66.1 |     67.2 |    102.7 |    9.3% |    9.9% |   10.1% |     0 |

## burst (32 note-ons + the block they land in)

| scenario                           |  p50 us |  p99 us | p99.9 us |  max us | p50/bud | p99/bud | p99.9/bud | late |
|------------------------------------|---------|---------|----------|---------|---------|---------|-----------|------|
| 32-note burst, idle pool           |     51.8 |     55.3 |     56.6 |     84.6 |    7.8% |    8.3% |    8.5% |     0 |
| 32-note burst, full pool           |     99.8 |    104.4 |    105.1 |    134.4 |   15.0% |   15.6% |   15.8% |     0 |

## engine (le_engine_process, 8 tracks x 8 lanes PLAYING; informational)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 x 8 lanes                        |    533.9 |    581.7 |   1465.9 |    507.4 |   80.0% |   87.2% |
| 8 x 8 lanes + 32 voices            |    230.7 |    242.2 |    388.1 |    230.2 |   34.6% |   36.3% |

## joint (8 x 8 lanes + 8 monitored inputs with reverb + read head 8x + 32 voices)

| scenario                           |  p50 us |  p99 us | p99.9 us |  max us | p50/bud | p99/bud | p99.9/bud | late |
|------------------------------------|---------|---------|----------|---------|---------|---------|-----------|------|
| joint without instruments          |    380.8 |    398.8 |    409.9 |    826.6 |   57.1% |   59.8% |   61.5% |     1 |
| joint worst case                   |    431.6 |    453.5 |    474.7 |    870.9 |   64.7% |   68.0% |   71.2% |     7 |

- instruments' share of the joint period, p50: 50.8 us (7.6%)

- peak RSS: 815 MiB

## verdict (Pi 5 thresholds)

- PASS: 32 voices p99.9 <= 15% of period (7.52 vs 15.00)
- PASS: 64 voices p99.9 <= 30% of period (14.50 vs 30.00)
- PASS: 32-note burst p99.9 <= 20% of period (15.76 vs 20.00)
- PASS: joint worst case p99.9 <= 75% of period (71.17 vs 75.00)
- FAIL: joint worst case: no period over the budget (7.00 vs 0.00)

voice pool: 64 (64 when the 64-voice threshold passes)

THRESHOLDS FAILED
