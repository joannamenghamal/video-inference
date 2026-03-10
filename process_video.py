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

def process_from_s3(input_bucket, video_key, output_bucket):
    """
    Download video from S3, process it, and upload results to S3.
    """
    s3 = boto3.client('s3')
    
    # Create temp directory
    os.makedirs('/tmp/videos', exist_ok=True)
    
    # Download video from S3
    local_video_path = f'/tmp/videos/{os.path.basename(video_key)}'
    print(f"Downloading {video_key} from {input_bucket}...")
    s3.download_file(input_bucket, video_key, local_video_path)
    print("Download complete!")
    
    # Process video
    local_json_path = '/tmp/videos/output.json'
    process_video_to_json(local_video_path, local_json_path, confidence_threshold=0.5)
    
    # Upload JSON to S3
    output_key = f"results/{os.path.splitext(os.path.basename(video_key))[0]}.json"
    print(f"Uploading results to {output_bucket}/{output_key}...")
    s3.upload_file(local_json_path, output_bucket, output_key)
    print("Upload complete!")
    
    # Cleanup
    os.remove(local_video_path)
    os.remove(local_json_path)
    
    print(f"✓ Processing complete! Results: s3://{output_bucket}/{output_key}")

def poll_sqs_queue(queue_url, input_bucket, output_bucket):
    """
    Poll SQS queue for video processing jobs.
    """
    sqs = boto3.client('sqs')
    
    print(f"Starting SQS polling from queue: {queue_url}")
    print(f"Input bucket: {input_bucket}")
    print(f"Output bucket: {output_bucket}")
    
    while True:
        # Poll for messages
        response = sqs.receive_message(
            QueueUrl=queue_url,
            MaxNumberOfMessages=1,
            WaitTimeSeconds=20  # Long polling
        )
        
        if 'Messages' not in response:
            print("No messages in queue, waiting...")
            continue
        
        for message in response['Messages']:
            try:
                # Parse S3 event notification
                body = json.loads(message['Body'])
                
                # Handle S3 test notification
                if 'Event' in body and body['Event'] == 's3:TestEvent':
                    print("Received S3 test event, deleting...")
                    sqs.delete_message(
                        QueueUrl=queue_url,
                        ReceiptHandle=message['ReceiptHandle']
                    )
                    continue
                
                # Extract S3 bucket and key from message
                if 'Records' in body:
                    for record in body['Records']:
                        bucket = record['s3']['bucket']['name']
                        key = record['s3']['object']['key']
                        
                        print(f"\n{'='*60}")
                        print(f"Processing video: {key}")
                        print(f"{'='*60}\n")
                        
                        # Process the video
                        process_from_s3(bucket, key, output_bucket)
                        
                        # Delete message from queue
                        sqs.delete_message(
                            QueueUrl=queue_url,
                            ReceiptHandle=message['ReceiptHandle']
                        )
                        print("Message deleted from queue\n")
                
            except Exception as e:
                print(f"Error processing message: {e}")
                # Don't delete message on error - it will be retried

if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "poll":
        # SQS polling mode: python process_video.py poll <queue_url> <output_bucket>
        queue_url = sys.argv[2]
        output_bucket = sys.argv[3]
        poll_sqs_queue(queue_url, "video-input-gvill005-devops", output_bucket)
    elif len(sys.argv) == 4:
        # S3 mode: python process_video.py <input_bucket> <video_key> <output_bucket>
        input_bucket = sys.argv[1]
        video_key = sys.argv[2]
        output_bucket = sys.argv[3]
        process_from_s3(input_bucket, video_key, output_bucket)
    elif len(sys.argv) == 3:
        # Local mode: python process_video.py <video_file> <output_json>
        video_file = sys.argv[1]
        output_file = sys.argv[2]
        process_video_to_json(video_file, output_file, confidence_threshold=0.5)
    else:
        print("Usage:")
        print("  SQS poll mode: python process_video.py poll <queue_url> <output_bucket>")
        print("  S3 mode:       python process_video.py <input_bucket> <video_key> <output_bucket>")
        print("  Local mode:    python process_video.py <video_file> <output_json>")
        sys.exit(1)