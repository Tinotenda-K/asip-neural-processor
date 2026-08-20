import numpy as np
from tensorflow.keras.datasets import mnist
import random
import os

def quantize_to_int8(array):
    """Quantizes a NumPy array to signed 8-bit integers."""
    # Normalize to -1.0 to 1.0 range if it's pixel data (0-255)
    if np.max(array) > 1.0:
        array = (array / 255.0) * 2.0 - 1.0
    
    max_val = np.max(np.abs(array))
    scale = 127.0 / max_val if max_val > 0 else 1.0
    quantized = np.round(array * scale).astype(np.int8)
    return quantized, scale

def save_image_to_mem(image_data, output_file="mnist_image.mem"):
    """Saves quantized image data as 32-bit binary strings to a file."""
    with open(output_file, "w") as f:
        for val in image_data:
            # Convert int8 to a 32-bit binary representation for the memory file
            # Correctly handle negative values for 2's complement
            bin_str = format((int(val) + (1 << 32)) % (1 << 32), '032b')
            f.write(bin_str + "\n")
    print(f"[SUCCESS] Saved quantized image to {output_file}")

def main():
    """Loads MNIST, picks a random test image, and saves it."""
    # Ensure the script can find the dataset
    os.environ['TF_DATA_DIR'] = './'
    
    # Load MNIST test set
    try:
        (_, _), (x_test, y_test) = mnist.load_data()
    except Exception as e:
        print(f"Could not load MNIST dataset. Error: {e}")
        print("Please ensure you have an internet connection to download it.")
        return

    # Select a random image and its label
    idx = random.randint(0, len(x_test) - 1)
    img_pixels = x_test[idx]
    label = y_test[idx]
    
    print(f"Selected test image index: {idx}, which is the digit: {label}")

    # Flatten and quantize the image
    img_flat = img_pixels.flatten().astype(np.float32)
    img_quantized, scale = quantize_to_int8(img_flat)

    # Save the quantized image and its label
    save_image_to_mem(img_quantized, "mnist_image.mem")
    with open("mnist_label.txt", "w") as f:
        f.write(str(label) + "\n")
    # Save the input scale so the assembler can align weights/biases
    with open("mnist_image.scale", "w") as f:
        f.write(f"{float(scale)}\n")

if __name__ == "__main__":
    main()