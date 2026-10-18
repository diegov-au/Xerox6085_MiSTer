module xerox_video
(
	input             clk,
	input             reset,

	input             test_pattern,

	output reg [15:0] disp_addr,
	input      [15:0] disp_data,

	input             sdram_done,
	input             sdram_pass,

	output reg        hsync,
	output reg        vsync,
	output reg        hblank,
	output reg        vblank,
	output reg  [7:0] video,

	output reg [11:0] hcnt,
	output reg [10:0] vcnt,
	output            frame_start
);

localparam H_ACTIVE = 12'd1152;
localparam H_FRONT  = 12'd48;
localparam H_SYNC   = 12'd160;
localparam H_TOTAL  = 12'd1520;

localparam V_ACTIVE = 11'd861;
localparam V_FRONT  = 11'd3;
localparam V_SYNC    = 11'd6;
localparam V_TOTAL  = 11'd1052;

localparam H_SYNC_ST = H_ACTIVE + H_FRONT;
localparam H_SYNC_EN = H_ACTIVE + H_FRONT + H_SYNC;
localparam V_SYNC_ST = V_ACTIVE + V_FRONT;
localparam V_SYNC_EN = V_ACTIVE + V_FRONT + V_SYNC;

assign frame_start = (hcnt == 12'd0) && (vcnt == 11'd0);

always @(posedge clk) begin
	if (reset) begin
		hcnt <= 12'd0;
		vcnt <= 11'd0;
	end
	else if (hcnt == H_TOTAL - 1'd1) begin
		hcnt <= 12'd0;
		vcnt <= (vcnt == V_TOTAL - 1'd1) ? 11'd0 : vcnt + 1'd1;
	end
	else hcnt <= hcnt + 1'd1;
end

always @(posedge clk) begin
	hblank <= (hcnt >= H_ACTIVE);
	vblank <= (vcnt >= V_ACTIVE);
	hsync  <= (hcnt >= H_SYNC_ST) && (hcnt < H_SYNC_EN);
	vsync  <= (vcnt >= V_SYNC_ST) && (vcnt < V_SYNC_EN);
end

wire in_active = (hcnt < H_ACTIVE) && (vcnt < V_ACTIVE);

wire at_edge   = (hcnt < 12'd4) || (hcnt >= H_ACTIVE - 12'd4) ||
                 (vcnt < 11'd4) || (vcnt >= V_ACTIVE - 11'd4);

wire at_grid   = (hcnt[5:0] < 6'd2) || (vcnt[5:0] < 6'd2);

wire at_cross  = (hcnt >= H_ACTIVE/2 - 12'd2 && hcnt < H_ACTIVE/2 + 12'd2) ||
                 (vcnt >= V_ACTIVE/2 - 11'd2 && vcnt < V_ACTIVE/2 + 11'd2);

wire cell_fill = hcnt[6] ^ vcnt[6];

wire [7:0] ramp = hcnt[10:3];

localparam WORDS_PER_LINE = 12'd72;

wire [11:0] fetch_h    = (hcnt + 12'd8 >= H_TOTAL) ? (hcnt + 12'd8 - H_TOTAL)
                                                   : (hcnt + 12'd8);
wire        fetch_wrap = (hcnt + 12'd8) >= H_TOTAL;
wire [10:0] fetch_v    = fetch_wrap ? ((vcnt == V_TOTAL - 1'd1) ? 11'd0 : vcnt + 1'd1)
                                    : vcnt;

wire [16:0] line_base = {fetch_v, 6'd0} + {fetch_v, 3'd0};

always @(posedge clk) begin
	disp_addr <= line_base[15:0] + {4'd0, fetch_h[11:4]};
end

reg [15:0] pix_sr;

always @(posedge clk) begin
	if (hcnt[3:0] == 4'd15) pix_sr <= disp_data;
	else                    pix_sr <= {pix_sr[14:0], 1'b0};
end

wire [7:0] bitmap_px = pix_sr[15] ? 8'h00 : 8'hFF;

wire in_badge = !sdram_pass &&
                (hcnt >= 12'd16) && (hcnt < 12'd80) &&
                (vcnt >= 11'd16) && (vcnt < 11'd80);

wire badge_checker = hcnt[3] ^ vcnt[3];

wire [7:0] badge = !sdram_done ? 8'hFF
                 :  badge_checker ? 8'hFF : 8'h00;

always @(posedge clk) begin
	if (!in_active)                    video <= 8'h00;
	else if (in_badge)                 video <= badge;
	else if (!test_pattern)            video <= bitmap_px;
	else if (at_edge)                  video <= 8'hFF;
	else if (at_cross)                 video <= 8'hFF;
	else if (at_grid)                  video <= 8'hC0;
	else if (vcnt > V_ACTIVE - 11'd64) video <= ramp;
	else if (cell_fill)                video <= 8'h50;
	else                               video <= 8'h00;
end

endmodule
