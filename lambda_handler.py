import json
import os
import boto3
from process_video import process_video_to_json
def summarize_detections(yolo_results):
    total_frames = 0
    total_people = 0
    total_cars = 0
    max_people = 0

    # Normalize structure
    frames = yolo_results
    if isinstance(yolo_results, dict):
        frames = yolo_results.get("frames", [])

    for frame in frames:
        total_frames += 1

        detections = frame.get("detections", [])
        people = sum(1 for d in detections if d.get("class") == "person")
        cars = sum(1 for d in detections if d.get("class") == "car")

        total_people += people
        total_cars += cars
        max_people = max(max_people, people)

    return {
        "total_frames": total_frames,
        "avg_people_per_frame": total_people / total_frames if total_frames else 0,
        "avg_cars_per_frame": total_cars / total_frames if total_frames else 0,
        "peak_people_in_frame": max_people
    }

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
    
    # Read YOLO output file

    with open(output_path, 'r') as f:
        yolo_results = json.load(f)
    
# call bedrock
    bedrock = boto3.client('bedrock-runtime', region_name='us-west-2')

    aggregated = summarize_detections(yolo_results)

    response = bedrock.invoke_model(
        modelId='us.anthropic.claude-3-haiku-20240307-v1:0',
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 512,
            "messages": [
                {
                    "role": "user",
                    "content": f"""Summarize this traffic analysis:

{json.dumps(aggregated)}

Focus on:
- traffic patterns
- pedestrian activity
- notable trends"""
                }
            ]
        })
    )

    # Extract the summary from the response
    bedrock_response = json.loads(response['body'].read())
    summary = bedrock_response['content'][0]['text']
    print("BEDROCK SUMMARY:")
    print(summary)

    # Add summary to output
    final_output = {
        "summary_stats": aggregated,
        "bedrock_summary": summary,
        "raw_data": yolo_results
    }

    with open(output_path, 'w') as f:
        json.dump(final_output, f, indent=2)
    # # call bedrock
    # bedrock = boto3.client('bedrock-runtime', region_name='us-west-2')
    # aggregated = summarize_detections(yolo_results)

    # response = bedrock.invoke_model(
    #     modelId='anthropic.claude-sonnet-4-6',
    #     body=json.dumps({
    #         "anthropic_version": "bedrock-2023-05-31",
    #         "max_tokens": 512,
    #         "messages": [
    #             {
    #                 "role": "user",
    #                 "content": f"""
    #                 Summarize this traffic analysis:

    #                 {json.dumps(aggregated)}

    #                 Focus on:
    #                 - traffic patterns
    #                 - pedestrian activity
    #                 - notable trends
    #                 """
    #             }
    #         ]
    #     })
    # )

    # # Extract the summary from the response
    # bedrock_response = json.loads(response['body'].read())
    # summary = bedrock_response['content'][0]['text']
    # print("BEDROCK SUMMARY:")
    # print(summary)

    # # Add summary to output
    # final_output = {
    # "summary_stats": aggregated,
    # "bedrock_summary": summary,
    # "raw_data": yolo_results
    # }

    # with open(output_path, 'w') as f:
    #     json.dump(final_output, f, indent=2)


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

if __name__ == "__main__":
    # Simulate local run
    video_file = "short_test_footage.mp4"
    output_file = "output.json"

    process_video_to_json(video_file, output_file)

    with open(output_file, 'r') as f:
        yolo_results = json.load(f)

    aggregated = summarize_detections(yolo_results)

    bedrock = boto3.client('bedrock-runtime', region_name='us-east-1')

    response = bedrock.invoke_model(
        modelId='anthropic.claude-3-haiku-20240307-v1:0',
        body=json.dumps({
            "anthropic_version": "bedrock-2023-05-31",
            "max_tokens": 512,
            "messages": [
                {
                    "role": "user",
                    "content": f"Summarize this traffic analysis: {json.dumps(aggregated)}"
                }
            ]
        })
    )

    raw_body = response['body'].read()
    print("RAW BEDROCK BODY:", raw_body)

    bedrock_response = json.loads(raw_body)
    print("PARSED BEDROCK RESPONSE:", bedrock_response)
    summary = bedrock_response['content'][0]['text']

    print("\n=== BEDROCK SUMMARY ===")
    print(summary)
