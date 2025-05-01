/*
 * This file is a part of: https://github.com/brilliantlabsAR/frame-codebase
 *
 * CERN Open Hardware Licence Version 2 - Permissive
 */

module polygon_engine (
    input logic clock_in,
    input logic reset_n_in,
    input logic enable_in,

    input logic [7:0] vertex_count_in,
    input logic [3:0] color_index_in,
    input logic [9:0] focal_length_in,
    
    input logic [9:0] x_vertex_in,
    input logic [9:0] y_vertex_in,
    input logic [9:0] z_vertex_in,
    input logic data_valid_in,
    
    output logic pixel_write_enable_out,
    output logic [17:0] pixel_write_address_out,
    output logic [3:0] pixel_write_data_out
);

// State machine states
typedef enum logic [2:0] {
    IDLE,
    COLLECTING_VERTICES,
    PROCESS_VERTICES,
    RASTERIZE,
    DONE
} state_t;

state_t current_state;
state_t next_state;

// Storage for polygon vertices
parameter MAX_VERTICES = 32;
logic [9:0] x_vertices [MAX_VERTICES-1:0];
logic [9:0] y_vertices [MAX_VERTICES-1:0];
logic [9:0] z_vertices [MAX_VERTICES-1:0];
logic [9:0] x_projected [MAX_VERTICES-1:0];
logic [9:0] y_projected [MAX_VERTICES-1:0];

// Current vertex being processed
logic [7:0] current_vertex;
logic [7:0] vertex_count;

// Rasterization variables
logic [9:0] min_x, max_x, min_y, max_y;
logic [9:0] current_raster_x, current_raster_y;
logic pixel_inside_polygon;

// Edge function for testing if point is inside triangle
// Returns positive if point is on left side of edge
function logic signed [20:0] edge_function(
    logic [9:0] x0, logic [9:0] y0,
    logic [9:0] x1, logic [9:0] y1,
    logic [9:0] px, logic [9:0] py
);
    // (y1 - y0) * (px - x0) - (x1 - x0) * (py - y0)
    logic signed [10:0] y1_minus_y0;
    logic signed [10:0] px_minus_x0;
    logic signed [10:0] x1_minus_x0;
    logic signed [10:0] py_minus_y0;
    
    y1_minus_y0 = {1'b0, y1} - {1'b0, y0};
    px_minus_x0 = {1'b0, px} - {1'b0, x0};
    x1_minus_x0 = {1'b0, x1} - {1'b0, x0};
    py_minus_y0 = {1'b0, py} - {1'b0, y0};
    
    return y1_minus_y0 * px_minus_x0 - x1_minus_x0 * py_minus_y0;
endfunction

// Check if point is inside polygon using winding number algorithm
function logic point_inside_polygon(logic [9:0] px, logic [9:0] py);
    logic inside = 0;
    logic [7:0] i;
    logic [7:0] j;
    
    // We only support triangles for now
    if (vertex_count == 3) begin
        logic signed [20:0] e0, e1, e2;
        
        e0 = edge_function(x_projected[0], y_projected[0], x_projected[1], y_projected[1], px, py);
        e1 = edge_function(x_projected[1], y_projected[1], x_projected[2], y_projected[2], px, py);
        e2 = edge_function(x_projected[2], y_projected[2], x_projected[0], y_projected[0], px, py);
        
        // Point is inside if all edge functions are positive (or all negative for clockwise)
        inside = (e0 >= 0 && e1 >= 0 && e2 >= 0) || (e0 <= 0 && e1 <= 0 && e2 <= 0);
    end
    
    return inside;
endfunction

// Process for state transitions
always_ff @(posedge clock_in or negedge reset_n_in) begin
    if (!reset_n_in) begin
        current_state <= IDLE;
    end else begin
        current_state <= next_state;
    end
end

// Process for next state logic
always_comb begin
    next_state = current_state;
    
    case (current_state)
        IDLE: begin
            if (enable_in) begin
                next_state = COLLECTING_VERTICES;
            end
        end
        
        COLLECTING_VERTICES: begin
            if (current_vertex >= vertex_count && data_valid_in) begin
                next_state = PROCESS_VERTICES;
            end
        end
        
        PROCESS_VERTICES: begin
            next_state = RASTERIZE;
        end
        
        RASTERIZE: begin
            if (current_raster_y > max_y) begin
                next_state = DONE;
            end
        end
        
        DONE: begin
            next_state = IDLE;
        end
    endcase
end

// Datapath operations
always_ff @(posedge clock_in or negedge reset_n_in) begin
    if (!reset_n_in) begin
        current_vertex <= 0;
        vertex_count <= 0;
        pixel_write_enable_out <= 0;
        pixel_write_address_out <= 0;
        pixel_write_data_out <= 0;
        current_raster_x <= 0;
        current_raster_y <= 0;
        
        for (int i = 0; i < MAX_VERTICES; i++) begin
            x_vertices[i] <= 0;
            y_vertices[i] <= 0;
            z_vertices[i] <= 0;
            x_projected[i] <= 0;
            y_projected[i] <= 0;
        end
    end else begin
        case (current_state)
            IDLE: begin
                current_vertex <= 0;
                pixel_write_enable_out <= 0;
                
                if (enable_in) begin
                    vertex_count <= vertex_count_in;
                end
            end
            
            COLLECTING_VERTICES: begin
                if (data_valid_in) begin
                    // Store incoming vertex data
                    if (current_vertex < MAX_VERTICES) begin
                        x_vertices[current_vertex] <= x_vertex_in;
                        y_vertices[current_vertex] <= y_vertex_in;
                        z_vertices[current_vertex] <= z_vertex_in;
                        current_vertex <= current_vertex + 1;
                    end
                end
            end
            
            PROCESS_VERTICES: begin
                // Perspective projection for each vertex
                // Projected x = focal_length * x / z
                // Projected y = focal_length * y / z
                min_x <= 10'hFFF;
                max_x <= 0;
                min_y <= 10'hFFF;
                max_y <= 0;
                
                for (int i = 0; i < vertex_count; i++) begin
                    // Simple perspective projection with z-clipping at 1
                    logic [9:0] z_safe;
                    z_safe = (z_vertices[i] == 0) ? 1 : z_vertices[i];
                    
                    // Apply perspective transformation
                    // Using focal_length as the scaling factor
                    // To simplify calculation, we're just doing a scale by 
                    // z distance instead of full perspective division
                    x_projected[i] <= (focal_length_in * x_vertices[i]) / z_safe;
                    y_projected[i] <= (focal_length_in * y_vertices[i]) / z_safe;
                    
                    // Find bounding box (will be updated in next cycle)
                    if (x_projected[i] < min_x) min_x <= x_projected[i];
                    if (x_projected[i] > max_x) max_x <= x_projected[i];
                    if (y_projected[i] < min_y) min_y <= y_projected[i];
                    if (y_projected[i] > max_y) max_y <= y_projected[i];
                end
                
                // Initialize rasterization coordinates
                current_raster_x <= min_x;
                current_raster_y <= min_y;
            end
            
            RASTERIZE: begin
                // Check if current pixel is inside the polygon
                pixel_inside_polygon = point_inside_polygon(current_raster_x, current_raster_y);
                
                // If inside, write the pixel
                if (pixel_inside_polygon) begin
                    pixel_write_enable_out <= 1;
                    // Convert x,y to frame buffer address (assuming 640x400 display)
                    // Address = y * 640 + x
                    pixel_write_address_out <= {current_raster_y[8:0], 9'b0} + 
                                              {current_raster_y[8:0], 7'b0} +
                                              {9'b0, current_raster_x[9:0]};
                    pixel_write_data_out <= color_index_in;
                end else begin
                    pixel_write_enable_out <= 0;
                end
                
                // Move to next pixel
                if (current_raster_x < max_x) begin
                    current_raster_x <= current_raster_x + 1;
                end else begin
                    current_raster_x <= min_x;
                    current_raster_y <= current_raster_y + 1;
                end
            end
            
            DONE: begin
                pixel_write_enable_out <= 0;
            end
        endcase
    end
end

endmodule 