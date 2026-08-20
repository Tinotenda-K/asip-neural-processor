# Synthesis and implementation reports

Exported unedited from AMD Vivado 2025.1 targeting the Spartan-7 XC7S50, so the
figures quoted in the top-level README can be checked rather than taken on trust.

Reports are held for **both** configurations, which is what makes the comparison
in `benchmark.md` verifiable rather than asserted.

## Files

| File | Contents |
|---|---|
| `mac4/timing_summary.txt` | Static timing, MAC4 build, post-route physopt. WNS **+0.029 ns**, TNS 0.000, WHS **+0.034 ns**, 0 of **3,694** endpoints failing. |
| `mac4/utilisation.txt` | Post-placement resource usage: 2,005 LUTs, 1,054 registers, 103 CARRY4, 33 BRAM tiles, 0 DSP. |
| `mac4/report_power.txt` | 0.166 W total on-chip, 0.092 W dynamic. Per-hierarchy breakdown puts the ALU at 0.002 W. |
| `mac4/report_clock_utilization.txt` | Two BUFGs: `sys_clk` at 100 MHz, `core_clk` at 50 MHz with 1,086 clock loads. |
| `baseline/timing_summary_baseline_mac.txt` | Static timing, MAC-only build, routed. WNS **+1.270 ns**, WHS **+0.152 ns**, 0 of **3,632** endpoints failing. |
| `baseline/utilisation_baseline_mac.txt` | 1,661 LUTs, 1,024 registers, 50 CARRY4, 33 BRAM tiles, 0 DSP. |
| `baseline/report_power_baseline_mac.txt` | 0.156 W total on-chip, 0.081 W dynamic. |
| `baseline/report_control_sets_baseline_mac.txt`, `report_io_baseline_mac.txt`, `implementation_log_baseline_mac.txt` | Control-set histogram, pin assignment, and the full implementation transcript. |
| `benchmark.md` | The comparison: instruction counts, cycle counts, resource and timing deltas, critical paths, power and energy. |

**Check `LUT as Memory` reads zero** in either utilisation report. Non-zero means
a memory reverted to distributed LUTRAM, which on this design means it will not
place — see [../docs/debugging.md](../docs/debugging.md).

## Reading the timing number

+0.029 ns on a 20 ns period looks alarming and is better than it looks, for a
specific reason that has to be read out of the report body rather than the
summary line.

**The MAC4 build carries 500 ps of self-imposed pessimism.** The path detail
shows total clock uncertainty of 0.535 ns, decomposed as 0.035 ns of jitter plus
a **User Uncertainty of 0.500 ns** — an explicit
`set_clock_uncertainty 0.500 [get_clocks core_clk]` in the XDC. That 500 ps is
subtracted from the requirement before slack is computed, so the design is
passing a constraint half a nanosecond tighter than the hardware imposes. Strip
it and WNS is ≈ **+0.529 ns**.

**The baseline does not carry it.** Its paths report 0.035 ns of uncertainty,
jitter only. So the +1.270 ns and +0.029 ns figures are *not* directly
comparable, and the raw −1.241 ns delta overstates the cost of `MAC4` by about
40%. Like-for-like the instruction costs ≈ 0.74 ns. **The baseline should be
rebuilt with the same uncertainty constraint** before the two numbers are quoted
side by side; until then `benchmark.md` marks the adjusted row as arithmetic
rather than measurement.

Two further points in the design's favour:

- Vivado's slow corner already assumes worst-case process, 0.95 V and 85 °C. A
  bench board at room temperature and nominal voltage has margin beyond the
  reported number.
- Hold slack is +0.034 ns with THS exactly zero, and TNS is exactly zero, so
  nothing is marginal in the other direction and no endpoint is being traded off
  against another.

The remaining honest caveat is placement variance: WNS at this margin moves with
the seed, and an added debug port can cost more than it appears to.

## Where the time goes

The two builds fail in different places, which is the more interesting result
and is set out in full in `benchmark.md`. In short: the baseline's worst path
ends at the data-memory address port (17.804 ns, 19 logic levels, 5 CARRY4 of
address adder); the MAC4 build's worst path ends at the register-file write port
— the accumulator writeback — at 19.446 ns over 23 logic levels with 11 CARRY4.
All ten of its worst setup paths end there. The `MAC4` adder tree defines the
critical path in the build that uses it.