FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home canvas && mkdir /data && chown canvas /data
COPY server.py .
USER canvas
ENV PYTHONUNBUFFERED=1 CANVAS_DB=/data/canvas.sqlite3
EXPOSE 8765
CMD ["python", "server.py"]
