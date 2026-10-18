module xerox_timer8254 #(
	parameter integer DIV_N = 128,
	parameter         FREE  = 0
)
(
	input             clk,
	input             reset,
	input             en,

	input      [23:0] rd_a,
	input             rd_stb,
	output     [15:0] rd_q,
	output            sel,

	input      [23:0] wr_a,
	input      [15:0] wr_d,
	input             wr_en,

	output            intr
);

localparam [7:0] PORT_C0 = 8'h40, PORT_CTL = 8'h43;
/* verilator lint_off WIDTHTRUNC */
localparam [9:0] DIV_LAST = DIV_N - 1;
/* verilator lint_on WIDTHTRUNC */
wire             step = FREE ? 1'b1 : en;

reg  [9:0] div                 /* verilator public_flat_rw */;
reg [31:0] down                /* verilator public_flat_rw */;
reg [31:0] ticks               /* verilator public_flat_rw */;
reg [15:0] latch_v[0:2]        /* verilator public_flat_rw */;
reg  [2:0] latch_ok            /* verilator public_flat_rw */;
reg  [2:0] read_hi             /* verilator public_flat_rw */;
reg [15:0] c0                  /* verilator public_flat_rw */;
reg [15:0] c0_initial          /* verilator public_flat_rw */;
reg  [7:0] c0_pending          /* verilator public_flat_rw */;
reg        c0_load_hi          /* verilator public_flat_rw */;
reg [31:0] reads               /* verilator public_flat_rw */;
reg [31:0] writes              /* verilator public_flat_rw */;
reg [31:0] latches             /* verilator public_flat_rw */;
reg [31:0] ints                /* verilator public_flat_rw */;

reg [31:0] replay_d            /* verilator public_flat_rw */;
reg        replay_v            /* verilator public_flat_rw */;
reg [31:0] replay_short        /* verilator public_flat_rw */;

wire [31:0] casc_live = {down[31:16] - {15'd0, down[15:0] <= 16'd1}, down[15:0]};
wire [31:0] casc = replay_v ? {16'd0 - replay_d[31:16], 16'd1 - replay_d[15:0]}
                            : casc_live;

wire [7:0] rd_port = rd_a[23:16];
wire [7:0] wr_port = wr_a[23:16];

assign sel = (rd_port >= PORT_C0) && (rd_port <= PORT_CTL);

wire [1:0] rd_n = rd_port[1:0];

reg [15:0] live;
always @* begin
	case (rd_n)
	2'd0:    live = c0;
	2'd1:    live = casc_live[15:0];
	2'd2:    live = casc_live[31:16];
	default: live = 16'd0;
	endcase
end

wire [15:0] shown = latch_ok[rd_n] ? latch_v[rd_n] : live;

assign rd_q = (rd_port == PORT_CTL) ? 16'd0
            : read_hi[rd_n] ? {8'd0, shown[15:8]} : {8'd0, shown[7:0]};

assign intr = step && !reset && (div == DIV_LAST)
              && (c0_initial != 16'd0) && (c0 == 16'd1);

integer i;

always @(posedge clk) begin
	if (reset) begin
		div <= 10'd0; down <= 32'd0; ticks <= 32'd0;
		latch_ok <= 3'd0; read_hi <= 3'd0;
		c0 <= 16'd0; c0_initial <= 16'd0;
		c0_pending <= 8'd0; c0_load_hi <= 1'b0;
		reads <= 32'd0; writes <= 32'd0; ints <= 32'd0; latches <= 32'd0;
		for (i = 0; i < 3; i = i + 1) latch_v[i] <= 16'd0;
	end
	else begin
		if (step) begin
		if (div == DIV_LAST) begin
			div   <= 10'd0;
			ticks <= ticks + 32'd1;
			down  <= down - 32'd1;
			if (c0_initial != 16'd0) begin
				if (c0 == 16'd1) begin
					c0   <= c0_initial;
					ints <= ints + 32'd1;
				end
				else c0 <= c0 - 16'd1;
			end
		end
		else div <= div + 10'd1;
		end

		if (en && wr_en && wr_port >= PORT_C0 && wr_port <= PORT_CTL) begin
			writes <= writes + 32'd1;
			if (wr_port == PORT_CTL) begin
				if (wr_d[7:6] == 2'b11) begin
					if (!wr_d[5]) begin
						latches <= latches + 32'd1;
						if (wr_d[3]) begin
							latch_v[2] <= casc[31:16];
							latch_ok[2] <= 1'b1; read_hi[2] <= 1'b0;
						end
						if (wr_d[2]) begin
							latch_v[1] <= casc[15:0];
							latch_ok[1] <= 1'b1; read_hi[1] <= 1'b0;
						end
						if (wr_d[1]) begin
							latch_v[0] <= c0;
							latch_ok[0] <= 1'b1; read_hi[0] <= 1'b0;
						end
					end
				end
				else if (wr_d[5:4] == 2'b00) begin
					latch_v[wr_d[7:6]] <= (wr_d[7:6] == 2'd0) ? c0
					                    : (wr_d[7:6] == 2'd1) ? casc_live[15:0]
					                                          : casc_live[31:16];
					latch_ok[wr_d[7:6]] <= 1'b1;
					read_hi[wr_d[7:6]]  <= 1'b0;
				end
				else begin
					read_hi[wr_d[7:6]]  <= 1'b0;
					latch_ok[wr_d[7:6]] <= 1'b0;
					if (wr_d[7:6] == 2'd0) c0_load_hi <= 1'b0;
				end
			end
			else if (wr_port == PORT_C0) begin
				if (c0_load_hi) begin
					c0_initial <= {wr_d[7:0], c0_pending};
					c0         <= {wr_d[7:0], c0_pending};
					c0_load_hi <= 1'b0;
				end
				else begin
					c0_pending <= wr_d[7:0];
					c0_load_hi <= 1'b1;
				end
			end
		end

		if (en && rd_stb && sel && rd_port != PORT_CTL) begin
			reads <= reads + 32'd1;
			if (read_hi[rd_n]) begin
				read_hi[rd_n]  <= 1'b0;
				latch_ok[rd_n] <= 1'b0;
			end
			else read_hi[rd_n] <= 1'b1;
		end
	end
end

endmodule
