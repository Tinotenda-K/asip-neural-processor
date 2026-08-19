set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports clk]
set_property -dict {PACKAGE_PIN J2 IOSTANDARD LVCMOS33} [get_ports rst]
set_property -dict {PACKAGE_PIN G1 IOSTANDARD LVCMOS33} [get_ports {pc_out[0]}]
set_property -dict {PACKAGE_PIN G2 IOSTANDARD LVCMOS33} [get_ports {pc_out[1]}]
set_property -dict {PACKAGE_PIN F1 IOSTANDARD LVCMOS33} [get_ports {pc_out[2]}]
set_property -dict {PACKAGE_PIN F2 IOSTANDARD LVCMOS33} [get_ports {pc_out[3]}]
set_property -dict {PACKAGE_PIN E1 IOSTANDARD LVCMOS33} [get_ports {pc_out[4]}]
set_property -dict {PACKAGE_PIN E2 IOSTANDARD LVCMOS33} [get_ports {pc_out[5]}]
set_property -dict {PACKAGE_PIN E3 IOSTANDARD LVCMOS33} [get_ports {pc_out[6]}]
set_property -dict {PACKAGE_PIN E5 IOSTANDARD LVCMOS33} [get_ports {pc_out[7]}]
set_property -dict {PACKAGE_PIN E6 IOSTANDARD LVCMOS33} [get_ports {pc_out[8]}]
set_property -dict {PACKAGE_PIN C3 IOSTANDARD LVCMOS33} [get_ports {pc_out[9]}]
set_property -dict {PACKAGE_PIN B2 IOSTANDARD LVCMOS33} [get_ports {pc_out[10]}]
set_property -dict {PACKAGE_PIN A2 IOSTANDARD LVCMOS33} [get_ports {result_out[0]}]
set_property -dict {PACKAGE_PIN B3 IOSTANDARD LVCMOS33} [get_ports {result_out[1]}]
set_property -dict {PACKAGE_PIN A3 IOSTANDARD LVCMOS33} [get_ports {result_out[2]}]
set_property -dict {PACKAGE_PIN B4 IOSTANDARD LVCMOS33} [get_ports {result_out[3]}]
set_property -dict {PACKAGE_PIN A4 IOSTANDARD LVCMOS33} [get_ports done]
# ============================================================================
# Boolean board (xc7s50csga324-1)
#
# 1. Board clock stays 100 MHz. The core runs on a /2 generated clock, which
#    is what the timing engine must be told about -- otherwise it keeps
#    analysing every core path against the 10 ns period and keeps failing.
# 2. CFGBVS / CONFIG_VOLTAGE silence the CFGBVS-1 DRC warning.
# 3. rst is asynchronous and synchronised in TopModule; mark it false path
#    so it stops appearing as an unconstrained 11 ns path.
# 4. Output pins are not timing-critical -- no output delay needed, but
#    declaring them false paths removes the TIMING-18 warnings.
# ============================================================================

# ============================================================================
#
# THE BLOCKER IN THE PREVIOUS VERSION
# -----------------------------------
# clk, rst and pc_out[15:0] had NO pin assignments -- the LOC/IOSTANDARD lines
# were all still commented out at the bottom of the file. Vivado auto-placed
# them (clk landed on P14, rst on R15) which is why place & route succeeded,
# but the DRC reported:
#
#   NSTD-1  Critical Warning  18 of 23 ports use IOSTANDARD 'DEFAULT'
#   UCIO-1  Critical Warning  18 of 23 ports have no LOC constraint
#
# Both say: "This design will fail to generate a bitstream." Implementation
# passing is not the same as having a bitstream.
#
# PIN BUDGET
# ----------
# pc_out was 16 bits, occupying every LED. The PC only reaches 616 (155
# instructions x 4), so bits [15:11] are permanently zero and were wasting
# five LEDs. pc_out is now 11 bits and those five LEDs show the answer.
#
#   Requires in TopModule.v:   output [10:0] pc_out;
#                              assign pc_out = pc[10:0];
# ============================================================================

# ---------------------------------------------------------------------------
# Clocks
# ---------------------------------------------------------------------------
create_clock -period 10.000 -name sys_clk -waveform {0.000 5.000} [get_ports clk]

create_generated_clock -name core_clk -source [get_ports clk] -divide_by 2 [get_pins clk_div_reg/Q]

# ---------------------------------------------------------------------------
# Configuration bank
# ---------------------------------------------------------------------------
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ---------------------------------------------------------------------------
# Timing exceptions
#   rst is asynchronous and synchronised inside TopModule.
#   All outputs drive LEDs -- no external timing requirement.
# ---------------------------------------------------------------------------
set_false_path -from [get_ports rst]
set_false_path -to [get_ports {pc_out[*]}]
set_false_path -to [get_ports {result_out[*]}]
set_false_path -to [get_ports done]

# ---------------------------------------------------------------------------
# Clock and reset pins
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# LEDs 0-10 : program counter (bits [10:0], max value 616)
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# LEDs 11-14 : predicted digit.  LED 15 : done.
# Expect 0011 (=3) with done lit, about 27 ms after reset is released.
# ---------------------------------------------------------------------------


## On-board 7-Segment display 0
#set_property -dict {PACKAGE_PIN D5 IOSTANDARD LVCMOS33} [get_ports {D0_AN[0]}]
#set_property -dict {PACKAGE_PIN C4 IOSTANDARD LVCMOS33} [get_ports {D0_AN[1]}]
#set_property -dict {PACKAGE_PIN C7 IOSTANDARD LVCMOS33} [get_ports {D0_AN[2]}]
#set_property -dict {PACKAGE_PIN A8 IOSTANDARD LVCMOS33} [get_ports {D0_AN[3]}]
#set_property -dict {PACKAGE_PIN D7 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[0]}]
#set_property -dict {PACKAGE_PIN C5 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[1]}]
#set_property -dict {PACKAGE_PIN A5 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[2]}]
#set_property -dict {PACKAGE_PIN B7 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[3]}]
#set_property -dict {PACKAGE_PIN A7 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[4]}]
#set_property -dict {PACKAGE_PIN D6 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[5]}]
#set_property -dict {PACKAGE_PIN B5 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[6]}]
#set_property -dict {PACKAGE_PIN A6 IOSTANDARD LVCMOS33} [get_ports {D0_SEG[7]}]

## On-board 7-Segment display 1
#set_property -dict {PACKAGE_PIN H3 IOSTANDARD LVCMOS33} [get_ports {D1_AN[0]}]
#set_property -dict {PACKAGE_PIN J4 IOSTANDARD LVCMOS33} [get_ports {D1_AN[1]}]
#set_property -dict {PACKAGE_PIN F3 IOSTANDARD LVCMOS33} [get_ports {D1_AN[2]}]
#set_property -dict {PACKAGE_PIN E4 IOSTANDARD LVCMOS33} [get_ports {D1_AN[3]}]
#set_property -dict {PACKAGE_PIN F4 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[0]}]
#set_property -dict {PACKAGE_PIN J3 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[1]}]
#set_property -dict {PACKAGE_PIN D2 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[2]}]
#set_property -dict {PACKAGE_PIN C2 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[3]}]
#set_property -dict {PACKAGE_PIN B1 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[4]}]
#set_property -dict {PACKAGE_PIN H4 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[5]}]
#set_property -dict {PACKAGE_PIN D1 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[6]}]
#set_property -dict {PACKAGE_PIN C1 IOSTANDARD LVCMOS33} [get_ports {D1_SEG[7]}]

set_clock_uncertainty 0.500 [get_clocks core_clk]
