# Use AWS Lambda Python base image
FROM public.ecr.aws/lambda/python:3.11

# Install system dependencies
RUN yum install -y \
    mesa-libGL \
    glib2 \
    libgomp \
    gcc \
    gcc-c++ \
    make \
    && yum clean all

# Copy requirements and install
COPY requirements.txt .
RUN pip install --upgrade pip && \
    pip install --no-cache-dir --only-binary :all: -r requirements.txt

# Copy application code
COPY process_video.py ${LAMBDA_TASK_ROOT}/
COPY lambda_handler.py ${LAMBDA_TASK_ROOT}/

# Set handler (use Lambda's default entrypoint)
CMD ["lambda_handler.lambda_handler"]