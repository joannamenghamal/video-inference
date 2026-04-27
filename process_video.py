import json
import sys
import boto3
import time
from ultralytics import YOLO
from datetime import datetime
import cv2
import os

def process_video_to_json(video_path, output_json_path, confidence_threshold=0.5):
    """
    Process video with YOLO and output structured JSON detection results.
    """
    # Load YOLO model (weights baked into image at /var/task/yolov8n.pt)
    model = YOLO('/var/task/yolov8n.pt')
    
    # Get video metadata
    cap = cv2.VideoCapture(video_path)
    fps = cap.get(cv2.CAP_PROP_FPS)
    total_frames = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
    width = int(cap.get(cv2.CAP_PROP_FRAME_WIDTH))
    height = int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
    cap.release()
    
    # Run inference
    results = model(video_path, stream=True)
    
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
            
            if conf >= confidence_threshold:
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
        
        detections_data["frames"].append({
            "frame_number": frame_num,
            "timestamp_seconds": round(frame_num / fps, 2) if fps > 0 else 0,
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
