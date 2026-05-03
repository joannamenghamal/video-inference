# Video Inference Pipeline

A fully serverless video analysis pipeline that uses **YOLO** for real-time object detection and **Amazon Bedrock** for natural language summaries. Includes a chat UI with natural language querying of processed results.

---

## Architecture

```
Upload .mp4
    │
    ▼
┌─────────────────┐
│   S3 (input)    │  video-input-{id}
└────────┬────────┘
         │ S3 Event Trigger
         ▼
┌─────────────────┐
│  AWS Lambda     │  video-processor (container image)
│                 │
│  1. YOLO v8     │  ← detects people, cars, trucks, etc. per frame
│  2. Aggregate   │  ← avg/peak counts across all frames
│  3. Bedrock     │  ← Claude Haiku 4.5 writes natural language summary
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│   S3 (output)   │  json-output-{id}/results/{video}.json
└─────────────────┘

Chat UI Flow
    │
    ▼
┌─────────────────┐
│  AWS Cognito    │  User authentication
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  S3 Website     │  chat-frontend-{id} (static HTML)
└────────┬────────┘
         │ fetch POST /chat
         ▼
┌─────────────────┐
│  API Gateway    │  HTTP API
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│  Chat Lambda    │  Reads all S3 JSON files
│                 │  Sends to Bedrock for synthesis
│  Amazon Bedrock │  ← Claude Haiku 4.5 generates responses
└─────────────────┘
```

---

## Live Demo

| Resource | URL |
|---|---|
| Chat UI | http://chat-frontend-72708bd7.s3-website-us-west-2.amazonaws.com |
| Chat API | https://7f8boyvvs3.execute-api.us-west-2.amazonaws.com/chat |

---

## Project Structure

```
.
├── Dockerfile              # Lambda container image (YOLO pipeline)
├── lambda_handler.py       # Video processor Lambda handler
├── process_video.py        # YOLO inference + S3 upload logic
├── chat_lambda.py          # Chat Lambda (reads S3, calls Bedrock)
├── requirements.txt        # Python dependencies
├── templates/
│   └── index.html          # Chat UI (served via S3 static website)
└── terraform/
    └── main.tf             # All AWS infrastructure as code
```

---

## How It Works

### 1. Video Processing Pipeline

Upload a `.mp4` to the S3 input bucket. This triggers the `video-processor` Lambda automatically via S3 event notification.

The Lambda:
1. Downloads the video to `/tmp`
2. Runs **YOLOv8n** on every frame — detecting people, cars, trucks, buses, bicycles, traffic lights, etc.
3. Aggregates detections across all frames (avg per frame, peak counts)
4. Sends the aggregated stats to **Amazon Bedrock** (Claude Haiku 4.5) for a natural language summary focused on traffic patterns, pedestrian safety, and AV fleet navigation recommendations
5. Saves the full result JSON to the S3 output bucket

**Output JSON format:**
```json
{
  "summary_stats": {
    "total_frames": 1123,
    "avg_people_per_frame": 1.99,
    "avg_cars_per_frame": 4.15,
    "peak_people_in_frame": 9
  },
  "bedrock_summary": "The footage shows moderate traffic with...",
  "raw_data": { "frames": [...] }
}
```

### 2. Chat Interface with Authentication

The chat interface provides natural language querying of processed video analysis results. 

**Flow:**
1. Users authenticate through **AWS Cognito** (manages credentials and access control)
2. After authentication, users access the S3-hosted static website
3. When a user submits a question, it's sent via API Gateway to the Chat Lambda
4. Chat Lambda reads all processed JSON files from the S3 output bucket
5. Lambda sends the user's question and complete analysis data to **Amazon Bedrock**
6. Bedrock (Claude Haiku 4.5) synthesizes information across all videos to generate natural language responses

This enables comparative queries like:
- *"Which video had the highest pedestrian activity?"*
- *"Compare traffic density across all videos"*
- *"Summarize the traffic patterns in short_test_footage"*

No manual JSON parsing required — Bedrock handles synthesis automatically.

---

## CI/CD Pipeline

Automated deployment using **GitHub Actions**:

**Workflow:**
1. Triggers on code changes to main branch (`lambda_handler.py`, `process_video.py`, `requirements.txt`, `Dockerfile`)
2. Builds Docker image for `linux/amd64` platform
3. Pushes to Amazon ECR
4. Updates Lambda function with new image

**Benefits:**
- Eliminates manual deployment steps
- Ensures consistent, repeatable deployments
- Can also be triggered manually via GitHub Actions interface

After initial Terraform setup, no manual Docker commands needed — just `git push`!

---

## Tech Stack

| Layer | Technology |
|---|---|
| Object detection | YOLOv8n (Ultralytics) |
| Language model | Amazon Bedrock — Claude Haiku 4.5 (`us.anthropic.claude-haiku-4-5-20251001-v1:0`) |
| Video pipeline | AWS Lambda (container image, ECR) |
| Chat backend | AWS Lambda (Python zip) + API Gateway HTTP API |
| Authentication | AWS Cognito |
| Frontend | S3 static website |
| Infrastructure | Terraform |
| CI/CD | GitHub Actions, Amazon ECR |
| Storage | S3 (input video, output JSON) |
| Logs | CloudWatch |

---

## Deploying From Scratch

You need AWS credentials configured and Terraform installed.

```bash
# 1. Build and push the YOLO container image
aws ecr get-login-password --region us-west-2 | \
  docker login --username AWS --password-stdin <account_id>.dkr.ecr.us-west-2.amazonaws.com

docker buildx build \
  --platform linux/amd64 \
  --provenance=false \
  --push \
  -t <account_id>.dkr.ecr.us-west-2.amazonaws.com/video-processor:v1 \
  .

# 2. Deploy all infrastructure
cd terraform
terraform init
terraform apply

# 3. Update Lambda to use the pushed image
aws lambda update-function-code \
  --function-name video-processor \
  --image-uri <account_id>.dkr.ecr.us-west-2.amazonaws.com/video-processor:v1 \
  --region us-west-2
```

After `terraform apply`, the outputs show your live URLs:
```
chat_url        = "http://chat-frontend-....s3-website-us-west-2.amazonaws.com"
chat_api_endpoint = "https://....execute-api.us-west-2.amazonaws.com/chat"
input_bucket    = "video-input-..."
output_bucket   = "json-output-..."
```

### Testing the pipeline

```bash
# Upload a video to trigger processing
aws s3 cp your_video.mp4 s3://<input_bucket>/your_video.mp4 --region us-west-2

# Watch logs live
aws logs tail /aws/lambda/video-processor --follow --region us-west-2

# Download the result
aws s3 cp s3://<output_bucket>/results/your_video.json - | python3 -m json.tool
```

### Testing the chat API

```bash
curl -s -X POST "<chat_api_endpoint>" \
  -H "Content-Type: application/json" \
  -d '{"conversation":[{"role":"user","content":[{"type":"text","text":"Which video had the highest pedestrian activity?"}]}]}' \
  | python3 -m json.tool
```

---

## Challenges & Solutions

### Docker Image Size
- **Problem:** 8GB disk too small for 17GB image
- **Solution:** Increased to 20GB EBS volumes, optimized image layers

### AI Model Compatibility
- **Problem:** 14 Docker iterations required; legacy Bedrock model IDs deprecated, direct model IDs inactive in us-west-2
- **Solution:** Switched to cross-region inference profiles (`us.anthropic.claude-haiku-4-5-20251001-v1:0`) and submitted use case details for Anthropic model access

### Team Coordination
- **Problem:** Simultaneous development prior to CI/CD integration
- **Solution:** Clear communication + Git workflows

### Cost Management
- **Problem:** EC2 instances expensive to scale
- **Solution:** Lambda functions (serverless, pay-per-execution only)

---

## Notes

- The YOLO model weights (`yolov8n.pt`) are baked into the Docker image at build time — Lambda's filesystem is read-only at runtime
- The Docker image must be built with `--platform linux/amd64` and `--provenance=false` (required for Lambda container images from Apple Silicon)
- Terraform state is local — if teammates redeploy, they get separate AWS resources with different bucket name suffixes
- S3 event notifications automatically trigger Lambda when videos are uploaded — no polling required