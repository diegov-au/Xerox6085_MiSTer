module xerox_dispram
(
	input         clk,
	input         a_clk,

	input  [15:0] a_addr,
	input  [15:0] a_din,
	input         a_we,
	output [15:0] a_dout,

	input  [15:0] b_addr,
	output [15:0] b_dout
);

reg [15:0] ram[0:65535] /* verilator public_flat_rw */;

reg [15:0] b_q1, b_q2;
reg [15:0] a_q1, a_q2;

always @(posedge a_clk) begin
	if (a_we) ram[a_addr] <= a_din;
	a_q1 <= ram[a_addr];
	a_q2 <= a_q1;
end
always @(posedge clk) begin
	b_q1 <= ram[b_addr];
	b_q2 <= b_q1;
end

assign a_dout = a_q2;
assign b_dout = b_q2;

endmodule
