with open("output.txt", 'r') as f:
    output_file = f.read()

output = {}
output_array = []
expected_output = [2,1,0,2,0,2,0,1,1,1,2,1,1,1,1,0,1,1,0,0,2,1,0,0,2,0,0,1,1,0]

# for each line
for line in output_file.splitlines():
    if line.strip() and ":" in line:  # Check if the line is not empty
        index, value = line.strip().split(":")
        if index not in output.keys():
            output[index] = {}
        if value not in output[index].keys():
            output[index][value] = 0
        output[index][value] += 1

print("Output Summary:")
for index, values in output.items():
    # get max count value
    max_value = max(values, key=values.get)
    max_count = values[max_value]
    print(f"Index {index}: {max_value[-1]} (Count: {max_count})")
    output_array.append(int(max_value[-1]))

print("Output Array:", output_array)

# Calculate accuracy
correct = sum(1 for i in range(len(expected_output)) if output_array[i] == expected_output[i])
total = len(expected_output)
print("------")
print(f"Test Accuracy: {100 * correct / total:.2f}% ({correct}/{total})")
print("------")