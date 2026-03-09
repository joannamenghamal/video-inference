FROM python:3.11-slim

# Install system dependencies for OpenCV
RUN apt-get update && apt-get install -y \
    libgl1 \
    libglib2.0-0 \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy requirements and install
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY process_video.py .
COPY short_test_footage.mp4 .

# Pre-download YOLO model to reduce runtime
RUN python -c "from ultralytics import YOLO; YOLO('yolov8n.pt')"

# Default command
CMD ["python", "process_video.py"]