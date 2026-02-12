module outgoing_enc #(
    parameter neurons_can_handle = 32,  // Configurable network size
    parameter packet_width = 11,
    parameter cluster_id = 6'b000000
)(
    input wire clk,
    input wire rst,
    input wire spikes_done,                          // Indicates spike vector is valid
    input wire fifo_full,
    input wire [neurons_can_handle-1:0] spikes,     // Spike vector from neurons
    output reg [packet_width-1:0] packet,
    output reg wr_en,
    output wire outgoing_enc_done // Signal to indicate encoding is done
);
    // ================ Internal Registers ================
    reg enc_state;
    reg prev_spikes_done;
    reg [neurons_can_handle-1:0] sent_spikes; // Track sent spikes
    reg [neurons_can_handle-1:0] sent_spikes_prev; // Track previous sent spikes
    wire [neurons_can_handle-1:0] remaining_spikes; // Remaining spikes after masking
    wire [neurons_can_handle-1:0] selected_spike; // Current neuron index
    wire [$clog2(neurons_can_handle)-1:0] selected_spike_index; // Index of the current neuron


    function integer onehot_to_index;
        input [neurons_can_handle-1:0] onehot;
        integer idx;
        begin
            onehot_to_index = 0;
            for (idx = 0; idx <= neurons_can_handle-1; idx = idx + 1)
                if (onehot[idx]) onehot_to_index = idx;
        end
    endfunction

    genvar k;
    // Calculate remaining spikes after masking
    assign remaining_spikes = spikes & ~sent_spikes;
    // select the current spike
    generate
        assign selected_spike[0] = remaining_spikes[0];
        for (k = 1; k < neurons_can_handle; k = k + 1) begin : selected_spike_gen
            assign selected_spike[k] = ~|remaining_spikes[k-1:0] & remaining_spikes[k];
        end
    endgenerate

    assign selected_spike_index = onehot_to_index(selected_spike);

    assign outgoing_enc_done = ~(spikes_done && !prev_spikes_done | enc_state);

    always @(posedge clk) begin
        // Edge detection for spikes_done
        prev_spikes_done <= spikes_done;
        if (rst) begin
            packet <= 0;
            enc_state <= 0;
            prev_spikes_done <= 0;
            wr_en <= 0;  
            sent_spikes <= 0;  
            sent_spikes_prev <= 0; // Reset sent spikes      
        end else if (spikes_done && !prev_spikes_done) begin
            enc_state <= 1;  // Begin encoding    // Reset counter at start
        end else if (enc_state == 1) begin
            if (!fifo_full) begin
                if (|selected_spike) begin  // Check masked spikes
                    sent_spikes_prev <= sent_spikes; // Store previous sent spikes
                    packet <= {cluster_id, selected_spike_index[4:0]};
                    sent_spikes <= sent_spikes | selected_spike; // Update sent spikes
                    wr_en <= 1;
                end else begin
                    enc_state <= 0; // Move to done state
                    sent_spikes <= 0; // Reset sent spikes
                    wr_en <= 0; // done spikes
                end
            end else begin
                sent_spikes <= sent_spikes_prev; // Restore previous sent spikes
                wr_en <= 0; // FIFO is full, do not write
            end
        end
    end

endmodule
