derive_pll_clocks
derive_clock_uncertainty

#=============================================================================
# Clocks
#
#   clk_sys   96 MHz   video only (outclk_0)
#   clk_m     32 MHz   the machine, the SDRAM, hps_io (outclk_1, X5)
#
# The two meet in three places, each built as a crossing rather than timed as
# one: the dual-clock display RAM, the vsync synchroniser (clk_sys -> clk_m),
# and the status line's slow words (clk_m -> clk_sys, a torn frame harmless).
# So the two are asynchronous groups; nothing else may cross.
#
# clk_sys doubles as CLK_VIDEO with CE_PIXEL tied high: the 19-inch frame is
# 1520 x 1052 total, which at 96 MHz is 60.04 Hz. Choosing the total rather than
# the pixel clock is what lets the PLL stay exactly as Superman shipped it - see
# rtl/xerox_video.v.
#=============================================================================

#--- SDRAM -------------------------------------------------------------------
# The SDRAM I/O has no input or output delay constraints, so those paths are not
# timed. This is what the Superman core does on this board, and it is part of
# the working configuration rather than an oversight: the pin clock comes from
# an altddio_out cell, and sys/sys.tcl pins the DQ registers into the I/O cells
# (FAST_INPUT_REGISTER / FAST_OUTPUT_REGISTER / FAST_OUTPUT_ENABLE_REGISTER,
# lines 95-98), which is what actually meets the timing.
#=============================================================================

set_clock_groups -asynchronous \
    -group [get_clocks {*|pll|pll_inst|altera_pll_i|*[0].*|divclk}] \
    -group [get_clocks {*|pll|pll_inst|altera_pll_i|*[1].*|divclk}]
