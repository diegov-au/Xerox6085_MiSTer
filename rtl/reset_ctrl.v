module reset_ctrl
(
	input  wire clk,
	input  wire rst_i,
	output wire rst_o
);

(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg r1 = 1'b1;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg r2 = 1'b1;

always @(posedge clk) begin
	r1 <= rst_i;
	r2 <= r1;
end

assign rst_o = r2;

endmodule
