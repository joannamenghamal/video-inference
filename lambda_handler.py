import json
import os
import boto3
from process_video import process_video_to_json

def lambda_handler(event, context):
    """
    AWS Lambda handler function.
    Triggered by S3 upload events.
    """
    s3 = boto3.client('s3')
    
    # Get bucket and key from S3 event
    record = event['Records'][0]
    bucket = record['s3']['bucket']['name']
    key = record['s3']['object']['key']
    
    print(f"Processing video: {key} from bucket: {bucket}")
    
    # Download video from S3
    video_path = f'/tmp/{os.path.basename(key)}'
    s3.download_file(bucket, key, video_path)
    print(f"Downloaded to {video_path}")
    
    # Process video
    output_path = f'/tmp/output.json'
    process_video_to_json(video_path, output_path, confidence_threshold=0.5)
    print("Processing complete")
    
    # Upload JSON to output bucket
    output_bucket = os.environ['OUTPUT_BUCKET']
    output_key = f"results/{os.path.splitext(os.path.basename(key))[0]}.json"
    s3.upload_file(output_path, output_bucket, output_key)
    print(f"Uploaded to s3://{output_bucket}/{output_key}")
    
    # Cleanup
    os.remove(video_path)
    os.remove(output_path)
    
    return {
        'statusCode': 200,
        'body': json.dumps(f'Processed {key} successfully')
    }