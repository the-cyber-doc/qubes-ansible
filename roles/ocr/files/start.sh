#!/bin/bash -f

cd /home/user/Documents/local-llm-pdf-ocr
source bin/activate
uv run local-llm-pdf-ocr-server --port 8000
