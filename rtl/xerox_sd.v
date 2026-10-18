module xerox_sd
(
	input             clk,
	input             reset,

	input       [1:0] img_mounted,
	input      [63:0] img_size,
	output reg [31:0] sd_lba,
	output reg  [5:0] sd_blk_cnt,
	output reg  [1:0] sd_rd,
	output reg  [1:0] sd_wr,
	input       [1:0] sd_ack,
	input      [13:0] sd_buff_addr,
	input       [7:0] sd_buff_dout,
	output      [7:0] sd_buff_din,
	input             sd_buff_wr,

	input      [31:0] disk_lba,
	input       [4:0] disk_cmd,
	input             disk_go,
	output reg        disk_done,
	output reg        disk_ok,
	output     [31:0] disk_sectors,
	output     [31:0] fdd_info,
	output      [8:0] sb_a,
	output reg [15:0] sb_wd,
	output reg        sb_we,
	input      [15:0] sb_rd,

	output            active
);

reg  [31:0] sectors;
reg  [23:0] fdd_blocks;
reg   [7:0] fdd_mounts;
assign disk_sectors = sectors;
assign fdd_info     = {fdd_mounts, fdd_blocks};

always @(posedge clk) begin
	if (img_mounted[0]) sectors <= img_size[41:10];
	if (reset) fdd_mounts <= 8'd0;
	else if (img_mounted[1]) begin
		fdd_blocks <= img_size[32:9] + {23'd0, img_size[8:0] != 9'd0};
		fdd_mounts <= fdd_mounts + 8'd1;
	end
end

initial begin sectors = 32'd0; fdd_blocks = 24'd0; end

reg        busy, acked;
reg  [9:0] boff;
reg  [7:0] hi;
assign active = busy;

wire [13:0] b    = sd_buff_addr + {4'd0, boff};
wire        in_s = b < 14'd532;
assign sb_a      = b[9:1];
assign sd_buff_din = !in_s ? 8'd0 : b[0] ? sb_rd[7:0] : sb_rd[15:8];

wire floppy = disk_cmd[4];

always @(posedge clk) begin
	disk_done <= 1'b0;
	sb_we     <= 1'b0;
	if (reset) begin
		busy  <= 1'b0;
		sd_rd <= 2'b00;
		sd_wr <= 2'b00;
		acked <= 1'b0;
	end
	else begin
		if (disk_go && !busy) begin
			if (floppy ? (!disk_cmd[0] || disk_lba >= {8'd0, fdd_blocks})
			           : (sectors == 32'd0 || disk_lba >= sectors
			              || (disk_cmd[1] && disk_cmd[3:2] == 2'b00))) begin
				disk_done <= 1'b1;
				disk_ok   <= 1'b0;
			end
			else begin
				busy  <= 1'b1;
				acked <= 1'b0;
				if (floppy) begin
					sd_lba <= disk_lba; sd_blk_cnt <= 6'd0;
					boff <= 10'd0; sd_rd <= 2'b10;
				end
				else if (disk_cmd[0]) begin
					sd_lba <= {disk_lba[30:0], 1'b0}; sd_blk_cnt <= 6'd1;
					boff <= 10'd0; sd_rd <= 2'b01;
				end
				else if (disk_cmd[3:2] == 2'b11) begin
					sd_lba <= {disk_lba[30:0], 1'b0}; sd_blk_cnt <= 6'd1;
					boff <= 10'd0; sd_wr <= 2'b01;
				end
				else if (disk_cmd[2]) begin
					sd_lba <= {disk_lba[30:0], 1'b0}; sd_blk_cnt <= 6'd0;
					boff <= 10'd0; sd_wr <= 2'b01;
				end
				else begin
					sd_lba <= {disk_lba[30:0], 1'b1}; sd_blk_cnt <= 6'd0;
					boff <= 10'd512; sd_wr <= 2'b01;
				end
			end
		end

		if (busy) begin
			if (sd_ack != 2'b00) begin
				acked <= 1'b1;
				sd_rd <= 2'b00;
				sd_wr <= 2'b00;
			end
			else if (acked) begin
				busy      <= 1'b0;
				disk_done <= 1'b1;
				disk_ok   <= 1'b1;
			end
		end

		if (sd_ack != 2'b00 && sd_buff_wr && in_s) begin
			if (!b[0]) hi <= sd_buff_dout;
			else begin sb_wd <= {hi, sd_buff_dout}; sb_we <= 1'b1; end
		end
	end
end

endmodule
