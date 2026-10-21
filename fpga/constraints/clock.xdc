# Clock constraint for exploratory synthesis and timing analysis
# Port: clk
# Target frequency: 100.0 MHz (Period: 10.000 ns, 50% duty cycle)
# Note: This is an exploratory timing constraint for timing analysis,
# not a physical hardware demonstration.
create_clock -period 10.000 -name clk -waveform {0.000 5.000} [get_ports clk]
