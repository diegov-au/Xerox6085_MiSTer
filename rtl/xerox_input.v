module xerox_input
(
	input             clk,
	input             reset,
	input      [10:0] ps2_key,
	input      [24:0] ps2_mouse,
	output reg [31:0] mouse_xy,
	output reg [143:0] keys
);

function [6:0] keynum(input [8:0] k);
	case (k)
	9'h01C: keynum = 7'd37;  9'h032: keynum = 7'd55;  9'h021: keynum = 7'd53;
	9'h023: keynum = 7'd21;  9'h024: keynum = 7'd19;  9'h02B: keynum = 7'd51;
	9'h034: keynum = 7'd66;  9'h033: keynum = 7'd68;  9'h043: keynum = 7'd39;
	9'h03B: keynum = 7'd54;  9'h042: keynum = 7'd25;  9'h04B: keynum = 7'd42;
	9'h03A: keynum = 7'd71;  9'h031: keynum = 7'd70;  9'h044: keynum = 7'd41;
	9'h04D: keynum = 7'd27;  9'h015: keynum = 7'd35;  9'h02D: keynum = 7'd64;
	9'h01B: keynum = 7'd36;  9'h02C: keynum = 7'd65;  9'h03C: keynum = 7'd22;
	9'h02A: keynum = 7'd23;  9'h01D: keynum = 7'd34;  9'h022: keynum = 7'd40;
	9'h035: keynum = 7'd67;  9'h01A: keynum = 7'd56;
	9'h016: keynum = 7'd48;  9'h01E: keynum = 7'd33;  9'h026: keynum = 7'd32;
	9'h025: keynum = 7'd17;  9'h02E: keynum = 7'd16;  9'h036: keynum = 7'd18;
	9'h03D: keynum = 7'd20;  9'h03E: keynum = 7'd69;  9'h046: keynum = 7'd38;
	9'h045: keynum = 7'd24;
	9'h029: keynum = 7'd73;  9'h05A: keynum = 7'd60;  9'h15A: keynum = 7'd63;
	9'h066: keynum = 7'd31;  9'h171: keynum = 7'd62;  9'h00D: keynum = 7'd49;
	9'h012: keynum = 7'd57;  9'h059: keynum = 7'd76;  9'h058: keynum = 7'd72;
	9'h04E: keynum = 7'd26;  9'h055: keynum = 7'd75;  9'h054: keynum = 7'd74;
	9'h05B: keynum = 7'd45;  9'h04C: keynum = 7'd59;  9'h052: keynum = 7'd44;
	9'h041: keynum = 7'd43;  9'h049: keynum = 7'd58;  9'h04A: keynum = 7'd28;
	9'h00E: keynum = 7'd61;  9'h076: keynum = 7'd77;  9'h17A: keynum = 7'd63;
	9'h005: keynum = 7'd97;  9'h006: keynum = 7'd99;  9'h004: keynum = 7'd100;
	9'h00C: keynum = 7'd3;   9'h003: keynum = 7'd4;   9'h00B: keynum = 7'd101;
	9'h083: keynum = 7'd2;   9'h00A: keynum = 7'd104; 9'h001: keynum = 7'd80;
	9'h009: keynum = 7'd29;
	9'h011: keynum = 7'd47;  9'h111: keynum = 7'd93;
	default: keynum = 7'd127;
	endcase
endfunction

function [6:0] ctrlnum(input [8:0] k);
	case (k)
	9'h044: ctrlnum = 7'd46;  9'h04D: ctrlnum = 7'd52;  9'h021: ctrlnum = 7'd89;
	9'h03A: ctrlnum = 7'd78;  9'h031: ctrlnum = 7'd63;  9'h02B: ctrlnum = 7'd90;
	9'h01C: ctrlnum = 7'd91;  9'h01B: ctrlnum = 7'd30;  9'h03C: ctrlnum = 7'd79;
	9'h033: ctrlnum = 7'd92;
	default: ctrlnum = 7'd127;
	endcase
endfunction
function [7:0] bitpos(input [6:0] n);
	bitpos = {n[6:4], 4'd0} + (8'd15 - {4'd0, n[3:0]});
endfunction

reg        key_t, mouse_t;
reg        lctrl, rctrl;
wire [6:0] kc = ctrlnum(ps2_key[8:0]);
wire [6:0] kp = (lctrl | rctrl) && kc != 7'd127 ? kc : keynum(ps2_key[8:0]);
reg [11:0] mx;
reg [10:0] my;
wire [6:0] kn = keynum(ps2_key[8:0]);
wire signed [13:0] dx = {{6{ps2_mouse[4]}}, ps2_mouse[15:8]};
wire signed [13:0] dy = {{6{ps2_mouse[5]}}, ps2_mouse[23:16]};
wire signed [13:0] nx = $signed({2'b00, mx}) + dx;
wire signed [13:0] ny = $signed({3'b000, my}) - dy;

always @(posedge clk) begin
	if (reset) begin
		keys     <= {144{1'b1}};
		key_t    <= ps2_key[10];
		lctrl    <= 1'b0;
		rctrl    <= 1'b0;
		mouse_t  <= ps2_mouse[24];
		mx       <= 12'd576;
		my       <= 11'd430;
		mouse_xy <= {16'd430, 16'd576};
	end
	else begin
		if (ps2_key[10] != key_t) begin
			key_t <= ps2_key[10];
			if (ps2_key[8:0] == 9'h014) lctrl <= ps2_key[9];
			else if (ps2_key[8:0] == 9'h114) rctrl <= ps2_key[9];
			else if (ps2_key[9]) begin
				if (kp != 7'd127) keys[bitpos(kp)] <= 1'b0;
			end
			else begin
				if (kn != 7'd127) keys[bitpos(kn)] <= 1'b1;
				if (kc != 7'd127) keys[bitpos(kc)] <= 1'b1;
			end
		end
		if (ps2_mouse[24] != mouse_t) begin
			mouse_t <= ps2_mouse[24];
			mx <= nx < 0 ? 12'd0 : nx > 14'sd1151 ? 12'd1151 : nx[11:0];
			my <= ny < 0 ? 11'd0 : ny > 14'sd860  ? 11'd860  : ny[10:0];
			keys[bitpos(7'd13)] <= ~ps2_mouse[0];
			keys[bitpos(7'd14)] <= ~ps2_mouse[1];
			keys[bitpos(7'd15)] <= ~ps2_mouse[2];
		end
		mouse_xy <= {5'd0, my, 4'd0, mx};
	end
end

endmodule
