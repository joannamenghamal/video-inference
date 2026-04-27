import json
import boto3
from flask import Flask, render_template, request, jsonify

app = Flask(__name__)

OUTPUT_BUCKET = "json-output-72708bd7"
REGION = "us-west-2"
BEDROCK_REGION = "us-east-1"
MODEL_ID = "anthropic.claude-3-haiku-20240307-v1:0"

s3 = boto3.client("s3", region_name=REGION)
bedrock = boto3.client("bedrock-runtime", region_name=BEDROCK_REGION)

# ── Tool definitions ──────────────────────────────────────────────────────────

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

# ── Tool implementations ───────────────────────────────────────────────────────

def list_processed_videos():
    resp = s3.list_objects_v2(Bucket=OUTPUT_BUCKET, Prefix="results/")
    items = resp.get("Contents", [])
    if not items:
        return {"videos": [], "message": "No videos have been processed yet."}
    names = [obj["Key"].replace("results/", "").replace(".json", "") for obj in items]
    return {"videos": names}


def get_analysis(video_name: str):
    key = f"results/{video_name}.json"
    try:
        obj = s3.get_object(Bucket=OUTPUT_BUCKET, Key=key)
        data = json.loads(obj["Body"].read())
        return {
            "video": video_name,
            "summary_stats": data.get("summary_stats"),
            "bedrock_summary": data.get("bedrock_summary"),
        }
    except s3.exceptions.NoSuchKey:
        return {"error": f"No analysis found for '{video_name}'. Run the pipeline first."}
    except Exception as e:
        return {"error": str(e)}


def compare_analyses(video_a: str, video_b: str):
    a = get_analysis(video_a)
    b = get_analysis(video_b)
    return {"video_a": a, "video_b": b}


def dispatch_tool(name: str, inputs: dict):
    if name == "list_processed_videos":
        return list_processed_videos()
    elif name == "get_analysis":
        return get_analysis(inputs["video_name"])
    elif name == "compare_analyses":
        return compare_analyses(inputs["video_a"], inputs["video_b"])
    return {"error": f"Unknown tool: {name}"}


# ── Agent loop ────────────────────────────────────────────────────────────────

SYSTEM_PROMPT = """You are a traffic analysis assistant for a video inference pipeline.
The pipeline uses YOLO to detect objects in traffic footage, then summarises findings with Bedrock.
You have tools to list processed videos, fetch detailed analysis results, and compare videos.
Be concise, insightful, and highlight actionable observations about traffic patterns and pedestrian activity.
When presenting stats, use clear formatting."""


def run_agent(conversation: list[dict]) -> str:
    messages = conversation.copy()

    while True:
        resp = bedrock.invoke_model(
            modelId=MODEL_ID,
            body=json.dumps({
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 1024,
                "system": SYSTEM_PROMPT,
                "tools": TOOLS,
                "messages": messages,
            }),
        )
        body = json.loads(resp["body"].read())
        stop_reason = body.get("stop_reason")
        content = body.get("content", [])

        # Add assistant turn to messages
        messages.append({"role": "assistant", "content": content})

        if stop_reason == "end_turn":
            # Return the text response
            for block in content:
                if block.get("type") == "text":
                    return block["text"]
            return ""

        if stop_reason == "tool_use":
            tool_results = []
            for block in content:
                if block.get("type") == "tool_use":
                    result = dispatch_tool(block["name"], block.get("input", {}))
                    tool_results.append({
                        "type": "tool_result",
                        "tool_use_id": block["id"],
                        "content": json.dumps(result),
                    })
            messages.append({"role": "user", "content": tool_results})
        else:
            break

    return "Unexpected stop reason."


# ── Routes ────────────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/chat", methods=["POST"])
def chat():
    data = request.json
    conversation = data.get("conversation", [])
    try:
        reply = run_agent(conversation)
        return jsonify({"reply": reply})
    except Exception as e:
        return jsonify({"error": str(e)}), 500


if __name__ == "__main__":
    app.run(debug=True, port=5001)
