import sys
import re

def main():
    if len(sys.argv) < 2:
        print("Usage: compute_rtf.py <log_file>")
        return
        
    log_file = sys.argv[1]
    
    total_audio_duration = 0.0
    total_inference_time = 0.0
    
    with open(log_file, 'r') as f:
        for line in f:
            if "Loaded" in line and "audio samples" in line:
                match = re.search(r'\(([\d.]+)\s+seconds\)', line)
                if match:
                    total_audio_duration += float(match.group(1))
            
            # Predict took 0.0123 seconds
            if "Predict took" in line:
                match = re.search(r'Predict took ([\d.]+)', line)
                if match:
                    total_inference_time += float(match.group(1))
                    
    if total_audio_duration > 0:
        rtf = total_inference_time / total_audio_duration
        print(f"Total Audio: {total_audio_duration:.2f}s")
        print(f"Total Inference: {total_inference_time:.2f}s")
        print(f"RTF: {rtf:.3f}x")
    else:
        print("No audio duration found in logs.")

if __name__ == "__main__":
    main()
