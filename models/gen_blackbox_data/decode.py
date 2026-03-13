#!/usr/bin/env python3

def analyze_hex_data_by_cluster(filename):
    """
    Reads hex data file and extracts 11-bit numbers based on count field.
    Groups data by input cluster and calculates frequency and percentage of each number per cluster.
    """
    
    cluster_data = {}  # Dictionary to store data by cluster
    
    try:
        with open(filename, "r") as file:
            for line_num, line in enumerate(file, 1):
                line = line.strip()
                if not line:
                    continue
                
                # Parse the line format: hexvalue:cluster_id
                try:
                    hex_part, cluster_part = line.split(':')
                    cluster_id = int(cluster_part.strip())
                    hex_string = hex_part.strip()
                except ValueError:
                    print(f"Warning: Line {line_num} has invalid format, skipping")
                    continue
                
                # Remove any non-hex characters and convert to uppercase
                hex_string = ''.join(c for c in hex_string if c in '0123456789ABCDEFabcdef')
                
                if len(hex_string) < 16:  # Need at least 16 hex chars for 64-bit number
                    print(f"Warning: Line {line_num} hex part too short, skipping")
                    continue
                
                try:
                    # Convert hex string to integer
                    hex_value = int(hex_string, 16)
                    
                    # Extract count from bits [3:1] (bits 1, 2, 3)
                    count = (hex_value >> 1) & 0x7  # 0x7 = 111 in binary (3 bits)
                    
                    # Initialize cluster data if not exists
                    if cluster_id not in cluster_data:
                        cluster_data[cluster_id] = []
                    
                    if count > 0:
                        # Extract 11-bit numbers from the left (most significant bits)
                        bit_position = 64 - 11  # Start from bit 53 for first 11-bit number
                        
                        for i in range(count):
                            # Extract 11 bits from the current position
                            eleven_bit_num = (hex_value >> bit_position) & 0x7FF
                            cluster_data[cluster_id].append(eleven_bit_num)
                            
                            # Move to next 11-bit position (11 bits to the right)
                            bit_position -= 11
                            
                            # Debug print for first few entries
                            if line_num <= 10 and eleven_bit_num != 0:
                                print(f"  Line {line_num}, Cluster {cluster_id}: Extracted {hex(eleven_bit_num)} from bit position {bit_position + 11}")
                
                except ValueError as e:
                    print(f"Error processing line {line_num}: {e}")
                    continue
    
    except FileNotFoundError:
        print(f"Error: File '{filename}' not found")
        return
    except Exception as e:
        print(f"Error reading file: {e}")
        return
    
    if not cluster_data:
        print("No valid data extracted")
        return
    
    # Analyze each cluster
    print(f"Found {len(cluster_data)} input clusters\n")
    
    for cluster_id in sorted(cluster_data.keys()):
        numbers_list = cluster_data[cluster_id]
        
        if not numbers_list:
            print(f"Cluster {cluster_id}: No numbers extracted")
            continue
            
        # Filter out zeros for meaningful analysis
        non_zero_numbers = [num for num in numbers_list if num != 0]
        
        print(f"=== CLUSTER {cluster_id} ===")
        print(f"Total numbers extracted: {len(numbers_list)}")
        print(f"Non-zero numbers: {len(non_zero_numbers)}")
        
        if non_zero_numbers:
            print(f"Range of non-zero numbers: {min(non_zero_numbers)} to {max(non_zero_numbers)}")
            
            # Count frequencies (only non-zero numbers)
            frequency = {}
            for num in non_zero_numbers:
                frequency[num] = frequency.get(num, 0) + 1
            
            # Calculate percentages
            total_nonzero = len(non_zero_numbers)
            
            print(f"\nFrequency Analysis (Non-zero numbers only):")
            print(f"{'Number':<10} {'Hex':<8} {'Count':<10} {'Percentage':<12}")
            print("-" * 45)
            
            # Sort by frequency (most common first)
            for num, count in sorted(frequency.items(), key=lambda x: x[1], reverse=True):
                percentage = (count / total_nonzero) * 100
                print(f"{num:<10} {hex(num):<8} {count:<10} {percentage:<12.2f}%")
            
            # Summary statistics
            print(f"\nCluster {cluster_id} Summary:")
            print(f"Unique non-zero numbers: {len(frequency)}")
            if frequency:
                most_freq = max(frequency.items(), key=lambda x: x[1])
                least_freq = min(frequency.items(), key=lambda x: x[1])
                print(f"Most frequent: {most_freq[0]} (hex: {hex(most_freq[0])}) - {most_freq[1]} times")
                print(f"Least frequent: {least_freq[0]} (hex: {hex(least_freq[0])}) - {least_freq[1]} times")
        else:
            print("No non-zero numbers found in this cluster")
        
        print("\n" + "="*50 + "\n")
    
    # Overall summary across all clusters
    all_numbers = []
    for numbers_list in cluster_data.values():
        all_numbers.extend(numbers_list)
    
    all_non_zero = [num for num in all_numbers if num != 0]
    
    print("=== OVERALL SUMMARY ===")
    print(f"Total clusters: {len(cluster_data)}")
    print(f"Total numbers across all clusters: {len(all_numbers)}")
    print(f"Total non-zero numbers: {len(all_non_zero)}")
    
    if all_non_zero:
        overall_freq = {}
        for num in all_non_zero:
            overall_freq[num] = overall_freq.get(num, 0) + 1
        
        print(f"Unique non-zero numbers across all clusters: {len(overall_freq)}")
        print(f"Range: {min(all_non_zero)} to {max(all_non_zero)}")
        
        # Show top 10 most frequent numbers across all clusters
        print(f"\nTop 10 most frequent numbers across all clusters:")
        print(f"{'Number':<10} {'Hex':<8} {'Count':<10} {'Percentage':<12}")
        print("-" * 45)
        
        sorted_freq = sorted(overall_freq.items(), key=lambda x: x[1], reverse=True)
        for i, (num, count) in enumerate(sorted_freq[:10]):
            percentage = (count / len(all_non_zero)) * 100
            print(f"{num:<10} {hex(num):<8} {count:<10} {percentage:<12.2f}%")
    
    return cluster_data


def write_spike_outputs(cluster_data, output_filename="spike_outputs.txt"):
    """
    Writes the cluster analysis results to a file in the format:
    cluster_id:number_1,number_1_freq:number_2,number_2_freq:...
    """
    try:
        with open(output_filename, "w") as file:
            for cluster_id in sorted(cluster_data.keys()):
                numbers_list = cluster_data[cluster_id]
                
                # Filter out zeros and count frequencies
                non_zero_numbers = [num for num in numbers_list if num != 0]
                
                if not non_zero_numbers:
                    # Write cluster with no data
                    file.write(f"{cluster_id}:\n")
                    continue
                
                # Count frequencies
                frequency = {}
                for num in non_zero_numbers:
                    frequency[num] = frequency.get(num, 0) + 1
                
                # Build the output line
                line_parts = [str(cluster_id)]
                
                # Sort by number value for consistent output
                for num in sorted(frequency.keys()):
                    count = frequency[num]
                    line_parts.append(f"{num},{count}")
                
                # Write the line
                file.write(":".join(line_parts) + "\n")
        
        print(f"Results written to '{output_filename}'")
        return True
        
    except Exception as e:
        print(f"Error writing to file '{output_filename}': {e}")
        return False


# Example usage
if __name__ == "__main__":    
    print("Analyzing hex data by input clusters...")
    result = analyze_hex_data_by_cluster("output.txt")
    
    if result:
        print(f"\nAnalysis complete! Found data for {len(result)} clusters.")
        
        # Write results to spike_outputs.txt
        print("\nWriting results to spike_outputs.txt...")
        write_spike_outputs(result)
        print("Done!")