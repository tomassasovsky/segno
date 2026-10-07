# bench_pitch_time

- CPU: Raspberry Pi 5 Model B Rev 1.1 / Cortex-A76 (part 0xd0b)
- timed loops (baseline, head, inline): SCHED_FIFO 70, held only for the loop
- rate 96000 Hz, period 64 frames, budget 667.0 us, 60 s per scenario, 30 s loops

## baseline (le_engine_process, 8 tracks PLAYING)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 tracks x 1 lane                  |     53.5 |     58.6 |    146.5 |     53.7 |    8.0% |    8.8% |
| 8 tracks x 8 lanes                 |    193.3 |    203.1 |    478.1 |    192.4 |   29.0% |   30.4% |
| 8 tracks x 1 lane at 1/2           |     61.6 |     66.8 |    512.5 |     61.8 |    9.2% |   10.0% |
| 8 tracks x 8 lanes at 1/2          |    210.7 |    219.5 |    310.2 |    210.8 |   31.6% |   32.9% |
| 8 tracks x 1 lane at 4/1           |     64.8 |     74.3 |    250.8 |     65.7 |    9.7% |   11.1% |
| 8 tracks x 8 lanes at 4/1          |    292.9 |    309.1 |    565.5 |    292.4 |   43.9% |   46.3% |
| 8 tracks x 1 lane at 8/1           |     66.6 |     75.1 |    168.1 |     67.1 |   10.0% |   11.3% |
| 8 tracks x 8 lanes at 8/1          |    355.6 |    406.9 |    445.3 |    357.7 |   53.3% |   61.0% |
| 8 x 8 with Pre chains at 8/1       |    968.6 |    985.6 |   1283.5 |    969.1 |  145.2% |  147.8% |
| 8 x 8, Pre chains, 8/1, all +7 st  |    962.5 |    977.3 |   1229.8 |    962.9 |  144.3% |  146.5% |

- transposed rig: 8 of 8 tracks sounding +7 st when timed; renders took 128.7 s; peak RSS after them 2936 MiB

## head (engine_read_head.h kernel; 'added' = minus the mixer's integer read)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 8 lanes integer read (control)     |      1.5 |      2.7 |     19.3 |      1.6 |    0.2% |    0.4% |
| 8 lanes identity head              |      5.3 |      6.8 |     11.3 |      5.4 |    0.8% |    1.0% |
| 8 lanes 1/2x                       |      5.4 |      6.0 |     75.7 |      5.4 |    0.8% |    0.9% |
| 8 lanes 2x                         |      6.9 |      7.4 |     34.1 |      7.0 |    1.0% |    1.1% |
| 8 lanes 4x                         |      8.5 |     10.7 |     22.7 |      8.6 |    1.3% |    1.6% |
| 8 lanes 8x                         |     11.3 |     12.6 |     37.5 |     11.4 |    1.7% |    1.9% |
| 8 lanes ratio 0.75                 |      5.7 |      6.5 |     75.5 |      5.7 |    0.8% |    1.0% |
| 8 lanes ratio 4/3                  |      5.4 |      6.7 |     16.0 |      5.5 |    0.8% |    1.0% |
| 8 lanes worst ADDED                |      9.8 |      9.9 |          |          |    1.5% |    1.5% |
| 64 lanes integer read (control)    |     15.5 |     18.7 |    120.7 |     15.6 |    2.3% |    2.8% |
| 64 lanes identity head             |     22.7 |     27.1 |    181.1 |     22.8 |    3.4% |    4.1% |
| 64 lanes 1/2x                      |     20.4 |     22.6 |     83.6 |     20.4 |    3.1% |    3.4% |
| 64 lanes 2x                        |     84.5 |     91.1 |    141.1 |     84.3 |   12.7% |   13.7% |
| 64 lanes 4x                        |    148.8 |    156.8 |    253.7 |    148.3 |   22.3% |   23.5% |
| 64 lanes 8x                        |    179.4 |    188.4 |    280.7 |    179.3 |   26.9% |   28.2% |
| 64 lanes ratio 0.75                |     23.5 |     26.1 |     41.3 |     23.5 |    3.5% |    3.9% |
| 64 lanes ratio 4/3                 |     30.1 |     34.7 |     51.3 |     30.1 |    4.5% |    5.2% |
| 64 lanes worst ADDED               |    163.8 |    169.7 |          |          |   24.6% |   25.4% |

## inline (streaming le_stretch_process, 64 frames per call; informational)

| scenario                           |  p50 us |  p99 us |  max us | mean us | p50/bud | p99/bud |
|------------------------------------|---------|---------|---------|---------|---------|---------|
| 1 streams aligned                  |      0.5 |    801.6 |    875.3 |     13.9 |    0.1% |  120.2% |
| 1 streams staggered                |      0.5 |    803.4 |    834.5 |     14.0 |    0.1% |  120.5% |
| 8 streams aligned                  |      4.2 |   7469.5 |   7654.6 |    128.9 |    0.6% | 1119.9% |
| 8 streams staggered                |      4.3 |    964.8 |   1150.5 |    129.0 |    0.6% |  144.6% |
| 64 streams aligned                 |     33.9 |  59352.1 |  60354.9 |   1024.6 |    5.1% | 8898.4% |
| 64 streams staggered               |    967.2 |   1922.8 |   2049.2 |   1030.5 |  145.0% |  288.3% |

seek re-prime (block + interval frames): 25.9 us (3.9% of the period)

## render (le_stretch_render_offline, 30 s mono, x real time)

| configuration              |   idle |   loaded | peak heap KiB | scratch KiB |
|----------------------------|--------|----------|---------------|-------------|
| cheaper +12 st ratio 1     |   47.8x |    43.7x |          1176 |          71 |
| cheaper -12 st ratio 1     |   48.7x |    44.6x |          1176 |          71 |
| cheaper stretch 0.75       |   61.6x |    56.3x |          1176 |          71 |
| cheaper stretch 4/3        |   34.6x |    31.7x |          1176 |          71 |
| default +12 st ratio 1     |   36.7x |    33.4x |          1184 |          79 |
| default stretch 0.75       |   46.4x |    42.3x |          1184 |          79 |

renderer thread (read back): SCHED_OTHER, nice 10; load thread (read back): SCHED_FIFO 70

## memory

- stretcher live heap per mono instance: cheaper 1105 KiB, default 1105 KiB
- render worker scratch (peak C++ heap during a render minus one stretcher), worst recipe: 79 KiB
- rendered entry: 2880000 frames x 4 = 11.0 MiB per mono lane (the caller's buffer, outside the scratch)
- peak RSS: 2936 MiB

## verdict (Pi 5 thresholds)

- PASS: head added p99 at 8 lanes <= 10% of period (1.49 vs 10.00)
- PASS: head added p99 at 64 lanes <= 35% of period (25.44 vs 35.00)
- PASS: baseline p99 + head added p99 (8 lanes) <= 50% of period (10.27 vs 50.00)
- PASS: render cheaper under load >= 20x real time (31.70 vs 20.00)
- PASS: mixer at 1/2x, 4x, 8x p99 (8 lanes) <= 50% of period (11.26 vs 50.00)
- FAIL: mixer at 1/2x, 4x, 8x p99 (64 lanes) <= 50% of period (61.00 vs 50.00)
- FAIL: 8 x 8 with live Pre chains at 8x p99 <= 50% of period (147.77 vs 50.00)
- FAIL: 8 x 8, chains, 8x, all transposed p99 <= 50% of period (146.52 vs 50.00)
- PASS: transposed rig: every track sounding its pitch (8.00 vs 8.00)
- PASS: render worker scratch under 1 MiB (0.08 vs 1.00)
- PASS: stretcher heap per instance (cheaper) <= 4 MiB (1.08 vs 4.00)

THRESHOLDS FAILED
