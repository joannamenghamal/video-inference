# Chat agent Lambda — serves the agentic chat API for the video inference pipeline.
# Triggered via API Gateway POST /chat. Uses Amazon Bedrock (Nova Lite) with tool use
# to answer questions about YOLO analysis results stored in S3.
# Deploy with: cd terraform && terraform apply

import json
import os
import boto3

OUTPUT_BUCKET = os.environ["OUTPUT_BUCKET"]  # injected by Terraform via Lambda env var
BEDROCK_REGION = "us-west-2"
MODEL_ID = "us.amazon.nova-lite-v1:0"

s3 = boto3.client("s3")
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

# ── Tool definitions (Bedrock Converse API format) ────────────────────────────

TOOLS = [
    {
        "toolSpec": {
            "name": "list_processed_videos",
            "description": "List all videos that have been analyzed by the pipeline.",
            "inputSchema": {"json": {"type": "object", "properties": {}, "required": []}},
        }
    },
    {
        "toolSpec": {
            "name": "get_analysis",
            "description": (
                "Fetch the full analysis result for a specific video, "
                "including YOLO detection stats and the Bedrock summary."
            ),
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {
                        "video_name": {
                            "type": "string",
                            "description": "Filename without extension, e.g. 'short_test_footage'",
                        }
                    },
                    "required": ["video_name"],
                }
            },
        }
    },
    {
        "toolSpec": {
            "name": "compare_analyses",
            "description": "Compare the detection statistics of two processed videos side by side.",
            "inputSchema": {
                "json": {
                    "type": "object",
                    "properties": {
                        "video_a": {"type": "string", "description": "First video name (no extension)"},
                        "video_b": {"type": "string", "description": "Second video name (no extension)"},
                    },
                    "required": ["video_a", "video_b"],
                }
            },
        }
    },
]

# Load the agent's personality/instructions from SYSTEM_PROMPT.md — edit that file to change behaviour
_prompt_path = os.path.join(os.path.dirname(__file__), "SYSTEM_PROMPT.md")
with open(_prompt_path) as _f:
    SYSTEM_PROMPT = [{"text": _f.read()}]

# ── Tool implementations ───────────────────────────────────────────────────────

def list_processed_videos():
    resp = s3.list_objects_v2(Bucket=OUTPUT_BUCKET, Prefix="results/")
    items = resp.get("Contents", [])
    if not items:
        return {"videos": [], "message": "No videos have been processed yet."}
    names = [obj["Key"].replace("results/", "").replace(".json", "") for obj in items]
    return {"videos": names}


def get_analysis(video_name):
    key = f"results/{video_name}.json"
    try:
        obj = s3.get_object(Bucket=OUTPUT_BUCKET, Key=key)
        data = json.loads(obj["Body"].read())
        return {
            "video": video_name,
            "summary_stats": data.get("summary_stats"),
            "bedrock_summary": data.get("bedrock_summary"),
        }
    except Exception as e:
        return {"error": str(e)}


def compare_analyses(video_a, video_b):
    return {"video_a": get_analysis(video_a), "video_b": get_analysis(video_b)}


def dispatch_tool(name, inputs):
    if name == "list_processed_videos":
        return list_processed_videos()
    elif name == "get_analysis":
        return get_analysis(inputs["video_name"])
    elif name == "compare_analyses":
        return compare_analyses(inputs["video_a"], inputs["video_b"])
    return {"error": f"Unknown tool: {name}"}


# ── Agent loop (Bedrock Converse API) ─────────────────────────────────────────

def run_agent(conversation):
    # Convert frontend conversation format to Converse API format
    messages = []
    for msg in conversation:
        role = msg["role"]
        content = msg["content"]
        if isinstance(content, list):
            converse_content = []
            for block in content:
                if block.get("type") == "text":
                    converse_content.append({"text": block["text"]})
            messages.append({"role": role, "content": converse_content})
        else:
            messages.append({"role": role, "content": [{"text": str(content)}]})

    while True:
        resp = bedrock.converse(
            modelId=MODEL_ID,
            system=SYSTEM_PROMPT,
            messages=messages,
            toolConfig={"tools": TOOLS},
            inferenceConfig={"maxTokens": 1024},
        )

        stop_reason = resp.get("stopReason")
        out_msg = resp["output"]["message"]
        messages.append(out_msg)

        if stop_reason == "end_turn":
            for block in out_msg.get("content", []):
                if "text" in block:
                    return block["text"]
            return ""

        if stop_reason == "tool_use":
            tool_results = []
            for block in out_msg.get("content", []):
                if "toolUse" in block:
                    tool = block["toolUse"]
                    result = dispatch_tool(tool["name"], tool.get("input", {}))
                    tool_results.append({
                        "toolResult": {
                            "toolUseId": tool["toolUseId"],
                            "content": [{"text": json.dumps(result)}],
                        }
                    })
            messages.append({"role": "user", "content": tool_results})
        else:
            break

    return "Unexpected stop reason."


# ── Lambda handler ────────────────────────────────────────────────────────────

def lambda_handler(event, _context):
    headers = {"Content-Type": "application/json", "Access-Control-Allow-Origin": "*"}
    try:
        body = json.loads(event.get("body") or "{}")
        conversation = body.get("conversation", [])
        reply = run_agent(conversation)
        return {"statusCode": 200, "headers": headers, "body": json.dumps({"reply": reply})}
    except Exception as e:
        return {"statusCode": 500, "headers": headers, "body": json.dumps({"error": str(e)})}
