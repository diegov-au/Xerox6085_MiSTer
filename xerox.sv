//============================================================================
//
//  Xerox 6085 "Daybreak" core for MiSTer — top level.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

`default_nettype none

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

wire       beep, beep_on;
reg  [1:0] beep_s, beep_on_s;
reg [15:0] beep_pcm;
always @(posedge CLK_AUDIO) begin
	beep_s    <= {beep_s[0], beep};
	beep_on_s <= {beep_on_s[0], beep_on};
	if (!beep_on_s[1]) beep_pcm <= 16'd0;
	else case (status[2:1])
		2'd0: beep_pcm <= beep_s[1] ? 16'h1000 : 16'hF000;
		2'd1: beep_pcm <= beep_s[1] ? 16'h2800 : 16'hD800;
		2'd2: beep_pcm <= beep_s[1] ? 16'h0600 : 16'hFA00;
		2'd3: beep_pcm <= 16'd0;
	endcase
end
assign AUDIO_L = beep_pcm;
assign AUDIO_R = beep_pcm;
assign AUDIO_S = 1'b1;
assign AUDIO_MIX = 0;

assign BUTTONS = 0;

`include "build_id.v"
localparam CONF_STR = {
	"Xerox-6085;;",

	"S1,IMDDMK,Mount Floppy;",
	"SC0,VHD,Mount Disk;",
	"O[3],Boot From Floppy,No,Yes;",
	"O[4],Clock,MiSTer RTC,Legacy 1997;",
	"-;",

	"O[122:121],Aspect Ratio,Original,Full Screen;",
	"O[125:123],Scale,Normal,V-Integer,Narrower HV-Integer,Wider HV-Integer,HV-Integer;",
	"-;",
	"O[2:1],Beep Volume,Medium,Loud,Soft,Off;",
	"O[126],Maintenance Panel,Off,On;",
	"-;",

	"R0,Reset;",

	"V,v",`BUILD_DATE
};

wire [127:0] status;
wire   [1:0] buttons;
wire         forced_scandoubler;
wire  [21:0] gamma_bus;

wire         ioctl_download;
wire         ioctl_wr;
wire  [26:0] ioctl_addr;
wire   [7:0] ioctl_dout;
wire  [15:0] ioctl_index;
wire         ioctl_wait;

wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;

wire  [32:0] timestamp;
wire  [64:0] rtc;

wire   [1:0] img_mounted;
wire         img_readonly;
wire  [63:0] img_size;
wire  [31:0] sd_lba;
wire   [5:0] sd_blk_cnt;
wire   [1:0] sd_rd, sd_wr, sd_ack;
wire  [13:0] sd_buff_addr;
wire   [7:0] sd_buff_dout, sd_buff_din;
wire         sd_buff_wr;

hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io
(
	.clk_sys(clk_m),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),
	.TIMESTAMP(timestamp),
	.RTC(rtc),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_index(ioctl_index),
	.ioctl_wait(ioctl_wait),

	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_lba('{sd_lba, sd_lba}),
	.sd_blk_cnt('{sd_blk_cnt, sd_blk_cnt}),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din, sd_buff_din}),
	.sd_buff_wr(sd_buff_wr),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse)
);

wire clk_sys;
wire clk_m;
wire pll_locked;

reg        rst_pll     = 1'b0;
reg  [7:0] rst_pll_cnt = 8'd0;
reg        old_locked  = 1'b0;

pll pll
(
	.refclk(CLK_50M),
	.rst(rst_pll),
	.outclk_0(clk_sys),
	.outclk_1(clk_m),
	.locked(pll_locked)
);

always @(posedge CLK_50M) begin
	old_locked <= pll_locked;
	if (old_locked && !pll_locked) begin
		rst_pll_cnt <= 8'hFF;
		rst_pll     <= 1'b1;
	end
	else if (rst_pll_cnt) rst_pll_cnt <= rst_pll_cnt - 1'b1;
	else                  rst_pll     <= 1'b0;
end

wire reset_async = RESET | ~pll_locked;
wire reset_m, reset_v;

reset_ctrl reset_m_ctrl (.clk(clk_m),   .rst_i(reset_async), .rst_o(reset_m));
reset_ctrl reset_v_ctrl (.clk(clk_sys), .rst_i(reset_async), .rst_o(reset_v));

wire [12:0] sd_a;
wire  [1:0] sd_ba;
wire [15:0] sd_dq_out;
wire        sd_dq_oe;
wire        sd_dqml, sd_dqmh;
wire        sd_ncs, sd_nras, sd_ncas, sd_nwe, sd_cke;
wire        sdram_ready;

wire [24:0] p0_addr;
wire [15:0] p0_din;
wire        p0_req, p0_ack;
wire [24:0] p1_addr;
wire [15:0] p1_din, p1_dout;
wire        p1_we, p1_req, p1_ack;

sdram #(.CLK_HZ(32_000_000)) sdram
(
	.clk(clk_m),
	.init(reset_m),

	.SDRAM_A(sd_a),
	.SDRAM_BA(sd_ba),
	.SDRAM_DQ_IN(SDRAM_DQ),
	.SDRAM_DQ_OUT(sd_dq_out),
	.SDRAM_DQ_OE(sd_dq_oe),
	.SDRAM_DQML(sd_dqml),
	.SDRAM_DQMH(sd_dqmh),
	.SDRAM_nCS(sd_ncs),
	.SDRAM_nRAS(sd_nras),
	.SDRAM_nCAS(sd_ncas),
	.SDRAM_nWE(sd_nwe),
	.SDRAM_CKE(sd_cke),
	.SDRAM_CLK(),

	.p0_addr(p0_addr), .p0_din(p0_din), .p0_wide(1'b1), .p0_mask_all(1'b0),
	.p0_we(1'b1), .p0_req(p0_req), .p0_ack(p0_ack), .p0_dout(),

	.p1_addr(p1_addr),
	.p1_din(p1_din),
	.p1_we(p1_we),
	.p1_req(p1_req),
	.p1_ack(p1_ack),
	.p1_dout(p1_dout),

	.p2_addr(25'd0), .p2_req(1'b0), .p2_ack(), .p2_dout(), .dbg_p2_stall(),
	.p3_addr(25'd0), .p3_req(1'b0), .p3_ack(), .p3_dout(),

	.ready(sdram_ready)
);

assign SDRAM_DQ = sd_dq_oe ? sd_dq_out : 16'bZZZZZZZZZZZZZZZZ;

assign SDRAM_A    = sd_a;
assign SDRAM_BA   = sd_ba;
assign SDRAM_DQML = sd_dqml;
assign SDRAM_DQMH = sd_dqmh;
assign SDRAM_nCS  = sd_ncs;
assign SDRAM_nRAS = sd_nras;
assign SDRAM_nCAS = sd_ncas;
assign SDRAM_nWE  = sd_nwe;
assign SDRAM_CKE  = sd_cke;

altddio_out
#(
	.extend_oe_disable ("OFF"),
	.intended_device_family ("Cyclone V"),
	.invert_output ("OFF"),
	.lpm_hint ("UNUSED"),
	.lpm_type ("altddio_out"),
	.oe_reg ("UNREGISTERED"),
	.power_up_high ("OFF"),
	.width (1)
)
sdramclk_ddr
(
	.datain_h   (1'b0),
	.datain_l   (1'b1),
	.outclock   (clk_m),
	.dataout    (SDRAM_CLK),
	.aclr       (1'b0),
	.aset       (1'b0),
	.oe         (1'b1),
	.outclocken (1'b1),
	.sclr       (1'b0),
	.sset       (1'b0)
);

wire [12:0] fw_a;
wire        ld_we, fw_we;
wire  [9:0] ld_a;
wire [15:0] ld_d;
wire [31:0] fw_d;
wire [12:0] cs_n;
wire        booted;
wire        ld_z_we;
wire [20:0] ld_z_a;

xerox_loader loader
(
	.clk(clk_m), .reset(reset_m), .sdram_ready(sdram_ready),
	.ioctl_download(ioctl_download), .ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr), .ioctl_addr(ioctl_addr), .ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.m_addr(p0_addr), .m_din(p0_din), .m_req(p0_req), .m_ack(p0_ack),
	.ld_we(ld_we), .ld_a(ld_a), .ld_d(ld_d),
	.fw_a(fw_a), .fw_d(fw_d), .fw_we(fw_we),
	.cs_n(cs_n),
	.restart(status[0] | buttons[1]),
	.z_we(ld_z_we), .z_a(ld_z_a),
	.booted(booted)
);

wire        reset_mach = reset_m | ~booted;
wire        m_stb;
wire [20:0] m_a;
wire [15:0] m_d;
wire [31:0] disk_lba, disk_sectors, fdd_info;
wire  [4:0] disk_cmd;
wire        disk_go, disk_done, disk_ok, disk_active;
wire  [8:0] sb_a;
wire [15:0] sb_wd, sb_rd;
wire        sb_we;
wire [31:0] mouse_xy;

reg  [31:0] unix_time = 32'd0;
reg  [24:0] unix_div  = 25'd0;
reg         ts_t      = 1'b0;
always @(posedge clk_m) begin
	ts_t <= timestamp[32];
	if (ts_t != timestamp[32]) begin
		unix_time <= timestamp[31:0];
		unix_div  <= 25'd0;
	end
	else if (unix_div == 25'd31_999_999) begin
		unix_div <= 25'd0;
		if (unix_time != 32'd0) unix_time <= unix_time + 32'd1;
	end
	else unix_div <= unix_div + 25'd1;
end
reg  [63:0] clock_rtc = 64'd0;
reg         rtc_t     = 1'b0;
always @(posedge clk_m) begin
	rtc_t <= rtc[64];
	if (rtc_t != rtc[64]) clock_rtc[31:0] <= {1'b1, 7'd0, rtc[23:0]};
	if (ts_t != timestamp[32]) clock_rtc[63:32] <= timestamp[31:0];
end
wire [143:0] keys;
wire [31:0] dispatches;
wire        running;
wire [31:0] cursor_xy;
wire [255:0] cursor_pat;

reg [2:0] vs_sync;
always @(posedge clk_m) vs_sync <= {vs_sync[1:0], vid_vs};
wire vsync_m = vs_sync[1] & ~vs_sync[2];

xerox_machine machine
(
	.clk(clk_m), .reset(reset_mach),
	.ld_we(ld_we), .ld_a(ld_a), .ld_d(ld_d),
	.fw_a(fw_a), .fw_d(fw_d), .fw_we(fw_we),
	.cs_n(cs_n),
	.m_addr(p1_addr), .m_din(p1_din), .m_we(p1_we), .m_req(p1_req),
	.m_ack(p1_ack), .m_dout(p1_dout),
	.w_stb(m_stb), .w_a(m_a), .w_d(m_d),
	.vsync(vsync_m),
	.disk_lba(disk_lba), .disk_cmd(disk_cmd), .disk_go(disk_go),
	.disk_done(disk_done), .disk_ok(disk_ok), .disk_sectors(disk_sectors),
	.sb_a(sb_a), .sb_wd(sb_wd), .sb_we(sb_we), .sb_rd(sb_rd),
	.mouse_xy(mouse_xy), .keys(keys), .unix_time(unix_time), .clock_rtc(clock_rtc), .fdd_info(fdd_info),
	.boot_floppy(status[3]), .legacy_clock(status[4]),
	.dispatches(dispatches), .running(running),
	.cursor_xy(cursor_xy), .cursor_pat(cursor_pat),
	.beep(beep), .beep_on(beep_on)
);

xerox_sd sd
(
	.clk(clk_m), .reset(reset_m),
	.img_mounted(img_mounted), .img_size(img_size),
	.sd_lba(sd_lba), .sd_blk_cnt(sd_blk_cnt), .sd_rd(sd_rd), .sd_wr(sd_wr),
	.sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din), .sd_buff_wr(sd_buff_wr),
	.disk_lba(disk_lba), .disk_cmd(disk_cmd), .disk_go(disk_go),
	.disk_done(disk_done), .disk_ok(disk_ok), .disk_sectors(disk_sectors),
	.fdd_info(fdd_info),
	.sb_a(sb_a), .sb_wd(sb_wd), .sb_we(sb_we), .sb_rd(sb_rd),
	.active(disk_active)
);

xerox_input input_dev
(
	.clk(clk_m), .reset(reset_mach),
	.ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
	.mouse_xy(mouse_xy), .keys(keys)
);

reg [15:0] mp;
always @(posedge clk_m)
	if (reset_mach) mp <= 16'd0;
	else if (m_stb && m_a == 21'h050000) mp <= {m_d[7:0], m_d[15:8]};

assign LED_USER  = disk_active;
assign LED_DISK  = 2'b00;
assign LED_POWER = 2'b00;

assign CLK_VIDEO = clk_sys;
assign VGA_SL = 2'b00;

wire        vid_hs, vid_vs, vid_hbl, vid_vbl;
wire  [7:0] vid_data;
wire [11:0] vid_h;
wire [10:0] vid_v;
wire [15:0] disp_addr, disp_data;

wire        dw_z    = ld_z_we && ld_z_a[20:16] == 5'h1F;
wire        dw_we   = (m_stb && m_a[20:16] == 5'h1F) || dw_z;
wire [15:0] dw_addr = dw_z ? ld_z_a[15:0] : m_a[15:0];
wire [15:0] dw_data = dw_z ? 16'd0 : m_d;

xerox_dispram dispram
(
	.clk(clk_sys),
	.a_clk(clk_m),
	.a_addr(dw_addr),
	.a_din(dw_data),
	.a_we(dw_we),
	.a_dout(),
	.b_addr(disp_addr),
	.b_dout(disp_data)
);

xerox_video vid
(
	.clk(clk_sys),
	.reset(reset_v),
	.test_pattern(1'b0),
	.disp_addr(disp_addr),
	.disp_data(disp_data),
	.sdram_done(1'b1),
	.sdram_pass(1'b1),
	.hsync(vid_hs),
	.vsync(vid_vs),
	.hblank(vid_hbl),
	.vblank(vid_vbl),
	.video(vid_data),
	.hcnt(vid_h),
	.vcnt(vid_v),
	.frame_start()
);

function [15:0] bcd4(input [15:0] b);
	reg [35:0] s;
	integer i;
	begin
		s = {20'd0, b};
		for (i = 0; i < 16; i = i + 1) begin
			if (s[19:16] >= 4'd5) s[19:16] = s[19:16] + 4'd3;
			if (s[23:20] >= 4'd5) s[23:20] = s[23:20] + 4'd3;
			if (s[27:24] >= 4'd5) s[27:24] = s[27:24] + 4'd3;
			if (s[31:28] >= 4'd5) s[31:28] = s[31:28] + 4'd3;
			if (s[35:32] >= 4'd5) s[35:32] = s[35:32] + 4'd3;
			s = s << 1;
		end
		bcd4 = s[31:16];
	end
endfunction
reg [15:0] mp_dec;
always @(posedge clk_m) mp_dec <= bcd4(mp);
reg [15:0] mp_v;
reg [15:0] disp_v;
reg  [2:0] flags_v;
reg        ran_m;
reg  [2:0] ran_s;
always @(posedge clk_m) begin
	if (vsync_m) ran_m <= 1'b0;
	else if (running) ran_m <= 1'b1;
end
reg [24:0] st_div  = 25'd0;
reg [15:0] st_req  = 16'd0;
reg [24:0] st_busy = 25'd0, st_stop = 25'd0;
reg [15:0] sd_req_m  = 16'd0;
reg [11:0] sd_busy_m = 12'd0, cp_stop_m = 12'd0;
always @(posedge clk_m) begin
	if (st_div == 25'd31_999_999) begin
		st_div    <= 25'd0;
		sd_req_m  <= st_req;
		sd_busy_m <= st_busy[24:15];
		cp_stop_m <= st_stop[24:15];
		st_req    <= 16'd0;
		st_busy   <= 25'd0;
		st_stop   <= 25'd0;
	end
	else begin
		st_div <= st_div + 25'd1;
		if (disk_done && st_req != 16'hFFFF) st_req <= st_req + 16'd1;
		if (disk_active) st_busy <= st_busy + 25'd1;
		if (!running)    st_stop <= st_stop + 25'd1;
	end
end
reg [15:0] sd_req_v;
reg [11:0] sd_busy_v, cp_stop_v;

always @(posedge clk_sys) begin
	sd_req_v  <= sd_req_m;
	sd_busy_v <= sd_busy_m;
	cp_stop_v <= cp_stop_m;
	ran_s   <= {ran_s[1:0], ran_m};
	mp_v    <= mp_dec;
	disp_v  <= dispatches[31:16];
	flags_v <= {booted, ran_s[2], disk_sectors != 32'd0};
end

localparam [4:0] CH_M = 5'd16, CH_P = 5'd17, CH_COLON = 5'd18, CH_I = 5'd19,
                 CH_S = 5'd20, CH_K = 5'd21, CH_SP = 5'd31;
function [7:0] glyph(input [4:0] d, input [2:0] row);
	reg [55:0] g;
	begin
		case (d)
		CH_M:     g = 56'h11_1B_15_15_11_11_11;
		CH_P:     g = 56'h1E_11_11_1E_10_10_10;
		CH_COLON: g = 56'h00_0C_0C_00_0C_0C_00;
		CH_I:     g = 56'h0E_04_04_04_04_04_0E;
		CH_S:     g = 56'h0F_10_10_0E_01_01_1E;
		CH_K:     g = 56'h11_12_14_18_14_12_11;
		CH_SP:    g = 56'h00_00_00_00_00_00_00;
		4'h0: g = 56'h0E_11_13_15_19_11_0E;  4'h1: g = 56'h04_0C_04_04_04_04_0E;
		4'h2: g = 56'h0E_11_01_02_04_08_1F;  4'h3: g = 56'h1F_02_04_02_01_11_0E;
		4'h4: g = 56'h02_06_0A_12_1F_02_02;  4'h5: g = 56'h1F_10_1E_01_01_11_0E;
		4'h6: g = 56'h06_08_10_1E_11_11_0E;  4'h7: g = 56'h1F_01_02_04_08_08_08;
		4'h8: g = 56'h0E_11_11_0E_11_11_0E;  4'h9: g = 56'h0E_11_11_0F_01_02_0C;
		4'hA: g = 56'h0E_11_11_11_1F_11_11;  4'hB: g = 56'h1E_11_11_1E_11_11_1E;
		4'hC: g = 56'h0E_11_10_10_10_11_0E;  4'hD: g = 56'h1C_12_11_11_11_12_1C;
		4'hE: g = 56'h1F_10_10_1E_10_10_1F;  4'hF: g = 56'h1F_10_10_1E_10_10_10;
		default: g = 56'h00_00_00_00_00_00_00;
		endcase
		glyph = (row < 3'd7) ? g[55 - 8 * row -: 8] : 8'd0;
	end
endfunction

localparam [11:0] OV_X = 12'd1152 - 12'd136 - 12'd2;
localparam [10:0] OV_Y = 11'd861 - 11'd9;
localparam [10:0] OV_Y2 = OV_Y - 11'd9;
wire        ov_top  = vid_v < OV_Y;
wire [11:0] ov_dx   = vid_h - OV_X;
wire [10:0] ov_dy   = ov_top ? vid_v - OV_Y2 : vid_v - OV_Y;
wire        ov_in   = status[126] && vid_h >= OV_X && vid_h < OV_X + 12'd136 && vid_v >= OV_Y2 && vid_v < OV_Y + 11'd7;
wire  [4:0] ov_cell = ov_dx[7:3];
wire  [2:0] ov_col  = ov_dx[2:0];
reg   [4:0] ov_dig;
always @(*) begin
	if (ov_top) case (ov_cell)
	5'd0:  ov_dig = 5'hD;
	5'd1:  ov_dig = CH_S;
	5'd2:  ov_dig = CH_K;
	5'd3:  ov_dig = CH_COLON;
	5'd4:  ov_dig = {1'b0, sd_req_v[15:12]};
	5'd5:  ov_dig = {1'b0, sd_req_v[11:8]};
	5'd6:  ov_dig = {1'b0, sd_req_v[7:4]};
	5'd7:  ov_dig = {1'b0, sd_req_v[3:0]};
	5'd9:  ov_dig = {1'b0, sd_busy_v[11:8]};
	5'd10: ov_dig = {1'b0, sd_busy_v[7:4]};
	5'd11: ov_dig = {1'b0, sd_busy_v[3:0]};
	5'd13: ov_dig = {1'b0, cp_stop_v[11:8]};
	5'd14: ov_dig = {1'b0, cp_stop_v[7:4]};
	5'd15: ov_dig = {1'b0, cp_stop_v[3:0]};
	default: ov_dig = CH_SP;
	endcase
	else case (ov_cell)
	5'd0:  ov_dig = CH_M;
	5'd1:  ov_dig = CH_P;
	5'd3:  ov_dig = CH_COLON;
	5'd4:  ov_dig = {1'b0, mp_v[15:12]};
	5'd5:  ov_dig = {1'b0, mp_v[11:8]};
	5'd6:  ov_dig = {1'b0, mp_v[7:4]};
	5'd7:  ov_dig = {1'b0, mp_v[3:0]};
	5'd9:  ov_dig = {1'b0, disp_v[15:12]};
	5'd10: ov_dig = {1'b0, disp_v[11:8]};
	5'd11: ov_dig = {1'b0, disp_v[7:4]};
	5'd12: ov_dig = {1'b0, disp_v[3:0]};
	5'd14: ov_dig = flags_v[2] ? 5'hB : CH_SP;
	5'd15: ov_dig = flags_v[1] ? 5'hA : CH_SP;
	5'd16: ov_dig = flags_v[0] ? 5'hD : CH_SP;
	default: ov_dig = CH_SP;
	endcase
end
wire  [7:0] ov_row  = ov_dy < 11'd7 ? glyph(ov_dig, ov_dy[2:0]) : 8'd0;
wire        ov_gap  = 1'b0;
wire        ov_on   = ov_in && !ov_gap && ov_col < 3'd5 && ov_row[3'd4 - ov_col];
reg         ov_px, ov_box;
always @(posedge clk_sys) begin
	ov_px  <= ov_on;
	ov_box <= ov_in;
end

reg  [31:0] cur_xy_s;
reg [255:0] cur_pat_s;
always @(posedge clk_sys) if (vid_vbl) begin
	cur_xy_s  <= cursor_xy;
	cur_pat_s <= cursor_pat;
end
wire signed [13:0] cur_dx = $signed({2'b00, vid_h}) - $signed(cur_xy_s[13:0]);
wire signed [13:0] cur_dy = $signed({3'b000, vid_v}) - $signed(cur_xy_s[29:16]);
wire        cur_in  = cur_xy_s[31] && cur_dx >= 0 && cur_dx < 16 && cur_dy >= 0 && cur_dy < 16;
wire [15:0] cur_row = cur_pat_s[16 * cur_dy[3:0] +: 16];
reg         cur_px;
always @(posedge clk_sys) cur_px <= cur_in && cur_row[4'd15 - cur_dx[3:0]];

wire        pic_blank = cur_xy_s[30];

assign gamma_bus[21] = 1'b0;

reg [7:0] vga_r_r, vga_g_r, vga_b_r;
reg       vga_hs_r, vga_vs_r, vga_de_r;
wire [7:0] pix = ov_box ? (ov_px ? 8'hFF : 8'h00) : cur_px ? 8'h00
               : pic_blank ? 8'hFF : vid_data;

always @(posedge clk_sys) begin
	vga_r_r  <= pix;
	vga_g_r  <= pix;
	vga_b_r  <= pix;
	vga_hs_r <= vid_hs;
	vga_vs_r <= vid_vs;
	vga_de_r <= ~(vid_hbl | vid_vbl);
end

assign VGA_R  = vga_r_r;
assign VGA_G  = vga_g_r;
assign VGA_B  = vga_b_r;
assign VGA_HS = vga_hs_r;
assign VGA_VS = vga_vs_r;

assign CE_PIXEL = 1'b1;

video_freak video_freak
(
	.CLK_VIDEO(CLK_VIDEO),
	.CE_PIXEL(CE_PIXEL),
	.VGA_VS(VGA_VS),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),

	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),

	.VGA_DE_IN(vga_de_r),
	.ARX(status[122] ? 12'd0 : 12'd4),
	.ARY(status[122] ? 12'd0 : 12'd3),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(status[125:123])
);

endmodule

`default_nettype wire
