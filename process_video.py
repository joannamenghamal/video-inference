import json
from ultralytics import YOLO
from datetime import datetime
import cv2
import sys

def process_video_to_json(video_path, output_json_path, confidence_threshold=0.5):
    """
    Process video with YOLO and output structured JSON detection results.
    """
    # Load YOLO model
    model = YOLO('yolov8n.pt')
    
    # Get video metadata
    cap = cv2.VideoCapture(video_path)
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    
    # Run inference
    results = model(video_path, stream=True)  # stream=True for memory efficiency (prcess on frame at a time)
    
    # Build JSON structure
    detections_data = {
        "video_metadata": {
            "filename": video_path,
            "fps": fps,
            "total_frames": total_frames,
            "resolution": f"{width}x{height}",
            "processed_at": datetime.now().isoformat()
        },
        "frames": []
    }
    
    # Process each frame
    frame_num = 0
    for result in results:
        frame_detections = []
        
        for box in result.boxes:
            conf = float(box.conf)
            
            # Filter by confidence threshold
            if conf >= confidence_threshold:
                # Get bounding box coordinates (x, y, width, height)
                x, y, w, h = box.xywh[0].tolist()
                
                detection = {
                    "class": result.names[int(box.cls)],
                    "confidence": round(conf, 2),
                    "bounding_box": {
                        "x": round(x, 2),
                        "y": round(y, 2),
                        "width": round(w, 2),
                        "height": round(h, 2)
                    }
                }
                frame_detections.append(detection)
        
        # Add frame data
        detections_data["frames"].append({
            "frame_number": frame_num,
            "timestamp_seconds": round(frame_num / fps, 2),
            "detections": frame_detections,
            "object_count": len(frame_detections)
        })
        
        frame_num += 1
    
    # Write to JSON file
    with open(output_json_path, 'w') as f:
        json.dump(detections_data, f, indent=2)
    
    print(f"Processed {frame_num} frames")
    print(f"JSON output saved to: {output_json_path}")
    return detections_data

# Test it
if __name__ == "__main__":
    video_file = sys.argv[1] if len(sys.argv) > 1 else "short_test_footage.mp4"
    output_file = sys.argv[2] if len(sys.argv) > 2 else "detections_output.json"
    
    process_video_to_json(video_file, output_file, confidence_threshold=0.5)