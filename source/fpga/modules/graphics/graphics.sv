/*
 * This file is a part of: https://github.com/brilliantlabsAR/frame-codebase
 *
 * Authored by: Rohit Rathnam / Silicon Witchery AB (rohit@siliconwitchery.com)
 *              Raj Nakarja / Brilliant Labs Limited (raj@brilliant.xyz)
 *              Robert Metchev / Raumzeit Technologies (robert@raumzeit.co)
 *
 * CERN Open Hardware Licence Version 2 - Permissive
 *
 * Copyright © 2023 Brilliant Labs Limited
 */

`ifndef RADIANT
`include "modules/graphics/color_palette.sv"
`include "modules/graphics/display_buffers.sv"
`include "modules/graphics/display_driver.sv"
`include "modules/graphics/sprite_engine.sv"
`include "modules/graphics/polygon_engine.sv"
`endif

module graphics (
    input logic spi_clock_in,
    input logic spi_reset_n_in,

    input logic display_clock_in,
    input logic display_reset_n_in,

    input logic [7:0] op_code_in,
    input logic op_code_valid_in,
    input logic [7:0] operand_in,
    input logic operand_valid_in,
    input logic [31:0] operand_count_in,
    input logic operand_read,
    input logic [31:0] rd_operand_count_in,  // was operand_count_out
    output logic [7:0] response_out,

    output logic display_clock_out,
    output logic display_hsync_out,
    output logic display_vsync_out,
    output logic [3:0] display_y_out,
    output logic [2:0] display_cb_out,
    output logic [2:0] display_cr_out
);

// register addresses
parameter GRAPHICS_ASSIGN_COLOR = 'h11;
parameter GRAPHICS_DRAW_SPRITE = 'h12;
parameter GRAPHICS_DRAW_VECTOR = 'h13;
parameter GRAPHICS_BUFFER_SHOW = 'h14;
parameter GRAPHICS_DRAW_POLYGON = 'h15;
parameter GRAPHICS_BUFFER_STATUS = 'h18;

logic [3:0] assign_color_index_spi_domain;
logic [9:0] assign_color_value_spi_domain;
logic assign_color_enable_spi_domain;
logic assign_color_enable;

logic [9:0] sprite_x_position_spi_domain;     // 0 - 639
logic [9:0] sprite_y_position_spi_domain;     // 0 - 399
logic [9:0] sprite_width_spi_domain;          // 1 - 640
logic [4:0] sprite_color_count_spi_domain;    // 1, 4 or 16 colors
logic [3:0] sprite_palette_offset_spi_domain; // 0 - 15
logic [7:0] sprite_data_spi_domain;
logic sprite_data_valid_spi_domain;
logic sprite_enable_spi_domain;
logic sprite_data_valid;
logic sprite_enable;

// Polygon signals
logic [9:0] polygon_x_vertex_spi_domain;      // 0 - 639
logic [9:0] polygon_y_vertex_spi_domain;      // 0 - 399
logic [9:0] polygon_z_vertex_spi_domain;      // Z-coordinate for 3D rendering
logic [3:0] polygon_color_index_spi_domain;   // 0 - 15
logic [7:0] polygon_vertex_count_spi_domain;  // Number of vertices
logic [9:0] polygon_focal_length_spi_domain;  // Focal length for perspective projection
logic polygon_data_valid_spi_domain;
logic polygon_enable_spi_domain;
logic polygon_data_valid;
logic polygon_enable;

logic switch_buffer_spi_domain;
logic switch_buffer;
logic [1:0] buffer_status;

// SPI registers

// Assign color
always_comb assign_color_enable_spi_domain  = op_code_in == GRAPHICS_ASSIGN_COLOR & operand_valid_in & operand_count_in == 3;
// Draw sprite
always_comb sprite_data_valid_spi_domain    = op_code_in == GRAPHICS_DRAW_SPRITE & operand_valid_in & operand_count_in > 7;
always_comb sprite_enable_spi_domain        = operand_count_in == 8;
always_comb sprite_enable                   = sprite_enable_spi_domain;
// Draw polygon
always_comb polygon_data_valid_spi_domain   = op_code_in == GRAPHICS_DRAW_POLYGON & operand_valid_in & operand_count_in > 3;
always_comb polygon_enable_spi_domain       = op_code_in == GRAPHICS_DRAW_POLYGON & operand_valid_in & operand_count_in >= (polygon_vertex_count_spi_domain * 3 + 3);
always_comb polygon_enable                  = polygon_enable_spi_domain;
// Switch buffer
always_comb switch_buffer_spi_domain        = op_code_in == GRAPHICS_BUFFER_SHOW & op_code_valid_in;

always_ff @(negedge spi_clock_in) begin
    case (op_code_in)
        // Assign color
        GRAPHICS_ASSIGN_COLOR: begin
            if (operand_valid_in) begin
                case (operand_count_in)
                    0: assign_color_index_spi_domain <= operand_in[3:0];
                    1: assign_color_value_spi_domain[9:6] <= operand_in[3:0];
                    2: assign_color_value_spi_domain[5:3] <= operand_in[2:0];
                    3: assign_color_value_spi_domain[2:0] <= operand_in[2:0];
                endcase
            end
        end

        // Draw sprite
        GRAPHICS_DRAW_SPRITE: begin
            if (operand_valid_in) begin
                case (operand_count_in)
                    0: sprite_x_position_spi_domain <= {operand_in[1:0], 8'b0};
                    1: sprite_x_position_spi_domain <= {sprite_x_position_spi_domain[9:8], operand_in};
                    2: sprite_y_position_spi_domain <= {operand_in[1:0], 8'b0};
                    3: sprite_y_position_spi_domain <= {sprite_y_position_spi_domain[9:8], operand_in};
                    4: sprite_width_spi_domain <= {operand_in[1:0], 8'b0};
                    5: sprite_width_spi_domain <= {sprite_width_spi_domain[9:8], operand_in};
                    6: sprite_color_count_spi_domain <= operand_in[4:0];
                    7: sprite_palette_offset_spi_domain <= operand_in[3:0];
                    default: sprite_data_spi_domain <= operand_in;        
                endcase
            end
        end
        
        // Draw polygon
        GRAPHICS_DRAW_POLYGON: begin
            if (operand_valid_in) begin
                case (operand_count_in)
                    0: polygon_vertex_count_spi_domain <= operand_in; // Number of vertices
                    1: polygon_color_index_spi_domain <= operand_in[3:0]; // Color index
                    2: polygon_focal_length_spi_domain[9:8] <= operand_in[1:0]; // Focal length upper bits
                    3: polygon_focal_length_spi_domain[7:0] <= operand_in; // Focal length lower bits
                    default: begin
                        // Vertex coordinates are stored in sequence: x1, y1, z1, x2, y2, z2...
                        if (operand_count_in >= 4) begin
                            case ((operand_count_in - 4) % 6)
                                0: polygon_x_vertex_spi_domain[9:8] <= operand_in[1:0]; // X coordinate upper bits
                                1: polygon_x_vertex_spi_domain[7:0] <= operand_in; // X coordinate lower bits
                                2: polygon_y_vertex_spi_domain[9:8] <= operand_in[1:0]; // Y coordinate upper bits
                                3: polygon_y_vertex_spi_domain[7:0] <= operand_in; // Y coordinate lower bits
                                4: polygon_z_vertex_spi_domain[9:8] <= operand_in[1:0]; // Z coordinate upper bits
                                5: polygon_z_vertex_spi_domain[7:0] <= operand_in; // Z coordinate lower bits
                            endcase
                        end
                    end
                endcase
            end
        end
    endcase
end

always_comb
    case (op_code_in)
    GRAPHICS_BUFFER_STATUS: response_out = buffer_status;
    default: response_out = 0;
    endcase


// SPI to display CDC
// SPI pulse sync
psync1 psync1_assign_color_enable (
        .in             (assign_color_enable_spi_domain),
        .in_clk         (~spi_clock_in),
        .in_reset_n     (spi_reset_n_in),
        .out            (assign_color_enable),
        .out_clk        (display_clock_in),
        .out_reset_n    (display_reset_n_in)
);

psync1 psync1_sprite_data_valid (
        .in             (sprite_data_valid_spi_domain),
        .in_clk         (~spi_clock_in),
        .in_reset_n     (spi_reset_n_in),
        .out            (sprite_data_valid),
        .out_clk        (display_clock_in),
        .out_reset_n    (display_reset_n_in)
);

psync1 psync1_polygon_data_valid (
        .in             (polygon_data_valid_spi_domain),
        .in_clk         (~spi_clock_in),
        .in_reset_n     (spi_reset_n_in),
        .out            (polygon_data_valid),
        .out_clk        (display_clock_in),
        .out_reset_n    (display_reset_n_in)
);

psync1 psync1_switch_buffer (
        .in             (switch_buffer_spi_domain),
        .in_clk         (~spi_clock_in),
        .in_reset_n     (spi_reset_n_in),
        .out            (switch_buffer),
        .out_clk        (display_clock_in),
        .out_reset_n    (display_reset_n_in)
);


// Feed display buffer from either sprite or vector engine
logic pixel_write_enable_sprite_to_mux_wire;
logic [17:0] pixel_write_address_sprite_to_mux_wire;
logic [3:0] pixel_write_data_sprite_to_mux_wire;

logic pixel_write_enable_vector_to_mux_wire = 0; // TODO wire this up
logic [17:0] pixel_write_address_vector_to_mux_wire;
logic [3:0] pixel_write_data_vector_to_mux_wire;

// Polygon engine outputs
logic pixel_write_enable_polygon_to_mux_wire = 0; // Will be wired up when polygon engine is implemented
logic [17:0] pixel_write_address_polygon_to_mux_wire;
logic [3:0] pixel_write_data_polygon_to_mux_wire;

logic pixel_write_enable_mux_to_buffer_wire;
logic [17:0] pixel_write_address_mux_to_buffer_wire;
logic [3:0] pixel_write_data_mux_to_buffer_wire;

always_comb begin
    if (pixel_write_enable_sprite_to_mux_wire) begin
        pixel_write_enable_mux_to_buffer_wire = 1'b1;
        pixel_write_address_mux_to_buffer_wire = pixel_write_address_sprite_to_mux_wire;
        pixel_write_data_mux_to_buffer_wire = pixel_write_data_sprite_to_mux_wire;
    end

    else if (pixel_write_enable_vector_to_mux_wire) begin
        pixel_write_enable_mux_to_buffer_wire = 1'b1;
        pixel_write_address_mux_to_buffer_wire = pixel_write_address_vector_to_mux_wire;
        pixel_write_data_mux_to_buffer_wire = pixel_write_data_vector_to_mux_wire;
    end
    
    else if (pixel_write_enable_polygon_to_mux_wire) begin
        pixel_write_enable_mux_to_buffer_wire = 1'b1;
        pixel_write_address_mux_to_buffer_wire = pixel_write_address_polygon_to_mux_wire;
        pixel_write_data_mux_to_buffer_wire = pixel_write_data_polygon_to_mux_wire;
    end

    else begin
        pixel_write_enable_mux_to_buffer_wire = 1'b0;
        pixel_write_address_mux_to_buffer_wire = 18'b0;
        pixel_write_data_mux_to_buffer_wire = 4'b0;
    end
end

sprite_engine sprite_engine (
    .clock_in(display_clock_in),
    .reset_n_in(display_reset_n_in),
    .enable_in(sprite_enable),

    .x_position_in(sprite_x_position_spi_domain),
    .y_position_in(sprite_y_position_spi_domain),
    .width_in(sprite_width_spi_domain),
    .total_colors_in(sprite_color_count_spi_domain),
    .color_palette_offset_in(sprite_palette_offset_spi_domain),

    .data_valid_in(sprite_data_valid),
    .data_in(sprite_data_spi_domain),

    .pixel_write_enable_out(pixel_write_enable_sprite_to_mux_wire),
    .pixel_write_address_out(pixel_write_address_sprite_to_mux_wire),
    .pixel_write_data_out(pixel_write_data_sprite_to_mux_wire)
);

// Polygon engine for 3D polygon rendering
polygon_engine polygon_engine (
    .clock_in(display_clock_in),
    .reset_n_in(display_reset_n_in),
    .enable_in(polygon_enable),

    .vertex_count_in(polygon_vertex_count_spi_domain),
    .color_index_in(polygon_color_index_spi_domain),
    .focal_length_in(polygon_focal_length_spi_domain),
    
    .x_vertex_in(polygon_x_vertex_spi_domain),
    .y_vertex_in(polygon_y_vertex_spi_domain),
    .z_vertex_in(polygon_z_vertex_spi_domain),
    .data_valid_in(polygon_data_valid),
    
    .pixel_write_enable_out(pixel_write_enable_polygon_to_mux_wire),
    .pixel_write_address_out(pixel_write_address_polygon_to_mux_wire),
    .pixel_write_data_out(pixel_write_data_polygon_to_mux_wire)
);

// Vector engine
// TODO

logic [17:0] read_address_driver_to_buffer_wire;
logic [3:0] color_data_buffer_to_palette_wire;
logic [9:0] color_data_palette_to_driver_wire;

display_buffers display_buffers (
    .clock_in(display_clock_in),
    .reset_n_in(display_reset_n_in),

    .pixel_write_enable_in(pixel_write_enable_mux_to_buffer_wire),
    .pixel_write_address_in(pixel_write_address_mux_to_buffer_wire),
    .pixel_write_data_in(pixel_write_data_mux_to_buffer_wire),

    .pixel_read_address_in(read_address_driver_to_buffer_wire),
    .pixel_read_data_out(color_data_buffer_to_palette_wire),

    .buffer_status(buffer_status),
    .switch_write_buffer_in(switch_buffer)
);

color_palette color_palette (
    .clock_in(display_clock_in),
    .reset_n_in(display_reset_n_in),

    .pixel_index_in(color_data_buffer_to_palette_wire),
    .yuv_color_out(color_data_palette_to_driver_wire),

    .assign_color_enable_in(assign_color_enable),
    .assign_color_index_in(assign_color_index_spi_domain),
    .assign_color_value_in(assign_color_value_spi_domain)
);

display_driver display_driver (
    .clock_in(display_clock_in),
    .reset_n_in(display_reset_n_in),

    .pixel_data_address_out(read_address_driver_to_buffer_wire),
    .pixel_data_value_in(color_data_palette_to_driver_wire),

    .display_clock_out(display_clock_out),
    .display_hsync_out(display_hsync_out),
    .display_vsync_out(display_vsync_out),
    .display_y_out(display_y_out),
    .display_cb_out(display_cb_out),
    .display_cr_out(display_cr_out)
);

endmodule
