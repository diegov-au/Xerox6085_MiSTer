module xerox_iop
(
	input             clk,
	input             reset,

	input      [12:0] fw_a,
	input      [31:0] fw_d,
	input             fw_we,

	output reg [20:0] cpm_a,
	output reg [15:0] cpm_wd,
	output reg        cpm_we,
	output reg        cpm_req,
	input      [15:0] cpm_rd,
	input             cpm_ready,

	input             ev_notify,
	input             ev_lockrel,
	input             ev_vsync,
	input             ev_vsync_safe,
	input             ev_input,

	output reg [15:0] wake_mask,
	output reg        wake_stb,

	output reg        hold,

	output reg [31:0] disk_lba,
	output reg  [4:0] disk_cmd,
	output reg        disk_go,
	input             disk_done,
	input             disk_ok,
	input      [31:0] disk_sectors,
	input       [8:0] sb_a,
	input      [15:0] sb_wd,
	input             sb_we,
	output     [15:0] sb_rd,

	input      [31:0] mouse_xy,
	input     [143:0] keys,

	input      [31:0] usec,
	input      [31:0] unix_time,
	input      [63:0] clock_rtc,
	input      [31:0] fdd_info,

	input             cfg_boot,
	input             cfg_free_clock,
	input             cfg_boot_floppy,
	input             cfg_legacy_clock,
	output reg [11:0] cs_a,
	output reg [47:0] cs_d,
	output reg        cs_we,
	output reg [31:0] cursor_xy,
	output reg [255:0] cursor_pat,
	output reg [15:0] beep_div
);

wire        mem_valid, mem_instr;
reg         mem_ready;
wire [31:0] mem_addr, mem_wdata;
wire  [3:0] mem_wstrb;
wire [31:0] mem_rdata;

picorv32 #(
	.ENABLE_COUNTERS(0), .ENABLE_COUNTERS64(0), .ENABLE_REGS_16_31(1),
	.ENABLE_REGS_DUALPORT(1), .BARREL_SHIFTER(1), .COMPRESSED_ISA(0),
	.CATCH_MISALIGN(1), .CATCH_ILLINSN(1), .ENABLE_PCPI(0), .ENABLE_MUL(0),
	.ENABLE_FAST_MUL(0), .ENABLE_DIV(0), .ENABLE_IRQ(0), .ENABLE_TRACE(0),
	.PROGADDR_RESET(32'h0000_0000), .STACKADDR(32'h0000_8000)
) cpu (
	.clk(clk), .resetn(~reset), .trap(),
	.mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
	.mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
	.mem_rdata(mem_rdata),
	.mem_la_read(), .mem_la_write(), .mem_la_addr(), .mem_la_wdata(),
	.mem_la_wstrb(),
	.pcpi_valid(), .pcpi_insn(), .pcpi_rs1(), .pcpi_rs2(),
	.pcpi_wr(1'b0), .pcpi_rd(32'd0), .pcpi_wait(1'b0), .pcpi_ready(1'b0),
	.irq(32'd0), .eoi(), .trace_valid(), .trace_data()
);

reg [31:0] ram[0:8191]  /* verilator public_flat_rw */;
reg [31:0] ram_q;
wire       sel_ram = mem_addr[31:28] == 4'h0;
wire       sel_reg = mem_addr[31:16] == 16'h1000;
wire       sel_sb  = mem_addr[31:16] == 16'h1001;
wire       sel_cpm = mem_addr[31:28] == 4'h2;

wire [12:0] ram_a  = fw_we ? fw_a : mem_addr[14:2];
wire [31:0] ram_wd = fw_we ? fw_d : mem_wdata;
wire  [3:0] ram_be = fw_we ? 4'hF
                   : (mem_valid && !mem_ready && sel_ram) ? mem_wstrb : 4'h0;

always @(posedge clk) begin
	if (ram_be[0]) ram[ram_a][ 7: 0] <= ram_wd[ 7: 0];
	if (ram_be[1]) ram[ram_a][15: 8] <= ram_wd[15: 8];
	if (ram_be[2]) ram[ram_a][23:16] <= ram_wd[23:16];
	if (ram_be[3]) ram[ram_a][31:24] <= ram_wd[31:24];
	ram_q <= ram[ram_a];
end

reg [15:0] sb[0:511]  /* verilator public_flat_rw */;
reg [15:0] sb_q, sb_hq;
assign sb_rd = sb_hq;

wire       sb_cwe = mem_valid && !mem_ready && sel_sb && mem_wstrb != 4'd0;

always @(posedge clk) begin
	if (sb_we) begin sb[sb_a] <= sb_wd; sb_hq <= sb_wd; end
	else sb_hq <= sb[sb_a];
end
reg        dma_run, dma_fin, dma_dir;
reg  [1:0] dma_ph;
reg [20:0] dma_real;
reg  [8:0] dma_word, dma_cnt;
reg [15:0] dma_wd;
wire       dma_sbwe = dma_run && dma_dir && dma_ph == 2'd3;
wire [8:0] sb_pa  = dma_run ? dma_word : mem_addr[10:2];
wire       sb_pwe = sb_cwe | dma_sbwe;
wire [15:0] sb_pwd = dma_run ? dma_wd : mem_wdata[15:0];

always @(posedge clk) begin
	if (sb_pwe) begin sb[sb_pa] <= sb_pwd; sb_q <= sb_pwd; end
	else sb_q <= sb[sb_pa];
end

reg  [3:0] status;
reg        vs_safe;
reg        disk_busy, disk_okq;
reg [31:0] reg_qq, cpm_q;

assign mem_rdata = sel_ram ? ram_q : sel_sb ? {16'd0, sb_q} : sel_reg ? reg_qq : cpm_q;

localparam ST_NOTIFY = 0, ST_LOCKREL = 1, ST_VSYNC = 2, ST_INPUT = 3;

reg [31:0] reg_q;
always @(*) begin
	case (mem_addr[7:0])
	8'h00: reg_q = {27'd0, vs_safe, status};
	8'h18: reg_q = {30'd0, disk_okq, disk_busy};
	8'h1C: reg_q = disk_sectors;
	8'h20: reg_q = mouse_xy;
	8'h80: reg_q = usec;
	8'h84: reg_q = {28'd0, cfg_legacy_clock, cfg_boot_floppy, cfg_free_clock, cfg_boot};
	8'hA8: reg_q = unix_time;
	8'hAC: reg_q = clock_rtc[31:0];
	8'hB0: reg_q = clock_rtc[63:32];
	8'hB4: reg_q = fdd_info;
	default:
		if (mem_addr[7:0] >= 8'h40 && mem_addr[7:0] < 8'h64)
			reg_q = {16'd0, keys[16 * ((mem_addr[7:0] - 8'h40) >> 2) +: 16]};
		else
			reg_q = 32'd0;
	endcase
end

always @(posedge clk) begin
	wake_stb <= 1'b0;
	disk_go  <= 1'b0;
	cs_we    <= 1'b0;
	mem_ready <= 1'b0;
	reg_qq    <= reg_q;
	if (reset) begin
		status  <= 4'd0;
		vs_safe <= 1'b0;
		hold    <= 1'b1;
		cpm_req <= 1'b0;
		cpm_we  <= 1'b0;
		wake_mask <= 16'd0;
		disk_lba <= 32'd0;
		disk_cmd <= 5'd0;
		disk_busy <= 1'b0;
		disk_okq  <= 1'b0;
		dma_run   <= 1'b0;
		dma_fin   <= 1'b0;
		cursor_xy <= 32'd0;
		beep_div  <= 16'd0;
	end
	else begin
		if (ev_notify)  status[ST_NOTIFY]  <= 1'b1;
		if (ev_lockrel) status[ST_LOCKREL] <= 1'b1;
		if (ev_vsync) begin
			status[ST_VSYNC] <= 1'b1;
			vs_safe <= (status[ST_VSYNC] & vs_safe) | ev_vsync_safe;
		end
		if (ev_input)   status[ST_INPUT]   <= 1'b1;
		if (disk_done) begin disk_busy <= 1'b0; disk_okq <= disk_ok; end

		if (mem_valid && !mem_ready) begin
			if (sel_cpm) begin
				if (!cpm_req) begin
					cpm_req <= 1'b1;
					cpm_a   <= mem_addr[22:2];
					cpm_wd  <= mem_wdata[15:0];
					cpm_we  <= mem_wstrb != 4'd0;
				end
				else if (cpm_ready) begin
					cpm_req   <= 1'b0;
					cpm_we    <= 1'b0;
					cpm_q     <= {16'd0, cpm_rd};
					mem_ready <= 1'b1;
				end
			end
			else if (sel_reg && mem_wstrb != 4'd0 && mem_addr[7:0] == 8'hA0) begin
				if (dma_fin) begin
					dma_fin   <= 1'b0;
					mem_ready <= 1'b1;
				end
				else if (!dma_run) begin
					if (mem_wdata[8:0] == 9'd0) dma_fin <= 1'b1;
					else begin
						dma_run <= 1'b1;
						dma_ph  <= 2'd0;
						dma_cnt <= mem_wdata[8:0];
						dma_dir <= mem_wdata[16];
					end
				end
			end
			else begin
				mem_ready <= 1'b1;
				if (sel_reg && mem_wstrb != 4'd0) begin
					case (mem_addr[7:0])
					8'h04: begin
						status <= (status & ~mem_wdata[3:0])
						        | {ev_input, ev_vsync, ev_lockrel, ev_notify};
						if (mem_wdata[ST_VSYNC]) vs_safe <= ev_vsync & ev_vsync_safe;
					end
					8'h08: begin wake_mask <= mem_wdata[15:0]; wake_stb <= 1'b1; end
					8'h0C: hold <= mem_wdata[0] | ((status & ~mem_wdata[7:4]) != 4'd0);
					8'h10: disk_lba <= mem_wdata;
					8'h14: begin
						disk_cmd  <= mem_wdata[4:0];
						disk_go   <= 1'b1;
						disk_busy <= 1'b1;
					end
					8'h88: cs_a <= mem_wdata[11:0];
					8'h8C: cs_d[15:0]  <= mem_wdata[15:0];
					8'h90: cs_d[31:16] <= mem_wdata[15:0];
					8'h94: begin cs_d[47:32] <= mem_wdata[15:0]; cs_we <= 1'b1; end
					8'h98: dma_real <= mem_wdata[20:0];
					8'h9C: dma_word <= mem_wdata[8:0];
					8'hA4: cursor_xy <= mem_wdata;
					8'hB8: beep_div  <= mem_wdata[15:0];
					default:
						if (mem_addr[7:6] == 2'b11)
							cursor_pat[16 * mem_addr[5:2] +: 16] <= mem_wdata[15:0];
					endcase
				end
			end
		end

		if (dma_run) begin
			case (dma_ph)
			2'd0: dma_ph <= 2'd1;
			2'd1: begin
				cpm_req <= 1'b1;
				cpm_a   <= dma_real;
				cpm_wd  <= sb_q;
				cpm_we  <= ~dma_dir;
				dma_ph  <= 2'd2;
			end
			2'd2: if (cpm_ready) begin
				cpm_req <= 1'b0;
				cpm_we  <= 1'b0;
				dma_wd  <= cpm_rd;
				dma_ph  <= dma_dir ? 2'd3 : 2'd0;
			end
			default: dma_ph <= 2'd0;
			endcase
			if ((dma_ph == 2'd2 && cpm_ready && !dma_dir) || dma_ph == 2'd3) begin
				dma_word <= dma_word + 9'd1;
				dma_real <= dma_real + 21'd1;
				dma_cnt  <= dma_cnt - 9'd1;
				if (dma_cnt == 9'd1) begin dma_run <= 1'b0; dma_fin <= 1'b1; end
			end
		end

		if (ev_notify | ev_lockrel | ev_vsync | ev_input) hold <= 1'b1;
		if (cs_we) cs_a <= cs_a + 12'd1;
	end
end

endmodule
